import XCTest
@testable import VidDL

final class ThumbnailCacheTests: XCTestCase {
    func testCacheKeyIsDeterministicAndSafe() {
        let url = "https://cdn.pmvhaven.com/thumbs/appetite.jpg"

        let first = ThumbnailCache.cacheKey(for: url)
        let second = ThumbnailCache.cacheKey(for: url)

        XCTAssertEqual(first, second)
        XCTAssertTrue(first.hasPrefix("viddl_thumb_"))
        XCTAssertTrue(first.hasSuffix(".jpg"))
        XCTAssertFalse(first.contains("/"))
        XCTAssertFalse(first.contains(":"))
    }

    func testDifferentURLsProduceDifferentKeys() {
        let a = ThumbnailCache.cacheKey(for: "https://example.test/a.jpg")
        let b = ThumbnailCache.cacheKey(for: "https://example.test/b.jpg")
        XCTAssertNotEqual(a, b)
    }
}
