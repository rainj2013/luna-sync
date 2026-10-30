import SwiftUI
import Photos
import UIKit
import LunaSyncCore
import LunaSyncPhotoKit

enum PhotoDateFilter: String, CaseIterable, Identifiable {
    case all, today, last7Days, last30Days, thisYear, custom
    var id: Self { self }
    var title: String {
        switch self {
        case .all: L10n.tr("copy.f7e5f13b")
        case .today: L10n.tr("copy.a848765c")
        case .last7Days: L10n.tr("copy.56fd2708")
        case .last30Days: L10n.tr("copy.f274c882")
        case .thisYear: L10n.tr("copy.dd50a8cb")
        case .custom: L10n.tr("copy.6a354f44")
        }
    }
}

@MainActor
final class BackupModel: ObservableObject {
    enum RunState { case idle, running, paused, completed, failed }
    @Published var runState: RunState = .idle
    #if DEBUG
    private let startupStartedAt = Date()
    private(set) var startupUIReadySeconds: TimeInterval = 0
    #endif
    @Published var restoring = true
    var hasSavedDestination: Bool { UserDefaults.standard.data(forKey: "directoryBookmark") != nil }
    @Published var destinationNeedsReconnect = false
    @Published var requiresDestinationConfirmation = false
    @Published var connecting = false
    @Published var scanning = false
    @Published var preview: BackupPreview?
    @Published var archiveRecords: [AssetRecord] = []
    @Published var activePhotoID: String?
    @Published var isVerifying = false
    @Published var verification: VerificationResult?
    @Published var verificationDate: Date?
    @Published var availableBytes: Int64?
    @Published var archiveURL: URL?
    @Published var archiveMarkerURL: URL?
    @Published var authorization = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    @Published private(set) var storedCount = 0
    @Published private(set) var storedBytes: UInt64 = 0
    @Published private(set) var historyPhotoIDs: [UUID: String] = [:]
    var diskHistory: [SessionSummary] { history.filter { $0.archiveID == archive?.archiveID } }
    var destinationSummary: String {
        guard let archiveURL, archiveURL.standardizedFileURL != access?.url.standardizedFileURL else { return directoryName }
        return directoryName + "/" + archiveURL.lastPathComponent
    }
    @Published var archive: ArchiveMetadata?
    @Published var selectedSource: UUID?
    @Published var busy = false
    @Published var status = L10n.tr("copy.d6d98a17")
    @Published var currentFile = ""
    @Published var currentBytes: UInt64 = 0
    @Published var total = 0
    @Published var completed = 0
    @Published var initialCompleted = 0
    @Published var sessionPhotoIDs: [String] = []
    @Published var issues: [String: String] = [:]
    @Published var cloudAssets: Set<String> = []
    @Published var history: [SessionSummary] = []
    @Published var notice: String?
    @Published var limitedAccess = false
    @Published var directoryName = L10n.tr("copy.ef014917")
    @Published var dateFilter: PhotoDateFilter = .all
    @Published var selectedPhotoIDs: Set<String>?
    @Published var customStart = Calendar.autoupdatingCurrent.date(byAdding: .month, value: -1, to: Date()) ?? Date()
    @Published var customEnd = Date()
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
    private let backgroundSession = BackgroundBackupSession()
    @Published private(set) var backgroundBackupState: BackgroundBackupSession.State = .idle
    @Published private(set) var backgroundPauseReason: String?

    var transferInstructions: String {
        switch backgroundBackupState {
        case .continued: return L10n.tr("background.available")
        case .requesting: return L10n.tr("background.requesting")
        case .stopping: return L10n.tr("background.stopping")
        case .foregroundOnly: return L10n.tr("background.foreground")
        case .idle: return L10n.tr("design.transfer.body")
        }
    }

    func enteredBackground() {
        if busy && runState == .running && !isVerifying { backgroundSession.enteredBackground() }
    }
    func enteredForeground() { backgroundSession.enteredForeground() }
    func protectedDataBecameUnavailable() {
        guard busy else { return }
        backgroundPauseReason = L10n.tr("background.protected")
        pause()
    }
    private var requiresAssociation = false
    private var planned = false
    private var pendingDirectoryURL: URL?
    private var destinationRevision = 0

    func restore() async {
        do {
            let (cache, sessions) = try await Task.detached(priority: .userInitiated) {
                let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                let cache = try LocalCatalog(url: support.appendingPathComponent("catalog.sqlite"))
                return (cache, try await cache.history())
            }.value
            catalog = cache; history = sessions
        } catch { notice = error.localizedDescription }
        refreshAuthorization()
        // Render the app before waiting on external providers, record snapshots or cache rebuilds.
        #if DEBUG
        startupUIReadySeconds = Date().timeIntervalSince(startupStartedAt)
        #endif
        restoring = false
        await reconnectDirectory()
    }

    /// A saved external drive can be absent at launch. Keep its bookmark for retry
    /// and show an inline reconnect state instead of interrupting startup.
    func reconnectDirectory() async {
        guard !busy, !scanning, !connecting, let bookmark = UserDefaults.standard.data(forKey: "directoryBookmark") else { return }
        connecting = true
        defer { finishConnecting() }
        do {
            let scope = try await Task.detached(priority: .utility) { try DirectoryAccess(bookmark: bookmark) }.value
            try await open(scope, initialize: false)
        }
        catch {
            destinationNeedsReconnect = true
            preview = nil; availableBytes = nil
            status = L10n.tr("destination.unavailable.title")
        }
    }

    /// iOS has no general external-drive attach notification for document providers.
    /// Probe the authorized location while foregrounded; never create a new archive here.
    func refreshDestinationAvailability() async {
        guard !restoring, !busy, !scanning, !connecting else { return }
        let revision = destinationRevision
        if let archiveURL {
            let readable = await Task.detached(priority: .utility) {
                do {
                    let marker = archiveURL.appendingPathComponent(".luna-sync/archive.json")
                    let path = FileManager.default.fileExists(atPath: marker.path) ? marker : archiveURL.appendingPathComponent("archive.json")
                    let handle = try FileHandle(forReadingFrom: path)
                    defer { try? handle.close() }
                    return try handle.read(upToCount: 1)?.isEmpty == false
                } catch { return false }
            }.value
            guard revision == destinationRevision, !connecting, !busy, !scanning else { return }
            if readable {
                if destinationNeedsReconnect {
                    destinationNeedsReconnect = false
                    status = selectedSource == nil ? L10n.tr("copy.9eb7599e") : L10n.tr("copy.4f92a197")
                    await refreshCache()
                }
                return
            }
            if !readable {
                destinationNeedsReconnect = true
                preview = nil; availableBytes = nil
            }
        }
        await reconnectDirectory()
    }

    func selectDirectory(_ url: URL) {
        guard !busy, !scanning else { return }
        destinationRevision += 1
        if connecting { pendingDirectoryURL = url; return }
        connecting = true
        Task {
            defer { finishConnecting() }
            do {
                let scope = try await Task.detached(priority: .userInitiated) { try DirectoryAccess(url: url) }.value
                try await open(scope, initialize: true)
            }
            catch { notice = error.localizedDescription }
        }
    }

    private func finishConnecting() {
        connecting = false
        if let pendingDirectoryURL {
            self.pendingDirectoryURL = nil
            selectDirectory(pendingDirectoryURL)
        }
    }

    private func open(_ scope: DirectoryAccess, initialize: Bool) async throws {
        let prepared = try await Task.detached(priority: .userInitiated) {
            try withExtendedLifetime(scope) {
                let selected = scope.url
                let fm = FileManager.default
                let hasMarker = fm.fileExists(atPath: selected.appendingPathComponent("archive.json").path) ||
                    fm.fileExists(atPath: selected.appendingPathComponent(".luna-sync/archive.json").path)
                let oldRoot = selected.appendingPathComponent("LunaSync", isDirectory: true)
                let restoringOld = !initialize && !hasMarker && fm.fileExists(atPath: oldRoot.appendingPathComponent("archive.json").path)
                let root = restoringOld ? oldRoot : selected
                let store = try ArchiveStore(root: root, create: initialize)
                let metadata = store.metadata
                let marker = store.markerURL
                let worker = BackupCoordinator(store: store, source: PhotoKitSource())
                return (worker, metadata, root, try scope.bookmark(), DirectoryDisplayName.read(selected),
                        restoringOld, marker, Self.availableCapacity(at: root))
            }
        }.value
        let (worker, metadata, root, bookmark, displayName, restoringOldArchive, marker, capacity) = prepared
        let sameArchive = archive?.archiveID == metadata.archiveID
        coordinator = worker; access = scope; archive = metadata; directoryName = displayName
        destinationNeedsReconnect = false
        requiresDestinationConfirmation = restoringOldArchive
        archiveURL = root; preview = nil; verification = nil; verificationDate = nil
        archiveMarkerURL = marker
        if !sameArchive { runState = .idle }
        availableBytes = capacity
        UserDefaults.standard.set(bookmark, forKey: "directoryBookmark")
        if let saved = UserDefaults.standard.string(forKey: bindingKey(metadata.archiveID)),
           let id = UUID(uuidString: saved), metadata.sources.contains(where: { $0.id == id }) {
            selectedSource = id; requiresAssociation = false
        } else { selectedSource = nil; requiresAssociation = true }
        if metadata.sources.isEmpty { try await addSource() }
        status = selectedSource == nil ? L10n.tr("copy.9eb7599e") : L10n.tr("copy.4f92a197")
        await refreshCache()
    }

    func chooseSource(_ id: UUID) {
        guard !busy else { return }
        selectedSource = id; requiresAssociation = true
        status = L10n.tr("copy.2374a97b")
    }

    func createSource() async {
        guard !busy, !connecting else { return }
        busy = true
        defer { busy = false }
        do { try await addSource() } catch { notice = error.localizedDescription }
    }
    private func addSource() async throws {
        guard let coordinator else { return }
        let source = try await coordinator.addSource(name: "\(UIDevice.current.name) · \(Date().formatted(date: .numeric, time: .shortened))")
        archive = await coordinator.metadata(); selectedSource = source.id; requiresAssociation = false
        if let archive { UserDefaults.standard.set(source.id.uuidString, forKey: bindingKey(archive.archiveID)) }
        status = L10n.tr("copy.38274f2c")
    }

    func start() {
        guard !busy, !scanning, !connecting, !destinationNeedsReconnect, !requiresDestinationConfirmation, let coordinator, let sourceID = selectedSource, let archive else { return }
        runState = .running; isVerifying = false; backgroundPauseReason = nil
        busy = true; planned = false; total = 0; completed = 0; initialCompleted = 0; sessionPhotoIDs = []; issues = [:]; cloudAssets = []; currentBytes = 0
        let started = Date(), network = allowNetwork, videos = includeVideos, check = requiresAssociation
        let selection = backupSelection(at: started)
        UIApplication.shared.isIdleTimerDisabled = true
        backgroundSession.begin(work: { [self] in
            operation = Task {
                var succeeded = false
                defer {
                    backgroundSession.finish(success: succeeded)
                    busy = false; operation = nil; UIApplication.shared.isIdleTimerDisabled = false
                }
                let authorization = await PhotoKitSource.authorization()
                refreshAuthorization()
                guard authorization == .authorized || authorization == .limited else {
                    status = L10n.tr("copy.6c73c375"); runState = .failed; return
                }
                let (stream, continuation) = AsyncStream<BackupEvent>.makeStream()
                let consumer = Task { for await event in stream { receive(event) } }
                var outcome = L10n.tr("copy.00206a11")
                var finalState: RunState = .completed
                do {
                    try await coordinator.run(sourceID: sourceID, includeVideos: videos, allowNetwork: network,
                                              requireAssociationCheck: check, selection: selection) { continuation.yield($0) }
                } catch {
                    outcome = error is CancellationError ? L10n.tr("copy.4e8fd14b") : L10n.tr("copy.be0b6d2b")
                    finalState = error is CancellationError ? .paused : .failed
                    if !(error is CancellationError) { notice = error.localizedDescription }
                }
                continuation.finish(); await consumer.value
                status = finalState == .completed ? (issues.isEmpty ? L10n.tr("copy.af1f5a4b") : L10n.format("copy.2ea514b7", String(describing: issues.count))) : outcome
                currentFile = ""
                runState = finalState; preview = nil
                if planned {
                    requiresAssociation = false
                    UserDefaults.standard.set(sourceID.uuidString, forKey: bindingKey(archive.archiveID))
                }
                do {
                    try await catalog?.save(SessionSummary(archiveID: archive.archiveID, startedAt: started,
                        status: status, total: total, completed: completed, issues: issues))
                    history = try await catalog?.history() ?? []
                } catch { notice = L10n.format("copy.63b34838", String(describing: error.localizedDescription)) }
                await refreshCache()
                succeeded = finalState == .completed
            }
        }, pause: { [weak self] in
            guard let self else { return }
            self.backgroundPauseReason = L10n.tr("background.interrupted")
            self.pause()
        }, stateChanged: { [weak self] state in self?.backgroundBackupState = state })
    }

    func pause() {
        if backgroundSession.cancelPendingStart() {
            busy = false; runState = .paused
            UIApplication.shared.isIdleTimerDisabled = false
            status = L10n.tr("copy.4e8fd14b")
            return
        }
        operation?.cancel()
        if busy { status = L10n.tr("copy.f25ab250") }
    }

    func verify() {
        guard !busy, !scanning, !connecting, !destinationNeedsReconnect, let coordinator else { return }
        isVerifying = true; verification = nil
        busy = true; status = L10n.tr("copy.8b40ccdb"); currentFile = ""
        UIApplication.shared.isIdleTimerDisabled = true
        operation = Task {
            defer { busy = false; isVerifying = false; operation = nil; UIApplication.shared.isIdleTimerDisabled = false }
            let (stream, continuation) = AsyncStream<Int>.makeStream()
            let consumer = Task { for await count in stream { status = L10n.format("copy.0a14aae0", String(describing: count)) } }
            do {
                let result = try await coordinator.verify { continuation.yield($0) }
                verification = result; verificationDate = Date()
                continuation.finish(); await consumer.value
                status = L10n.format("copy.4625754d", String(describing: result.checked), String(describing: result.issues.count))
                issues = Dictionary(uniqueKeysWithValues: result.issues.enumerated().map { (L10n.format("copy.405ed1ed", String(describing: $0.offset+1)), $0.element) })
            } catch {
                continuation.finish(); await consumer.value
                status = error is CancellationError ? L10n.tr("copy.1e8e1a60") : L10n.tr("copy.ab9a0a94")
                if !(error is CancellationError) { notice = error.localizedDescription }
            }
            await refreshCache()
        }
    }

    func refreshAuthorization() {
        authorization = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        limitedAccess = authorization == .limited
    }

    func requestPhotos() async {
        _ = await PhotoKitSource.authorization()
        refreshAuthorization()
    }

    func scanPreview(showErrors: Bool = true) async {
        guard !busy, !scanning, !connecting, !destinationNeedsReconnect, let coordinator, let selectedSource else { return }
        scanning = true; preview = nil
        defer { scanning = false }
        await requestPhotos()
        guard authorization == .authorized || authorization == .limited else {
            if showErrors { notice = L10n.tr("copy.6c73c375") }; return
        }
        do {
            preview = try await coordinator.preview(sourceID: selectedSource, includeVideos: includeVideos,
                selection: backupSelection(at: Date()), requireAssociationCheck: requiresAssociation)
        } catch { if showErrors { notice = error.localizedDescription } }
    }
    var selectionSummary: String {
        if let selectedPhotoIDs { return L10n.format("copy.2c9d8531", String(describing: selectedPhotoIDs.count)) }
        switch dateFilter {
        case .custom:
            let lower = L10n.shortDate(min(customStart, customEnd))
            let upper = L10n.shortDate(max(customStart, customEnd))
            return lower == upper ? lower : "\(lower) – \(upper)"
        default: return dateFilter.title
        }
    }

    var canStart: Bool { selectedSource != nil && !connecting && !destinationNeedsReconnect && !requiresDestinationConfirmation && selectedPhotoIDs?.isEmpty != true }

    func useDateFilter(_ filter: PhotoDateFilter) {
        dateFilter = filter
        selectedPhotoIDs = nil
        preview = nil
    }

    func usePhotoSelection(_ identifiers: Set<String>) {
        selectedPhotoIDs = identifiers
        preview = nil
    }

    func clearPhotoSelection() { selectedPhotoIDs = nil; preview = nil }

    private func backupSelection(at now: Date) -> BackupSelection {
        if let selectedPhotoIDs { return BackupSelection(localIdentifiers: selectedPhotoIDs) }
        let calendar = Calendar.autoupdatingCurrent
        let today = calendar.startOfDay(for: now)
        switch dateFilter {
        case .all:
            return .all
        case .today:
            return BackupSelection(startDate: today, endDate: calendar.date(byAdding: .day, value: 1, to: today))
        case .last7Days:
            return BackupSelection(startDate: calendar.date(byAdding: .day, value: -6, to: today),
                                   endDate: calendar.date(byAdding: .day, value: 1, to: today))
        case .last30Days:
            return BackupSelection(startDate: calendar.date(byAdding: .day, value: -29, to: today),
                                   endDate: calendar.date(byAdding: .day, value: 1, to: today))
        case .thisYear:
            let interval = calendar.dateInterval(of: .year, for: now)
            return BackupSelection(startDate: interval?.start, endDate: interval?.end)
        case .custom:
            let first = calendar.startOfDay(for: min(customStart, customEnd))
            let last = calendar.startOfDay(for: max(customStart, customEnd))
            return BackupSelection(startDate: first, endDate: calendar.date(byAdding: .day, value: 1, to: last))
        }
    }

    private func receive(_ event: BackupEvent) {
        switch event {
        case .scanning: status = L10n.tr("copy.16c48a9f")
        case let .planned(total, completed): self.total = total; self.completed = completed; initialCompleted = completed; planned = true
        case let .transferring(id, filename, bytes): status = L10n.tr("copy.791145e2"); currentFile = filename; currentBytes = bytes; activePhotoID = id
        case .verifying(let filename): status = L10n.tr("copy.f1f3ce5e"); currentFile = filename
        case .completed(let id): completed += 1; sessionPhotoIDs.append(id); issues.removeValue(forKey: id); cloudAssets.remove(id)
        case let .failed(id, message, cloudOnly): issues[id] = message; if cloudOnly { cloudAssets.insert(id) }
        case .paused: status = L10n.tr("copy.4e8fd14b")
        case .finished: break
        case .recoveryWarning(let warning): notice = warning
        }
        let counts = total > 0 ? L10n.format("background.progress", completed.formatted(), total.formatted()) : status
        let subtitle = currentBytes > 0 ? counts + " · " + ByteCountFormatter.string(fromByteCount: Int64(clamping: currentBytes), countStyle: .file) : counts
        backgroundSession.update(completed: completed + issues.count, total: total, subtitle: subtitle)
    }
    private func refreshCache() async {
        guard let coordinator, let archive else { return }
        if let archiveURL {
            let retainedAccess = access
            availableBytes = await Task.detached(priority: .utility) {
                withExtendedLifetime(retainedAccess) { Self.availableCapacity(at: archiveURL) }
            }.value
        }
        do {
            let snapshot = try await coordinator.snapshot()
            let sessions = diskHistory
            let statistics = await Task.detached(priority: .utility) {
                let count = snapshot.records.reduce(0) { $0 + ($1.generations.contains(where: \.isComplete) ? 1 : 0) }
                let bytes = snapshot.records.reduce(UInt64(0)) { $0 + $1.generations.reduce(0) { $0 + $1.resources.values.reduce(0) { $0 + $1.byteCount } } }
                var thumbnails: [UUID: String] = [:]
                for session in sessions {
                    thumbnails[session.id] = snapshot.records.first { record in
                        record.generations.contains { generation in
                            generation.resources.values.contains { $0.completedAt >= session.startedAt && $0.completedAt <= session.finishedAt }
                        }
                    }?.localIdentifier
                }
                return (count, bytes, thumbnails)
            }.value
            storedCount = statistics.0; storedBytes = statistics.1
            historyPhotoIDs = statistics.2
            archiveRecords = snapshot.records
            try await catalog?.rebuild(archiveID: archive.archiveID, records: snapshot.records)
            if !snapshot.issues.isEmpty { notice = L10n.format("copy.2613f983", String(describing: snapshot.issues.count)) }
        }
        catch is CancellationError { }
        catch { notice = L10n.format("copy.e46bb2e9", String(describing: error.localizedDescription)) }
    }
    private func bindingKey(_ archiveID: UUID) -> String { "sourceBinding.\(archiveID.uuidString)" }

    nonisolated private static func availableCapacity(at url: URL) -> Int64? {
        guard let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey, .volumeTotalCapacityKey]) else { return nil }
        if let available = values.volumeAvailableCapacityForImportantUsage, available > 0 { return available }
        if let available = values.volumeAvailableCapacity, available > 0 { return Int64(available) }
        // Some document providers report zero for every capacity key rather than
        // an actual measurement. Only report a full drive if total capacity is known.
        if let total = values.volumeTotalCapacity, total > 0, values.volumeAvailableCapacity == 0 { return 0 }
        return nil
    }
}

#if DEBUG && targetEnvironment(simulator)
// Explicit simulator-only visual fixtures. Uses sample JPEG files and a
// disposable local archive; never selected external storage or production data.
extension BackupModel {
    func prepareDesignReview(_ screen: String) async throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("UI Review", isDirectory: true)
        let source = DesignReviewPhotoSource()
        let assets = try await source.scan(includeVideos: true).suffix(12)
        let ids = assets.map(\.localIdentifier)
        let copiedIDs = Array(ids.prefix(6))
        let (worker, sourceID) = try await Task.detached {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let store = try ArchiveStore(root: root, create: true)
            let id = try store.metadata.sources.first?.id ?? store.addSource(name: "Simulator UI Review").id
            return (BackupCoordinator(store: store, source: source), id)
        }.value
        try await worker.run(sourceID: sourceID, includeVideos: true, allowNetwork: false,
                             requireAssociationCheck: false, selection: BackupSelection(localIdentifiers: Set(copiedIDs)), events: { _ in })
        archive = await worker.metadata(); archiveURL = root; selectedSource = sourceID
        access = try DirectoryAccess(url: root)
        coordinator = worker; directoryName = root.lastPathComponent
        connecting = false; destinationNeedsReconnect = false; requiresDestinationConfirmation = false
        archiveRecords = try await worker.records()
        storedCount = archiveRecords.filter { $0.generations.contains(where: \.isComplete) }.count
        availableBytes = Self.availableCapacity(at: root)
        preview = try await worker.preview(sourceID: sourceID, includeVideos: true, selection: BackupSelection(localIdentifiers: Set(ids)))
        completed = copiedIDs.count; total = ids.count; sessionPhotoIDs = copiedIDs
        activePhotoID = ids.last; currentFile = assets.last?.resources.first?.originalFilename ?? ""
        status = L10n.tr("copy.791145e2")
        if screen == "complete" { total = completed }
        if screen == "integrity" { verification = try await worker.verify(progress: { _ in }); verificationDate = Date() }
        if screen == "errors", let id = ids.last { issues[id] = L10n.tr("ui.review.failure"); runState = .failed }
        if let archive {
            let summary = SessionSummary(archiveID: archive.archiveID, startedAt: Date(), status: L10n.tr("ui.complete.title"),
                                         total: copiedIDs.count, completed: copiedIDs.count, issues: [:])
            history = [summary]
            if let first = copiedIDs.first { historyPhotoIDs[summary.id] = first }
        }
        return root
    }
}
#endif

#if DEBUG && targetEnvironment(simulator)
private struct DesignReviewPhotoSource: PhotoLibrarySource {
    private var root: URL { FileManager.default.temporaryDirectory.appendingPathComponent("UI Review Photos", isDirectory: true) }
    func scan(includeVideos: Bool) async throws -> [AssetDescriptor] {
        try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "jpg" }.sorted { $0.lastPathComponent < $1.lastPathComponent }.map { url in
                AssetDescriptor(localIdentifier: "ui-review-" + url.lastPathComponent, mediaType: 1,
                    resources: [ResourceDescriptor(type: 1, ordinal: 0, originalFilename: url.lastPathComponent, uniformTypeIdentifier: "public.jpeg")])
            }
    }
    func read(asset: AssetDescriptor, resource: ResourceDescriptor, allowNetwork: Bool,
              consume: @escaping @Sendable (Data) throws -> Void) async throws {
        let handle = try FileHandle(forReadingFrom: root.appendingPathComponent(resource.originalFilename))
        defer { try? handle.close() }
        while let data = try handle.read(upToCount: 64 * 1024), !data.isEmpty {
            try Task.checkCancellation()
            try consume(data)
        }
    }
}
#endif
