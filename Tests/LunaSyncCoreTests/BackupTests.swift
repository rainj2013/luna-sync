import XCTest
@testable import LunaSyncCore

private struct InjectedCrash: Error {}

private final class FakeSource: PhotoLibrarySource, @unchecked Sendable {
    let assets: [AssetDescriptor]
    var cloudKeys: Set<String> = []
    var chunkDelay: UInt64 = 0
    private let lock = NSLock()
    private var readCount = 0
    private var scannedSelections: [BackupSelection] = []
    var selections: [BackupSelection] { lock.lock(); defer { lock.unlock() }; return scannedSelections }
    var reads: Int { lock.lock(); defer { lock.unlock() }; return readCount }
    init(_ assets: [AssetDescriptor]) { self.assets = assets }
    func scan(includeVideos: Bool) async throws -> [AssetDescriptor] {
        assets.filter { includeVideos || $0.mediaType != 2 }
    }
    func scan(includeVideos: Bool, selection: BackupSelection) async throws -> [AssetDescriptor] {
        recordScan(selection)
        return try await scan(includeVideos: includeVideos).filter(selection.includes)
    }
    private func recordScan(_ selection: BackupSelection) { lock.lock(); scannedSelections.append(selection); lock.unlock() }
    func read(asset: AssetDescriptor, resource: ResourceDescriptor, allowNetwork: Bool,
              consume: @escaping @Sendable (Data) throws -> Void) async throws {
        countRead()
        if cloudKeys.contains(resource.key) && !allowNetwork { throw BackupFailure.cloudOnly }
        let data = Self.content(asset, resource)
        for index in stride(from: 0, to: data.count, by: 7) {
            if chunkDelay > 0 { try await Task.sleep(nanoseconds: chunkDelay) }
            try Task.checkCancellation()
            try consume(data.subdata(in: index..<min(index+7, data.count)))
        }
    }
    private func countRead() { lock.lock(); readCount += 1; lock.unlock() }
    static func content(_ asset: AssetDescriptor, _ resource: ResourceDescriptor) -> Data {
        Data((asset.localIdentifier + resource.originalFilename + String(repeating: "sample", count: 20)).utf8)
    }
}

final class BackupTests: XCTestCase {
    private var roots: [URL] = []
    override func tearDownWithError() throws {
        for root in roots { try? FileManager.default.removeItem(at: root) }
    }
    private func makeStore() throws -> (ArchiveStore, UUID) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        roots.append(root)
        let store = try ArchiveStore(root: root, create: true)
        return (store, try store.addSource(name: "Test iPhone").id)
    }
    private func resource(_ type: Int = 1, name: String = "IMG_0001.HEIC", ordinal: Int = 0) -> ResourceDescriptor {
        ResourceDescriptor(type: type, ordinal: ordinal, originalFilename: name, uniformTypeIdentifier: "public.data")
    }
    private func asset(_ id: String = "photo/1", live: Bool = false) -> AssetDescriptor {
        AssetDescriptor(localIdentifier: id, resources: live ? [resource(), resource(9, name: "IMG_0001.MOV")] : [resource()])
    }
    private func run(_ coordinator: BackupCoordinator, sourceID: UUID, network: Bool = false) async throws {
        try await coordinator.run(sourceID: sourceID, includeVideos: true, allowNetwork: network,
                                  requireAssociationCheck: false, events: { _ in })
    }
    private func commit(_ store: ArchiveStore, _ asset: AssetDescriptor, _ sourceID: UUID,
                        _ resource: ResourceDescriptor) throws {
        let generation = try store.ensureGeneration(asset: asset, sourceID: sourceID)
        let transaction = try store.prepare(asset: asset, sourceID: sourceID, generation: generation, resource: resource)
        let data = FakeSource.content(asset, resource)
        try data.write(to: store.safeURL(transaction.partialPath))
        try store.commit(transaction, bytes: UInt64(data.count), hash: SHA256Digest.hex(data))
    }

    func testSHA256KnownVectorsAndChunkBoundaries() {
        XCTAssertEqual(SHA256Digest.hex(Data()), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(SHA256Digest.hex(Data("abc".utf8)), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        var hash = SHA256Digest()
        for _ in 0..<1000 { hash.update(Data(repeating: 97, count: 1000)) }
        XCTAssertEqual(hash.finalize(), "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0")
    }

    func testPreviewAndBackupRequestOnlySelectedAssets() async throws {
        let (store, sourceID) = try makeStore()
        let source = FakeSource((0..<50_000).map { asset("photo/\($0)") })
        let coordinator = BackupCoordinator(store: store, source: source)
        let selection = BackupSelection(localIdentifiers: ["photo/49999"])
        let preview = try await coordinator.preview(sourceID: sourceID, includeVideos: true, selection: selection)
        XCTAssertEqual(preview.total, 1)
        try await coordinator.run(sourceID: sourceID, includeVideos: true, allowNetwork: false, requireAssociationCheck: false,
                                  selection: selection, events: { _ in })
        XCTAssertEqual(source.selections, [selection, selection])
        XCTAssertEqual(source.reads, 1)
    }

    func testReassociationStillScansWholeLibraryWithPartialSelection() async throws {
        let (store, sourceID) = try makeStore()
        let existing = asset("photo/existing")
        try commit(store, existing, sourceID, existing.resources[0])
        let source = FakeSource([existing, asset("photo/new")])
        let coordinator = BackupCoordinator(store: store, source: source)
        let selection = BackupSelection(localIdentifiers: ["photo/new"])
        let preview = try await coordinator.preview(sourceID: sourceID, includeVideos: true, selection: selection, requireAssociationCheck: true)
        XCTAssertEqual(preview.total, 1)
        try await coordinator.run(sourceID: sourceID, includeVideos: true, allowNetwork: false, requireAssociationCheck: true,
                                  selection: selection, events: { _ in })
        XCTAssertEqual(source.selections, [.all, .all])
        XCTAssertEqual(source.reads, 1)
    }

    func testBackupSelectionUsesExclusiveEndAndExcludesUndatedAssets() {
        let start = Date(timeIntervalSince1970: 100)
        let end = Date(timeIntervalSince1970: 200)
        let selection = BackupSelection(startDate: start, endDate: end)
        XCTAssertTrue(selection.includes(AssetDescriptor(localIdentifier: "start", creationDate: start, resources: [resource()])))
        XCTAssertTrue(selection.includes(AssetDescriptor(localIdentifier: "inside", creationDate: Date(timeIntervalSince1970: 199), resources: [resource()])))
        XCTAssertFalse(selection.includes(AssetDescriptor(localIdentifier: "end", creationDate: end, resources: [resource()])))
        XCTAssertFalse(selection.includes(asset("undated")))
        XCTAssertTrue(BackupSelection.all.includes(asset("undated")))
    }

    func testBackupSelectionCanUseExplicitPhotoIdentifiers() {
        let selection = BackupSelection(localIdentifiers: ["photo/1", "photo/3"])
        XCTAssertTrue(selection.includes(asset("photo/1")))
        XCTAssertFalse(selection.includes(asset("photo/2")))
        XCTAssertTrue(selection.includes(asset("photo/3")))
    }

    func testPreviewCountsPendingResourcesWithoutExportingOrCommitting() async throws {
        let (store, sourceID) = try makeStore()
        let saved = asset("saved"), pending = asset("pending")
        let video = AssetDescriptor(localIdentifier: "video", mediaType: 2, resources: [resource(2, name: "clip.MOV")])
        let unsupported = AssetDescriptor(localIdentifier: "unsupported", resources: [], issue: "Needs review")
        try commit(store, saved, sourceID, saved.resources[0])
        let source = FakeSource([saved, pending, video, unsupported])
        let coordinator = BackupCoordinator(store: store, source: source)
        let preview = try await coordinator.preview(sourceID: sourceID, includeVideos: true)
        XCTAssertEqual(preview.total, 4)
        XCTAssertEqual(preview.completed, 1)
        XCTAssertEqual(preview.photoCount, 1)
        XCTAssertEqual(preview.videoCount, 1)
        XCTAssertEqual(Set(preview.pendingIdentifiers), ["pending", "video"])
        XCTAssertEqual(preview.issues["unsupported"], "Needs review")
        XCTAssertEqual(source.reads, 0)
        XCTAssertEqual(try store.records().count, 1)

        let selected = try await coordinator.preview(sourceID: sourceID, includeVideos: false,
                                                     selection: BackupSelection(localIdentifiers: ["pending"]))
        XCTAssertEqual(selected.total, 1)
        XCTAssertEqual(selected.pendingCount, 1)
        XCTAssertEqual(selected.videoCount, 0)
        XCTAssertEqual(source.reads, 0)
    }

    func testBackupCoordinatorOnlyTransfersSelectedDateRange() async throws {
        let (store, sourceID) = try makeStore()
        let old = AssetDescriptor(localIdentifier: "old", creationDate: Date(timeIntervalSince1970: 50), resources: [resource()])
        let selected = AssetDescriptor(localIdentifier: "selected", creationDate: Date(timeIntervalSince1970: 150), resources: [resource()])
        let source = FakeSource([old, selected])
        let coordinator = BackupCoordinator(store: store, source: source)
        try await coordinator.run(sourceID: sourceID, includeVideos: true, allowNetwork: false,
                                  requireAssociationCheck: false,
                                  selection: BackupSelection(startDate: Date(timeIntervalSince1970: 100),
                                                             endDate: Date(timeIntervalSince1970: 200)),
                                  events: { _ in })
        XCTAssertEqual(source.reads, 1)
        XCTAssertEqual(try store.plan(assets: [selected], sourceID: sourceID).completed, 1)
        XCTAssertEqual(try store.plan(assets: [old], sourceID: sourceID).pending.count, 1)
    }

    func testSupplementaryAdjustmentCompatibilityMatchesTypeAndContent() {
        XCTAssertTrue(PhotoResourceCompatibility.isSupplementaryAdjustment(
            type: 16, uniformTypeIdentifier: "com.apple.photos.apple-adjustment-envelope"))
        XCTAssertFalse(PhotoResourceCompatibility.isSupplementaryAdjustment(type: 16, uniformTypeIdentifier: "public.heic"))
        XCTAssertFalse(PhotoResourceCompatibility.isSupplementaryAdjustment(
            type: 99, uniformTypeIdentifier: "com.apple.photos.apple-adjustment-envelope"))
        XCTAssertFalse(PhotoResourceCompatibility.isSupplementaryAdjustment(type: 1, uniformTypeIdentifier: "public.heic"))
    }

    func testHEICAndVideoLongerThanTwoMinutesKeepOriginalBytes() async throws {
        let (store, sourceID) = try makeStore()
        let photoResource = ResourceDescriptor(type: 1, ordinal: 0, originalFilename: "PHOTO.HEIC", uniformTypeIdentifier: "public.heic")
        let videoResource = ResourceDescriptor(type: 2, ordinal: 0, originalFilename: "LONG.MOV", uniformTypeIdentifier: "com.apple.quicktime-movie")
        let photo = AssetDescriptor(localIdentifier: "heic", resources: [photoResource])
        let video = AssetDescriptor(localIdentifier: "long-video", mediaType: 2, duration: 3600, resources: [videoResource])
        let coordinator = BackupCoordinator(store: store, source: FakeSource([photo, video]))
        let preview = try await coordinator.preview(sourceID: sourceID, includeVideos: true)
        XCTAssertEqual(preview.pendingCount, 2)
        XCTAssertTrue(preview.issues.isEmpty)
        try await run(coordinator, sourceID: sourceID)
        for asset in [photo, video] {
            let resource = try XCTUnwrap(asset.resources.first)
            let record = try XCTUnwrap(store.record(for: asset, sourceID: sourceID))
            let receipt = try XCTUnwrap(record.generations.last?.resources[resource.key])
            XCTAssertEqual(receipt.relativePath, resource.originalFilename)
            XCTAssertEqual(try Data(contentsOf: store.root.appendingPathComponent(receipt.relativePath)), FakeSource.content(asset, resource))
        }
    }

    func testIncrementalSameNamesAndLateImportedOldPhoto() async throws {
        let (store, sourceID) = try makeStore()
        let first = asset(), second = asset("another/1")
        let source = FakeSource([first, second])
        let coordinator = BackupCoordinator(store: store, source: source)
        try await run(coordinator, sourceID: sourceID)
        XCTAssertEqual(source.reads, 2)
        try await run(coordinator, sourceID: sourceID)
        XCTAssertEqual(source.reads, 2)
        let old = AssetDescriptor(localIdentifier: "old/import", creationDate: Date(timeIntervalSince1970: 1), resources: [resource()])
        let next = FakeSource([first, second, old])
        try await run(BackupCoordinator(store: store, source: next), sourceID: sourceID)
        XCTAssertEqual(next.reads, 1)
        XCTAssertEqual(try store.plan(assets: [first, second, old], sourceID: sourceID).completed, 3)
        let paths = try store.records().flatMap { $0.generations.flatMap { $0.resources.values.map(\.relativePath) } }
        XCTAssertEqual(Set(paths).count, 3)
    }

    func testOriginalFilenameIsUsedAndCollisionGetsSuffix() throws {
        let (store, sourceID) = try makeStore()
        let first = asset("first")
        let second = asset("second")
        try commit(store, first, sourceID, first.resources[0])
        try commit(store, second, sourceID, second.resources[0])
        let firstPath = try XCTUnwrap(store.record(for: first, sourceID: sourceID)?.generations.first?.resources.values.first?.relativePath)
        let secondPath = try XCTUnwrap(store.record(for: second, sourceID: sourceID)?.generations.first?.resources.values.first?.relativePath)
        XCTAssertEqual(firstPath, "IMG_0001.HEIC")
        XCTAssertEqual(secondPath, "IMG_0001 (2).HEIC")
    }

    func testFlatDestinationPreservesUnrelatedPhotosAndKeepsMetadataHidden() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        roots.append(root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let existing = Data("an unrelated existing photo".utf8)
        try existing.write(to: root.appendingPathComponent("IMG_0001.HEIC"))
        let unrelatedArchive = Data("{\"belongsTo\":\"another app\"}".utf8)
        try unrelatedArchive.write(to: root.appendingPathComponent("archive.json"))
        let store = try ArchiveStore(root: root, create: true)
        let sourceID = try store.addSource(name: "Phone").id
        let photo = AssetDescriptor(localIdentifier: "dated", creationDate: Date(), resources: [resource()])
        try commit(store, photo, sourceID, photo.resources[0])
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("IMG_0001.HEIC")), existing)
        XCTAssertEqual(try store.record(for: photo, sourceID: sourceID)?.generations.last?.resources.values.first?.relativePath, "IMG_0001 (2).HEIC")
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: root.path)), [".luna-sync", "archive.json", "IMG_0001.HEIC", "IMG_0001 (2).HEIC"])
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("archive.json")), unrelatedArchive)
        XCTAssertEqual(store.markerURL, root.appendingPathComponent(".luna-sync/archive.json"))
        XCTAssertEqual(try ArchiveStore(root: root).plan(assets: [photo], sourceID: sourceID).completed, 1)
    }

    func testUnrelatedHiddenMetadataFolderIsNotOverwritten() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        roots.append(root)
        let metadata = root.appendingPathComponent(".luna-sync")
        try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: true)
        let existing = Data("keep this file".utf8), file = metadata.appendingPathComponent("unrelated.txt")
        try existing.write(to: file)
        XCTAssertThrowsError(try ArchiveStore(root: root, create: true))
        XCTAssertEqual(try Data(contentsOf: file), existing)
        XCTAssertFalse(FileManager.default.fileExists(atPath: metadata.appendingPathComponent("archive.json").path))
    }

    func testFlatRecoveryCannotPromotePhotoOverMetadata() throws {
        let (store, sourceID) = try makeStore(), photo = asset()
        let originalHeader = try Data(contentsOf: store.markerURL)
        let generation = try store.ensureGeneration(asset: photo, sourceID: sourceID)
        let transaction = try store.prepare(asset: photo, sourceID: sourceID, generation: generation, resource: photo.resources[0])
        let path = try store.safeURL(".luna-sync/transactions/\(transaction.id.uuidString.lowercased()).json")
        var json = try JSONSerialization.jsonObject(with: Data(contentsOf: path)) as! [String: Any]
        json["finalPath"] = ".luna-sync/archive.json"
        try JSONSerialization.data(withJSONObject: json).write(to: path)
        XCTAssertThrowsError(try store.recover())
        XCTAssertEqual(try Data(contentsOf: store.markerURL), originalHeader)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path.path))
    }

    func testHiddenMetadataSymlinkCannotEscapeDestination() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        roots.append(contentsOf: [root, outside])
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent(".luna-sync"), withDestinationURL: outside)
        XCTAssertThrowsError(try ArchiveStore(root: root, create: true))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
    }

    func testLegacyArchiveRemainsReadableAndNewFilesAreFlat() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        roots.append(root)
        let source = LibrarySource(name: "Legacy phone")
        var metadata = ArchiveMetadata(); metadata.formatVersion = 1; metadata.sources = [source]
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONEncoder().encode(metadata).write(to: root.appendingPathComponent("archive.json"))
        let old = asset("old"), data = FakeSource.content(old, old.resources[0])
        let relative = "originals/2020-01/IMG_0001.HEIC", oldFile = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: oldFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: oldFile)
        let receipt = ResourceReceipt(descriptor: old.resources[0], relativePath: relative, byteCount: UInt64(data.count), sha256: SHA256Digest.hex(data), completedAt: Date())
        let generation = AssetGeneration(id: UUID(), asset: old, resources: [old.resources[0].key: receipt])
        let key = old.key(sourceID: source.id)
        let record = AssetRecord(assetKey: key, sourceID: source.id, localIdentifier: old.localIdentifier, generations: [generation])
        let recordFile = root.appendingPathComponent("records/\(key.prefix(2))/\(key).json")
        try FileManager.default.createDirectory(at: recordFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(record).write(to: recordFile)

        let store = try ArchiveStore(root: root)
        XCTAssertEqual(try store.plan(assets: [old], sourceID: source.id).completed, 1)
        let added = AssetDescriptor(localIdentifier: "new", resources: [resource(name: "NEW.HEIC")])
        try commit(store, added, source.id, added.resources[0])
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("NEW.HEIC").path))
        XCTAssertEqual(try Data(contentsOf: oldFile), data)
        let reopened = try ArchiveStore(root: root)
        XCTAssertEqual(reopened.metadata.formatVersion, 2)
        XCTAssertEqual(try reopened.plan(assets: [old, added], sourceID: source.id).completed, 2)
        XCTAssertTrue(try reopened.verify().issues.isEmpty)
    }

    func testRangeSelectionExpandsImmediatelyAcrossManyPages() {
        let identifiers = (0..<10_000).map { "photo/\($0)" }
        var selection = PhotoRangeSelection()
        selection.select(identifiers[8_000], orderedIdentifiers: identifiers)
        XCTAssertNotNil(selection.anchor)
        XCTAssertEqual(selection.selected.count, 1)
        selection.select(identifiers[10], orderedIdentifiers: identifiers)
        XCTAssertNil(selection.anchor)
        XCTAssertEqual(selection.selected.count, 7_991)
        XCTAssertTrue(selection.selected.contains(identifiers[5_000]))
        XCTAssertFalse(selection.selected.contains(identifiers[9]))
        selection.deselect(identifiers[5_000])
        XCTAssertEqual(selection.selected.count, 7_990)
        selection.select(identifiers[7_999], orderedIdentifiers: identifiers)
        selection.select(identifiers[9_999], orderedIdentifiers: identifiers)
        XCTAssertEqual(selection.selected.count, 9_989)
    }

    func testLivePhotoCloudHalfIsNotCompleteAndResumeSkipsCompletedHalf() async throws {
        let (store, sourceID) = try makeStore()
        let live = asset(live: true), source = FakeSource([asset(live: true)])
        source.cloudKeys = [live.resources[1].key]
        let coordinator = BackupCoordinator(store: store, source: source)
        try await run(coordinator, sourceID: sourceID)
        XCTAssertFalse(try XCTUnwrap(store.record(for: live, sourceID: sourceID)?.generations.first).isComplete)
        XCTAssertEqual(source.reads, 2)
        try await run(coordinator, sourceID: sourceID, network: true)
        XCTAssertEqual(source.reads, 3)
        XCTAssertEqual(try store.plan(assets: [live], sourceID: sourceID).completed, 1)
    }

    func testCrashRecoveryAtEveryCommitBoundary() throws {
        for stage in [CommitStage.prepared, .dataWritten, .verified, .promoted, .recorded] {
            let (store, sourceID) = try makeStore(), asset = asset()
            store.checkpoint = { if $0 == stage { throw InjectedCrash() } }
            XCTAssertThrowsError(try commit(store, asset, sourceID, asset.resources[0]))
            let reopened = try ArchiveStore(root: store.root)
            _ = try reopened.recover()
            let plan = try reopened.plan(assets: [asset], sourceID: sourceID)
            switch stage {
            case .prepared, .dataWritten: XCTAssertEqual(plan.pending.count, 1)
            case .verified, .promoted, .recorded: XCTAssertEqual(plan.completed, 1)
            }
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: store.root.appendingPathComponent(".luna-sync/transactions").path).isEmpty)
        }
    }

    func testCorruptionDuringWriteCannotCommit() throws {
        let (store, sourceID) = try makeStore(), asset = asset()
        let generation = try store.ensureGeneration(asset: asset, sourceID: sourceID)
        let transaction = try store.prepare(asset: asset, sourceID: sourceID, generation: generation, resource: asset.resources[0])
        let expected = FakeSource.content(asset, asset.resources[0])
        try Data(repeating: 0, count: expected.count).write(to: store.safeURL(transaction.partialPath))
        XCTAssertThrowsError(try store.commit(transaction, bytes: UInt64(expected.count), hash: SHA256Digest.hex(expected))) {
            guard case BackupFailure.integrityMismatch = $0 else { return XCTFail("\($0)") }
        }
        _ = try store.recover()
        XCTAssertEqual(try store.plan(assets: [asset], sourceID: sourceID).completed, 0)
    }

    func testRecoveryInvalidatesAlreadyRecordedCorruptFile() throws {
        let (store, sourceID) = try makeStore(), asset = asset()
        store.checkpoint = { if $0 == .recorded { throw InjectedCrash() } }
        XCTAssertThrowsError(try commit(store, asset, sourceID, asset.resources[0]))
        let receipt = try XCTUnwrap(store.record(for: asset, sourceID: sourceID)?.generations.first?.resources.values.first)
        try Data(repeating: 0, count: Int(receipt.byteCount)).write(to: store.safeURL(receipt.relativePath))
        let reopened = try ArchiveStore(root: store.root)
        XCTAssertEqual(try reopened.recover().count, 1)
        XCTAssertEqual(try reopened.plan(assets: [asset], sourceID: sourceID).completed, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try store.safeURL(receipt.relativePath).path))
    }

    func testCorruptTransactionBlocksWritingAndIsPreserved() throws {
        let (store, _) = try makeStore()
        let path = try store.safeURL(".luna-sync/transactions/broken.json")
        try Data("{".utf8).write(to: path)
        XCTAssertThrowsError(try store.recover())
        XCTAssertTrue(FileManager.default.fileExists(atPath: path.path))
    }

    func testSameSizeCorruptionIsDetectedAndRepairedWithoutOverwriting() async throws {
        let (store, sourceID) = try makeStore(), asset = asset()
        let source = FakeSource([asset]), coordinator = BackupCoordinator(store: store, source: FakeSource([asset]))
        try await run(coordinator, sourceID: sourceID)
        let receipt = try XCTUnwrap(store.record(for: asset, sourceID: sourceID)?.generations.first?.resources.values.first)
        let url = try store.safeURL(receipt.relativePath)
        try Data(repeating: 0, count: Int(receipt.byteCount)).write(to: url)
        XCTAssertEqual(try store.plan(assets: [asset], sourceID: sourceID).completed, 1) // quick size check
        let result = try store.verify()
        XCTAssertEqual(result.issues.count, 1)
        XCTAssertEqual(try store.plan(assets: [asset], sourceID: sourceID).pending.count, 1)
        try await run(BackupCoordinator(store: store, source: source), sourceID: sourceID)
        XCTAssertEqual(source.reads, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let repaired = try XCTUnwrap(store.record(for: asset, sourceID: sourceID)?.generations.first?.resources.values.first)
        XCTAssertNotEqual(repaired.relativePath, receipt.relativePath)
        XCTAssertTrue(try store.verify().issues.isEmpty)
    }

    func testMissingFileTriggersBackupAndPhoneDeletionKeepsArchive() async throws {
        let (store, sourceID) = try makeStore(), asset = asset()
        let source = FakeSource([asset]), coordinator = BackupCoordinator(store: store, source: source)
        try await run(coordinator, sourceID: sourceID)
        let receipt = try XCTUnwrap(store.record(for: asset, sourceID: sourceID)?.generations.first?.resources.values.first)
        try FileManager.default.removeItem(at: store.safeURL(receipt.relativePath))
        try await run(coordinator, sourceID: sourceID)
        XCTAssertEqual(source.reads, 2)
        XCTAssertTrue(try store.plan(assets: [], sourceID: sourceID).pending.isEmpty)
        XCTAssertEqual(try store.records().count, 1)
    }

    func testCancellationKeepsPartialUncommittedAndCanResume() async throws {
        let (store, sourceID) = try makeStore(), asset = asset(live: true)
        let source = FakeSource([asset]); source.chunkDelay = 5_000_000
        let coordinator = BackupCoordinator(store: store, source: source)
        let task = Task { try await run(coordinator, sourceID: sourceID) }
        try await Task.sleep(nanoseconds: 30_000_000); task.cancel()
        do { try await task.value; XCTFail("Expected cancellation") } catch is CancellationError {} catch { XCTFail("\(error)") }
        XCTAssertEqual(try store.plan(assets: [asset], sourceID: sourceID).completed, 0)
        source.chunkDelay = 0
        try await run(coordinator, sourceID: sourceID)
        XCTAssertEqual(try store.plan(assets: [asset], sourceID: sourceID).completed, 1)
        // Background expiration uses this same cancellation path. A resumed Live
        // Photo must contain both complete originals, never the interrupted bytes.
        let generation = try XCTUnwrap(store.record(for: asset, sourceID: sourceID)?.generations.first)
        for resource in asset.resources {
            let receipt = try XCTUnwrap(generation.resources[resource.key])
            XCTAssertEqual(try Data(contentsOf: store.safeURL(receipt.relativePath)), FakeSource.content(asset, resource))
        }
        XCTAssertTrue(try store.verify().issues.isEmpty)
    }

    func testPathsRejectTraversalAndSymlinkEscape() throws {
        let (store, _) = try makeStore()
        for path in ["../escape", "/tmp/escape", "originals/../../escape", "originals//file", "a\\b"] {
            XCTAssertThrowsError(try store.safeURL(path))
        }
        try FileManager.default.createSymbolicLink(atPath: store.root.appendingPathComponent("escape").path, withDestinationPath: "/tmp")
        XCTAssertThrowsError(try store.safeURL("escape/file"))
        XCTAssertEqual(resource(name: "bad.$(touch hacked)").fileExtension, "bin")
    }

    func testFutureFormatIsRejectedWithoutWriting() throws {
        let (store, _) = try makeStore()
        var metadata = store.metadata; metadata.formatVersion = 99
        let data = try JSONEncoder().encode(metadata), marker = store.markerURL
        try data.write(to: marker)
        XCTAssertThrowsError(try ArchiveStore(root: store.root))
        XCTAssertEqual(try Data(contentsOf: marker), data)
    }

    func testRecordCorruptionBlocksFalseSuccess() throws {
        let (store, sourceID) = try makeStore(), asset = asset()
        try commit(store, asset, sourceID, asset.resources[0])
        let key = asset.key(sourceID: sourceID)
        try Data("{".utf8).write(to: store.safeURL(".luna-sync/records/\(key.prefix(2))/\(key).json"))
        let plan = try store.plan(assets: [asset, self.asset("healthy")], sourceID: sourceID)
        XCTAssertEqual(plan.completed, 0)
        XCTAssertEqual(plan.needsReview.count, 1)
        XCTAssertEqual(plan.pending.count, 1)
        XCTAssertEqual(try store.snapshot().issues.count, 1)
        XCTAssertFalse(try store.verify().issues.isEmpty)
    }

    func testSourceReassociationAndNewDeviceIsolation() throws {
        let (store, sourceID) = try makeStore(), asset = asset()
        try commit(store, asset, sourceID, asset.resources[0])
        let reopened = try ArchiveStore(root: store.root)
        XCTAssertNoThrow(try reopened.validateAssociation(assets: [asset], sourceID: sourceID))
        XCTAssertThrowsError(try reopened.validateAssociation(assets: [self.asset("unrelated")], sourceID: sourceID))
        let conflicting = AssetDescriptor(localIdentifier: asset.localIdentifier, resources: [resource(name: "different.JPG")])
        XCTAssertThrowsError(try reopened.validateAssociation(assets: [conflicting], sourceID: sourceID))
        let otherSource = try reopened.addSource(name: "New iPhone")
        XCTAssertEqual(try reopened.plan(assets: [asset], sourceID: otherSource.id).pending.count, 1)
    }

    func testChangedOriginalCreatesGenerationAndRetainsOldFile() throws {
        let (store, sourceID) = try makeStore(), original = asset()
        try commit(store, original, sourceID, original.resources[0])
        let replacement = AssetDescriptor(localIdentifier: original.localIdentifier, resources: [resource(name: "replacement.JPG")])
        try commit(store, replacement, sourceID, replacement.resources[0])
        let record = try XCTUnwrap(store.record(for: replacement, sourceID: sourceID))
        XCTAssertEqual(record.generations.count, 2)
        for generation in record.generations { XCTAssertTrue(try store.isPresent(XCTUnwrap(generation.resources.values.first))) }
    }

    func testRAWAndJPEGAreBothRequired() throws {
        let (store, sourceID) = try makeStore()
        let raw = AssetDescriptor(localIdentifier: "raw", resources: [resource(name: "RAW.DNG"), resource(4, name: "RAW.JPG")])
        try commit(store, raw, sourceID, raw.resources[0])
        XCTAssertEqual(try store.plan(assets: [raw], sourceID: sourceID).completed, 0)
        try commit(store, raw, sourceID, raw.resources[1])
        XCTAssertEqual(try store.plan(assets: [raw], sourceID: sourceID).completed, 1)
    }

    func testTenThousandAssetMetadataPlanning() throws {
        let (store, sourceID) = try makeStore()
        let assets = (0..<10_001).map { asset("asset/\($0)") }
        let plan = try store.plan(assets: assets, sourceID: sourceID)
        XCTAssertEqual(plan.pending.count, 10_001)
        XCTAssertEqual(plan.completed, 0)
    }
}
