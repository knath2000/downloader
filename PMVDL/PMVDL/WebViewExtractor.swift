import WebKit
import Foundation

@MainActor
class WebViewExtractor {
    static let shared = WebViewExtractor()

    private init() {} // Prevent external instantiation

    /// Load a page in WebView and extract video URL from the DOM after JavaScript execution
    func extractVideoUrl(from url: URL, timeout: TimeInterval = 10) async throws -> String {
        return try await withCheckedThrowingContinuation { continuation in
            let startTime = Date()
            let webView = WKWebView()

            webView.navigationDelegate = WebViewDelegate(continuation)

            let request = URLRequest(url: url)
            webView.load(request)

            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
                if Date().timeIntervalSince(startTime) >= timeout {
                    continuation.resume(throwing: WebViewError.timeout)
                }
            }
        }
    }
}

private class WebViewDelegate: NSObject, WKNavigationDelegate {
    let continuation: CheckedContinuation<String, Error>

    init(_ continuation: CheckedContinuation<String, Error>) {
        self.continuation = continuation
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) {
            extractVideoUrl(from: webView, continuation: self.continuation)
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        continuation.resume(throwing: error)
    }
}

private func extractVideoUrl(from webView: WKWebView, continuation: CheckedContinuation<String, Error>) {
    let script = """
    (function() {
        try {
            var videoElement = document.querySelector("video");
            if (videoElement) {
                var src = videoElement.currentSrc || videoElement.src;
                if (src && src.length > 0 && !src.startsWith("blob:") && !src.startsWith("data:")) {
                    return src;
                }
            }

            var sources = document.querySelectorAll("video source");
            for (var i = 0; i < sources.length; i++) {
                var s = sources[i].src || sources[i].getAttribute("src");
                if (s && s.trim().length > 0) {
                    s = s.trim();
                    if (s.includes(".mp4") || s.includes(".m3u8") || s.includes("tapecontent.net")) {
                        return s;
                    }
                }
            }

            var allScripts = document.querySelectorAll("script");
            for (var i = 0; i < allScripts.length; i++) {
                var text = allScripts[i].textContent || "";
                var match = text.match(/https:\\/\\/[^"'\\s]*tapecontent\\.net[^"'\\s]*/g);
                if (match && match[0]) return match[0];
            }

            var allElements = document.querySelectorAll("*");
            for (var i = 0; i < Math.min(allElements.length, 500); i++) {
                var html = allElements[i].outerHTML || "";
                var match = html.match(/https:\\/\\/[^"'\\s]*tapecontent\\.net[^"'\\s]*/g);
                if (match && match[0]) return match[0];
            }

            var ideooolink = document.querySelector("#ideoooolink");
            if (ideooolink && ideooolink.textContent) {
                var text = ideooolink.textContent.trim();
                if (text.length > 0) return text;
            }

            var captchalink = document.querySelector("#captchalink");
            if (captchalink && captchalink.textContent) {
                var text = captchalink.textContent.trim();
                if (text.length > 0) return text;
            }

            var norobotlink = document.querySelector("#norobotlink");
            if (norobotlink && norobotlink.textContent) {
                var text = norobotlink.textContent.trim();
                if (text.length > 0) return text;
            }

            if (window.videoUrl && typeof window.videoUrl === "string") {
                var v = window.videoUrl.trim();
                if (v.length > 0) return v;
            }

            if (window.mp4 && typeof window.mp4 === "string") {
                var v = window.mp4.trim();
                if (v.length > 0) return v;
            }

            if (window.jwplayer) {
                try {
                    var player = window.jwplayer();
                    if (player && player.getPlaylist) {
                        var playlist = player.getPlaylist();
                        if (playlist && playlist[0] && playlist[0].file) {
                            return playlist[0].file;
                        }
                    }
                } catch(e) {}
            }

            var bodyText = document.body.innerText || "";
            var urlMatch = bodyText.match(/https:\\/\\/[^\\s"'<>]+\\.(mp4|m3u8|mkv)[^\\s"'<>]*/gi);
            if (urlMatch && urlMatch[0]) return urlMatch[0];

            return null;
        } catch(e) {
            return null;
        }
    })();
    """

    webView.evaluateJavaScript(script) { result, error in
        if let error = error {
            continuation.resume(throwing: error)
            return
        }
        if let videoUrl = result as? String, !videoUrl.isEmpty {
            continuation.resume(returning: videoUrl)
        } else {
            continuation.resume(throwing: WebViewError.noVideoUrlFound)
        }
    }
}

enum WebViewError: LocalizedError {
    case timeout
    case noVideoUrlFound
    case navigationFailed(String)

    var errorDescription: String? {
        switch self {
        case .timeout: return "Timeout loading page"
        case .noVideoUrlFound: return "Could not find video URL in page"
        case .navigationFailed(let msg): return msg
        }
    }
}
