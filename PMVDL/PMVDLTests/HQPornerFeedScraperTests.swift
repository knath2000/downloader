import XCTest
@testable import VidDL

final class HQPornerFeedScraperTests: XCTestCase {
    func testParsesListingCard() throws {
        let fixture = """
        <section class="box feature">
          <a href="/hdporn/126118-lets_dare_to_e_more_than_this.html" class="image featured non-overlay">
            <div>
              <img id="cover_126118" src="//fastporndelivery.hqporner.com/imgs/6/34/72d97dd8f1a94ff_main.jpg" alt="let's dare to e more than this" />
            </div>
          </a>
          <div id="span-case">
            <h3 class="meta-data-title"><a href="/hdporn/126118-lets_dare_to_e_more_than_this.html" class="click-trigger">let's dare to e more than this</a></h3>
            <span class="icon fa-clock-o meta-data">28m 8s</span>
            <span class="meta-data">HD</span>
          </div>
        </section>
        """

        let now = Date(timeIntervalSince1970: 1_000)
        let items = HQPornerFeedScraper.parseEntries(from: fixture, now: now)

        let item = try XCTUnwrap(items.first)
        XCTAssertEqual(item.id, "hqporner-126118")
        XCTAssertEqual(item.title, "let's dare to e more than this")
        XCTAssertEqual(item.url, "https://hqporner.com/hdporn/126118-lets_dare_to_e_more_than_this.html")
        XCTAssertEqual(item.thumbnailURL, "https://fastporndelivery.hqporner.com/imgs/6/34/72d97dd8f1a94ff_main.jpg")
        XCTAssertEqual(item.referer, "https://hqporner.com/")
        XCTAssertEqual(item.durationSeconds, 1_688)
        XCTAssertEqual(item.siteName, "hqporner.com")
        XCTAssertEqual(item.uploadDate, now)
        XCTAssertTrue(item.qualityLabels.contains("HD"))
    }

    func testDurationParserHandlesMinutesAndSeconds() {
        XCTAssertEqual(HQPornerFeedScraper.durationSeconds(from: "28m 8s"), 1_688)
        XCTAssertEqual(HQPornerFeedScraper.durationSeconds(from: "1h 2m 3s"), 3_723)
        XCTAssertNil(HQPornerFeedScraper.durationSeconds(from: ""))
    }
}
