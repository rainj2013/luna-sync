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

    /// Reads metadata and checks recorded files without exporting original media.
    public func preview(sourceID: UUID, includeVideos: Bool, selection: BackupSelection = .all,
                        requireAssociationCheck: Bool = false) async throws -> BackupPreview {
        guard !running else { throw BackupFailure.unavailable(BackupCopy.tr("diagnostic.5ae7cc7b")) }
        running = true; defer { running = false }
        let assets = try await source.scan(includeVideos: includeVideos, selection: requireAssociationCheck ? .all : selection)
        try Task.checkCancellation()
        if requireAssociationCheck { try store.validateAssociation(assets: assets, sourceID: sourceID) }
        let selected = assets.filter(selection.includes)
        let plan = try store.plan(assets: selected, sourceID: sourceID)
        return BackupPreview(total: selected.count, completed: plan.completed,
                             photoCount: plan.pending.filter { $0.mediaType == 1 }.count,
                             videoCount: plan.pending.filter { $0.mediaType == 2 }.count,
                             pendingIdentifiers: plan.pending.map(\.localIdentifier), issues: plan.needsReview)
    }

    public func run(sourceID: UUID, includeVideos: Bool, allowNetwork: Bool, requireAssociationCheck: Bool,
                    selection: BackupSelection = .all,
                    events: @escaping @Sendable (BackupEvent) -> Void) async throws {
        guard !running else { throw BackupFailure.unavailable(BackupCopy.tr("diagnostic.5ae7cc7b")) }
        running = true; defer { running = false }
        do {
            try Task.checkCancellation()
            for warning in try store.recover() { events(.recoveryWarning(warning)) }
            events(.scanning)
            let checkAssociation = requireAssociationCheck && !associationChecked.contains(sourceID)
            let assets = try await source.scan(includeVideos: includeVideos, selection: checkAssociation ? .all : selection)
            try Task.checkCancellation()
            if checkAssociation {
                try store.validateAssociation(assets: assets, sourceID: sourceID)
                associationChecked.insert(sourceID)
            }
            let selectedAssets = assets.filter(selection.includes)
            let plan = try store.plan(assets: selectedAssets, sourceID: sourceID)
            events(.planned(total: selectedAssets.count, completed: plan.completed))
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
        guard !running else { throw BackupFailure.unavailable(BackupCopy.tr("diagnostic.cf3f5122")) }
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
