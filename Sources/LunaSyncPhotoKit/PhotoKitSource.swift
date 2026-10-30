import Foundation
import LunaSyncCore

#if os(iOS)
import Photos

public final class PhotoKitSource: NSObject, PhotoLibrarySource, PHPhotoLibraryChangeObserver, @unchecked Sendable {
    private let metadataCache = PhotoDescriptorCache()
    private static let knownResourceTypes: Set<PHAssetResourceType> = [.photo, .video, .audio, .alternatePhoto,
            .fullSizePhoto, .fullSizeVideo, .adjustmentData, .adjustmentBasePhoto,
            .pairedVideo, .fullSizePairedVideo, .adjustmentBasePairedVideo,
            .adjustmentBaseVideo, .photoProxy]


    public override init() {
        super.init()
        PHPhotoLibrary.shared().register(self)
    }

    deinit { PHPhotoLibrary.shared().unregisterChangeObserver(self) }

    public func photoLibraryDidChange(_ changeInstance: PHChange) {
        metadataCache.invalidate()
    }

    #if DEBUG
    public var scanCacheStatistics: [String: Int] {
        let statistics = metadataCache.statistics
        return ["hits": statistics.hits, "resourceQueries": statistics.loads]
    }
    #endif

    private func scanDescription(_ asset: PHAsset) -> AssetDescriptor {
        // Fetch PhotoKit's current asset list every scan. A changed timestamp or
        // descriptor field misses the cache even before the change observer fires.
        let key = "\(asset.localIdentifier)|\(asset.modificationDate?.timeIntervalSinceReferenceDate.description ?? "nil")|\(asset.creationDate?.timeIntervalSinceReferenceDate.description ?? "nil")|\(asset.mediaType.rawValue)|\(asset.mediaSubtypes.rawValue)|\(asset.pixelWidth)|\(asset.pixelHeight)|\(asset.duration)"
        return metadataCache.descriptor(for: key) { Self.describe(asset) }
    }

    public static func authorization() async -> PHAuthorizationStatus {
        await PHPhotoLibrary.requestAuthorization(for: .readWrite)
    }

    public func scan(includeVideos: Bool) async throws -> [AssetDescriptor] {
        try await scan(includeVideos: includeVideos, selection: .all)
    }

    public func scan(includeVideos: Bool, selection: BackupSelection) async throws -> [AssetDescriptor] {
        let scan = Task.detached(priority: .userInitiated) {
            let authorization = PHPhotoLibrary.authorizationStatus(for: .readWrite)
            guard authorization == .authorized || authorization == .limited else { throw BackupFailure.permissionDenied }
            let options = PHFetchOptions()
            var predicates = [NSPredicate(format: includeVideos ? "mediaType == 1 OR mediaType == 2" : "mediaType == 1")]
            if let start = selection.startDate { predicates.append(NSPredicate(format: "creationDate >= %@", start as NSDate)) }
            if let end = selection.endDate { predicates.append(NSPredicate(format: "creationDate < %@", end as NSDate)) }
            options.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
            options.includeAllBurstAssets = true
            options.includeHiddenAssets = true
            options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
            let fetch: PHFetchResult<PHAsset>
            if let identifiers = selection.localIdentifiers {
                guard !identifiers.isEmpty else { return [AssetDescriptor]() }
                fetch = PHAsset.fetchAssets(withLocalIdentifiers: Array(identifiers), options: options)
            } else { fetch = PHAsset.fetchAssets(with: options) }
            var result: [AssetDescriptor] = []
            #if DEBUG
            let diagnose = ProcessInfo.processInfo.arguments.contains("--diagnose-photo-resources")
            var diagnostics: [[String: Any]] = []
            #endif
            result.reserveCapacity(fetch.count)
            for index in 0..<fetch.count {
                try Task.checkCancellation()
                autoreleasepool {
                    let photo = fetch.object(at: index)
                    let description = self.scanDescription(photo)
                    result.append(description)
                    #if DEBUG
                    if diagnose, let issue = description.issue {
                        diagnostics.append([
                            "identifier": photo.localIdentifier, "issue": issue,
                            "mediaType": photo.mediaType.rawValue,
                            "resources": PHAssetResource.assetResources(for: photo).map {
                                ["type": $0.type.rawValue, "filename": $0.originalFilename,
                                 "uti": $0.uniformTypeIdentifier] as [String: Any]
                            }
                        ])
                    }
                    #endif
                }
            }
            #if DEBUG
            if diagnose, let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
                let folder = documents.appendingPathComponent("DesignReview", isDirectory: true)
                try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let report: [String: Any] = ["scanned": result.count, "issues": diagnostics]
                if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                    try? data.write(to: folder.appendingPathComponent("photo-resource-diagnostics.json"), options: .atomic)
                }
            }
            #endif
            return result
        }
        return try await withTaskCancellationHandler { try await scan.value } onCancel: { scan.cancel() }
    }

    private static func originalResources(_ all: [PHAssetResource]) -> [PHAssetResource] {
        all.filter {
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

    private static func describe(_ asset: PHAsset, all: [PHAssetResource]? = nil) -> AssetDescriptor {
        let all = all ?? PHAssetResource.assetResources(for: asset)
        let resources = originalResources(all)
        let descriptions = descriptors(resources)
        // Auxiliary edit resources and deferred photo proxies are known types;
        // they do not replace the original resources exported above.
        let unknownTypes = Set(all.filter {
            !knownResourceTypes.contains($0.type) && !PhotoResourceCompatibility.isSupplementaryAdjustment(
                type: $0.type.rawValue, uniformTypeIdentifier: $0.uniformTypeIdentifier)
        }.map { $0.type.rawValue }).sorted()
        var issue: String?
        if !unknownTypes.isEmpty {
            issue = BackupCopy.format("diagnostic.resource.unknown", unknownTypes.map(String.init).joined(separator: ", "))
        } else if asset.mediaType == .image, !resources.contains(where: { $0.type == .photo }),
                  all.contains(where: { $0.type == .photoProxy }) {
            issue = BackupCopy.tr("diagnostic.resource.proxy")
        } else if descriptions.isEmpty {
            issue = BackupCopy.tr("diagnostic.4af26dea")
        } else if asset.mediaSubtypes.contains(.photoLive) &&
                    (!resources.contains(where: { $0.type == .photo }) || !resources.contains(where: { $0.type == .pairedVideo })) {
            issue = BackupCopy.tr("diagnostic.0b96c825")
        } else if asset.mediaType == .image && !resources.contains(where: { $0.type == .photo }) {
            issue = BackupCopy.tr("diagnostic.cf4f7a2e")
        } else if asset.mediaType == .video && !resources.contains(where: { $0.type == .video }) {
            issue = BackupCopy.tr("diagnostic.f1492818")
        }
        // Identical sort keys cannot safely be assigned persistent ordinals.
        let keys = descriptions.map { "\($0.type)|\($0.originalFilename)|\($0.uniformTypeIdentifier)" }
        if Set(keys).count != keys.count { issue = BackupCopy.tr("diagnostic.d819807c") }
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
                    continuation.resume(throwing: BackupFailure.unavailable(BackupCopy.tr("diagnostic.db3f2bb7"))); return
                }
                let all = PHAssetResource.assetResources(for: current)
                // Export always validates live resource metadata, never a cached descriptor.
                guard Self.describe(current, all: all).fingerprint == asset.fingerprint else {
                    continuation.resume(throwing: BackupFailure.unavailable(BackupCopy.tr("diagnostic.91fd2ff5"))); return
                }
                let resources = Self.originalResources(all)
                let descriptors = Self.descriptors(resources)
                guard let index = descriptors.firstIndex(of: resource) else {
                    continuation.resume(throwing: BackupFailure.unavailable(BackupCopy.tr("diagnostic.799cdab5"))); return
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
                            continuation.resume(throwing: BackupFailure.unavailable(BackupCopy.format("diagnostic.be9abc27", String(describing: error.localizedDescription))))
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
