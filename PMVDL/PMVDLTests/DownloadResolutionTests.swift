import XCTest
@testable import VidDL

final class StreamTapeExtractorTests: XCTestCase {
    func testWatchPageJsAssignmentsResolveToTapeContentUrl() async throws {
        let pageURL = URL(string: "https://streamtape.com/v/d3yv4qm2B4hkYq3")!

        let html = """
        <html>
          <head>
            <title>StreamTape Test</title>
          </head>
          <body>
            <div id="ideoooolink" style="display:none;">
              /streamtaped.com/get_video?id=d3yv4qm2B4hkYq3&expires=111&ip=test&token=bad
            </div>
            <span id="captchalink" style="display:none;">
              /streamtape.com/get_video?id=d3yv4qm2B4hkYq3&expires=111&ip=test&token=static
            </span>
            <div id="norobotlink" style="display:none;">
              /streamtape.com/get_video?id=d3yv4qm2B4hkYq3&expires=111&ip=test&token=static
            </div>

            <script>
              document.getElementById('captchalink').innerHTML =
                '/streamt' + ('ape.com/get_video?id=d3yv4qm2B4hkYq3&expires=111&ip=test&token=good').substring(0);
            </script>
          </body>
        </html>
        """

        let finalURL = "https://2303352013.tapecontent.net/radosgw/d3yv4qm2B4hkYq3/video.mp4"

        let source = try await StreamTapeExtractor.extract(
            fromHTML: html,
            url: pageURL,
            redirectResolver: { candidate, referer in
                XCTAssertEqual(candidate, "https://streamtape.com/get_video?id=d3yv4qm2B4hkYq3&expires=111&ip=test&token=good")
                XCTAssertEqual(referer, pageURL)
                return finalURL
            }
        )

        XCTAssertEqual(source.siteName, "StreamTape")
        XCTAssertEqual(source.mp4, finalURL)
        XCTAssertEqual(source.hls.count, 1)
        XCTAssertEqual(source.hls.first?.url, finalURL)
        XCTAssertEqual(source.hls.first?.kind, .direct)
        XCTAssertEqual(source.hls.first?.sourcePageUrl, pageURL.absoluteString)
        XCTAssertEqual(source.hls.first?.headers?["Referer"], pageURL.absoluteString)
        XCTAssertEqual(source.hls.first?.headers?["User-Agent"], NetworkConstants.chromeUserAgent)
    }

    func testEmbedPageSupportsBotlinkRobotlinkAndIdeoolinkAssignments() async throws {
        let pageURL = URL(string: "https://streamtape.com/e/d3yv4qm2B4hkYq3")!

        let html = """
        <html>
          <body>
            <div id="ideoolink" style="display:none;">
              /streamtape.com/get_video?id=d3yv4qm2B4hkYq3&expires=111&ip=test&token=static
            </div>
            <span id="botlink" style="display:none;">
              /streamtape.com/get_video?id=d3yv4qm2B4hkYq3&expires=111&ip=test&token=static
            </span>
            <div id="robotlink" style="display:none;">
              /streamtape.com/get_video?id=d3yv4qm2B4hkYq3&expires=111&ip=test&token=static
            </div>

            <script>
              document.getElementById('robotlink').innerHTML =
                '//streamt' + ('xcdape.com/get_video?id=d3yv4qm2B4hkYq3&expires=111&ip=test&token=embedgood').substring(2).substring(1);
            </script>
          </body>
        </html>
        """

        let finalURL = "https://2303352013.tapecontent.net/radosgw/d3yv4qm2B4hkYq3/embed-video.mp4"

        let source = try await StreamTapeExtractor.extract(
            fromHTML: html,
            url: pageURL,
            redirectResolver: { candidate, _ in
                XCTAssertEqual(candidate, "https://streamtape.com/get_video?id=d3yv4qm2B4hkYq3&expires=111&ip=test&token=embedgood")
                return finalURL
            }
        )

        XCTAssertEqual(source.mp4, finalURL)
        XCTAssertEqual(source.hls.first?.url, finalURL)
        XCTAssertEqual(source.hls.first?.kind, .direct)
    }
}

final class MixDropExtractorTests: XCTestCase {
    func testMixContentSourcesUseInitialByteRangeRequests() throws {
        XCTAssertTrue(MediaRequestHeaders.requiresInitialRange(for: try XCTUnwrap(URL(string: "https://a-delivery49.mxcontent.net/v2/video.mp4"))))
        XCTAssertFalse(MediaRequestHeaders.requiresInitialRange(for: try XCTUnwrap(URL(string: "https://example.test/video.mp4"))))
    }

    func testSupportsCurrentMirrorHost() throws {
        XCTAssertTrue(MixDropExtractor.supports(try XCTUnwrap(URL(string: "https://miiixdrop.net/e/4dvjklq6u3w8md"))))
        XCTAssertTrue(MixDropExtractor.supports(try XCTUnwrap(URL(string: "https://miiiixdrop.net/f/36430q3wfllnwj"))))
    }

    func testMixDropBuildsLiveMirrorFallback() throws {
        let staleURL = try XCTUnwrap(URL(string: "https://mxdrop.to/e/36430q3wfllnwj"))
        XCTAssertEqual(
            MixDropExtractor.fallbackMirrorURL(for: staleURL)?.absoluteString,
            "https://miiiixdrop.net/f/36430q3wfllnwj"
        )
    }

    func testMixDropAcceptsExtensionlessDeliveryURL() async throws {
        let pageURL = try XCTUnwrap(URL(string: "https://miiiixdrop.net/f/36430q3wfllnwj"))
        let mediaURL = "https://a-delivery49.mxcontent.net/d/36430q3wfllnwj/ga10u1fqoagjk2q6kbiea7j9kx5?ab=0&r=https%3A%2F%2Fmiiiixdrop.net%2Ff%2F36430q3wfllnwj"
        let html = "<script>MDCore.wurl = '\(mediaURL)';</script>"

        let source = try await MixDropExtractor.extract(fromHTML: html, url: pageURL)

        XCTAssertEqual(source.mp4, mediaURL)
        XCTAssertEqual(source.hls.first?.headers?["Referer"], pageURL.absoluteString)
    }

    func testMixDropPrefersMDCoreWurlOverAdScriptSrc() async throws {
        let pageURL = URL(string: "https://mixdrop.ag/e/039jlq83he41d6")!

        let html = """
        <html>
          <head>
            <script src="https://www.google.com/recaptcha/api.js"></script>
            <script src="//ys.theretenoned.com/sWKwb4HEQMyg/116946"></script>
          </head>
          <body>
            <script>
              MDCore.vfile = "f94e7458e7c6e118610a0e3eb2541f62.mp4";
              MDCore.wurl = "//q2dgt5pce.mxcontent.net/v2/039jlq83he41d6.mp4?s=sig&e=9999999999&_t=8888888888";
            </script>
          </body>
        </html>
        """

        let source = try await MixDropExtractor.extract(fromHTML: html, url: pageURL)

        XCTAssertEqual(source.siteName, "MixDrop")
        XCTAssertEqual(
            source.mp4,
            "https://q2dgt5pce.mxcontent.net/v2/039jlq83he41d6.mp4?s=sig&e=9999999999&_t=8888888888"
        )
        XCTAssertEqual(source.hls.first?.kind, .direct)
        XCTAssertEqual(source.hls.first?.url, source.mp4)
        XCTAssertEqual(source.hls.first?.headers?["Referer"], pageURL.absoluteString)
        XCTAssertEqual(source.hls.first?.headers?["User-Agent"], NetworkConstants.chromeUserAgent)
        XCTAssertFalse(source.hls.first?.url.contains("ys.theretenoned.com") ?? true)
        XCTAssertFalse(source.hls.first?.url.hasSuffix("f94e7458e7c6e118610a0e3eb2541f62.mp4") ?? true)
    }

    func testMixDropExtractsMDCoreWurlFromDecodedPackerPayload() async throws {
        let pageURL = URL(string: "https://mixdrop.ag/e/039jlq83he41d6")!

        let html = """
        <html>
          <body>
            <script>
            eval(function(p,a,c,k,e,d){e=function(c){return c};if(!''.replace(/^/,String)){while(c--){d[c]=k[c]||c}k=[function(e){return d[e]}];e=function(){return'\\\\w+'};c=1};while(c--){if(k[c]){p=p.replace(new RegExp('\\\\b'+e(c)+'\\\\b','g'),k[c])}}return p}('0.1="//2.3.4/5/6.7?8=9&10=11&12=13";0.14="badfile.mp4";',10,15,'MDCore|wurl|q2dgt5pce|mxcontent|net|v2|039jlq83he41d6|mp4|s|sig|e|9999999999|_t|8888888888|vfile'.split('|'),0,{}))
            </script>
          </body>
        </html>
        """

        let source = try await MixDropExtractor.extract(fromHTML: html, url: pageURL)

        XCTAssertEqual(
            source.mp4,
            "https://q2dgt5pce.mxcontent.net/v2/039jlq83he41d6.mp4?s=sig&e=9999999999&_t=8888888888"
        )
    }
}

final class DoodStreamExtractorTests: XCTestCase {
    func testSupportsVide0DoodAlias() {
        XCTAssertTrue(DoodStreamExtractor.supports(URL(string: "https://vide0.net/e/hxptj42uoxb0")!))
    }

    func testSupportsCurrentDooodsterAlias() {
        XCTAssertTrue(DoodStreamExtractor.supports(URL(string: "https://dooodster.com/e/xm7f2egykc8f")!))
    }

    func testDoodstreamAliasUsesPlaymogoMirror() {
        XCTAssertEqual(
            DoodStreamExtractor.alternatePlaymogoURLForTesting(URL(string: "https://doodstream.com/e/0465n2jwgl4g")!),
            URL(string: "https://playmogo.com/e/0465n2jwgl4g")
        )
    }

    func testTrustedDoodProviderMapsRotatedAliasToPlaymogo() {
        XCTAssertEqual(
            DoodStreamExtractor.alternatePlaymogoURLForTesting(
                URL(string: "https://dooodster.com/e/d5n3b9j5zn5y")!,
                force: true
            ),
            URL(string: "https://playmogo.com/e/d5n3b9j5zn5y")
        )
    }

    func testPlaymogoPassMd5BuildsCloudAtaDirectUrl() async throws {
        let pageURL = URL(string: "https://playmogo.com/e/ta6jhp0sh9jd")!

        let source = try await DoodStreamExtractor.extract(
            fromHTML: playmogoHTML(),
            url: pageURL,
            resolvedPageURL: pageURL,
            playmogoPassResolver: { passURL, referer in
                XCTAssertEqual(referer, pageURL)
                XCTAssertEqual(passURL.path, "/pass_md5/261326014-64-40-1777921946-testhash/lecbqerp8ef0ydxmhy78z1vv")
                return "https://ll288op.cloudatacdn.com/base/video~"
            },
            randomSuffix: { "abcdefghij" },
            nowMilliseconds: { "1777922000000" }
        )

        let expected = "https://ll288op.cloudatacdn.com/base/video~abcdefghij?token=testtoken&expiry=1777922000000"

        XCTAssertEqual(source.siteName, "Playmogo")
        XCTAssertNil(source.mp4)
        XCTAssertEqual(source.hls.first?.url, expected)
        XCTAssertEqual(source.hls.first?.kind, .direct)
        XCTAssertEqual(source.hls.first?.headers?["Referer"], pageURL.absoluteString)
        XCTAssertEqual(source.hls.first?.headers?["User-Agent"], NetworkConstants.chromeUserAgent)
    }

    func testDoodstreamInputThatFinalLoadsAsPlaymogoUsesPlaymogoPipeline() async throws {
        let originalURL = URL(string: "https://doodstream.com/e/ta6jhp0sh9jd")!
        let finalURL = URL(string: "https://playmogo.com/e/ta6jhp0sh9jd")!

        let source = try await DoodStreamExtractor.extract(
            fromHTML: playmogoHTML(),
            url: originalURL,
            resolvedPageURL: finalURL,
            playmogoPassResolver: { _, referer in
                XCTAssertEqual(referer, finalURL)
                return "https://ll288op.cloudatacdn.com/base/video~"
            },
            randomSuffix: { "abcdefghij" },
            nowMilliseconds: { "1777922000000" }
        )

        XCTAssertEqual(source.siteName, "Playmogo")
        XCTAssertNil(source.mp4)
        XCTAssertTrue(source.hls.first?.url.contains("cloudatacdn.com") == true)
        XCTAssertEqual(source.hls.first?.kind, .direct)
        XCTAssertEqual(source.hls.first?.headers?["Referer"], finalURL.absoluteString)
    }

    func testPlaymogoDPathUsesResolvedEmbedPage() async throws {
        let pageURL = URL(string: "https://playmogo.com/d/ta6jhp0sh9jd")!
        let embedURL = URL(string: "https://playmogo.com/e/ta6jhp0sh9jd")!

        let source = try await DoodStreamExtractor.extract(
            fromHTML: playmogoHTML(),
            url: pageURL,
            resolvedPageURL: embedURL,
            playmogoPassResolver: { _, referer in
                XCTAssertEqual(referer, embedURL)
                return "https://ll288op.cloudatacdn.com/base/video~"
            },
            randomSuffix: { "abcdefghij" },
            nowMilliseconds: { "1777922000000" }
        )

        XCTAssertEqual(source.siteName, "Playmogo")
        XCTAssertNil(source.mp4)
        XCTAssertEqual(source.hls.first?.headers?["Referer"], embedURL.absoluteString)
    }

    func testDoodDownloadPageUsesEmbeddedPlayerURL() {
        let pageURL = URL(string: "https://playmogo.com/d/89flmbsimkv3rg7asnuryarhjckeymi")!
        let html = #"<iframe src="/e/3betolo9i3aiilq78hgzum8qzc7wsqkg" scrolling="no"></iframe>"#

        XCTAssertEqual(
            DoodStreamExtractor.extractEmbeddedPlayerURLForTesting(from: html, pageURL: pageURL),
            URL(string: "https://playmogo.com/e/3betolo9i3aiilq78hgzum8qzc7wsqkg")
        )
    }

    func testPlaymogoMinifiedTokenBuilderParsesRenamedVariable() async throws {
        let pageURL = URL(string: "https://playmogo.com/e/ta6jhp0sh9jd")!
        let source = try await DoodStreamExtractor.extract(
            fromHTML: minifiedPlaymogoHTML(),
            url: pageURL,
            resolvedPageURL: pageURL,
            playmogoPassResolver: { passURL, referer in
                XCTAssertEqual(referer, pageURL)
                XCTAssertEqual(passURL.path, "/pass_md5/renamed/token")
                return "https://ll288op.cloudatacdn.com/base/video~"
            },
            randomSuffix: { "abcdefghij" },
            nowMilliseconds: { "1777922000000" }
        )

        XCTAssertEqual(
            source.hls.first?.url,
            "https://ll288op.cloudatacdn.com/base/video~abcdefghij?token=renamed&expiry=1777922000000"
        )
        XCTAssertNil(source.mp4)
    }

    func testPlaymogoParserHelpersReadAjaxShape() {
        let html = minifiedPlaymogoHTML()

        XCTAssertEqual(DoodStreamExtractor.extractPlaymogoPassPathForTesting(from: html), "/pass_md5/renamed/token")
        XCTAssertEqual(DoodStreamExtractor.extractPlaymogoTokenPrefixForTesting(from: html), "?token=renamed&expiry=")
    }

    func testPlaymogoParserHelpersReadEscapedXHRShape() {
        let html = """
        <script>
        var xhr = new XMLHttpRequest();
        xhr.open("GET", "\\/pass_md5\\/escaped\\/token", true);
        function mk(){return "abc?token=escaped&expiry=" + (new Date).getTime()}
        </script>
        """

        XCTAssertEqual(DoodStreamExtractor.extractPlaymogoPassPathForTesting(from: html), "/pass_md5/escaped/token")
        XCTAssertEqual(DoodStreamExtractor.extractPlaymogoTokenPrefixForTesting(from: html), "abc?token=escaped&expiry=")
    }

    func testPlaymogoBuildsCloudAtaUrlWithNewDateGetTime() async throws {
        let pageURL = URL(string: "https://playmogo.com/e/ta6jhp0sh9jd")!
        let html = """
        <script>
        fetch('/pass_md5/newdate/token').then(function(data){return data.text()});
        function makePlay(){return "xyz?token=newdate&expiry=" + new Date().getTime()}
        </script>
        """

        let source = try await DoodStreamExtractor.extract(
            fromHTML: html,
            url: pageURL,
            resolvedPageURL: pageURL,
            playmogoPassResolver: { passURL, referer in
                XCTAssertEqual(referer, pageURL)
                XCTAssertEqual(passURL.path, "/pass_md5/newdate/token")
                return "https://ll288op.cloudatacdn.com/base/video~"
            },
            randomSuffix: { "abcdefghij" },
            nowMilliseconds: { "1777922000000" }
        )

        XCTAssertNil(source.mp4)
        XCTAssertEqual(
            source.hls.first?.url,
            "https://ll288op.cloudatacdn.com/base/video~abcdefghijxyz?token=newdate&expiry=1777922000000"
        )
        XCTAssertEqual(source.hls.first?.kind, .direct)
        XCTAssertEqual(source.hls.first?.headers?["Referer"], pageURL.absoluteString)
        XCTAssertEqual(source.hls.first?.headers?["User-Agent"], NetworkConstants.chromeUserAgent)
        XCTAssertEqual(source.hls.first?.sourcePageUrl, pageURL.absoluteString)
    }

    private func playmogoHTML() -> String {
        """
        <html>
          <head>
            <title>Playmogo Test</title>
          </head>
          <body>
            <script>
              $.get('/pass_md5/261326014-64-40-1777921946-testhash/lecbqerp8ef0ydxmhy78z1vv', function(data) {
                dsplayer.src({ type: "video/mp4", src: data + makePlay() });
              });
              function makePlay() {
                for (var a = "", t = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789", n = t.length, o = 0; 10 > o; o++) a += t.charAt(Math.floor(Math.random() * n));
                return a + "?token=testtoken&expiry=" + Date.now();
              }
            </script>
          </body>
        </html>
        """
    }

    private func minifiedPlaymogoHTML() -> String {
        """
        <script>
        $.ajax({url:'/pass_md5/renamed/token',success:function(payload){player.src(payload+mk())}});
        function mk(){var z="";return z+"?token=renamed&expiry="+Date . now ( )}
        </script>
        """
    }
}

final class VidaraExtractorTests: XCTestCase {
    func testVidaraFilecodeAcceptsWatchEmbedAndDownloadPaths() throws {
        XCTAssertEqual(
            try VidaraExtractor.extractFilecodeForTesting(from: URL(string: "https://vidara.so/v/HMyhgZqHhW3Ml")!),
            "HMyhgZqHhW3Ml"
        )
        XCTAssertEqual(
            try VidaraExtractor.extractFilecodeForTesting(from: URL(string: "https://vidara.so/e/HMyhgZqHhW3Ml")!),
            "HMyhgZqHhW3Ml"
        )
        XCTAssertEqual(
            try VidaraExtractor.extractFilecodeForTesting(from: URL(string: "https://vidara.so/d/HMyhgZqHhW3Ml")!),
            "HMyhgZqHhW3Ml"
        )
    }

    func testParsedHLSQualitiesCarryVidaraHeadersAndSourcePageUrl() {
        let playlist = """
        #EXTM3U
        #EXT-X-STREAM-INF:BANDWIDTH=4500000,RESOLUTION=1920x1080
        video/1080.m3u8
        """
        let sourcePageUrl = "https://vidara.so/v/HMyhgZqHhW3Ml"

        let qualities = VidaraExtractor.parseHlsVariantsForTesting(
            playlist: playlist,
            masterUrl: "https://cdn.vidara.test/hls/master.m3u8?token=abc",
            sourcePageUrl: sourcePageUrl
        )

        XCTAssertEqual(qualities.count, 1)
        XCTAssertEqual(qualities[0].label, "1080p")
        XCTAssertEqual(qualities[0].url, "https://cdn.vidara.test/hls/video/1080.m3u8")
        XCTAssertEqual(qualities[0].headers?["User-Agent"], NetworkConstants.chromeUserAgent)
        XCTAssertEqual(qualities[0].headers?["Referer"], "https://vidara.so/")
        XCTAssertEqual(qualities[0].sourcePageUrl, sourcePageUrl)
    }
}

final class DownloadResolutionTests: XCTestCase {
    func testDirectMP4UsesSourceLevelHeaders() async throws {
        let headers = ["Referer": "https://pmvhaven.com/"]
        let source = VideoSource(
            mp4: "https://video.example.test/file.mp4",
            hls: [],
            title: "Example",
            headers: headers
        )

        let resolution = try await DownloadResolver.resolve(
            requestedUrl: "https://video.example.test/file.mp4",
            in: [ExtractResult(url: "https://example.test/watch", source: source, error: nil)]
        )

        XCTAssertEqual(resolution.finalUrl, "https://video.example.test/file.mp4")
        XCTAssertEqual(resolution.mediaKind, .direct)
        XCTAssertEqual(resolution.headers?["Referer"], "https://pmvhaven.com/")
    }

    func testHLSResolutionFallsBackToPageSlugInsteadOfM3U8Filename() async throws {
        // When source.title is nil (PMVHaven case), the title should come from the
        // page URL slug, not from the HLS media URL basename (e.g. "1080p.m3u8").
        let quality = VideoSource.Quality(
            label: "1080p",
            url: "https://video.pmvhaven.com/appetite_69b359ef6f11592f7f502f61/1080p.m3u8",
            kind: .hlsManifest,
            headers: ["Referer": "https://pmvhaven.com/"]
        )
        let source = VideoSource(mp4: nil, hls: [quality])  // title intentionally nil

        let resolution = try await DownloadResolver.resolve(
            requestedUrl: quality.url,
            in: [ExtractResult(
                url: "https://pmvhaven.com/video/appetite_69b359ef6f11592f7f502f61",
                source: source,
                error: nil
            )]
        )

        // Must not be the media file basename
        XCTAssertFalse(resolution.title.lowercased().contains("1080p"),
                       "Title should not contain '1080p' (got: \(resolution.title))")
        XCTAssertFalse(resolution.title.lowercased().hasSuffix(".m3u8"),
                       "Title should not end in '.m3u8' (got: \(resolution.title))")
        // Should look like the page slug
        XCTAssertTrue(resolution.title.lowercased().contains("appetite"),
                      "Title should contain the page slug word 'appetite' (got: \(resolution.title))")
    }

    func testResolvedTitleIsCanonicalForPMVHavenHLS() async throws {
        // Simulates the exact scenario: extractor sets title on the VideoSource
        // (Task 4 adds this), and resolution.title must surface it.
        let quality = VideoSource.Quality(
            label: "1080p",
            url: "https://video.pmvhaven.com/appetite_69b359ef6f11592f7f502f61/1080p.m3u8",
            kind: .hlsManifest,
            headers: ["Referer": "https://pmvhaven.com/"]
        )
        let source = VideoSource(mp4: nil, hls: [quality], title: "Appetite")

        let resolution = try await DownloadResolver.resolve(
            requestedUrl: quality.url,
            in: [ExtractResult(
                url: "https://pmvhaven.com/video/appetite_69b359ef6f11592f7f502f61",
                source: source,
                error: nil
            )]
        )

        XCTAssertEqual(resolution.title, "Appetite",
                       "resolution.title must return the title set by the extractor")
    }

    func testHLSQualityKeepsPerQualityHeaders() async throws {
        let quality = VideoSource.Quality(
            label: "1080p",
            url: "https://cdn.example.test/master.m3u8",
            kind: .hlsManifest,
            headers: ["Referer": "https://embed.example.test/"]
        )
        let source = VideoSource(mp4: nil, hls: [quality], title: "Stream")

        let resolution = try await DownloadResolver.resolve(
            requestedUrl: quality.url,
            in: [ExtractResult(url: "https://example.test/watch", source: source, error: nil)]
        )

        XCTAssertEqual(resolution.mediaKind, .hls)
        XCTAssertEqual(resolution.headers?["Referer"], "https://embed.example.test/")
    }

    func testVidaraHLSResolutionKeepsHeadersAndSourcePageUrl() async throws {
        let sourcePageUrl = "https://vidara.so/v/HMyhgZqHhW3Ml"
        let quality = VideoSource.Quality(
            label: "1080p",
            url: "https://cdn.vidara.test/hls/master.m3u8?token=abc",
            headers: [
                "User-Agent": NetworkConstants.chromeUserAgent,
                "Referer": "https://vidara.so/"
            ],
            sourcePageUrl: sourcePageUrl
        )
        let source = VideoSource(mp4: nil, hls: [quality], title: "Vidara Test", siteName: "Vidara")

        let resolution = try await DownloadResolver.resolve(
            requestedUrl: quality.url,
            in: [ExtractResult(url: sourcePageUrl, source: source, error: nil)]
        )

        XCTAssertEqual(resolution.mediaKind, .hls)
        XCTAssertEqual(resolution.headers?["User-Agent"], NetworkConstants.chromeUserAgent)
        XCTAssertEqual(resolution.headers?["Referer"], "https://vidara.so/")
        XCTAssertEqual(resolution.sourcePageUrl, sourcePageUrl)
    }

    func testVidaraProviderPageFallbackResolvesThroughExtractor() async throws {
        let providerPage = "https://vidara.so/d/HMyhgZqHhW3Ml"
        let quality = VideoSource.Quality(
            label: "VIDARA · provider page",
            url: providerPage,
            kind: .pageUrl,
            sourcePageUrl: providerPage
        )
        let source = VideoSource(mp4: nil, hls: [quality], title: "Provider Fixture")
        var requestedURLs: [String] = []

        let resolution = try await DownloadResolver.resolve(
            requestedUrl: providerPage,
            in: [ExtractResult(url: "https://allpornstream.com/post/test", source: source, error: nil)],
            extractor: { url in
                requestedURLs.append(url)
                return VideoSource(
                    mp4: nil,
                    hls: [
                        VideoSource.Quality(
                            label: "1080p",
                            url: "https://cdn.vidara.test/hls/master.m3u8?token=abc",
                            kind: .hlsManifest,
                            headers: ["Referer": "https://vidara.so/"],
                            sourcePageUrl: providerPage
                        )
                    ],
                    title: "Vidara Resolved",
                    siteName: "Vidara"
                )
            }
        )

        XCTAssertEqual(requestedURLs, [providerPage])
        XCTAssertEqual(resolution.mediaKind, .hls)
        XCTAssertEqual(resolution.finalUrl, "https://cdn.vidara.test/hls/master.m3u8?token=abc")
        XCTAssertEqual(resolution.sourcePageUrl, providerPage)
    }

    func testPornHubResolutionRefreshesStaleDirectURLAtDownloadTime() async throws {
        let pageURL = "https://www.pornhub.com/view_video.php?viewkey=phfixture"
        let staleURL = "https://ev-phncdn.example.test/videos/stale-720.mp4?ttl=old"
        let freshURL = "https://ev-phncdn.example.test/videos/fresh-720.mp4?ttl=new"
        let staleQuality = VideoSource.Quality(
            label: "720p MP4",
            url: staleURL,
            kind: .direct,
            headers: ["Referer": pageURL],
            sourcePageUrl: pageURL
        )
        let staleSource = VideoSource(
            mp4: staleURL,
            hls: [staleQuality],
            title: "Old PornHub Source",
            siteName: "PornHub"
        )
        let resolution = try await DownloadResolver.resolve(
            requestedUrl: staleURL,
            in: [ExtractResult(url: pageURL, source: staleSource, error: nil)]
        )

        let freshQuality = VideoSource.Quality(
            label: "720p MP4",
            url: freshURL,
            kind: .direct,
            headers: [
                "Referer": pageURL,
                "User-Agent": NetworkConstants.chromeUserAgent
            ],
            sourcePageUrl: pageURL
        )
        let freshSource = VideoSource(
            mp4: freshURL,
            hls: [freshQuality],
            title: "Fresh PornHub Source",
            siteName: "PornHub"
        )
        var extractorCalls: [String] = []

        let refreshed = try await DownloadResolver.refreshForDownloadIfNeeded(resolution) { url in
            extractorCalls.append(url)
            return freshSource
        }

        XCTAssertEqual(extractorCalls, [pageURL])
        XCTAssertEqual(refreshed.requestedUrl, staleURL)
        XCTAssertEqual(refreshed.finalUrl, freshURL)
        XCTAssertEqual(refreshed.mediaKind, .direct)
        XCTAssertEqual(refreshed.headers?["Referer"], pageURL)
        XCTAssertEqual(refreshed.headers?["User-Agent"], NetworkConstants.chromeUserAgent)
        XCTAssertEqual(refreshed.sourcePageUrl, pageURL)
        XCTAssertEqual(refreshed.title, "Fresh PornHub Source")
    }

    func testNonPornHubResolutionDoesNotRefreshAtDownloadTime() async throws {
        let source = VideoSource(
            mp4: "https://video.example.test/file.mp4",
            hls: [],
            title: "Example",
            siteName: "Example"
        )
        let resolution = try await DownloadResolver.resolve(
            requestedUrl: "https://video.example.test/file.mp4",
            in: [ExtractResult(url: "https://example.test/watch", source: source, error: nil)]
        )
        var didCallExtractor = false

        let refreshed = try await DownloadResolver.refreshForDownloadIfNeeded(resolution) { _ in
            didCallExtractor = true
            return source
        }

        XCTAssertFalse(didCallExtractor)
        XCTAssertEqual(refreshed, resolution)
    }

    func testPornHubRefreshFailureReturnsUserReadableError() async throws {
        let pageURL = "https://www.pornhub.com/view_video.php?viewkey=phfixture"
        let staleURL = "https://ev-phncdn.example.test/videos/stale-720.mp4?ttl=old"
        let source = VideoSource(
            mp4: staleURL,
            hls: [],
            title: "Old PornHub Source",
            siteName: "PornHub"
        )
        let resolution = try await DownloadResolver.resolve(
            requestedUrl: staleURL,
            in: [ExtractResult(url: pageURL, source: source, error: nil)]
        )

        do {
            _ = try await DownloadResolver.refreshForDownloadIfNeeded(resolution) { _ in
                throw VideoExtractorError.noVideoSources
            }
            XCTFail("Expected PornHub refresh to fail")
        } catch DownloadResolutionError.pornHubSourceRefreshFailed {
            XCTAssertEqual(
                DownloadResolutionError.pornHubSourceRefreshFailed.localizedDescription,
                "PornHub source expired; refresh the video and try again."
            )
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}

final class ProviderLinkExtractorResolutionTests: XCTestCase {
    func testAllPornStreamCandidatesPreferEmbedUrls() throws {
        let html = allPornStreamFixture()
        let candidates = ProviderLinkExtractor.providerCandidatesForTesting(from: html)

        XCTAssertEqual(candidates.map(\.providerName), ["STREAMTAPE", "MIXDROP", "DOODSTREAM"])
        XCTAssertEqual(candidates.map(\.url), [
            "https://streamtape.com/e/d3yv4qm2B4hkYq3",
            "https://mixdrop.ag/e/039jlq83he41d6",
            "https://doodstream.com/e/ta6jhp0sh9jd"
        ])
        XCTAssertEqual(candidates[2].providerName, "DOODSTREAM")
        XCTAssertEqual(candidates[2].url, "https://doodstream.com/e/ta6jhp0sh9jd")
    }

    func testAllPornStreamCandidatesParseInlineRSCVideoUrls() throws {
        let html = """
        3:[["$","$L10",null,{"initialPost":{"video_title":"[GlowingDesire] Mia James","video_urls":{"link":[["STREAMTAPE","https://streamtape.com/v/wPAXyzQ3l4UGr3"],["MIIIXDROP.NET","https://miiixdrop.net/f/4dvjklq6u3w8md"],["DOODSTREAM","https://doodstream.com/d/bzcfvq3l93ze"]],"direct":[],"iframe":[{"embed_url":"https://streamtape.com/e/wPAXyzQ3l4UGr3","file_code":"wPAXyzQ3l4UGr3","hosting_provider":"STREAMTAPE","status_code":200},{"embed_url":"https://miiixdrop.net/e/4dvjklq6u3w8md","file_code":"4dvjklq6u3w8md","hosting_provider":"MIIIXDROP.NET","status_code":200},{"embed_url":"https://doodstream.com/e/bzcfvq3l93ze","file_code":"bzcfvq3l93ze","hosting_provider":"DOODSTREAM","status_code":200}]}}}]]
        """

        let candidates = ProviderLinkExtractor.providerCandidatesForTesting(from: html)

        XCTAssertEqual(candidates.map(\.providerName), ["STREAMTAPE", "MIIIXDROP.NET", "DOODSTREAM"])
        XCTAssertEqual(candidates.map(\.url), [
            "https://streamtape.com/e/wPAXyzQ3l4UGr3",
            "https://miiixdrop.net/e/4dvjklq6u3w8md",
            "https://doodstream.com/e/bzcfvq3l93ze"
        ])
    }

    func testAllPornStreamDoodProviderResolvesUnknownAlias() async throws {
        let candidates = [
            ProviderLinkExtractor.ProviderCandidateForTesting(
                providerName: "DOODSTREAM",
                url: "https://rotating-dood-provider.example/e/hxptj42uoxb0"
            )
        ]

        let qualities = await ProviderLinkExtractor.resolveProviderCandidatesForTesting(candidates, resolver: { url in
            XCTAssertEqual(url, "https://rotating-dood-provider.example/e/hxptj42uoxb0")
            return VideoSource(
                mp4: "https://dood.video/e2/stream?token=test&expiry=999",
                siteName: "DoodStream"
            )
        })

        XCTAssertEqual(qualities.map(\.label), ["DOODSTREAM · Video"])
        XCTAssertEqual(qualities.first?.url, "https://dood.video/e2/stream?token=test&expiry=999")
    }

    func testAllPornStreamResolutionFlattensProviderSources() async throws {
        let candidates = [
            ProviderLinkExtractor.ProviderCandidateForTesting(providerName: "STREAMTAPE", url: "https://streamtape.com/e/d3yv4qm2B4hkYq3"),
            ProviderLinkExtractor.ProviderCandidateForTesting(providerName: "MIXDROP", url: "https://mixdrop.ag/e/039jlq83he41d6"),
            ProviderLinkExtractor.ProviderCandidateForTesting(providerName: "DOODSTREAM", url: "https://doodstream.com/e/ta6jhp0sh9jd")
        ]

        let qualities = await ProviderLinkExtractor.resolveProviderCandidatesForTesting(candidates, resolver: { url in
            if url.contains("streamtape") {
                return VideoSource(
                    mp4: "https://tapecontent.example/video.mp4",
                    hls: [
                        VideoSource.Quality(
                            label: "Video",
                            url: "https://tapecontent.example/video.mp4",
                            kind: .direct,
                            sourcePageUrl: url
                        )
                    ],
                    siteName: "StreamTape"
                )
            }
            if url.contains("mixdrop") {
                return VideoSource(
                    mp4: "https://q2dgt5pce.mxcontent.net/v2/039jlq83he41d6.mp4?s=sig&e=999&_t=888",
                    hls: [
                        VideoSource.Quality(
                            label: "Video",
                            url: "https://q2dgt5pce.mxcontent.net/v2/039jlq83he41d6.mp4?s=sig&e=999&_t=888",
                            kind: .direct,
                            sourcePageUrl: url
                        )
                    ],
                    siteName: "MixDrop"
                )
            }
            return VideoSource(
                mp4: nil,
                hls: [
                    VideoSource.Quality(
                        label: "Video",
                        url: "https://ll288op.cloudatacdn.com/base/video~abcdefghij?token=test&expiry=999",
                        kind: .direct,
                        headers: [
                            "Referer": "https://playmogo.com/e/ta6jhp0sh9jd",
                            "User-Agent": NetworkConstants.chromeUserAgent
                        ],
                        sourcePageUrl: "https://playmogo.com/e/ta6jhp0sh9jd"
                    )
                ],
                siteName: "Playmogo"
            )
        })

        XCTAssertEqual(qualities.map(\.label), ["STREAMTAPE · Video", "MIXDROP · Video", "DOODSTREAM · Video"])
        XCTAssertEqual(qualities.map(\.kind), [.direct, .direct, .direct])
        XCTAssertTrue(qualities[1].url.contains("mxcontent.net"))
        XCTAssertTrue(qualities[2].url.contains("cloudatacdn.com"))
        XCTAssertEqual(qualities[2].headers?["Referer"], "https://playmogo.com/e/ta6jhp0sh9jd")
        XCTAssertFalse(qualities.contains { $0.kind == .pageUrl })
        XCTAssertFalse(qualities.contains { $0.url.contains("streamtape.com/v/") })
        XCTAssertFalse(qualities.contains { $0.url.contains("mixdrop.ag/f/") })
        XCTAssertFalse(qualities.contains { $0.url.contains("doodstream.com/d/") })
    }

    func testFailedResolvedProviderIsRemoved() async throws {
        let candidates = [
            ProviderLinkExtractor.ProviderCandidateForTesting(providerName: "STREAMTAPE", url: "https://streamtape.com/e/d3yv4qm2B4hkYq3"),
            ProviderLinkExtractor.ProviderCandidateForTesting(providerName: "DOODSTREAM", url: "https://doodstream.com/e/ta6jhp0sh9jd")
        ]

        let qualities = await ProviderLinkExtractor.resolveProviderCandidatesForTesting(candidates, resolver: { url in
            if url.contains("doodstream") {
                throw VideoExtractorError.noVideoSources
            }

            return VideoSource(
                mp4: "https://tapecontent.example/video.mp4",
                hls: [
                    VideoSource.Quality(
                        label: "Video",
                        url: "https://tapecontent.example/video.mp4",
                        kind: .direct
                    )
                ],
                siteName: "StreamTape"
            )
        })

        XCTAssertEqual(qualities.map(\.label), ["STREAMTAPE · Video"])
        XCTAssertEqual(qualities.map(\.kind), [.direct])
    }

    func testVidaraProviderCandidateResolvesInsteadOfFallingBackToPage() async throws {
        let candidates = [
            ProviderLinkExtractor.ProviderCandidateForTesting(providerName: "VIDARA", url: "https://vidara.so/d/HMyhgZqHhW3Ml")
        ]

        let qualities = await ProviderLinkExtractor.resolveProviderCandidatesForTesting(candidates, resolver: { url in
            XCTAssertEqual(url, "https://vidara.so/d/HMyhgZqHhW3Ml")
            return VideoSource(
                mp4: nil,
                hls: [
                    VideoSource.Quality(
                        label: "1080p",
                        url: "https://cdn.vidara.test/hls/master.m3u8?token=abc",
                        kind: .hlsManifest,
                        headers: ["Referer": "https://vidara.so/"],
                        sourcePageUrl: url
                    )
                ],
                siteName: "Vidara"
            )
        })

        XCTAssertEqual(qualities.map(\.label), ["VIDARA · 1080p"])
        XCTAssertEqual(qualities.first?.kind, .hlsManifest)
        XCTAssertEqual(qualities.first?.url, "https://cdn.vidara.test/hls/master.m3u8?token=abc")
    }

    func testDirectQualityWithoutMP4ResolvesAsDirectDownload() async throws {
        let quality = VideoSource.Quality(
            label: "STREAMTAPE · Video",
            url: "https://tapecontent.example/video.mp4",
            kind: .direct,
            headers: ["Referer": "https://streamtape.com/e/abc"],
            sourcePageUrl: "https://streamtape.com/e/abc"
        )
        let source = VideoSource(mp4: nil, hls: [quality], title: "AllPornStream Video")

        let resolution = try await DownloadResolver.resolve(
            requestedUrl: quality.url,
            in: [ExtractResult(url: "https://allpornstream.com/post/example", source: source, error: nil)]
        )

        XCTAssertEqual(resolution.finalUrl, quality.url)
        XCTAssertEqual(resolution.mediaKind, .direct)
        XCTAssertEqual(resolution.headers?["Referer"], "https://streamtape.com/e/abc")
        XCTAssertEqual(resolution.sourcePageUrl, "https://streamtape.com/e/abc")
    }

    private func allPornStreamFixture() -> String {
        #"""
        <html>
        <head><title>AllPornStream Video</title></head>
        <body>
        <script>
        self.__next_f.push([1,"{\"video_urls\":{\"link\":[[\"STREAMTAPE\",\"https://streamtape.com/v/d3yv4qm2B4hkYq3\"],[\"MIXDROP\",\"https://mixdrop.ag/f/039jlq83he41d6\"],[\"DOODSTREAM\",\"https://doodstream.com/d/ta6jhp0sh9jd\"]],\"iframe\":[{\"hosting_provider\":\"STREAMTAPE\",\"embed_url\":\"https://streamtape.com/e/d3yv4qm2B4hkYq3\",\"file_code\":\"d3yv4qm2B4hkYq3\",\"status_code\":200},{\"hosting_provider\":\"MIXDROP\",\"embed_url\":\"https://mixdrop.ag/e/039jlq83he41d6\",\"file_code\":\"039jlq83he41d6\",\"status_code\":200},{\"hosting_provider\":\"DOODSTREAM\",\"embed_url\":\"https://doodstream.com/e/ta6jhp0sh9jd\",\"file_code\":\"ta6jhp0sh9jd\",\"status_code\":200}]}}"])
        </script>
        </body>
        </html>
        """#
    }
}

final class NativeVideoPageExtractorTitleTests: XCTestCase {

    func testExtractsOpenGraphTitleFromPMVHavenPage() throws {
        let url = URL(string: "https://pmvhaven.com/video/appetite_69b359ef6f11592f7f502f61")!
        let html = """
        <html>
          <head>
            <meta property="og:title" content="Appetite - PMVHaven" />
            <meta property="og:image" content="https://cdn.pmvhaven.com/thumbs/appetite.jpg" />
            <title>Appetite - PMVHaven</title>
          </head>
          <body></body>
        </html>
        """

        let title = NativeVideoPageExtractor.extractTitle(from: html, pageURL: url)
        XCTAssertEqual(title, "Appetite",
                       "Should strip site suffix and return clean title")

        let thumb = NativeVideoPageExtractor.extractThumbnail(from: html)
        XCTAssertEqual(thumb, "https://cdn.pmvhaven.com/thumbs/appetite.jpg")
    }

    func testExtractsTitleTagWhenOpenGraphTitleIsMissing() throws {
        let url = URL(string: "https://pmvhaven.com/video/something_cool_69b359ef6f11592f7f502f61")!
        let html = """
        <html>
          <head>
            <title>Something Cool | PMVHaven</title>
          </head>
          <body></body>
        </html>
        """

        let title = NativeVideoPageExtractor.extractTitle(from: html, pageURL: url)
        XCTAssertEqual(title, "Something Cool",
                       "Should fall back to <title> tag and strip site suffix")
    }

    func testFallsBackToURLSlugWhenNoMetaTitle() throws {
        let url = URL(string: "https://pmvhaven.com/video/appetite_69b359ef6f11592f7f502f61")!
        let html = "<html><body></body></html>"

        let title = NativeVideoPageExtractor.extractTitle(from: html, pageURL: url)
        XCTAssertEqual(title, "Appetite",
                       "Should extract slug from URL path when no HTML title is present")
    }

    func testMetaContentWorksRegardlessOfAttributeOrder() throws {
        // content before property
        let html1 = #"<meta content="Hello World" property="og:title" />"#
        let result1 = NativeVideoPageExtractor.metaContent(for: "og:title", in: html1)
        XCTAssertEqual(result1, "Hello World")

        // property before content
        let html2 = #"<meta property="og:title" content="Hello World" />"#
        let result2 = NativeVideoPageExtractor.metaContent(for: "og:title", in: html2)
        XCTAssertEqual(result2, "Hello World")
    }

    func testCleanTitleDecodesHTMLEntities() throws {
        let raw = "Tom &amp; Jerry &#8211; The Chase"
        let cleaned = NativeVideoPageExtractor.cleanTitle(raw)
        XCTAssertEqual(cleaned, "Tom & Jerry – The Chase")
    }
}

final class LuluStreamExtractorTests: XCTestCase {
    func testFindHlsSourceReadsDirectJWPlayerConfig() {
        let html = """
        <html>
        <script>
        jwplayer("vplayer").setup({
            sources: [{file:"https://cdn.example.test/hls/master.m3u8?token=abc123&expires=999", type:"hls"}]
        });
        </script>
        </html>
        """

        XCTAssertFalse(html.contains("eval("))
        XCTAssertEqual(
            LuluStreamExtractor.findHlsSourceForTesting(html),
            "https://cdn.example.test/hls/master.m3u8?token=abc123&expires=999"
        )
    }

    func testFindHlsSourceFallsBackToPackedConfig() {
        let html = """
        <html>
        <script>
        eval(function(p,a,c,k,e,d){return p}('0("v").1({2:[{3:"https://cdn.example.test/hls/4.5?token=old"}]});','36',6,'jwplayer|setup|sources|file|master|m3u8'.split('|')))
        </script>
        </html>
        """

        XCTAssertFalse(html.contains(".m3u8"))
        XCTAssertEqual(
            LuluStreamExtractor.findHlsSourceForTesting(html),
            "https://cdn.example.test/hls/master.m3u8?token=old"
        )
    }
}
