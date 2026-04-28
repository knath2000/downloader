import WebKit
import Foundation

@MainActor
class WebViewExtractor {
    static let shared = WebViewExtractor()

    private init() {} // Prevent external instantiation

    /// Load a page in WebView and extract video URL from the DOM after JavaScript execution
    func extractVideoUrl(from url: URL, timeout: TimeInterval = 10) async throws -> String {
        let task = WebViewExtractorTask()
        // The task stays alive in memory for as long as this 'await' is suspended
        return try await task.extract(url: url, timeout: timeout)
    }
}

@MainActor
private class WebViewExtractorTask: NSObject, WKNavigationDelegate {
    private var webView: WKWebView?
    private var continuation: CheckedContinuation<String, Error>?
    private var lastNavigationUrl: URL?
    private var redirectCount: Int = 0
    private var isFirstNavigation = true
    private var startTime: Date = Date()
    private var targetUrl: URL?
    private var finalUrl: URL?
    private var isCloudflareChallenge = false
    private var hasStartedPolling = false
    
    func extract(url: URL, timeout: TimeInterval) async throws -> String {
        return try await withCheckedThrowingContinuation { cont in
            self.continuation = cont
            self.startTime = Date()
            self.targetUrl = url

            // Create webView with proper configuration
            let configuration = WKWebViewConfiguration()
            configuration.preferences.javaScriptEnabled = true
            configuration.websiteDataStore = .default()

            self.webView = WKWebView(frame: .zero, configuration: configuration)
            self.webView?.navigationDelegate = self

            // Set user agent to match browser
            self.webView?.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"

            let request = URLRequest(url: url)
            self.webView?.load(request)

            // Increased timeout safety switch
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
                if let c = self.continuation {
                    print("[WebView] Timeout reached after \(timeout) seconds")
                    self.continuation = nil
                    self.webView?.stopLoading()
                    c.resume(throwing: WebViewError.timeout)
                }
            }
        }
    }
    
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if navigationAction.navigationType == .linkActivated || navigationAction.navigationType == .other {
            print("[WebView] Starting navigation to: \(navigationAction.request.url?.absoluteString ?? "unknown")")
        }

        lastNavigationUrl = navigationAction.request.url
        if isFirstNavigation {
            isFirstNavigation = false
        } else {
            redirectCount += 1
            print("[WebView] Redirect #\(redirectCount): \(navigationAction.request.url?.absoluteString ?? "unknown")")
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let loadTime = Date().timeIntervalSince(startTime)
        let currentUrl = webView.url
        print("[WebView] Page loaded after \(loadTime) seconds. Redirect count: \(redirectCount), Final URL: \(currentUrl?.absoluteString ?? "nil")")

        guard let currentUrl = currentUrl,
              let scheme = currentUrl.scheme?.lowercased(),
              (scheme == "http" || scheme == "https"),
              currentUrl.absoluteString != "about:blank",
              !currentUrl.absoluteString.hasPrefix("about:srcdoc") else {
            print("[WebView] Skipping non-HTTP(S) or about: page")
            return
        }

        // Check if this is a Cloudflare challenge page
        let urlString = currentUrl.absoluteString
        if urlString.contains("challenges.cloudflare.com") || urlString.contains("turnstile") {
            print("[WebView] Detected Cloudflare challenge, will wait longer for completion")
            isCloudflareChallenge = true
            // Don't start polling yet, wait for challenge to complete
            return
        }

        // Store the final URL after redirects
        self.finalUrl = currentUrl

        // Determine polling delay based on Cloudflare detection and page type
        let pollingDelay: TimeInterval
        if isCloudflareChallenge {
            pollingDelay = 20.0 // Much longer delay after Cloudflare
        } else if urlString.contains("/e/") {
            // Embed page - might need time for player to load
            pollingDelay = 10.0
        } else {
            pollingDelay = 5.0
        }

        // Start polling for video URL
        if !hasStartedPolling {
            hasStartedPolling = true
            print("[WebView] Will start polling in \(pollingDelay) seconds...")
            DispatchQueue.main.asyncAfter(deadline: .now() + pollingDelay) {
                self.executeScript()
            }
        }
    }
    
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        let nsError = error as NSError
        print("[WebView] Navigation failed: \(error.localizedDescription) (Code: \(nsError.code))")
        // Don't cancel immediately for cancelled requests (-999) - these might be normal during redirects
        if nsError.code != -999, let c = self.continuation {
            self.continuation = nil
            c.resume(throwing: error)
        }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        let nsError = error as NSError
        print("[WebView] Provisional navigation failed: \(error.localizedDescription) (Code: \(nsError.code))")
        // Don't cancel immediately for cancelled requests (-999) - these might be normal during redirects
        if nsError.code != -999, let c = self.continuation {
            self.continuation = nil
            c.resume(throwing: error)
        }
    }
    
    private func executeScript() {
        print("[WebView] Starting URL polling...")
        pollForVideoUrl(attempt: 1, maxAttempts: 60) // Poll for up to 60 seconds
    }

    private func pollForVideoUrl(attempt: Int, maxAttempts: Int) {
        // Simplified, more defensive JavaScript - each section wrapped in try-catch
        let script = """
        (function() {
            try {
                var result = null;
                
                // Check for video element with actual src
                try {
                    var videoElements = document.querySelectorAll("video");
                    for (var v = 0; v < videoElements.length; v++) {
                        var videoElement = videoElements[v];
                        var src = videoElement.currentSrc || videoElement.src;
                        if (src && src.length > 0 && !src.startsWith("blob:") && !src.startsWith("data:") &&
                            (src.includes(".mp4") || src.includes(".m3u8") || src.includes("dood.video"))) {
                            return {url: src, type: "video_element"};
                        }
                    }
                } catch(e) {}

                // Check for source elements
                try {
                    var sources = document.querySelectorAll("video source");
                    for (var i = 0; i < sources.length; i++) {
                        var s = sources[i].src || sources[i].getAttribute("src");
                        if (s && s.trim().length > 0 && !s.startsWith("blob:") && !s.startsWith("data:") &&
                            (s.includes(".mp4") || s.includes(".m3u8") || s.includes("dood.video"))) {
                            return {url: s.trim(), type: "source_element"};
                        }
                    }
                } catch(e) {}

                // Check for JWPlayer
                try {
                    if (window.jwplayer) {
                        var player = window.jwplayer();
                        if (player && player.getPlaylist) {
                            var playlist = player.getPlaylist();
                            if (playlist && playlist[0] && playlist[0].file &&
                                (playlist[0].file.includes(".mp4") || playlist[0].file.includes(".m3u8") || playlist[0].file.includes("dood.video"))) {
                                return {url: playlist[0].file, type: "jwplayer"};
                            }
                        }
                    }
                } catch(e) {}

                // Check for global variables
                try {
                    var globalVars = ["videoUrl", "mp4", "file", "src", "download_url", "downloadUrl", "source", "video_url", "video", "media"];
                    for (var i = 0; i < globalVars.length; i++) {
                        var val = window[globalVars[i]];
                        if (val && typeof val === "string" && val.trim().length > 0) {
                            return {url: val.trim(), type: "global_variable"};
                        }
                    }
                } catch(e) {}

                // Check script tags for dood.video URLs
                try {
                    var allScripts = document.querySelectorAll("script");
                    for (var i = 0; i < allScripts.length; i++) {
                        var text = allScripts[i].textContent || "";
                        if (text.includes("dood.video")) {
                            var regex = /https:\\/\\/[^"'\\s]*dood\\.video[^"'\\s]*/g;
                            var match = text.match(regex);
                            if (match && match[0]) {
                                return {url: match[0], type: "script_injection"};
                            }
                        }
                    }
                } catch(e) {}

                // Check all elements for dood.video URLs (sample)
                try {
                    var allElements = document.querySelectorAll("*");
                    var count = Math.min(allElements.length, 500);
                    for (var i = 0; i < count; i++) {
                        var html = allElements[i].outerHTML || "";
                        if (html.includes("dood.video")) {
                            var regex = /https:\\/\\/[^"'\\s]*dood\\.video[^"'\\s]*/g;
                            var match = html.match(regex);
                            if (match && match[0]) {
                                return {url: match[0], type: "html_attribute"};
                            }
                        }
                    }
                } catch(e) {}

                // Check page URL as fallback
                try {
                    var pageUrl = window.location.href;
                    if (pageUrl && pageUrl.includes("dood.video")) {
                        return {url: pageUrl, type: "page_url"};
                    }
                } catch(e) {}

                // Check for iframe src
                try {
                    var iframes = document.querySelectorAll("iframe");
                    for (var i = 0; i < iframes.length; i++) {
                        var src = iframes[i].src || "";
                        if (src && src.includes("dood.video")) {
                            return {url: src, type: "iframe_src"};
                        }
                    }
                } catch(e) {}

                // Check for dynamically loaded content in common containers
                try {
                    var containers = document.querySelectorAll("div, section, #player, .player, #video, .video");
                    var containerCount = Math.min(containers.length, 50);
                    for (var i = 0; i < containerCount; i++) {
                        var html = containers[i].innerHTML || "";
                        if (html.includes("dood.video")) {
                            var regex = /https:\\/\\/[^"'\\s]*dood\\.video[^"'\\s]*/g;
                            var match = html.match(regex);
                            if (match && match[0]) {
                                return {url: match[0], type: "container_content"};
                            }
                        }
                    }
                } catch(e) {}

                // Check body text for URLs
                try {
                    var bodyText = document.body ? (document.body.innerText || "") : "";
                    var urlMatch = bodyText.match(/https:\\/\\/[^\\s"'<>]+\\.(mp4|m3u8|mkv)[^\\s"'<>]*/gi);
                    if (urlMatch && urlMatch[0]) return {url: urlMatch[0], type: "body_text"};
                } catch(e) {}

                // Check data attributes
                try {
                    var elementsWithData = document.querySelectorAll("[data-src], [data-url], [data-video]");
                    for (var i = 0; i < elementsWithData.length; i++) {
                        var el = elementsWithData[i];
                        for (var attr of ["data-src", "data-url", "data-video"]) {
                            var val = el.getAttribute(attr);
                            if (val && val.includes("dood.video")) {
                                return {url: val, type: "data_attribute"};
                            }
                        }
                    }
                } catch(e) {}

                return null;
            } catch(e) {
                console.log("[JS] Error in extraction: " + e.message);
                return null;
            }
        })();
        """

        webView?.evaluateJavaScript(script) { [weak self] result, error in
            guard let self = self else { return }

            if let error = error {
                print("[WebView] JavaScript evaluation error: \(error.localizedDescription) (Code: \((error as NSError).code))")
                // Continue polling instead of failing immediately
                if attempt < maxAttempts {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        self.pollForVideoUrl(attempt: attempt + 1, maxAttempts: maxAttempts)
                    }
                } else {
                    self.handlePollingExhausted()
                }
                return
            }

            if let resultDict = result as? [String: Any] {
                // Check if result contains an error
                if let errorMsg = resultDict["error"] as? String {
                    print("[WebView] JavaScript execution error: \(errorMsg)")
                    if attempt < maxAttempts {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                            self.pollForVideoUrl(attempt: attempt + 1, maxAttempts: maxAttempts)
                        }
                    } else {
                        self.handlePollingExhausted()
                    }
                    return
                }

                if let videoUrl = resultDict["url"] as? String, !videoUrl.isEmpty,
                   let type = resultDict["type"] as? String {
                    // Ignore a returned URL equal to targetUrl?.absoluteString
                    if videoUrl == self.targetUrl?.absoluteString {
                        print("[WebView] Got page URL, continuing to poll...")
                    } else if videoUrl.contains("dood.video") && (videoUrl.contains(".mp4") || videoUrl.contains("token=") || videoUrl.contains("key=")) {
                        print("[WebView] Found valid video URL via \(type): \(videoUrl)")
                        self.continuation?.resume(returning: videoUrl)
                        self.continuation = nil
                        return
                    } else {
                        print("[WebView] Skipping invalid URL via \(type): \(videoUrl)")
                    }
                }
            }

            // If no URL found and we haven't exceeded max attempts, poll again
            if attempt < maxAttempts {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    self.pollForVideoUrl(attempt: attempt + 1, maxAttempts: maxAttempts)
                }
            } else {
                self.handlePollingExhausted()
            }
        }
    }

    private func handlePollingExhausted() {
        print("[WebView] No video URL found after polling")
        // If no video-specific URL is found, use the final page URL if it contains dood.video
        if let final = self.finalUrl, final.absoluteString.contains("dood.video") {
            let urlString = final.absoluteString
            if urlString.contains(".mp4") || urlString.contains("token=") || urlString.contains("key=") {
                print("[WebView] Using final page URL: \(urlString)")
                self.continuation?.resume(returning: urlString)
            } else {
                print("[WebView] Final page URL is not a valid video URL: \(urlString)")
                self.continuation?.resume(throwing: WebViewError.noVideoUrlFound)
            }
        } else {
            self.continuation?.resume(throwing: WebViewError.noVideoUrlFound)
        }
        self.continuation = nil
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
