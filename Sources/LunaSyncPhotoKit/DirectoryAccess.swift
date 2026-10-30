import Foundation
import LunaSyncCore

#if os(iOS)
/// One scope is held for the lifetime of the opened archive, including all IO.
public final class DirectoryAccess: @unchecked Sendable {
    public let url: URL
    private let scoped: Bool
    public init(url: URL) throws {
        self.url = url
        scoped = url.startAccessingSecurityScopedResource()
        // Some provider URLs are already accessible without an additional scope.
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            if scoped { url.stopAccessingSecurityScopedResource() }
            throw BackupFailure.permissionDenied
        }
    }
    public convenience init(bookmark: Data) throws {
        var stale = false
        let url = try URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
        guard !stale else { throw BackupFailure.unavailable(BackupCopy.tr("diagnostic.5c5d83fe")) }
        try self.init(url: url)
    }
    public func bookmark() throws -> Data {
        // .withSecurityScope is macOS-only; iOS directory-picker URLs carry scope.
        try url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
    }
    deinit { if scoped { url.stopAccessingSecurityScopedResource() } }
}
#endif
