import Foundation
import LunaSyncCore

/// A bounded metadata cache. In-flight work from before invalidation cannot repopulate it.
final class PhotoDescriptorCache: @unchecked Sendable {
    private final class Entry {
        let descriptor: AssetDescriptor
        init(_ descriptor: AssetDescriptor) { self.descriptor = descriptor }
    }
    private let lock = NSLock()
    private let entries = NSCache<NSString, Entry>()
    private var revision: UInt64 = 0
    private var hits = 0
    private var loads = 0

    init() {
        entries.countLimit = 50_000
        entries.totalCostLimit = 32 * 1024 * 1024
    }

    func descriptor(for key: String, load: () -> AssetDescriptor) -> AssetDescriptor {
        lock.lock()
        if let entry = entries.object(forKey: key as NSString) {
            hits += 1
            lock.unlock()
            return entry.descriptor
        }
        let startingRevision = revision
        loads += 1
        lock.unlock()
        let descriptor = load()
        let cost = 256 + key.utf8.count + descriptor.resources.reduce(0) {
            $0 + 128 + $1.originalFilename.utf8.count + $1.uniformTypeIdentifier.utf8.count
        }
        lock.lock()
        if startingRevision == revision { entries.setObject(Entry(descriptor), forKey: key as NSString, cost: cost) }
        lock.unlock()
        return descriptor
    }

    func invalidate() {
        lock.lock()
        revision &+= 1
        entries.removeAllObjects()
        lock.unlock()
    }

    var statistics: (hits: Int, loads: Int) {
        lock.lock(); defer { lock.unlock() }
        return (hits, loads)
    }
}
