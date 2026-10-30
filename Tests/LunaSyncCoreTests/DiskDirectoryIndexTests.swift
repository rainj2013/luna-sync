import XCTest
@testable import LunaSyncCore

final class DiskDirectoryIndexTests: XCTestCase {
    func testFiftyThousandFilesFilteringSortingAndPreviewPositions() async throws {
        try await Task.detached {
            let root = URL(fileURLWithPath: "/test-drive")
            let entries = (0..<50_000).map { index in
                DiskEntry(url: root.appendingPathComponent("IMG_\(index).\(index.isMultiple(of: 5) ? "mov" : "jpg")"),
                          kind: index.isMultiple(of: 5) ? .video : .image,
                          modifiedAt: Date(timeIntervalSince1970: Double(index)))
            } + [DiskEntry(url: root.appendingPathComponent("Folder"), kind: .directory)]
            let start = Date()
            let all = try DiskDirectoryIndex(entries: entries)
            XCTAssertEqual(all.entries.count, 50_001)
            XCTAssertEqual(all.rows.count, 1)
            XCTAssertEqual(all.media.count, 50_000)
            XCTAssertEqual(all.entries.first?.kind, .directory)
            XCTAssertEqual(all.media.first?.name, "IMG_49999.jpg")
            for position in [0, 123, 25_000, 49_999] {
                XCTAssertEqual(all.previewIndices[all.previewURLs[position]], position)
            }
            let photos = try DiskDirectoryIndex(entries: entries, filter: .photos, newestFirst: false)
            XCTAssertEqual(photos.media.count, 40_000)
            XCTAssertEqual(photos.entries.first?.kind, .directory)
            XCTAssertEqual(photos.media.prefix(3).map(\.name), ["IMG_1.jpg", "IMG_2.jpg", "IMG_3.jpg"])
            let videos = try DiskDirectoryIndex(entries: entries, filter: .videos)
            XCTAssertEqual(videos.media.count, 10_000)
            let search = try DiskDirectoryIndex(entries: entries, search: "img_49999")
            XCTAssertEqual(search.entries.map(\.name), ["IMG_49999.jpg"])
            print("50,000-file directory index, filters, name sort and search: \(Date().timeIntervalSince(start))s (metadata only)")
        }.value
    }

    func testReadingDirectoryClassifiesFilesAndSkipsHiddenMetadata() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["photo.HEIC", "clip.MOV", "notes.txt", ".luna-sync"] {
            try Data().write(to: root.appendingPathComponent(name))
        }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Album"), withIntermediateDirectories: false)
        let entries = try DiskDirectoryIndex.read(root)
        XCTAssertEqual(entries.count, 4)
        XCTAssertEqual(entries.first { $0.name == "photo.HEIC" }?.kind, .image)
        XCTAssertEqual(entries.first { $0.name == "clip.MOV" }?.kind, .video)
        XCTAssertEqual(entries.first { $0.name == "Album" }?.kind, .directory)
        XCTAssertEqual(try DiskDirectoryIndex(entries: entries).previewURLs.count, 3)
    }

    func testMediaPreviewSkipsDocumentsAndPreservesFilteredOrder() throws {
        let root = URL(fileURLWithPath: "/drive")
        let source = [DiskEntry(url: root.appendingPathComponent("a.txt"), kind: .other),
                      DiskEntry(url: root.appendingPathComponent("b.jpg"), kind: .image),
                      DiskEntry(url: root.appendingPathComponent("c.mov"), kind: .video)]
        let all = try DiskDirectoryIndex(entries: source, newestFirst: false)
        XCTAssertEqual(all.mediaPreviewURLs.map(\.lastPathComponent), ["b.jpg", "c.mov"])
        XCTAssertEqual(all.mediaPreviewIndices[source[2].url], 1)
        XCTAssertNil(all.mediaPreviewIndices[source[0].url])
        let photos = try DiskDirectoryIndex(entries: source, filter: .photos)
        XCTAssertEqual(photos.mediaPreviewURLs, [source[1].url])
        XCTAssertEqual(photos.mediaPreviewIndices[source[1].url], 0)
    }

    func testDeleteFileAndNonemptyFolderPreservesOtherFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let folder = root.appendingPathComponent("Untitled Folder")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let photo = root.appendingPathComponent("photo.jpg")
        let keep = root.appendingPathComponent("keep.jpg")
        try Data([1]).write(to: photo)
        try Data([2]).write(to: keep)
        try Data([3]).write(to: folder.appendingPathComponent("nested.jpg"))
        try DiskDirectoryIndex.delete(photo, in: root)
        try DiskDirectoryIndex.delete(folder, in: root)
        XCTAssertEqual(try DiskDirectoryIndex.read(root).map(\.name), ["keep.jpg"])
        XCTAssertEqual(try Data(contentsOf: keep), Data([2]))
    }

    func testDeleteRejectsRootOutsidePathsAndHiddenMetadata() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let hidden = root.appendingPathComponent(".luna-sync")
        try Data([1]).write(to: hidden)
        for target in [root, root.deletingLastPathComponent(), root.appendingPathComponent("../outside.jpg"), hidden] {
            XCTAssertThrowsError(try DiskDirectoryIndex.delete(target, in: root))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.path))
        XCTAssertEqual(try Data(contentsOf: hidden), Data([1]))
    }

    func testDeleteSymlinkDoesNotDeleteItsDestination() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        let keep = outside.appendingPathComponent("keep.jpg")
        try Data([9]).write(to: keep)
        let link = root.appendingPathComponent("linked-folder")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        try DiskDirectoryIndex.delete(link, in: root)
        XCTAssertEqual(try Data(contentsOf: keep), Data([9]))
    }

    func testCancelledIndexDoesNotPublishStaleResults() async {
        let worker = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return try DiskDirectoryIndex(entries: [DiskEntry(url: URL(fileURLWithPath: "/test.jpg"), kind: .image)])
        }
        do { _ = try await worker.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
    }
}
