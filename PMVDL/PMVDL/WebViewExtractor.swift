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
private class WebViewExtractorTask: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
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
    private let messageHandlerName = "videoCandidate"
    
    func extract(url: URL, timeout: TimeInterval) async throws -> String {
        return try await withCheckedThrowingContinuation { cont in
            self.continuation = cont
            self.startTime = Date()
            self.targetUrl = url

            // Create webView with proper configuration
            let configuration = WKWebViewConfiguration()
            configuration.preferences.javaScriptEnabled = true
            configuration.websiteDataStore = .default()
            configuration.userContentController.add(self, name: messageHandlerName)
            configuration.userContentController.addUserScript(WKUserScript(
                source: Self.candidateCollectorScript(handlerName: messageHandlerName),
                injectionTime: .atDocumentStart,
                forMainFrameOnly: false
            ))

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
                    self.cleanup()
                    c.resume(throwing: WebViewError.timeout)
                }
            }
        }
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == messageHandlerName,
              let body = message.body as? [String: Any],
              let rawUrl = body["url"] as? String else {
            return
        }

        let type = body["type"] as? String ?? "message"
        _ = handleCandidate(rawUrl, type: type)
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
            self.cleanup()
            c.resume(throwing: error)
        }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        let nsError = error as NSError
        print("[WebView] Provisional navigation failed: \(error.localizedDescription) (Code: \(nsError.code))")
        // Don't cancel immediately for cancelled requests (-999) - these might be normal during redirects
        if nsError.code != -999, let c = self.continuation {
            self.continuation = nil
            self.cleanup()
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

                if let videoUrl = resultDict["url"] as? String, !videoUrl.isEmpty {
                    let type = resultDict["type"] as? String ?? "poll"
                    if self.handleCandidate(videoUrl, type: type) {
                        return
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
            if isFinalDoodVideoUrl(urlString) {
                print("[WebView] Using final page URL: \(urlString)")
                self.continuation?.resume(returning: urlString)
            } else {
                print("[WebView] Final page URL is not a valid video URL: \(urlString)")
                self.continuation?.resume(throwing: WebViewError.noVideoUrlFound)
            }
        } else {
            self.continuation?.resume(throwing: WebViewError.noVideoUrlFound)
        }
        cleanup()
        self.continuation = nil
    }

    private func handleCandidate(_ rawUrl: String, type: String) -> Bool {
        guard let candidate = normalizedCandidate(rawUrl), candidate != targetUrl?.absoluteString else {
            return false
        }

        guard !isRejectedAsset(candidate) else {
            print("[WebView] Skipping invalid URL via \(type): \(candidate)")
            return false
        }

        if isFinalDoodVideoUrl(candidate) || isFullCloudMediaUrl(candidate) {
            print("[WebView] Found candidate URL via \(type): \(candidate)")
            let c = continuation
            continuation = nil
            cleanup()
            c?.resume(returning: candidate)
            return true
        }

        if candidate.lowercased().contains("dood.video") || candidate.lowercased().contains("cloudatacdn.com") {
            print("[WebView] Observed intermediate URL via \(type): \(candidate)")
            return false
        }

        return false
    }

    private func cleanup() {
        webView?.stopLoading()
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: messageHandlerName)
        webView?.navigationDelegate = nil
        webView = nil
    }

    private func normalizedCandidate(_ rawUrl: String) -> String? {
        let trimmed = rawUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed.hasPrefix("blob:") || trimmed.hasPrefix("data:") {
            return nil
        }
        if trimmed.hasPrefix("//") {
            return "https:" + trimmed
        }
        return trimmed
    }

    private func isRejectedAsset(_ url: String) -> Bool {
        let lower = url.lowercased()
        if lower.contains("no_video") || lower.contains("placeholder") || lower.contains("favicon") {
            return true
        }

        let path = URL(string: url)?.path.lowercased() ?? lower.components(separatedBy: "?").first ?? lower
        let rejectedExtensions = [".ico", ".svg", ".png", ".jpg", ".jpeg", ".gif", ".webp", ".css", ".js"]
        if rejectedExtensions.contains(where: { path.hasSuffix($0) }) {
            return true
        }

        return false
    }

    private func isFinalDoodVideoUrl(_ url: String) -> Bool {
        guard !isRejectedAsset(url),
              let components = URLComponents(string: url),
              let host = components.host?.lowercased(),
              host.contains("dood.video") else {
            return false
        }

        let path = components.percentEncodedPath
        guard !path.isEmpty, path != "/" else { return false }
        let queryItems = components.queryItems ?? []
        return queryItems.contains(where: { $0.name == "token" }) &&
            queryItems.contains(where: { $0.name == "expiry" })
    }

    private func isFullCloudMediaUrl(_ url: String) -> Bool {
        guard !isRejectedAsset(url),
              let components = URLComponents(string: url),
              let host = components.host?.lowercased(),
              host.contains("cloudatacdn.com") else {
            return false
        }

        let path = components.percentEncodedPath
        guard path.contains("~"), path.count > 12 else { return false }
        let queryItems = components.queryItems ?? []
        return queryItems.contains(where: { $0.name == "token" }) &&
            queryItems.contains(where: { $0.name == "expiry" })
    }

    private static func candidateCollectorScript(handlerName: String) -> String {
        """
        (function() {
            if (window.__pmvdlCollectorInstalled) return;
            window.__pmvdlCollectorInstalled = true;

            var handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.\(handlerName);
            if (!handler) return;

            function makeFullCandidate(value) {
                try {
                    if (!value) return null;
                    var text = String(value).trim();
                    if (!text) return null;
                    if (text.indexOf("//") === 0) text = "https:" + text;
                    if (text.indexOf("cloudatacdn.com") === -1 || text.indexOf("~") === -1) return text;
                    if (text.indexOf("?token=") !== -1 || text.indexOf("&token=") !== -1) return text;
                    if (typeof window.makePlay === "function") return text + window.makePlay();
                    return text;
                } catch (e) {
                    return value;
                }
            }

            function report(value, type) {
                try {
                    if (!value) return;
                    var text = makeFullCandidate(value);
                    if (!text || text.indexOf("blob:") === 0 || text.indexOf("data:") === 0) return;
                    if (text.indexOf("dood.video") === -1 && text.indexOf("cloudatacdn.com") === -1) return;
                    handler.postMessage({ url: text, type: type || "unknown", page: window.location.href });
                } catch (e) {}
            }

            function reportSourceObject(value, type) {
                try {
                    if (!value) return;
                    if (typeof value === "string") {
                        report(value, type);
                    } else if (value.src) {
                        report(value.src, type + ":src");
                    } else if (value.file) {
                        report(value.file, type + ":file");
                    } else if (Array.isArray(value)) {
                        for (var i = 0; i < value.length; i++) reportSourceObject(value[i], type + ":item");
                    } else {
                        scanText(JSON.stringify(value), type + ":json");
                    }
                } catch (e) {}
            }

            function scanText(text, type) {
                try {
                    if (!text) return;
                    var matches = String(text).match(/(?:https?:)?\\/\\/[^"'\\s<>]+(?:dood\\.video|cloudatacdn\\.com)[^"'\\s<>]*/gi);
                    if (!matches) return;
                    for (var i = 0; i < matches.length; i++) report(matches[i], type);
                } catch (e) {}
            }

            function scanElement(el, type) {
                try {
                    if (!el) return;
                    var attrs = ["src", "href", "data-src", "data-url", "data-video", "poster"];
                    for (var i = 0; i < attrs.length; i++) report(el.getAttribute && el.getAttribute(attrs[i]), type + ":" + attrs[i]);
                    if (el.currentSrc) report(el.currentSrc, type + ":currentSrc");
                    if (el.src) report(el.src, type + ":src");
                    if (el.href) report(el.href, type + ":href");
                    scanText(el.outerHTML, type + ":html");
                } catch (e) {}
            }

            function scanDocument(type) {
                try {
                    report(window.location.href, type + ":location");
                    scanText(document.documentElement && document.documentElement.innerHTML, type + ":document");
                    var nodes = document.querySelectorAll("video, source, iframe, a, script, [src], [href], [data-src], [data-url], [data-video]");
                    for (var i = 0; i < nodes.length; i++) scanElement(nodes[i], type);
                } catch (e) {}
            }

            try {
                var originalFetch = window.fetch;
                if (originalFetch) {
                    window.fetch = function(input, init) {
                        try {
                            report(typeof input === "string" ? input : input && input.url, "fetch");
                        } catch (e) {}
                        return originalFetch.apply(this, arguments).then(function(response) {
                            try {
                                report(response && response.url, "fetch:response");
                                if (response && response.clone) {
                                    response.clone().text().then(function(text) {
                                        scanText(text, "fetch:body");
                                        report(text, "fetch:body");
                                    }).catch(function() {});
                                }
                            } catch (e) {}
                            return response;
                        });
                    };
                }
            } catch (e) {}

            try {
                var originalOpen = XMLHttpRequest.prototype.open;
                XMLHttpRequest.prototype.open = function(method, url) {
                    this.__pmvdlUrl = url;
                    report(url, "xhr");
                    return originalOpen.apply(this, arguments);
                };
                var originalSend = XMLHttpRequest.prototype.send;
                XMLHttpRequest.prototype.send = function() {
                    try {
                        this.addEventListener("load", function() {
                            try {
                                report(this.responseURL || this.__pmvdlUrl, "xhr:response");
                                if (typeof this.responseText === "string") {
                                    scanText(this.responseText, "xhr:body");
                                    report(this.responseText, "xhr:body");
                                }
                            } catch (e) {}
                        });
                    } catch (e) {}
                    return originalSend.apply(this, arguments);
                };
            } catch (e) {}

            try {
                var originalWindowOpen = window.open;
                window.open = function(url) {
                    report(url, "window.open");
                    return originalWindowOpen.apply(this, arguments);
                };
            } catch (e) {}

            try {
                var originalSetAttribute = Element.prototype.setAttribute;
                Element.prototype.setAttribute = function(name, value) {
                    report(value, "setAttribute:" + name);
                    return originalSetAttribute.apply(this, arguments);
                };
            } catch (e) {}

            try {
                var mediaDescriptor = Object.getOwnPropertyDescriptor(HTMLMediaElement.prototype, "src");
                if (mediaDescriptor && mediaDescriptor.set) {
                    Object.defineProperty(HTMLMediaElement.prototype, "src", {
                        get: mediaDescriptor.get,
                        set: function(value) {
                            report(value, "media.src");
                            return mediaDescriptor.set.call(this, value);
                        }
                    });
                }
            } catch (e) {}

            function scanPlayers() {
                try {
                    if (window.dsplayer) {
                        try { reportSourceObject(window.dsplayer.src && window.dsplayer.src(), "dsplayer:src"); } catch (e) {}
                        try { reportSourceObject(window.dsplayer.currentSource && window.dsplayer.currentSource(), "dsplayer:currentSource"); } catch (e) {}
                        try { reportSourceObject(window.dsplayer.currentSources && window.dsplayer.currentSources(), "dsplayer:currentSources"); } catch (e) {}
                    }
                    var names = ["jwplayer", "player", "videojs", "flowplayer", "Plyr"];
                    for (var i = 0; i < names.length; i++) {
                        var value = window[names[i]];
                        scanText(JSON.stringify(value), "global:" + names[i]);
                    }
                } catch (e) {}
            }

            try {
                new MutationObserver(function(mutations) {
                    for (var i = 0; i < mutations.length; i++) {
                        for (var j = 0; j < mutations[i].addedNodes.length; j++) {
                            scanElement(mutations[i].addedNodes[j], "mutation");
                        }
                    }
                    scanPlayers();
                }).observe(document.documentElement || document, { childList: true, subtree: true, attributes: true });
            } catch (e) {}

            scanDocument("initial");
            setTimeout(function() { scanDocument("timeout:1"); scanPlayers(); }, 1000);
            setTimeout(function() { scanDocument("timeout:3"); scanPlayers(); }, 3000);
            document.addEventListener("DOMContentLoaded", function() { scanDocument("domcontentloaded"); scanPlayers(); });
            window.addEventListener("load", function() { scanDocument("load"); scanPlayers(); });
        })();
        """
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
