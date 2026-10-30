import BackgroundTasks
import UIKit

/// A user-started backup can continue while the user uses other apps on iOS 26.
/// No delayed/automatic backup is scheduled. Older systems and rejected requests
/// get only the finite UIKit grace period, then pause through the normal engine.
@MainActor
final class BackgroundBackupSession {
    enum State { case idle, requesting, continued, foregroundOnly, stopping }

    private var identifier: String?
    private var task: BGTask?
    private var pendingWork: (() -> Void)?
    private var pauseWork: (() -> Void)?
    private var stateChanged: ((State) -> Void)?
    private var cleanupTask: UIBackgroundTaskIdentifier = .invalid
    private var cleanupGeneration = UUID()
    private var submitted = false
    private var isBackgrounded = false
    private var lastUpdate = Date.distantPast
    private var completed = 0
    private var total = 0
    private var subtitle = ""

    func begin(work: @escaping () -> Void, pause: @escaping () -> Void,
               stateChanged: @escaping (State) -> Void) {
        precondition(identifier == nil)
        let identifier = "dev.lunasync.app.backup.\(UUID().uuidString)"
        self.identifier = identifier
        pendingWork = work; pauseWork = pause; self.stateChanged = stateChanged
        completed = 0; total = 0; lastUpdate = .distantPast
        subtitle = L10n.tr("background.preparing")
        isBackgrounded = UIApplication.shared.applicationState == .background

        guard #available(iOS 26.0, *) else { startInForeground(); return }
        stateChanged(.requesting)
        // Register the exact job ID. Info.plist permits this prefix via .*, but
        // exact registrations also avoid wildcard matching differences on iOS 26.
        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { [weak self] task in
            Task { @MainActor in
                guard let self else { task.setTaskCompleted(success: false); return }
                self.accept(task, identifier: identifier)
            }
        }
        guard registered else { startInForeground(); return }
        let request = BGContinuedProcessingTaskRequest(identifier: identifier,
            title: L10n.tr("background.title"), subtitle: subtitle)
        // If immediate runtime is unavailable, still allow the ordinary foreground
        // backup. Never queue a surprise job that could start after the drive leaves.
        request.strategy = .fail
        do {
            try BGTaskScheduler.shared.submit(request)
            submitted = true
        } catch {
            startInForeground()
        }
    }

    private func startInForeground() {
        stateChanged?(.foregroundOnly)
        let work = pendingWork; pendingWork = nil
        work?()
    }

    @available(iOS 26.0, *)
    private func accept(_ received: BGTask, identifier: String) {
        guard self.identifier == identifier, let continued = received as? BGContinuedProcessingTask,
              let work = pendingWork else {
            received.setTaskCompleted(success: false)
            return
        }
        task = continued
        continued.expirationHandler = { [weak self] in
            Task { @MainActor in self?.expire(identifier: identifier) }
        }
        pendingWork = nil
        stateChanged?(.continued)
        update(completed: completed, total: total, subtitle: subtitle, force: true)
        work()
        endCleanupTime()
    }

    /// Item counts include already present items and failed/reviewed items; bytes
    /// in the subtitle show real activity during a large video, without inventing
    /// a byte percentage when PhotoKit doesn't expose the resource's total size.
    func update(completed: Int, total: Int, subtitle: String, force: Bool = false) {
        self.completed = completed; self.total = total; self.subtitle = subtitle
        guard #available(iOS 26.0, *), let task = task as? BGContinuedProcessingTask else { return }
        task.progress.totalUnitCount = total > 0 ? Int64(total) : -1
        task.progress.completedUnitCount = Int64(min(max(0, completed), max(0, total)))
        guard force || Date().timeIntervalSince(lastUpdate) >= 1 else { return }
        lastUpdate = Date()
        task.updateTitle(L10n.tr("background.title"), subtitle: subtitle)
    }

    func enteredBackground() {
        isBackgrounded = true
        guard identifier != nil, task == nil else { return }
        // Covers older iOS and the brief interval between submission and delivery.
        // Expiration cancels the transfer, rather than silently suspending a write.
        beginCleanupTime()
    }

    func enteredForeground() {
        isBackgrounded = false
        endCleanupTime()
    }

    private func beginCleanupTime() {
        guard cleanupTask == .invalid else { return }
        let generation = UUID()
        cleanupGeneration = generation
        cleanupTask = UIApplication.shared.beginBackgroundTask(withName: "Finish backup file IO") { [weak self] in
            Task { @MainActor in
                guard let self, self.cleanupGeneration == generation, self.cleanupTask != .invalid else { return }
                self.stateChanged?(.stopping)
                self.pauseWork?()
                self.endCleanupTime()
            }
        }
        if cleanupTask == .invalid {
            stateChanged?(.stopping)
            pauseWork?()
        }
    }

    private func expire(identifier: String) {
        guard self.identifier == identifier else { return }
        stateChanged?(.stopping)
        // Ask for a short cleanup assertion before releasing continued runtime.
        if isBackgrounded { beginCleanupTime() }
        pauseWork?()
        task?.setTaskCompleted(success: false)
        task = nil
    }

    /// A pause can arrive while the system is delivering the launch handler.
    /// Cancel that pending launch so it can't start a backup after the user pauses.
    func cancelPendingStart() -> Bool {
        guard pendingWork != nil else { return false }
        finish(success: false)
        return true
    }

    func finish(success: Bool) {
        if #available(iOS 26.0, *), let continued = task as? BGContinuedProcessingTask, success {
            continued.progress.totalUnitCount = Int64(max(1, total))
            continued.progress.completedUnitCount = continued.progress.totalUnitCount
        }
        task?.expirationHandler = nil
        task?.setTaskCompleted(success: success)
        if submitted, task == nil, let identifier {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
        }
        task = nil; identifier = nil; pendingWork = nil; pauseWork = nil; submitted = false
        endCleanupTime()
        stateChanged?(.idle)
        stateChanged = nil
    }

    private func endCleanupTime() {
        guard cleanupTask != .invalid else { return }
        let token = cleanupTask; cleanupTask = .invalid
        cleanupGeneration = UUID()
        UIApplication.shared.endBackgroundTask(token)
    }
}

#if DEBUG
import SwiftUI
import LunaSyncCore

/// Opt-in device integration probe. Uses synthetic data and a disposable sandbox
/// archive, never the user's photos or selected drive. Slow chunks simulate a
/// provider transfer long enough to check continued runtime beyond UIKit grace.
@MainActor
final class BackgroundBackupProbe {
    static let shared = BackgroundBackupProbe()
    private let session = BackgroundBackupSession()
    private var operation: Task<Void, Never>?
    private var started = false
    private var completed = 0
    private var backgroundCompleted = 0
    private var state = "notStarted"
    private var startedAt = Date()
    private var backgroundStartedAt: Date?
    private var report: [String: Any] = [:]

    func sceneChanged(_ phase: ScenePhase) {
        guard started else { return }
        if phase == .background {
            backgroundStartedAt = Date()
            session.enteredBackground()
        } else if phase == .active { session.enteredForeground() }
    }

    func start() {
        guard !started else { return }
        started = true; startedAt = Date()
        session.begin(work: { [self] in operation = Task { await perform() } },
            pause: { [weak self] in self?.operation?.cancel() },
            stateChanged: { [weak self] value in self?.state = String(describing: value); self?.save() })
    }

    private func perform() async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BackgroundBackupProbe-\(UUID().uuidString)")
        var success = false
        do {
            let (worker, sourceID) = try await Task.detached {
                // User-selected destinations already exist. Match that contract
                // for this synthetic archive before canonical path validation.
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                let store = try ArchiveStore(root: root, create: true)
                let sourceID = try store.addSource(name: "Synthetic background test").id
                return (BackupCoordinator(store: store, source: ProbeSource()), sourceID)
            }.value
            let (stream, continuation) = AsyncStream<BackupEvent>.makeStream()
            let consumer = Task {
                for await event in stream {
                    if case .completed = event {
                        completed += 1
                        if UIApplication.shared.applicationState == .background { backgroundCompleted += 1 }
                        session.update(completed: completed, total: 96, subtitle: "\(completed) / 96")
                        save()
                    }
                }
            }
            do {
                try await worker.run(sourceID: sourceID, includeVideos: true, allowNetwork: false,
                    requireAssociationCheck: false) { continuation.yield($0) }
            } catch {
                continuation.finish(); await consumer.value
                throw error
            }
            continuation.finish(); await consumer.value
            let verification = try await worker.verify(progress: { _ in })
            report["verifiedResources"] = verification.checked
            report["verificationIssues"] = verification.issues.count
            success = completed == 96 && verification.issues.isEmpty
        } catch { report["error"] = String(describing: error) }
        await Task.detached { try? FileManager.default.removeItem(at: root) }.value
        report["finished"] = true; report["success"] = success
        save()
        session.finish(success: success)
        operation = nil
    }

    private func save() {
        report["state"] = state
        report["completed"] = completed
        report["backgroundCompleted"] = backgroundCompleted
        report["elapsedSeconds"] = Date().timeIntervalSince(startedAt)
        report["applicationState"] = UIApplication.shared.applicationState.rawValue
        report["backgroundSeconds"] = backgroundStartedAt.map { Date().timeIntervalSince($0) } ?? 0
        let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("DesignReview")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: folder.appendingPathComponent("background-transfer.json"), options: .atomic)
    }
}

private struct ProbeSource: PhotoLibrarySource {
    func scan(includeVideos: Bool) async throws -> [AssetDescriptor] {
        (0..<96).map { AssetDescriptor(localIdentifier: "synthetic/\($0)", resources: [
            ResourceDescriptor(type: 1, ordinal: 0, originalFilename: "probe-\($0).bin", uniformTypeIdentifier: "public.data")
        ]) }
    }
    func read(asset: AssetDescriptor, resource: ResourceDescriptor, allowNetwork: Bool,
              consume: @escaping @Sendable (Data) throws -> Void) async throws {
        let chunk = Data(repeating: UInt8(asset.localIdentifier.utf8.reduce(0) { ($0 + Int($1)) % 256 }), count: 64 * 1024)
        for _ in 0..<8 {
            try await Task.sleep(for: .milliseconds(80))
            try Task.checkCancellation()
            try consume(chunk)
        }
    }
}
#endif
