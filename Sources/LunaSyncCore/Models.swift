import Foundation

public struct ResourceDescriptor: Codable, Hashable, Sendable {
    public let type: Int
    public let ordinal: Int
    public let originalFilename: String
    public let uniformTypeIdentifier: String
    public var key: String { "resource-\(type)-\(ordinal)" }
    public var fileExtension: String {
        let ext = (originalFilename as NSString).pathExtension.lowercased()
        return !ext.isEmpty && ext.count <= 12 && ext.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) && $0.isASCII
        } ? ext : "bin"
    }
    public init(type: Int, ordinal: Int, originalFilename: String, uniformTypeIdentifier: String) {
        self.type = type; self.ordinal = ordinal; self.originalFilename = originalFilename
        self.uniformTypeIdentifier = uniformTypeIdentifier
    }
}

public struct AssetDescriptor: Codable, Hashable, Sendable {
    public let localIdentifier: String
    public let creationDate: Date?
    public let mediaType: Int
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let duration: Double
    public let resources: [ResourceDescriptor]
    public let issue: String?
    public init(localIdentifier: String, creationDate: Date? = nil, mediaType: Int = 1,
                pixelWidth: Int = 0, pixelHeight: Int = 0, duration: Double = 0,
                resources: [ResourceDescriptor], issue: String? = nil) {
        self.localIdentifier = localIdentifier; self.creationDate = creationDate; self.mediaType = mediaType
        self.pixelWidth = pixelWidth; self.pixelHeight = pixelHeight; self.duration = duration
        self.resources = resources; self.issue = issue
    }
    public var fingerprint: String {
        // Edits do not change this identity: modificationDate is intentionally excluded.
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return SHA256Digest.hex((try? encoder.encode(self)) ?? Data())
    }
    public func key(sourceID: UUID) -> String {
        SHA256Digest.hex(Data((sourceID.uuidString.lowercased() + "\n" + localIdentifier).utf8))
    }
}

public struct LibrarySource: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let name: String
    public let createdAt: Date
    public init(id: UUID = UUID(), name: String, createdAt: Date = Date()) {
        self.id = id; self.name = name; self.createdAt = createdAt
    }
}

public struct ArchiveMetadata: Codable, Sendable {
    public var formatVersion: Int = 1
    public let archiveID: UUID
    public let createdAt: Date
    public var sources: [LibrarySource]
    public init() { archiveID = UUID(); createdAt = Date(); sources = [] }
}

public struct ResourceReceipt: Codable, Equatable, Sendable {
    public let descriptor: ResourceDescriptor
    public let relativePath: String
    public let byteCount: UInt64
    public let sha256: String
    public let completedAt: Date
}

public struct AssetGeneration: Codable, Sendable {
    public let id: UUID
    public let asset: AssetDescriptor
    public var resources: [String: ResourceReceipt]
    public var isComplete: Bool {
        asset.issue == nil && !asset.resources.isEmpty && asset.resources.allSatisfy { resources[$0.key] != nil }
    }
}

public struct AssetRecord: Codable, Sendable {
    public let assetKey: String
    public let sourceID: UUID
    public let localIdentifier: String
    public var generations: [AssetGeneration]
}

public enum BackupFailure: Error, LocalizedError, Sendable {
    case cloudOnly, permissionDenied, unavailable(String), unsafePath, unsupportedFormat(Int)
    case corruptRecord(String), integrityMismatch, destinationUnavailable(String), unsupportedAsset(String)
    public var errorDescription: String? {
        switch self {
        case .cloudOnly: return "原片不在本机，请开启 iCloud 原片下载后重试。"
        case .permissionDenied: return "照片或目录权限不可用，请重新授权。"
        case .unavailable(let message): return message
        case .unsafePath: return "备份路径不安全，已停止操作。"
        case .unsupportedFormat(let version): return "无法写入格式版本 \(version) 的档案。"
        case .corruptRecord(let key): return "备份记录损坏：\(key)"
        case .integrityMismatch: return "文件读回校验失败，未标记为成功。"
        case .destinationUnavailable(let message): return "备份目录不可写或已断开：\(message)"
        case .unsupportedAsset(let message): return "资源组合需检查：\(message)"
        }
    }
    public var stopsSession: Bool {
        switch self {
        case .destinationUnavailable, .unsafePath, .unsupportedFormat, .corruptRecord: return true
        default: return false
        }
    }
}

public protocol PhotoLibrarySource: Sendable {
    func scan(includeVideos: Bool) async throws -> [AssetDescriptor]
    func read(asset: AssetDescriptor, resource: ResourceDescriptor, allowNetwork: Bool,
              consume: @escaping @Sendable (Data) throws -> Void) async throws
}

public struct BackupPlan: Sendable {
    public var pending: [AssetDescriptor] = []
    public var completed: Int = 0
    public var needsReview: [String: String] = [:]
    public init() {}
}

public enum BackupEvent: Sendable {
    case scanning, planned(total: Int, completed: Int)
    case transferring(assetID: String, filename: String, bytes: UInt64)
    case verifying(String), completed(String), failed(assetID: String, message: String, cloudOnly: Bool)
    case paused, finished, recoveryWarning(String)
}

public struct VerificationResult: Sendable {
    public var checked = 0
    public var issues: [String] = []
    public init() {}
}

public struct ArchiveSnapshot: Sendable {
    public let records: [AssetRecord]
    public let issues: [String]
}
