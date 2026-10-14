import Foundation

public actor BackupCoordinator {
    private let store: ArchiveStore
    private let source: any PhotoLibrarySource
    private var running = false
    private var associationChecked: Set<UUID> = []

    public init(store: ArchiveStore, source: any PhotoLibrarySource) {
        self.store = store; self.source = source
    }
    public func metadata() -> ArchiveMetadata { store.metadata }
    public func addSource(name: String) throws -> LibrarySource { try store.addSource(name: name) }
    public func records() throws -> [AssetRecord] { try store.records() }
    public func snapshot() throws -> ArchiveSnapshot { try store.snapshot() }

    public func run(sourceID: UUID, includeVideos: Bool, allowNetwork: Bool, requireAssociationCheck: Bool,
                    events: @escaping @Sendable (BackupEvent) -> Void) async throws {
        guard !running else { throw BackupFailure.unavailable("已有任务正在运行。") }
        running = true; defer { running = false }
        do {
            try Task.checkCancellation()
            for warning in try store.recover() { events(.recoveryWarning(warning)) }
            events(.scanning)
            let assets = try await source.scan(includeVideos: includeVideos)
            try Task.checkCancellation()
            if requireAssociationCheck && !associationChecked.contains(sourceID) {
                try store.validateAssociation(assets: assets, sourceID: sourceID)
                associationChecked.insert(sourceID)
            }
            let plan = try store.plan(assets: assets, sourceID: sourceID)
            events(.planned(total: assets.count, completed: plan.completed))
            for (id, issue) in plan.needsReview { events(.failed(assetID: id, message: issue, cloudOnly: false)) }
            for asset in plan.pending {
                try Task.checkCancellation()
                var assetFailed = false
                let generation = try store.ensureGeneration(asset: asset, sourceID: sourceID)
                for resource in asset.resources {
                    try Task.checkCancellation()
                    if let receipt = generation.resources[resource.key], try store.isPresent(receipt) { continue }
                    let transaction = try store.prepare(asset: asset, sourceID: sourceID, generation: generation, resource: resource)
                    let sink: ResourceSink
                    do { sink = try ResourceSink(url: store.safeURL(transaction.partialPath)) }
                    catch { throw BackupFailure.destinationUnavailable(error.localizedDescription) }
                    events(.transferring(assetID: asset.localIdentifier, filename: resource.originalFilename, bytes: 0))
                    let throttle = ProgressThrottle()
                    do {
                        try await source.read(asset: asset, resource: resource, allowNetwork: allowNetwork) { data in
                            if Task.isCancelled { throw CancellationError() }
                            let bytes = try sink.append(data)
                            if throttle.shouldReport() {
                                events(.transferring(assetID: asset.localIdentifier, filename: resource.originalFilename, bytes: bytes))
                            }
                        }
                        try Task.checkCancellation()
                        let content = try sink.finish()
                        events(.verifying(resource.originalFilename))
                        try store.commit(transaction, bytes: content.bytes, hash: content.hash)
                    } catch {
                        sink.close()
                        if error is CancellationError || Task.isCancelled { throw CancellationError() }
                        if let failure = error as? BackupFailure, failure.stopsSession { throw failure }
                        // Foundation errors here come from destination close/readback/rename.
                        if !(error is BackupFailure) { throw BackupFailure.destinationUnavailable(error.localizedDescription) }
                        assetFailed = true
                        let cloudOnly: Bool
                        if case BackupFailure.cloudOnly = error { cloudOnly = true } else { cloudOnly = false }
                        events(.failed(assetID: asset.localIdentifier, message: error.localizedDescription, cloudOnly: cloudOnly))
                    }
                }
                if !assetFailed { events(.completed(asset.localIdentifier)) }
            }
            events(.finished)
        } catch {
            if error is CancellationError || Task.isCancelled { events(.paused); throw CancellationError() }
            throw error
        }
    }

    public func verify(progress: @escaping @Sendable (Int) -> Void) throws -> VerificationResult {
        guard !running else { throw BackupFailure.unavailable("请先暂停备份。") }
        running = true; defer { running = false }
        _ = try store.recover()
        return try store.verify(cancelled: { Task.isCancelled }, progress: progress)
    }
}

private final class ProgressThrottle: @unchecked Sendable {
    private let lock = NSLock()
    private var last = Date.distantPast
    func shouldReport() -> Bool {
        lock.lock(); defer { lock.unlock() }
        let now = Date()
        guard now.timeIntervalSince(last) >= 0.2 else { return false }
        last = now; return true
    }
}
