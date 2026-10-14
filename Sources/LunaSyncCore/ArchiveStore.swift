import Foundation
#if os(Linux)
import Glibc
#else
import Darwin
#endif

public enum CommitStage: Sendable { case prepared, dataWritten, verified, promoted, recorded }

/// Confined to BackupCoordinator's actor (or a single test thread). Disk records,
/// not the phone's cache, decide whether a resource is complete.
public final class ArchiveStore {
    public let root: URL
    public private(set) var metadata: ArchiveMetadata
    private let fm = FileManager.default
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; return encoder
    }()
    private let decoder = JSONDecoder()
    // A deterministic fault-injection seam for crash recovery tests.
    public var checkpoint: ((CommitStage) throws -> Void)?

    public init(root: URL, create: Bool = false) throws {
        self.root = root.standardizedFileURL.resolvingSymlinksInPath()
        metadata = ArchiveMetadata()
        let marker = self.root.appendingPathComponent("archive.json")
        if fm.fileExists(atPath: marker.path) {
            guard marker.resolvingSymlinksInPath().path.hasPrefix(self.root.path + "/") else { throw BackupFailure.unsafePath }
            do { metadata = try decoder.decode(ArchiveMetadata.self, from: Data(contentsOf: marker)) }
            catch { throw BackupFailure.corruptRecord("archive.json") }
            guard metadata.formatVersion == 1 else { throw BackupFailure.unsupportedFormat(metadata.formatVersion) }
        } else {
            guard create else { throw BackupFailure.unavailable("所选目录没有 Luna Sync 档案。") }
            // Never silently initialize over a damaged or unrelated nonempty archive.
            if fm.fileExists(atPath: self.root.path), !(try fm.contentsOfDirectory(atPath: self.root.path)).isEmpty {
                throw BackupFailure.unavailable("新档案目录必须为空，已有文件不会被覆盖。")
            }
            try fm.createDirectory(at: self.root, withIntermediateDirectories: true)
            try write(metadata, to: "archive.json")
        }
        for directory in ["records", "transactions", "originals"] {
            try fm.createDirectory(at: safeURL(directory), withIntermediateDirectories: true)
        }
        try probeWriteAccess()
    }

    public func addSource(name: String) throws -> LibrarySource {
        let source = LibrarySource(name: name)
        var updated = metadata; updated.sources.append(source)
        try write(updated, to: "archive.json"); metadata = updated
        return source
    }

    public func safeURL(_ relative: String) throws -> URL {
        let parts = relative.split(separator: "/", omittingEmptySubsequences: false)
        guard !relative.isEmpty, !relative.hasPrefix("/"), !relative.contains("\\"),
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\0") }) else {
            throw BackupFailure.unsafePath
        }
        let target = root.appendingPathComponent(relative).standardizedFileURL
        // Foundation on Linux may not resolve a symlink ancestor when the final
        // file does not exist. Reject symlink components explicitly, including
        // dangling links, rather than relying solely on URL normalization.
        var ancestor = root
        for part in parts {
            ancestor.appendPathComponent(String(part))
            if (try? fm.destinationOfSymbolicLink(atPath: ancestor.path)) != nil { throw BackupFailure.unsafePath }
        }
        let resolved = target.resolvingSymlinksInPath().path
        guard resolved.hasPrefix(root.path + "/") else { throw BackupFailure.unsafePath }
        return target
    }

    public func record(for asset: AssetDescriptor, sourceID: UUID) throws -> AssetRecord? {
        try loadRecord(key: asset.key(sourceID: sourceID))
    }

    public func records() throws -> [AssetRecord] {
        let result = try snapshot()
        guard result.issues.isEmpty else { throw BackupFailure.corruptRecord(result.issues.joined(separator: "\n")) }
        return result.records
    }

    public func snapshot() throws -> ArchiveSnapshot {
        var records: [AssetRecord] = [], issues: [String] = []
        for path in try recordPaths() {
            do {
                let record = try read(AssetRecord.self, from: path)
                try validate(record)
                guard recordPath(record.assetKey) == path else { throw BackupFailure.corruptRecord(path) }
                records.append(record)
            } catch BackupFailure.corruptRecord(let message) { issues.append(message) }
        }
        return ArchiveSnapshot(records: records, issues: issues)
    }

    public func plan(assets: [AssetDescriptor], sourceID: UUID) throws -> BackupPlan {
        guard metadata.sources.contains(where: { $0.id == sourceID }) else {
            throw BackupFailure.unavailable("请先选择照片库来源。")
        }
        var plan = BackupPlan()
        for asset in assets {
            if let issue = asset.issue { plan.needsReview[asset.localIdentifier] = issue; continue }
            if asset.resources.isEmpty { plan.needsReview[asset.localIdentifier] = "未找到原始资源"; continue }
            let record: AssetRecord?
            do { record = try self.record(for: asset, sourceID: sourceID) }
            catch BackupFailure.corruptRecord(let message) {
                plan.needsReview[asset.localIdentifier] = "记录损坏，已保留文件并跳过该资产：\(message)"
                continue
            }
            if let generation = record?.generations.last(where: { $0.asset.fingerprint == asset.fingerprint }),
               generation.isComplete, try generation.resources.values.allSatisfy({ try isPresent($0) }) {
                plan.completed += 1
            } else { plan.pending.append(asset) }
        }
        return plan
    }

    /// Re-association is explicit. At least one recorded ID must resolve, and
    /// every overlapping asset must have a matching original-resource signature.
    public func validateAssociation(assets: [AssetDescriptor], sourceID: UUID) throws {
        let previous = try records().filter { $0.sourceID == sourceID }
        guard !previous.isEmpty else { return }
        let byID = Dictionary(assets.map { ($0.localIdentifier, $0) }, uniquingKeysWith: { first, _ in first })
        var overlap = 0
        for record in previous {
            guard let current = byID[record.localIdentifier] else { continue }
            overlap += 1
            guard record.generations.contains(where: { $0.asset.fingerprint == current.fingerprint }) else {
                throw BackupFailure.unavailable("照片库关联存在冲突，请作为新照片库备份。")
            }
        }
        guard overlap > 0 else { throw BackupFailure.unavailable("无法核对原照片库，请授予更多照片权限或作为新照片库备份。") }
    }

    public func ensureGeneration(asset: AssetDescriptor, sourceID: UUID) throws -> AssetGeneration {
        let key = asset.key(sourceID: sourceID)
        var record = try loadRecord(key: key) ?? AssetRecord(assetKey: key, sourceID: sourceID,
            localIdentifier: asset.localIdentifier, generations: [])
        if let existing = record.generations.last(where: { $0.asset.fingerprint == asset.fingerprint }) { return existing }
        let generation = AssetGeneration(id: UUID(), asset: asset, resources: [:])
        record.generations.append(generation)
        try write(record, to: recordPath(key))
        return generation
    }

    public func isPresent(_ receipt: ResourceReceipt) throws -> Bool {
        let url = try safeURL(receipt.relativePath)
        guard fm.fileExists(atPath: url.path) else { return false }
        let attributes = try fm.attributesOfItem(atPath: url.path)
        return attributes[.type] as? FileAttributeType == .typeRegular &&
            (attributes[.size] as? NSNumber)?.uint64Value == receipt.byteCount
    }

    struct Transaction: Codable {
        let id: UUID
        let assetKey: String
        let sourceID: UUID
        let generationID: UUID
        let asset: AssetDescriptor
        let resource: ResourceDescriptor
        let partialPath: String
        let finalPath: String
        var receipt: ResourceReceipt?
    }

    func prepare(asset: AssetDescriptor, sourceID: UUID, generation: AssetGeneration,
                 resource: ResourceDescriptor) throws -> Transaction {
        let id = UUID(), key = asset.key(sourceID: sourceID)
        var datePath = "undated"
        if let date = asset.creationDate {
            var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
            let parts = calendar.dateComponents([.year, .month], from: date)
            datePath = String(format: "%04d/%02d", parts.year!, parts.month!)
        }
        // Each attempt uses a new filename; damaged originals are never overwritten.
        let directory = "originals/\(datePath)/\(key)/\(generation.id.uuidString.lowercased())"
        let finalPath = "\(directory)/\(resource.key)-\(id.uuidString.lowercased()).\(resource.fileExtension)"
        let transaction = Transaction(id: id, assetKey: key, sourceID: sourceID,
            generationID: generation.id, asset: asset, resource: resource,
            partialPath: finalPath + ".partial", finalPath: finalPath, receipt: nil)
        try fm.createDirectory(at: safeURL(directory), withIntermediateDirectories: true)
        try write(transaction, to: transactionPath(id))
        try checkpoint?(.prepared)
        return transaction
    }

    func commit(_ initial: Transaction, bytes: UInt64, hash: String) throws {
        try checkpoint?(.dataWritten)
        let actual = try SHA256Digest.file(safeURL(initial.partialPath))
        guard bytes > 0, actual.bytes == bytes, actual.hash == hash else { throw BackupFailure.integrityMismatch }
        var transaction = initial
        transaction.receipt = ResourceReceipt(descriptor: transaction.resource, relativePath: transaction.finalPath,
            byteCount: bytes, sha256: hash, completedAt: Date())
        // Persist expected content BEFORE moving the file; recovery can now prove it.
        try write(transaction, to: transactionPath(transaction.id))
        try checkpoint?(.verified)
        try fm.moveItem(at: safeURL(transaction.partialPath), to: safeURL(transaction.finalPath))
        try checkpoint?(.promoted)
        try apply(transaction)
        try checkpoint?(.recorded)
        try fm.removeItem(at: safeURL(transactionPath(transaction.id)))
    }

    public func recover() throws -> [String] {
        var warnings: [String] = []
        let directory = try safeURL("transactions")
        for url in try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).sorted(by: { $0.path < $1.path })
            where url.pathExtension == "json" {
            let path = "transactions/" + url.lastPathComponent
            do {
                let transaction = try read(Transaction.self, from: path)
                guard transactionPath(transaction.id) == path,
                      transaction.assetKey == transaction.asset.key(sourceID: transaction.sourceID),
                      transaction.resource.key == transaction.receipt?.descriptor.key || transaction.receipt == nil else {
                    throw BackupFailure.corruptRecord(path)
                }
                let final = try safeURL(transaction.finalPath), partial = try safeURL(transaction.partialPath)
                guard transaction.finalPath.hasPrefix("originals/"), transaction.partialPath == transaction.finalPath + ".partial",
                      transaction.receipt == nil || transaction.receipt?.relativePath == transaction.finalPath else {
                    throw BackupFailure.unsafePath
                }
                if let receipt = transaction.receipt {
                    if !fm.fileExists(atPath: final.path), fm.fileExists(atPath: partial.path) {
                        let actual = try SHA256Digest.file(partial)
                        if actual.bytes == receipt.byteCount && actual.hash == receipt.sha256 {
                            try fm.moveItem(at: partial, to: final)
                        }
                    }
                    if fm.fileExists(atPath: final.path) {
                        let actual = try SHA256Digest.file(final)
                        if actual.bytes == receipt.byteCount && actual.hash == receipt.sha256 { try apply(transaction) }
                        else {
                            try invalidate(assetKey: transaction.assetKey, generationID: transaction.generationID, receipt: receipt)
                            warnings.append("校验失败，保留文件并安排重传：\(transaction.asset.localIdentifier)")
                        }
                    }
                }
                if fm.fileExists(atPath: partial.path) { try fm.removeItem(at: partial) }
                try fm.removeItem(at: safeURL(path))
            } catch let failure as BackupFailure {
                // A bad journal is preserved and blocks further writing, not silently discarded.
                throw failure
            } catch { throw BackupFailure.destinationUnavailable(error.localizedDescription) }
        }
        return warnings
    }

    public func verify(cancelled: () -> Bool = { false }, progress: (Int) -> Void = { _ in }) throws -> VerificationResult {
        var result = VerificationResult()
        for path in try recordPaths() {
            if cancelled() { throw CancellationError() }
            let record: AssetRecord
            do { record = try read(AssetRecord.self, from: path); try validate(record) }
            catch { result.issues.append("\(path)：\(error.localizedDescription)"); continue }
            for generation in record.generations {
                for receipt in generation.resources.values {
                    if cancelled() { throw CancellationError() }
                    do {
                        let actual = try SHA256Digest.file(safeURL(receipt.relativePath))
                        if actual.bytes != receipt.byteCount || actual.hash != receipt.sha256 {
                            result.issues.append("校验不符：\(receipt.relativePath)")
                            // Invalidate the receipt; leave the damaged file for inspection.
                            try invalidate(assetKey: record.assetKey, generationID: generation.id, receipt: receipt)
                        }
                    } catch {
                        result.issues.append("无法校验：\(receipt.relativePath)：\(error.localizedDescription)")
                        try invalidate(assetKey: record.assetKey, generationID: generation.id, receipt: receipt)
                    }
                    result.checked += 1; progress(result.checked)
                }
            }
        }
        return result
    }

    private func apply(_ transaction: Transaction) throws {
        guard let receipt = transaction.receipt else { throw BackupFailure.corruptRecord("事务没有校验值") }
        var record = try loadRecord(key: transaction.assetKey) ?? AssetRecord(assetKey: transaction.assetKey,
            sourceID: transaction.sourceID, localIdentifier: transaction.asset.localIdentifier, generations: [])
        if !record.generations.contains(where: { $0.id == transaction.generationID }) {
            record.generations.append(AssetGeneration(id: transaction.generationID, asset: transaction.asset, resources: [:]))
        }
        let index = record.generations.firstIndex(where: { $0.id == transaction.generationID })!
        guard record.generations[index].asset == transaction.asset else { throw BackupFailure.corruptRecord(transaction.assetKey) }
        record.generations[index].resources[transaction.resource.key] = receipt
        try write(record, to: recordPath(transaction.assetKey))
    }

    private func invalidate(assetKey: String, generationID: UUID, receipt: ResourceReceipt) throws {
        guard var updated = try loadRecord(key: assetKey),
              let index = updated.generations.firstIndex(where: { $0.id == generationID }),
              updated.generations[index].resources[receipt.descriptor.key]?.relativePath == receipt.relativePath else { return }
        updated.generations[index].resources.removeValue(forKey: receipt.descriptor.key)
        try write(updated, to: recordPath(assetKey))
    }

    private func validate(_ record: AssetRecord) throws {
        guard metadata.sources.contains(where: { $0.id == record.sourceID }),
              record.assetKey.count == 64,
              record.generations.allSatisfy({ $0.asset.localIdentifier == record.localIdentifier &&
                  $0.asset.key(sourceID: record.sourceID) == record.assetKey }) else {
            throw BackupFailure.corruptRecord(record.assetKey)
        }
        for generation in record.generations {
            for (key, receipt) in generation.resources {
                guard key == receipt.descriptor.key, generation.asset.resources.contains(receipt.descriptor),
                      receipt.relativePath.hasPrefix("originals/"), receipt.byteCount > 0,
                      receipt.sha256.count == 64 else { throw BackupFailure.corruptRecord(record.assetKey) }
                _ = try safeURL(receipt.relativePath)
            }
        }
    }

    private func loadRecord(key: String) throws -> AssetRecord? {
        let path = recordPath(key)
        guard fm.fileExists(atPath: try safeURL(path).path) else { return nil }
        let record = try read(AssetRecord.self, from: path)
        try validate(record)
        guard record.assetKey == key else { throw BackupFailure.corruptRecord(path) }
        return record
    }
    private func recordPath(_ key: String) -> String { "records/\(key.prefix(2))/\(key).json" }
    private func transactionPath(_ id: UUID) -> String { "transactions/\(id.uuidString.lowercased()).json" }
    private func recordPaths() throws -> [String] {
        let base = try safeURL("records")
        var traversalError: Error?
        guard let enumerator = fm.enumerator(at: base, includingPropertiesForKeys: [.isSymbolicLinkKey],
            options: [], errorHandler: { _, error in traversalError = error; return false }) else {
            throw BackupFailure.destinationUnavailable("无法读取索引目录")
        }
        var paths: [String] = []
        for case let url as URL in enumerator where url.pathExtension == "json" {
            let path = String(url.path.dropFirst(root.path.count + 1))
            _ = try safeURL(path); paths.append(path)
        }
        if let traversalError { throw BackupFailure.destinationUnavailable(traversalError.localizedDescription) }
        return paths.sorted()
    }
    private func read<T: Decodable>(_ type: T.Type, from relative: String) throws -> T {
        do { return try decoder.decode(type, from: Data(contentsOf: safeURL(relative))) }
        catch let error as BackupFailure { throw error }
        catch let error as DecodingError { throw BackupFailure.corruptRecord("\(relative)：\(error.localizedDescription)") }
        catch { throw BackupFailure.destinationUnavailable(error.localizedDescription) }
    }
    private func write<T: Encodable>(_ value: T, to relative: String) throws {
        let url = try safeURL(relative)
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).tmp")
        do {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try encoder.encode(value)
            guard fm.createFile(atPath: temporary.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
            let handle = try FileHandle(forWritingTo: temporary)
            do { try handle.write(contentsOf: data); try handle.synchronize(); try handle.close() }
            catch { try? handle.close(); throw error }
            // POSIX rename atomically replaces metadata without an unlink window.
            let status = temporary.path.withCString { from in url.path.withCString { to in rename(from, to) } }
            guard status == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            guard try Data(contentsOf: url) == data else { throw BackupFailure.integrityMismatch }
        } catch {
            try? fm.removeItem(at: temporary)
            if let failure = error as? BackupFailure { throw failure }
            throw BackupFailure.destinationUnavailable(error.localizedDescription)
        }
    }
    private func probeWriteAccess() throws {
        let probe = try safeURL(".probe-\(UUID().uuidString)")
        do { try Data([0]).write(to: probe, options: .withoutOverwriting); try fm.removeItem(at: probe) }
        catch { throw BackupFailure.destinationUnavailable(error.localizedDescription) }
    }
}
