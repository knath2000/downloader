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

    func testCopyBuildsWebDAVCopyRequest() async throws {
        RecordingURLProtocol.requests = []
        RecordingURLProtocol.statusCode = 201
        URLProtocol.registerClass(RecordingURLProtocol.self)
        defer { URLProtocol.unregisterClass(RecordingURLProtocol.self) }

        let client = WebDAVRemoteFileClient(
            baseURL: URL(string: "https://example.test/dav/")!,
            rootPath: "/root",
            user: "user",
            password: "pass"
        )

        try await client.copy(
            itemAt: "/Inbox",
            kind: .folder,
            toDirectory: "/Archive",
            newName: "Inbox copy"
        )

        let request = try XCTUnwrap(RecordingURLProtocol.requests.first)
        XCTAssertEqual(request.httpMethod, "COPY")
        XCTAssertEqual(request.url?.absoluteString, "https://example.test/dav/root/Inbox/")
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Destination"),
            "https://example.test/dav/root/Archive/Inbox%20copy/"
        )
        XCTAssertEqual(request.value(forHTTPHeaderField: "Overwrite"), "F")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Depth"), "infinity")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Basic dXNlcjpwYXNz")
    }

    func testMoveBuildsWebDAVMoveRequest() async throws {
        RecordingURLProtocol.requests = []
        RecordingURLProtocol.statusCode = 201
        URLProtocol.registerClass(RecordingURLProtocol.self)
        defer { URLProtocol.unregisterClass(RecordingURLProtocol.self) }

        let client = WebDAVRemoteFileClient(
            baseURL: URL(string: "https://example.test/dav/")!,
            rootPath: "/root",
            user: "",
            password: ""
        )

        try await client.move(
            itemAt: "/Inbox/video.mp4",
            kind: .file,
            toDirectory: "/Archive",
            newName: "video.mp4"
        )

        let request = try XCTUnwrap(RecordingURLProtocol.requests.first)
        XCTAssertEqual(request.httpMethod, "MOVE")
        XCTAssertEqual(request.url?.absoluteString, "https://example.test/dav/root/Inbox/video.mp4")
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Destination"),
            "https://example.test/dav/root/Archive/video.mp4"
        )
        XCTAssertEqual(request.value(forHTTPHeaderField: "Overwrite"), "F")
    }
}

private final class RecordingURLProtocol: URLProtocol {
    static var requests: [URLRequest] = []
    static var statusCode = 200

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "example.test"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.requests.append(request)
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: Self.statusCode,
            httpVersion: nil,
            headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data())
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
