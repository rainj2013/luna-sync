import Foundation

/// PhotoKit invokes a serial callback queue. Locking also makes cancellation and
/// synthetic sources safe; no unbounded async chunk queue is created.
public final class ResourceSink: @unchecked Sendable {
    private let lock = NSLock()
    private var handle: FileHandle?
    private var hash = SHA256Digest()
    private var count: UInt64 = 0
    public init(url: URL) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw BackupFailure.destinationUnavailable("无法创建临时文件")
        }
        handle = try FileHandle(forWritingTo: url)
    }
    public func append(_ data: Data) throws -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        guard let handle else { throw CancellationError() }
        do { try handle.write(contentsOf: data) }
        catch { throw BackupFailure.destinationUnavailable(error.localizedDescription) }
        hash.update(data); count += UInt64(data.count)
        return count
    }
    public func finish() throws -> (bytes: UInt64, hash: String) {
        lock.lock(); defer { lock.unlock() }
        guard let file = handle else { throw CancellationError() }
        try file.synchronize(); try file.close(); handle = nil
        return (count, hash.finalize())
    }
    public func close() { lock.lock(); defer { lock.unlock() }; try? handle?.close(); handle = nil }
    deinit { close() }
}
