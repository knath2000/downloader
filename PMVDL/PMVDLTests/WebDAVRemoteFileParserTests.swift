import XCTest
@testable import VidDL

final class WebDAVRemoteFileParserTests: XCTestCase {
    func testParsePropfindResponse() throws {
        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <d:multistatus xmlns:d="DAV:">
          <d:response>
            <d:href>/dav/videos/</d:href>
            <d:propstat>
              <d:prop>
                <d:resourcetype><d:collection/></d:resourcetype>
                <d:displayname>videos</d:displayname>
              </d:prop>
            </d:propstat>
          </d:response>
          <d:response>
            <d:href>/dav/videos/movie.mp4</d:href>
            <d:propstat>
              <d:prop>
                <d:getcontentlength>1234</d:getcontentlength>
                <d:getcontenttype>video/mp4</d:getcontenttype>
                <d:getlastmodified>Tue, 05 May 2026 12:00:00 GMT</d:getlastmodified>
              </d:prop>
            </d:propstat>
          </d:response>
        </d:multistatus>
        """.data(using: .utf8)!

        let entries = try WebDAVMultiStatusParser.parse(data: xml)

        XCTAssertEqual(entries.count, 2)
        XCTAssertTrue(entries[0].isCollection)
        XCTAssertEqual(entries[1].contentLength, 1234)
        XCTAssertEqual(entries[1].contentType, "video/mp4")
    }
}
