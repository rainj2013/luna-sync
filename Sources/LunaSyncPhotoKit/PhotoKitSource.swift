import Foundation
import LunaSyncCore

#if os(iOS)
import Photos

public final class PhotoKitSource: PhotoLibrarySource, @unchecked Sendable {
    public init() {}

    public static func authorization() async -> PHAuthorizationStatus {
        await PHPhotoLibrary.requestAuthorization(for: .readWrite)
    }

    public func scan(includeVideos: Bool) async throws -> [AssetDescriptor] {
        let scan = Task.detached(priority: .userInitiated) {
            let authorization = PHPhotoLibrary.authorizationStatus(for: .readWrite)
            guard authorization == .authorized || authorization == .limited else { throw BackupFailure.permissionDenied }
            let options = PHFetchOptions()
            options.predicate = NSPredicate(format: includeVideos ? "mediaType == 1 OR mediaType == 2" : "mediaType == 1")
            options.includeAllBurstAssets = true
            options.includeHiddenAssets = true
            options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
            let fetch = PHAsset.fetchAssets(with: options)
            var result: [AssetDescriptor] = []
            for index in 0..<fetch.count {
                try Task.checkCancellation()
                autoreleasepool { result.append(Self.describe(fetch.object(at: index))) }
            }
            return result
        }
        return try await withTaskCancellationHandler { try await scan.value } onCancel: { scan.cancel() }
    }

    private static func originalResources(_ asset: PHAsset) -> [PHAssetResource] {
        PHAssetResource.assetResources(for: asset).filter {
            [.photo, .video, .audio, .alternatePhoto, .pairedVideo].contains($0.type)
        }.sorted {
            if $0.type.rawValue != $1.type.rawValue { return $0.type.rawValue < $1.type.rawValue }
            if $0.originalFilename != $1.originalFilename { return $0.originalFilename < $1.originalFilename }
            return $0.uniformTypeIdentifier < $1.uniformTypeIdentifier
        }
    }

    private static func descriptors(_ resources: [PHAssetResource]) -> [ResourceDescriptor] {
        var counts: [Int: Int] = [:]
        return resources.map { resource in
            let type = resource.type.rawValue, ordinal = counts[type, default: 0]
            counts[type] = ordinal + 1
            return ResourceDescriptor(type: type, ordinal: ordinal, originalFilename: resource.originalFilename,
                                      uniformTypeIdentifier: resource.uniformTypeIdentifier)
        }
    }

    private static func describe(_ asset: PHAsset) -> AssetDescriptor {
        let resources = originalResources(asset)
        let descriptions = descriptors(resources)
        let all = PHAssetResource.assetResources(for: asset)
        let known: Set<Int> = [1,2,3,4,5,6,7,8,9,10,11]
        var issue: String?
        if all.contains(where: { !known.contains($0.type.rawValue) }) {
            issue = "存在当前版本不认识的照片资源，需人工检查。"
        } else if descriptions.isEmpty {
            issue = "未找到可导出的原始资源。"
        } else if asset.mediaSubtypes.contains(.photoLive) &&
                    (!resources.contains(where: { $0.type == .photo }) || !resources.contains(where: { $0.type == .pairedVideo })) {
            issue = "Live Photo 缺少原始静态图或配套视频。"
        } else if asset.mediaType == .image && !resources.contains(where: { $0.type == .photo }) {
            issue = "照片缺少原始静态图。"
        } else if asset.mediaType == .video && !resources.contains(where: { $0.type == .video }) {
            issue = "视频缺少原始视频资源。"
        }
        // Identical sort keys cannot safely be assigned persistent ordinals.
        let keys = descriptions.map { "\($0.type)|\($0.originalFilename)|\($0.uniformTypeIdentifier)" }
        if Set(keys).count != keys.count { issue = "原始资源描述重复，无法可靠区分。" }
        return AssetDescriptor(localIdentifier: asset.localIdentifier, creationDate: asset.creationDate,
            mediaType: asset.mediaType.rawValue, pixelWidth: asset.pixelWidth, pixelHeight: asset.pixelHeight,
            duration: asset.duration, resources: descriptions, issue: issue)
    }

    public func read(asset: AssetDescriptor, resource: ResourceDescriptor, allowNetwork: Bool,
                     consume: @escaping @Sendable (Data) throws -> Void) async throws {
        let control = RequestControl()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let assets = PHAsset.fetchAssets(withLocalIdentifiers: [asset.localIdentifier], options: nil)
                guard let current = assets.firstObject else {
                    continuation.resume(throwing: BackupFailure.unavailable("照片已删除或访问权限发生变化。")); return
                }
                guard Self.describe(current).fingerprint == asset.fingerprint else {
                    continuation.resume(throwing: BackupFailure.unavailable("扫描后原始资源发生变化，请重新扫描。")); return
                }
                let resources = Self.originalResources(current)
                let descriptors = Self.descriptors(resources)
                guard let index = descriptors.firstIndex(of: resource) else {
                    continuation.resume(throwing: BackupFailure.unavailable("原始资源不可用。")); return
                }
                let options = PHAssetResourceRequestOptions()
                options.isNetworkAccessAllowed = allowNetwork
                let id = PHAssetResourceManager.default().requestData(for: resources[index], options: options) { data in
                    do { try control.check(); try consume(data) }
                    catch { control.fail(error) }
                } completionHandler: { error in
                    if let failure = control.error {
                        continuation.resume(throwing: failure)
                    } else if let error {
                        let ns = error as NSError
                        if ns.domain == PHPhotosErrorDomain && ns.code == PHPhotosError.Code.networkAccessRequired.rawValue {
                            continuation.resume(throwing: BackupFailure.cloudOnly)
                        } else {
                            continuation.resume(throwing: BackupFailure.unavailable("读取原片失败：\(error.localizedDescription)"))
                        }
                    } else { continuation.resume() }
                }
                control.install(id)
            }
        } onCancel: { control.fail(CancellationError()) }
    }
}

private final class RequestControl: @unchecked Sendable {
    private let lock = NSLock()
    private var requestID: PHAssetResourceDataRequestID?
    private var failure: Error?
    var error: Error? { lock.lock(); defer { lock.unlock() }; return failure }
    func check() throws { if let error { throw error } }
    func install(_ id: PHAssetResourceDataRequestID) {
        lock.lock(); requestID = id; let cancel = failure != nil; lock.unlock()
        if cancel { PHAssetResourceManager.default().cancelDataRequest(id) }
    }
    func fail(_ error: Error) {
        lock.lock(); if failure == nil { failure = error }; let id = requestID; lock.unlock()
        if let id { PHAssetResourceManager.default().cancelDataRequest(id) }
    }
}
#endif
