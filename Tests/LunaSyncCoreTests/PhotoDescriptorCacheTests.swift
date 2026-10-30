import XCTest
@testable import LunaSyncPhotoKit
import LunaSyncCore

final class PhotoDescriptorCacheTests: XCTestCase {
    private func asset(_ id: String) -> AssetDescriptor {
        AssetDescriptor(localIdentifier: id, resources: [])
    }

    func testRepeatedScanReusesMetadataAndChangedAssetKeyLoadsAgain() {
        let cache = PhotoDescriptorCache()
        _ = cache.descriptor(for: "id|version1") { asset("original") }
        let same = cache.descriptor(for: "id|version1") { XCTFail("Repeated scan should reuse metadata"); return asset("wrong") }
        XCTAssertEqual(same.localIdentifier, "original")
        let changed = cache.descriptor(for: "id|version2") { asset("changed") }
        XCTAssertEqual(changed.localIdentifier, "changed")
        XCTAssertEqual(cache.statistics.hits, 1)
        XCTAssertEqual(cache.statistics.loads, 2)
    }

    func testLibraryChangeForcesSameKeyToReload() {
        let cache = PhotoDescriptorCache()
        _ = cache.descriptor(for: "key") { asset("before") }
        cache.invalidate()
        XCTAssertEqual(cache.descriptor(for: "key") { asset("after") }.localIdentifier, "after")
    }

    func testInvalidationDuringLoadingDoesNotRestoreOldMetadata() {
        let cache = PhotoDescriptorCache()
        _ = cache.descriptor(for: "key") {
            cache.invalidate()
            return asset("stale")
        }
        XCTAssertEqual(cache.descriptor(for: "key") { asset("fresh") }.localIdentifier, "fresh")
        XCTAssertEqual(cache.statistics.hits, 0)
    }
}
