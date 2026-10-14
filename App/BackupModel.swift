import SwiftUI
import Photos
import UIKit
import LunaSyncCore
import LunaSyncPhotoKit

@MainActor
final class BackupModel: ObservableObject {
    @Published var archive: ArchiveMetadata?
    @Published var selectedSource: UUID?
    @Published var busy = false
    @Published var status = "连接硬盘，选择备份目录"
    @Published var currentFile = ""
    @Published var currentBytes: UInt64 = 0
    @Published var total = 0
    @Published var completed = 0
    @Published var issues: [String: String] = [:]
    @Published var cloudAssets: Set<String> = []
    @Published var history: [SessionSummary] = []
    @Published var notice: String?
    @Published var limitedAccess = false
    @Published var directoryName = "尚未选择"
    @Published var allowNetwork = UserDefaults.standard.bool(forKey: "allowNetwork") {
        didSet { UserDefaults.standard.set(allowNetwork, forKey: "allowNetwork") }
    }
    @Published var includeVideos = UserDefaults.standard.object(forKey: "includeVideos") as? Bool ?? true {
        didSet { UserDefaults.standard.set(includeVideos, forKey: "includeVideos") }
    }
    private var access: DirectoryAccess?
    private var coordinator: BackupCoordinator?
    private var catalog: LocalCatalog?
    private var operation: Task<Void, Never>?
    private var requiresAssociation = false
    private var planned = false

    func restore() async {
        do {
            let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            catalog = try LocalCatalog(url: support.appendingPathComponent("catalog.sqlite"))
            history = try await catalog?.history() ?? []
        } catch { notice = error.localizedDescription }
        if let bookmark = UserDefaults.standard.data(forKey: "directoryBookmark") {
            do { try await open(DirectoryAccess(bookmark: bookmark), initialize: false) }
            catch { status = "请重新选择硬盘目录"; notice = error.localizedDescription }
        }
        refreshAuthorization()
    }

    func selectDirectory(_ url: URL) {
        guard !busy else { return }
        busy = true
        Task {
            defer { busy = false }
            do { try await open(DirectoryAccess(url: url), initialize: true) }
            catch { notice = error.localizedDescription }
        }
    }

    private func open(_ scope: DirectoryAccess, initialize: Bool) async throws {
        let selected = scope.url
        let isRoot = FileManager.default.fileExists(atPath: selected.appendingPathComponent("archive.json").path)
        let root = isRoot || selected.lastPathComponent == "LunaSync" ? selected : selected.appendingPathComponent("LunaSync", isDirectory: true)
        let worker = try await Task.detached(priority: .userInitiated) {
            BackupCoordinator(store: try ArchiveStore(root: root, create: initialize), source: PhotoKitSource())
        }.value
        let metadata = await worker.metadata()
        let bookmark = try scope.bookmark()
        // Swap the scope only after the new archive was opened successfully.
        coordinator = worker; access = scope; archive = metadata; directoryName = root.lastPathComponent
        UserDefaults.standard.set(bookmark, forKey: "directoryBookmark")
        if let saved = UserDefaults.standard.string(forKey: bindingKey(metadata.archiveID)),
           let id = UUID(uuidString: saved), metadata.sources.contains(where: { $0.id == id }) {
            selectedSource = id; requiresAssociation = false
        } else { selectedSource = nil; requiresAssociation = true }
        if metadata.sources.isEmpty { try await addSource() }
        status = selectedSource == nil ? "请选择原照片库，或建立新照片库" : "可以开始增量备份"
        await refreshCache()
    }

    func chooseSource(_ id: UUID) {
        guard !busy else { return }
        selectedSource = id; requiresAssociation = true
        status = "首次继续原照片库时，将核对资产标识"
    }

    func createSource() {
        guard !busy else { return }
        busy = true
        Task {
            defer { busy = false }
            do { try await addSource() } catch { notice = error.localizedDescription }
        }
    }
    private func addSource() async throws {
        guard let coordinator else { return }
        let source = try await coordinator.addSource(name: "\(UIDevice.current.name) · \(Date().formatted(date: .numeric, time: .shortened))")
        archive = await coordinator.metadata(); selectedSource = source.id; requiresAssociation = false
        if let archive { UserDefaults.standard.set(source.id.uuidString, forKey: bindingKey(archive.archiveID)) }
        status = "新照片库已建立，可以开始备份"
    }

    func start() {
        guard !busy, let coordinator, let sourceID = selectedSource, let archive else { return }
        busy = true; planned = false; total = 0; completed = 0; issues = [:]; cloudAssets = []; currentBytes = 0
        let started = Date(), network = allowNetwork, videos = includeVideos, check = requiresAssociation
        UIApplication.shared.isIdleTimerDisabled = true
        operation = Task {
            defer { busy = false; operation = nil; UIApplication.shared.isIdleTimerDisabled = false }
            let authorization = await PhotoKitSource.authorization()
            refreshAuthorization()
            guard authorization == .authorized || authorization == .limited else {
                status = "请在系统设置中允许访问照片"; return
            }
            let (stream, continuation) = AsyncStream<BackupEvent>.makeStream()
            let consumer = Task { for await event in stream { receive(event) } }
            var outcome = "已完成"
            do {
                try await coordinator.run(sourceID: sourceID, includeVideos: videos, allowNetwork: network,
                                          requireAssociationCheck: check) { continuation.yield($0) }
            } catch {
                outcome = error is CancellationError ? "已暂停" : "已停止"
                if !(error is CancellationError) { notice = error.localizedDescription }
            }
            continuation.finish(); await consumer.value
            status = outcome == "已完成" ? (issues.isEmpty ? "本轮备份完成" : "本轮结束，仍有 \(issues.count) 张待处理") : outcome
            currentFile = ""
            if planned {
                requiresAssociation = false
                UserDefaults.standard.set(sourceID.uuidString, forKey: bindingKey(archive.archiveID))
            }
            do {
                try await catalog?.save(SessionSummary(archiveID: archive.archiveID, startedAt: started,
                    status: status, total: total, completed: completed, issues: issues))
                history = try await catalog?.history() ?? []
            } catch { notice = "备份状态已保存在硬盘；本地历史保存失败：\(error.localizedDescription)" }
            await refreshCache()
        }
    }

    func pause() { operation?.cancel(); if busy { status = "正在暂停，等待当前读写收尾…" } }

    func verify() {
        guard !busy, let coordinator else { return }
        busy = true; status = "正在完整校验"; currentFile = ""
        UIApplication.shared.isIdleTimerDisabled = true
        operation = Task {
            defer { busy = false; operation = nil; UIApplication.shared.isIdleTimerDisabled = false }
            let (stream, continuation) = AsyncStream<Int>.makeStream()
            let consumer = Task { for await count in stream { status = "正在校验，已检查 \(count) 个文件" } }
            do {
                let result = try await coordinator.verify { continuation.yield($0) }
                continuation.finish(); await consumer.value
                status = "校验完成：\(result.checked) 个文件，\(result.issues.count) 个问题"
                issues = Dictionary(uniqueKeysWithValues: result.issues.enumerated().map { ("校验 \($0.offset+1)", $0.element) })
            } catch {
                continuation.finish(); await consumer.value
                status = error is CancellationError ? "校验已暂停" : "校验已停止"
                if !(error is CancellationError) { notice = error.localizedDescription }
            }
            await refreshCache()
        }
    }

    func refreshAuthorization() { limitedAccess = PHPhotoLibrary.authorizationStatus(for: .readWrite) == .limited }
    private func receive(_ event: BackupEvent) {
        switch event {
        case .scanning: status = "正在扫描照片库"
        case let .planned(total, completed): self.total = total; self.completed = completed; planned = true
        case let .transferring(_, filename, bytes): status = "正在备份"; currentFile = filename; currentBytes = bytes
        case .verifying(let filename): status = "正在读回校验"; currentFile = filename
        case .completed(let id): completed += 1; issues.removeValue(forKey: id); cloudAssets.remove(id)
        case let .failed(id, message, cloudOnly): issues[id] = message; if cloudOnly { cloudAssets.insert(id) }
        case .paused: status = "已暂停"
        case .finished: break
        case .recoveryWarning(let warning): notice = warning
        }
    }
    private func refreshCache() async {
        guard let coordinator, let archive else { return }
        do {
            let snapshot = try await coordinator.snapshot()
            try await catalog?.rebuild(archiveID: archive.archiveID, records: snapshot.records)
            if !snapshot.issues.isEmpty { notice = "\(snapshot.issues.count) 份资产记录损坏，已恢复其余记录；损坏部分需人工检查。" }
        }
        catch { notice = "本地索引未能重建：\(error.localizedDescription)" }
    }
    private func bindingKey(_ archiveID: UUID) -> String { "sourceBinding.\(archiveID.uuidString)" }
}
