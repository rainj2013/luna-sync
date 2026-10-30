import Foundation
import UniformTypeIdentifiers

/// Metadata only: never reads image contents while listing a directory.
public struct DiskEntry: Identifiable, Sendable {
    public enum Kind: Sendable { case directory, image, video, other }
    public let url: URL
    public let kind: Kind
    public let size: Int64?
    public let modifiedAt: Date?
    public let name: String
    public var id: URL { url }
    public var isDirectory: Bool { kind == .directory }
    public var isMedia: Bool { kind == .image || kind == .video }

    public init(url: URL, kind: Kind, size: Int64? = nil, modifiedAt: Date? = nil) {
        self.url = url; self.kind = kind; self.size = size; self.modifiedAt = modifiedAt
        name = url.lastPathComponent
    }
}

public struct DiskDirectoryIndex: Sendable {
    public enum Filter: Sendable { case all, photos, videos }
    public let entries: [DiskEntry]
    public let rows: [DiskEntry]
    public let media: [DiskEntry]
    public let mediaPreviewURLs: [URL]
    public let mediaPreviewIndices: [URL: Int]
    public let previewURLs: [URL]
    public let previewIndices: [URL: Int]

    /// Call on a worker task, including when only the sort/search changes.
    public init(entries source: [DiskEntry], filter: Filter = .all, search: String = "", newestFirst: Bool = true) throws {
        var entries: [DiskEntry] = []
        for (index, entry) in source.enumerated() {
            if index % 256 == 0 { try Task.checkCancellation() }
            guard search.isEmpty || entry.name.localizedCaseInsensitiveContains(search) else { continue }
            guard entry.isDirectory || filter == .all || (filter == .photos ? entry.kind == .image : entry.kind == .video) else { continue }
            entries.append(entry)
        }
        entries.sort {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            if newestFirst, $0.modifiedAt != $1.modifiedAt {
                return ($0.modifiedAt ?? .distantPast) > ($1.modifiedAt ?? .distantPast)
            }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        try Task.checkCancellation()
        self.entries = entries
        rows = entries.filter { !$0.isMedia }
        media = entries.filter(\.isMedia)
        mediaPreviewURLs = media.map(\.url)
        mediaPreviewIndices = Dictionary(mediaPreviewURLs.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: { first, _ in first })
        previewURLs = entries.filter { !$0.isDirectory }.map(\.url)
        previewIndices = Dictionary(previewURLs.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: { first, _ in first })
    }

    /// Delete only a visible direct child. Never accepts the current folder or an outside path.
    /// FileManager removes a symbolic link itself rather than following it.
    public static func delete(_ target: URL, in directory: URL) throws {
        let parent = directory.standardizedFileURL
        let child = target.standardizedFileURL
        guard child.isFileURL, parent.isFileURL,
              child != parent, child.deletingLastPathComponent() == parent,
              !child.lastPathComponent.hasPrefix(".") else {
            throw BackupFailure.unsafePath
        }
        try FileManager.default.removeItem(at: child)
    }

    public static func read(_ directory: URL) throws -> [DiskEntry] {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        let urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles])
        var result: [DiskEntry] = []
        result.reserveCapacity(urls.count)
        var kinds: [String: DiskEntry.Kind] = [:]
        for url in urls {
            try Task.checkCancellation()
            try autoreleasepool {
                let values = try url.resourceValues(forKeys: keys)
                guard values.isDirectory == true || values.isRegularFile == true else { return }
                let ext = url.pathExtension.lowercased()
                let kind: DiskEntry.Kind
                if values.isDirectory == true { kind = .directory }
                else if let cached = kinds[ext] { kind = cached }
                else {
                    let type = UTType(filenameExtension: ext)
                    kind = type?.conforms(to: .image) == true ? .image : (type?.conforms(to: .movie) == true ? .video : .other)
                    kinds[ext] = kind
                }
                result.append(DiskEntry(url: url, kind: kind, size: values.fileSize.map(Int64.init), modifiedAt: values.contentModificationDate))
            }
        }
        return result
    }
}
