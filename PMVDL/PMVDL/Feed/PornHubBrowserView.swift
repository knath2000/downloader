import AppKit
import SwiftUI
import WebKit

enum FeedBrowserSite: CaseIterable {
    case allPornStream
    case eporner
    case hqPorner
    case pornHub
    case rentry

    static let allCases: [FeedBrowserSite] = [
        .allPornStream,
        .rentry,
        .hqPorner,
        .pornHub,
        .eporner
    ]

    static var allHosts: [String] {
        allCases.map(\.host)
    }

    init?(host: String) {
        switch host {
        case AllPornStreamFeedScraper.supportedHost:
            self = .allPornStream
        case EpornerFeedScraper.supportedHost:
            self = .eporner
        case HQPornerFeedScraper.supportedHost:
            self = .hqPorner
        case PornHubFeedScraper.supportedHost:
            self = .pornHub
        case RentryFeedScraper.supportedHost:
            self = .rentry
        default:
            return nil
        }
    }

    var host: String {
        switch self {
        case .allPornStream: return AllPornStreamFeedScraper.supportedHost
        case .eporner: return EpornerFeedScraper.supportedHost
        case .hqPorner: return HQPornerFeedScraper.supportedHost
        case .pornHub: return PornHubFeedScraper.supportedHost
        case .rentry: return RentryFeedScraper.supportedHost
        }
    }

    var displayName: String {
        FeedSiteTheme.theme(for: host).displayName
    }

    var homeURL: URL {
        switch self {
        case .allPornStream:
            return URL(string: "https://allpornstream.com")!
        case .eporner:
            return URL(string: "https://www.eporner.com")!
        case .hqPorner:
            return URL(string: "https://hqporner.com")!
        case .pornHub:
            return URL(string: "https://www.pornhub.com")!
        case .rentry:
            return URL(string: "https://rentry.co/OnlyFan420")!
        }
    }

    func searchURL(for query: String) -> URL? {
        switch self {
        case .allPornStream:
            var components = URLComponents(string: "https://allpornstream.com")
            components?.queryItems = [URLQueryItem(name: "s", value: query)]
            return components?.url
        case .eporner:
            let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? query
            return URL(string: "https://www.eporner.com/search/\(encoded)/")
        case .hqPorner:
            var components = URLComponents(string: "https://hqporner.com")
            components?.queryItems = [URLQueryItem(name: "s", value: query)]
            return components?.url
        case .pornHub:
            var components = URLComponents(string: "https://www.pornhub.com/video/search")
            components?.queryItems = [URLQueryItem(name: "search", value: query)]
            return components?.url
        case .rentry:
            return homeURL
        }
    }

    func allows(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        switch self {
        case .allPornStream:
            return host == "allpornstream.com" || host.hasSuffix(".allpornstream.com")
        case .eporner:
            return host == "eporner.com" || host.hasSuffix(".eporner.com")
        case .hqPorner:
            return host == "hqporner.com" || host.hasSuffix(".hqporner.com")
        case .pornHub:
            return host == "pornhub.com" || host.hasSuffix(".pornhub.com")
        case .rentry:
            return host == "rentry.co" || host.hasSuffix(".rentry.co") || Self.rentryProviderHosts.contains(Self.normalizedHost(host))
        }
    }

    private static let rentryProviderHosts: Set<String> = [
        "luluvid.com",
        "luluvdo.com",
        "lulustream.com",
        "vidara.so",
        "playmogo.com",
        "doodstream.com",
        "dood.wf",
        "vide0.net"
    ]

    private static func normalizedHost(_ host: String) -> String {
        host.lowercased().replacingOccurrences(of: "www.", with: "")
    }
}

enum FeedBrowserContextResolver {
    static func resolvedURL(
        anchorHref: String?,
        cardDataHref: String?,
        descendantHref: String?,
        currentURL: URL
    ) -> URL {
        for href in [anchorHref, cardDataHref, descendantHref] {
            if let url = videoURL(from: href, relativeTo: currentURL) {
                return url
            }
        }
        return currentURL
    }

    private static func videoURL(from href: String?, relativeTo currentURL: URL) -> URL? {
        guard let href = href?.trimmingCharacters(in: .whitespacesAndNewlines),
              !href.isEmpty,
              let url = URL(string: href, relativeTo: currentURL)?.absoluteURL,
              isVideoURL(url) else {
            return nil
        }
        return url
    }

    static func isVideoURL(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        let path = url.path.lowercased()
        let absoluteString = url.absoluteString.lowercased()

        if (host == "allpornstream.com" || host.hasSuffix(".allpornstream.com")) && path.contains("/post/") {
            return true
        }

        if (host == "eporner.com" || host.hasSuffix(".eporner.com")) && path.contains("/video-") {
            return true
        }

        if (host == "hqporner.com" || host.hasSuffix(".hqporner.com")) && path.contains("/hdporn/") {
            return true
        }

        if (host == "pornhub.com" || host.hasSuffix(".pornhub.com")) &&
            absoluteString.contains("view_video.php") &&
            absoluteString.contains("viewkey=") {
            return true
        }

        if rentryProviderHosts.contains(normalizedHost(host)) {
            return true
        }

        return false
    }

    private static let rentryProviderHosts: Set<String> = [
        "luluvid.com",
        "luluvdo.com",
        "lulustream.com",
        "vidara.so",
        "playmogo.com",
        "doodstream.com",
        "dood.wf",
        "vide0.net"
    ]

    private static func normalizedHost(_ host: String) -> String {
        host.lowercased().replacingOccurrences(of: "www.", with: "")
    }
}

enum PornHubBrowserFeedMapper {
    static func feedItem(
        title: String,
        url: String,
        thumbnailURL: String?,
        previewVideoURL: String? = nil,
        uploaderName: String? = nil,
        uploaderURL: String? = nil,
        durationSeconds: Int? = nil,
        uploadDate: Date = Date()
    ) -> FeedItem? {
        guard let viewkey = pornHubViewkey(from: url) else { return nil }
        let normalizedURL = "https://www.pornhub.com/view_video.php?viewkey=\(viewkey)"
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return FeedItem(
            id: "pornhub-browser-\(viewkey)",
            title: cleanTitle.isEmpty ? "PornHub video" : cleanTitle,
            url: normalizedURL,
            thumbnailURL: normalizedURLString(thumbnailURL),
            previewURLs: [],
            previewVideoURL: normalizedURLString(previewVideoURL),
            referer: "https://www.pornhub.com",
            uploadDate: uploadDate,
            uploadDateIsApproximate: true,
            viewCount: 0,
            siteName: PornHubFeedScraper.supportedHost,
            studio: uploaderName,
            studioURL: normalizedURLString(uploaderURL),
            durationSeconds: durationSeconds,
            categories: [],
            tags: [],
            performers: [],
            qualityLabels: [],
            sourceKind: .siteFeed
        )
    }

    static func currentPageItem(title: String?, url: URL?) -> FeedItem? {
        currentPageItem(title: title, url: url, site: .pornHub)
    }

    static func currentPageItem(title: String?, url: URL?, site: FeedBrowserSite) -> FeedItem? {
        guard let url else { return nil }
        return item(title: title, url: url, site: site)
    }

    static func item(title: String?, url: URL) -> FeedItem? {
        item(title: title, url: url, site: .pornHub)
    }

    static func item(title: String?, url: URL, site: FeedBrowserSite) -> FeedItem? {
        guard site.allows(url) else { return nil }
        if let videoItem = feedItem(
            title: title ?? url.absoluteString,
            url: url.absoluteString,
            thumbnailURL: nil
        ) {
            return videoItem
        }

        if let videoItem = feedItemForSite(
            title: title ?? url.absoluteString,
            url: url.absoluteString,
            thumbnailURL: nil,
            site: site
        ) {
            return videoItem
        }

        let cleanTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayTitle: String
        if let cleanTitle, !cleanTitle.isEmpty {
            displayTitle = cleanTitle
        } else {
            displayTitle = url.absoluteString
        }
        return FeedItem(
            id: "\(site.host)-browser-page-\(url.absoluteString.lowercased())",
            title: displayTitle,
            url: url.absoluteString,
            thumbnailURL: nil,
            previewURLs: [],
            previewVideoURL: nil,
            referer: site.homeURL.absoluteString,
            uploadDate: Date(),
            uploadDateIsApproximate: true,
            viewCount: 0,
            siteName: site.host,
            studio: nil,
            studioURL: nil,
            durationSeconds: nil,
            categories: [],
            tags: [],
            performers: [],
            qualityLabels: [],
            sourceKind: .siteFeed
        )
    }

    static func feedItemForSite(
        title: String,
        url: String,
        thumbnailURL: String?,
        previewURLs: [String] = [],
        durationSeconds: Int? = nil,
        site: FeedBrowserSite
    ) -> FeedItem? {
        switch site {
        case .pornHub:
            return feedItem(
                title: title,
                url: url,
                thumbnailURL: thumbnailURL,
                durationSeconds: durationSeconds
            )
        case .allPornStream:
            guard let parsedURL = URL(string: url),
                  site.allows(parsedURL),
                  let id = allPornStreamID(from: url) else { return nil }
            return FeedItem(
                id: "allpornstream-browser-\(id)",
                title: cleanedTitle(title, fallback: "AllPornStream video"),
                url: parsedURL.absoluteString,
                thumbnailURL: normalizedURLString(thumbnailURL),
                previewURLs: previewURLs,
                referer: site.homeURL.absoluteString,
                uploadDate: Date(),
                uploadDateIsApproximate: true,
                viewCount: 0,
                siteName: site.host,
                studio: nil,
                durationSeconds: durationSeconds,
                sourceKind: .siteFeed
            )
        case .eporner:
            guard let parsedURL = URL(string: url),
                  site.allows(parsedURL),
                  let id = epornerID(from: url) else { return nil }
            return FeedItem(
                id: "eporner-browser-\(id)",
                title: cleanedTitle(title, fallback: "Eporner video"),
                url: parsedURL.absoluteString,
                thumbnailURL: normalizedURLString(thumbnailURL),
                previewURLs: previewURLs,
                referer: site.homeURL.absoluteString,
                uploadDate: Date(),
                uploadDateIsApproximate: true,
                viewCount: 0,
                siteName: site.host,
                studio: nil,
                durationSeconds: durationSeconds,
                sourceKind: .siteFeed
            )
        case .hqPorner:
            guard let parsedURL = URL(string: url),
                  site.allows(parsedURL),
                  let id = hqPornerID(from: url) else { return nil }
            return FeedItem(
                id: "hqporner-browser-\(id)",
                title: cleanedTitle(title, fallback: "HQPorner video"),
                url: parsedURL.absoluteString,
                thumbnailURL: normalizedURLString(thumbnailURL),
                previewURLs: previewURLs,
                referer: site.homeURL.absoluteString,
                uploadDate: Date(),
                uploadDateIsApproximate: true,
                viewCount: 0,
                siteName: site.host,
                studio: nil,
                durationSeconds: durationSeconds,
                sourceKind: .siteFeed
            )
        case .rentry:
            guard let parsedURL = URL(string: url),
                  site.allows(parsedURL),
                  let id = rentryProviderID(from: url) else { return nil }
            return FeedItem(
                id: "rentry-browser-\(id)",
                title: cleanedTitle(title, fallback: "Rentry video"),
                url: parsedURL.absoluteString,
                thumbnailURL: normalizedURLString(thumbnailURL),
                previewURLs: previewURLs,
                referer: site.homeURL.absoluteString,
                uploadDate: Date(),
                uploadDateIsApproximate: true,
                viewCount: 0,
                siteName: site.host,
                studio: nil,
                durationSeconds: durationSeconds,
                sourceKind: .siteFeed
            )
        }
    }

    static func pornHubViewkey(from raw: String) -> String? {
        guard let components = URLComponents(string: raw),
              let host = components.host?.lowercased(),
              host == "pornhub.com" || host.hasSuffix(".pornhub.com"),
              let value = components.queryItems?.first(where: { $0.name.caseInsensitiveCompare("viewkey") == .orderedSame })?.value?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value.lowercased()
    }

    static func items(from rawItems: [[String: Any]]) -> [FeedItem] {
        items(from: rawItems, site: .pornHub)
    }

    static func items(from rawItems: [[String: Any]], site: FeedBrowserSite) -> [FeedItem] {
        var seen = Set<String>()
        var output: [FeedItem] = []

        for rawItem in rawItems {
            let url = string(rawItem["url"])
            let key = stableVideoKey(for: url, site: site)
            guard let key,
                  !seen.contains(key) else { continue }
            let previewURLs = string(rawItem["previewURLs"])
                .split(separator: "|")
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            guard let item = site == .pornHub ? feedItem(
                title: string(rawItem["title"]),
                url: url,
                thumbnailURL: string(rawItem["thumbnailURL"]),
                previewVideoURL: string(rawItem["previewVideoURL"]),
                uploaderName: string(rawItem["uploaderName"]),
                uploaderURL: string(rawItem["uploaderURL"]),
                durationSeconds: duration(from: string(rawItem["duration"]))
            ) : feedItemForSite(
                title: string(rawItem["title"]),
                url: url,
                thumbnailURL: string(rawItem["thumbnailURL"]),
                previewURLs: previewURLs,
                durationSeconds: duration(from: string(rawItem["duration"])),
                site: site
            ) else { continue }
            seen.insert(key)
            output.append(item)
        }

        return output
    }

    private static func stableVideoKey(for url: String, site: FeedBrowserSite) -> String? {
        switch site {
        case .pornHub:
            return pornHubViewkey(from: url)
        case .allPornStream:
            return allPornStreamID(from: url)
        case .eporner:
            return epornerID(from: url)
        case .hqPorner:
            return hqPornerID(from: url)
        case .rentry:
            return rentryProviderID(from: url)
        }
    }

    private static func allPornStreamID(from raw: String) -> String? {
        guard let components = URLComponents(string: raw),
              let host = components.host?.lowercased(),
              host == "allpornstream.com" || host.hasSuffix(".allpornstream.com") else { return nil }
        let parts = components.path.split(separator: "/").map(String.init)
        guard let postIndex = parts.firstIndex(of: "post"),
              parts.indices.contains(postIndex + 1) else { return nil }
        return parts[postIndex + 1].lowercased()
    }

    private static func hqPornerID(from raw: String) -> String? {
        guard let components = URLComponents(string: raw),
              let host = components.host?.lowercased(),
              host == "hqporner.com" || host.hasSuffix(".hqporner.com") else { return nil }
        let parts = components.path.split(separator: "/").map(String.init)
        guard let hdpornIndex = parts.firstIndex(of: "hdporn"),
              parts.indices.contains(hdpornIndex + 1),
              let id = parts[hdpornIndex + 1].split(separator: "-").first,
              !id.isEmpty else { return nil }
        return String(id).lowercased()
    }

    private static func epornerID(from raw: String) -> String? {
        guard let components = URLComponents(string: raw),
              let host = components.host?.lowercased(),
              host == "eporner.com" || host.hasSuffix(".eporner.com") else { return nil }
        return firstCapture(pattern: #"\/video-([A-Za-z0-9]+)"#, in: components.path)
    }

    private static func rentryProviderID(from raw: String) -> String? {
        guard let url = URL(string: raw),
              let host = url.host?.lowercased() else { return nil }
        let normalizedHost = host.replacingOccurrences(of: "www.", with: "")
        guard rentryProviderHosts.contains(normalizedHost) else { return nil }
        let last = url.lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        if !last.isEmpty {
            return "\(normalizedHost):\(last)".lowercased()
        }
        let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if !path.isEmpty {
            return "\(normalizedHost):\(path)".lowercased()
        }
        return raw.lowercased()
    }

    private static let rentryProviderHosts: Set<String> = [
        "luluvid.com",
        "luluvdo.com",
        "lulustream.com",
        "vidara.so",
        "playmogo.com",
        "doodstream.com",
        "dood.wf",
        "vide0.net"
    ]

    private static func firstCapture(pattern: String, in value: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        guard let match = regex.firstMatch(in: value, range: range),
              match.numberOfRanges > 1,
              let captureRange = Range(match.range(at: 1), in: value) else { return nil }
        return String(value[captureRange]).lowercased()
    }

    private static func string(_ value: Any?) -> String {
        (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private static func cleanedTitle(_ title: String, fallback: String) -> String {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleanTitle.isEmpty ? fallback : cleanTitle
    }

    private static func normalizedURLString(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }

    private static func duration(from raw: String) -> Int? {
        let parts = raw.split(separator: ":").compactMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        guard !parts.isEmpty, parts.count <= 3 else { return nil }
        if parts.count == 3 {
            return parts[0] * 3600 + parts[1] * 60 + parts[2]
        }
        if parts.count == 2 {
            return parts[0] * 60 + parts[1]
        }
        return parts[0]
    }
}

@MainActor
final class PornHubBrowserViewModel: ObservableObject {
    @Published var currentURL: URL?
    @Published var pageTitle = "PornHub"
    @Published var estimatedProgress = 0.0
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var isLoading = false
    @Published var detectedItems: [FeedItem] = []
    @Published var site: FeedBrowserSite = .pornHub

    weak var webView: WKWebView?
    private var pendingURL: URL?

    var currentFeedItem: FeedItem? {
        PornHubBrowserFeedMapper.currentPageItem(title: pageTitle, url: currentURL, site: site)
    }

    var displayName: String { site.displayName }

    func attach(_ webView: WKWebView) {
        guard self.webView !== webView else { return }
        self.webView = webView
        if let pendingURL {
            self.pendingURL = nil
            webView.load(URLRequest(url: pendingURL))
        } else {
            updateState(from: webView)
        }
    }

    func load(_ url: URL) {
        guard let webView else {
            pendingURL = url
            return
        }
        if webView.url == url {
            updateState(from: webView)
            return
        }
        pendingURL = nil
        webView.load(URLRequest(url: url))
    }

    func configure(site: FeedBrowserSite) {
        guard self.site != site else { return }
        self.site = site
        currentURL = nil
        pageTitle = site.displayName
        detectedItems = []
    }

    func loadHome(feedModel: FeedViewModel) {
        if let url = homeURL(feedModel: feedModel) {
            load(url)
        }
    }

    func homeURL(feedModel: FeedViewModel) -> URL? {
        if site == .pornHub,
           let uploaderURL = feedModel.pornHubUploaderURL {
            return URL(string: "\(uploaderURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")))/videos")
        }
        if site == .pornHub {
            return feedModel.selectedPornHubSection.feedURL(page: 1)
        }
        if site == .eporner,
           let uploaderURL = feedModel.epornerUploaderURL {
            return URL(string: "\(uploaderURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")))/videos")
        }
        if site == .eporner {
            return feedModel.selectedEpornerSection.feedURL(page: 1)
        }
        return site.homeURL
    }

    func goBack() {
        webView?.goBack()
    }

    func goForward() {
        webView?.goForward()
    }

    func reloadOrStop() {
        guard let webView else { return }
        if webView.isLoading {
            webView.stopLoading()
        } else {
            webView.reload()
        }
    }

    func updateState(from webView: WKWebView) {
        currentURL = webView.url
        if let title = webView.title?.trimmingCharacters(in: .whitespacesAndNewlines),
           !title.isEmpty {
            pageTitle = title
        }
        estimatedProgress = webView.estimatedProgress
        canGoBack = webView.canGoBack
        canGoForward = webView.canGoForward
        isLoading = webView.isLoading
    }

    func detectVideosOnCurrentPage(completion: @escaping ([FeedItem]) -> Void) {
        guard let webView else {
            completion([])
            return
        }
        webView.evaluateJavaScript(Self.videoDetectionScript) { [weak self] result, _ in
            Task { @MainActor in
                guard let self else { return }
                let rawItems = result as? [[String: Any]] ?? []
                let items = PornHubBrowserFeedMapper.items(from: rawItems, site: self.site)
                self.detectedItems = items
                completion(items)
            }
        }
    }

    private static let videoDetectionScript = """
    (() => {
      const abs = value => {
        try { return value ? new URL(value, document.location.href).href : ""; } catch (_) { return ""; }
      };
      const text = value => (value || "").replace(/\\s+/g, " ").trim();
      const out = [];
      const seen = new Set();
      document.querySelectorAll('a[href*="view_video.php"][href*="viewkey="], a[href*="/view_video.php?viewkey="], a[href*="/hdporn/"], a[href*="/post/"], a[href*="/video-"], a[href*="luluvid.com"], a[href*="luluvdo.com"], a[href*="lulustream.com"], a[href*="vidara.so"], a[href*="playmogo.com"], a[href*="doodstream.com"], a[href*="dood.wf"]').forEach(anchor => {
        const url = abs(anchor.getAttribute("href"));
        if (!url || seen.has(url)) return;
        seen.add(url);
        const card = anchor.closest("li, .pcVideoListItem, .videoBox, .videoUList, .phimage, div") || anchor;
        const img = card.querySelector("img") || anchor.querySelector("img");
        const uploader = card.querySelector('a[href^="/model/"], a[href^="/pornstar/"], a[href^="/channels/"], a[href^="/user/"]');
        const duration = card.querySelector(".duration, var.duration, .videoDuration");
        const previewURLs = Array.from(card.querySelectorAll("img"))
          .map(image => abs(image.getAttribute("data-src") || image.getAttribute("data-image") || image.getAttribute("src")))
          .filter(Boolean)
          .join("|");
        out.push({
          url,
          title: text(anchor.getAttribute("title")) || text(img?.getAttribute("alt")) || text(anchor.textContent) || document.title,
          thumbnailURL: abs(img?.getAttribute("data-image") || img?.getAttribute("data-mediumthumb") || img?.getAttribute("data-src") || img?.getAttribute("src")),
          previewVideoURL: text(card.getAttribute("data-mediabook") || anchor.getAttribute("data-mediabook")),
          previewURLs,
          uploaderName: text(uploader?.textContent),
          uploaderURL: abs(uploader?.getAttribute("href")),
          duration: text(duration?.textContent)
        });
      });
      return out;
    })();
    """
}

struct PornHubBrowserChrome: View {
    @ObservedObject var browser: PornHubBrowserViewModel
    @Binding var selectedSite: String

    let accent: Color
    let currentPageDownloadedMatch: DownloadedFeedMatch?
    let goHome: () -> Void
    let extractCurrentPage: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.performanceProfile) private var performanceProfile

    private var allowsMotion: Bool {
        !reduceMotion && performanceProfile != .reducedEffects
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                iconButton("chevron.left", enabled: browser.canGoBack, help: "Back") {
                    browser.goBack()
                }
                iconButton("chevron.right", enabled: browser.canGoForward, help: "Forward") {
                    browser.goForward()
                }
                iconButton(browser.isLoading ? "xmark" : "arrow.clockwise", enabled: true, help: browser.isLoading ? "Stop" : "Reload") {
                    browser.reloadOrStop()
                }
                iconButton("house.fill", enabled: true, help: "\(browser.displayName) home") {
                    goHome()
                }

                pageTitlePill
                    .layoutPriority(1)

                Spacer(minLength: 0)
            }

            HStack(spacing: 10) {
                Button {
                    extractCurrentPage()
                } label: {
                    Label("Extract Current Page", systemImage: "bolt.fill")
                }
                .buttonStyle(MobilePrimaryButtonStyle(tint: accent))
                .disabled(browser.currentURL == nil)
                .pressEffect(scale: allowsMotion ? 0.98 : 1)

                if let currentPageDownloadedMatch {
                    Button {
                        AppStateManager.shared.pendingLibraryItemID = currentPageDownloadedMatch.libraryID
                        AppStateManager.shared.select(.library)
                    } label: {
                        Label("Open in Library", systemImage: "checkmark.circle.fill")
                    }
                    .buttonStyle(.bordered)
                    .tint(Theme.success)
                    .controlSize(.large)
                    .help(currentPageDownloadedMatch.tooltip)
                    .pressEffect(scale: allowsMotion ? 0.98 : 1)
                }

                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .mobileCard(tint: accent.opacity(0.18), cornerRadius: 22, isElevated: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottomLeading) {
            if browser.isLoading {
                GeometryReader { proxy in
                    Rectangle()
                        .fill(accent)
                        .frame(width: max(24, proxy.size.width * browser.estimatedProgress), height: 2)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                }
                .allowsHitTesting(false)
            }
        }
    }

    private var pageTitlePill: some View {
        Menu {
            ForEach(FeedBrowserSite.allHosts, id: \.self) { host in
                Button {
                    selectedSite = host
                } label: {
                    if host == selectedSite {
                        Label(FeedSiteTheme.theme(for: host).displayName, systemImage: "checkmark")
                    } else {
                        Text(FeedSiteTheme.theme(for: host).displayName)
                    }
                }
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: FeedSiteTheme.theme(for: selectedSite).icon)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(accent)
                VStack(alignment: .leading, spacing: 1) {
                    Text(FeedSiteTheme.theme(for: selectedSite).displayName)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    if !browser.pageTitle.isEmpty,
                       browser.pageTitle != browser.displayName,
                       browser.pageTitle != FeedSiteTheme.theme(for: selectedSite).displayName {
                        Text(browser.pageTitle)
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Theme.textSecondary)
            }
            .padding(.horizontal, 9)
            .frame(minHeight: 28, maxHeight: 28)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .background(Theme.surfaceGlass.opacity(0.46), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.borderSubtle.opacity(0.9), lineWidth: 0.6))
        }
        .menuStyle(.borderlessButton)
        .buttonStyle(.plain)
        .help("Switch feed site")
    }

    private func iconButton(_ systemImage: String, enabled: Bool, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .bold))
                .frame(width: 28, height: 28)
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? Theme.textPrimary : Theme.textSecondary.opacity(0.45))
        .background(Theme.surfaceGlass.opacity(enabled ? 0.38 : 0.18), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(enabled ? Theme.borderSubtle : Theme.borderSubtle.opacity(0.5), lineWidth: 0.5))
        .disabled(!enabled)
        .pressEffect(scale: enabled && allowsMotion ? 0.94 : 1)
        .help(help)
    }

}

private extension URL {
    var hostAndPathDisplay: String {
        let host = host ?? absoluteString
        let path = path.isEmpty || path == "/" ? "" : path
        return "\(host)\(path)"
    }
}

struct PornHubBrowserWebView: NSViewRepresentable {
    @ObservedObject var browser: PornHubBrowserViewModel
    let initialURL: URL?
    let downloadedItems: [LibraryItem]
    let isSelected: (FeedItem) -> Bool
    let toggleSelection: (FeedItem) -> Void
    let onNavigationFinished: () -> Void

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = WKWebsiteDataStore.default()
        configuration.userContentController.add(context.coordinator, name: "viddlContext")
        configuration.userContentController.addUserScript(WKUserScript(
            source: Self.contextMenuScript,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        ))
        let webView = PornHubContextMenuWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        context.coordinator.attach(to: webView)
        browser.attach(webView)
        if let initialURL {
            webView.load(URLRequest(url: initialURL))
        }
        return webView
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            browser: browser,
            downloadedItems: downloadedItems,
            isSelected: isSelected,
            toggleSelection: toggleSelection,
            onNavigationFinished: onNavigationFinished
        )
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.updateDownloadedIndicators(in: webView, items: downloadedItems)
    }

    private static func downloadedIndicatorPayload(for items: [LibraryItem]) -> String {
        let index = DownloadedFeedIndex(items: items)
        return index.javascriptPayload
    }

    private static let downloadedIndicatorScript = """
    (() => {
      const payload = __PAYLOAD__;
      window.__viddlDownloadedPayload = payload;
      window.__viddlDownloadedObserver?.disconnect();
      const normalize = value => {
        try {
          const url = new URL(value, document.location.href);
          url.protocol = url.protocol.toLowerCase();
          url.hostname = url.hostname.toLowerCase();
          url.hash = "";
          return url.href;
        } catch (_) { return String(value || "").trim(); }
      };
      const viewkey = value => {
        try {
          const url = new URL(value, document.location.href);
          if (!url.hostname.toLowerCase().includes("pornhub.com")) return "";
          return (url.searchParams.get("viewkey") || "").trim().toLowerCase();
        } catch (_) { return ""; }
      };
      const matches = value => {
        const normalized = normalize(value);
        const key = viewkey(value);
        return payload.urls.includes(normalized) || (key && payload.viewkeys.includes(key));
      };
      const selectors = 'a[href*="view_video.php"][href*="viewkey="], a[href*="/hdporn/"], a[href*="/post/"], a[href*="/video-"], a[href*="luluvid.com"], a[href*="luluvdo.com"], a[href*="lulustream.com"], a[href*="vidara.so"], a[href*="playmogo.com"], a[href*="doodstream.com"], a[href*="dood.wf"]';
      let observer;
      const decorate = () => {
        observer?.disconnect();
        document.querySelectorAll(selectors).forEach(anchor => {
          const href = anchor.getAttribute("href");
          const card = anchor.closest("li, .pcVideoListItem, .videoBox, .videoUList, .phimage, article, section, div") || anchor;
          const existingBadge = card.querySelector('.viddl-downloaded-badge');
          if (!matches(href)) {
            existingBadge?.remove();
            return;
          }
          if (existingBadge) return;
          if (getComputedStyle(card).position === "static") card.style.position = "relative";
          const badge = document.createElement("span");
          badge.className = "viddl-downloaded-badge";
          badge.textContent = "✓";
          badge.title = "Already downloaded in LustreStudio";
          card.appendChild(badge);
        });
        observer?.observe(document.body, { childList: true, subtree: true });
      };
      if (!document.getElementById("viddl-downloaded-style")) {
        const style = document.createElement("style");
        style.id = "viddl-downloaded-style";
        style.textContent = '.viddl-downloaded-badge { position: absolute; top: 8px; right: 8px; z-index: 2147483647; width: 22px; height: 22px; border-radius: 999px; display: flex; align-items: center; justify-content: center; background: #35d07f; color: #07150d; font: 700 15px -apple-system, BlinkMacSystemFont, sans-serif; box-shadow: 0 2px 8px rgba(0,0,0,.35); pointer-events: none; }';
        document.head.appendChild(style);
      }
      decorate();
      observer = new MutationObserver(() => { window.requestAnimationFrame(decorate); });
      window.__viddlDownloadedObserver = observer;
      observer.observe(document.body, { childList: true, subtree: true });
    })();
    """

    fileprivate static let rentryLayoutScript = """
    (() => {
      const host = window.location.hostname.toLowerCase();
      if (host !== "rentry.co" && !host.endsWith(".rentry.co")) return;
      const selectors = [
        "html",
        "body",
        ".body",
        ".sub-body",
        ".container-smooth",
        ".long-words",
        ".entry-text-container",
        ".entry-text",
        ".entry-text article",
        ".ntable-wrapper"
      ];
      selectors.forEach(selector => {
        document.querySelectorAll(selector).forEach(element => {
          element.style.height = "auto";
          element.style.minHeight = "0";
          element.style.maxHeight = "none";
          element.style.overflow = "visible";
          element.style.overflowY = "visible";
        });
      });
      document.documentElement.style.overflowY = "auto";
      document.body.style.overflowY = "auto";
      window.dispatchEvent(new Event("resize"));
    })();
    """

    private static let contextMenuScript = """
    (() => {
      if (window.__viddlContextMenuInstalled) return;
      window.__viddlContextMenuInstalled = true;
      const abs = value => {
        try { return value ? new URL(value, document.location.href).href : ""; } catch (_) { return ""; }
      };
      const isVideoURL = value => {
        try {
          if (!value) return false;
          const url = new URL(value, document.location.href);
          const host = url.hostname.toLowerCase();
          const path = url.pathname.toLowerCase();
          const href = url.href.toLowerCase();
          return ((host === "allpornstream.com" || host.endsWith(".allpornstream.com")) && path.includes("/post/")) ||
            ((host === "eporner.com" || host.endsWith(".eporner.com")) && path.includes("/video-")) ||
            ((host === "hqporner.com" || host.endsWith(".hqporner.com")) && path.includes("/hdporn/")) ||
            ((host === "pornhub.com" || host.endsWith(".pornhub.com")) && href.includes("view_video.php") && href.includes("viewkey=")) ||
            ["luluvid.com", "luluvdo.com", "lulustream.com", "vidara.so", "playmogo.com", "doodstream.com", "dood.wf"].includes(host.replace(/^www\\./, ""));
        } catch (_) {
          return false;
        }
      };
      const videoHref = value => isVideoURL(value) ? abs(value) : "";
      const text = value => (value || "").replace(/\\s+/g, " ").trim();
      const firstSrcsetURL = value => {
        const first = (value || "").split(",")[0]?.trim().split(/\\s+/)[0];
        return abs(first);
      };
      document.addEventListener("contextmenu", event => {
        const videoSelector = 'a[href*="view_video.php"][href*="viewkey="], a[href*="/hdporn/"], a[href*="/post/"], a[href*="/video-"], a[href*="luluvid.com"], a[href*="luluvdo.com"], a[href*="lulustream.com"], a[href*="vidara.so"], a[href*="playmogo.com"], a[href*="doodstream.com"], a[href*="dood.wf"]';
        const cardSelector = '[data-href*="/post/"], [data-thumb-id], [data-href*="/hdporn/"], [data-href*="view_video.php"], [data-href*="/video-"], li, .pcVideoListItem, .videoBox, .videoUList, .phimage, article, section';
        const anchor = event.target && event.target.closest ? event.target.closest(videoSelector) : null;
        const card = event.target && event.target.closest ? (event.target.closest(cardSelector) || anchor?.closest(cardSelector)) : null;
        const cardHref = card?.getAttribute("data-href") || card?.getAttribute("data-url") || card?.getAttribute("href");
        const descendant = card?.querySelector(videoSelector);
        const img = card?.querySelector("img") || anchor?.querySelector("img");
        const titleNode = anchor || card?.querySelector('a[href*="/post/"], a[href*="/hdporn/"], a[href*="view_video.php"], a[href*="/video-"], h1, h2, h3, [aria-label]');
        const url = videoHref(anchor?.getAttribute("href")) ||
          videoHref(cardHref) ||
          videoHref(descendant?.getAttribute("href")) ||
          document.location.href;
        const thumbnailURL = abs(img?.getAttribute("src")) ||
          abs(img?.getAttribute("data-src")) ||
          firstSrcsetURL(img?.getAttribute("srcset")) ||
          firstSrcsetURL(img?.getAttribute("data-srcset"));
        const title = text(anchor?.getAttribute("title")) ||
          text(titleNode?.getAttribute("title")) ||
          text(titleNode?.getAttribute("aria-label")) ||
          text(img?.getAttribute("alt")) ||
          text(titleNode?.textContent) ||
          document.title ||
          url;
        event.preventDefault();
        window.webkit?.messageHandlers?.viddlContext?.postMessage({ url, title, thumbnailURL, x: event.clientX, y: event.clientY });
      }, true);
    })();
    """

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        private weak var browser: PornHubBrowserViewModel?
        private weak var webView: PornHubContextMenuWebView?
        private var downloadedItems: [LibraryItem]
        private var lastDownloadedPayload: String?
        private let isSelected: (FeedItem) -> Bool
        private let toggleSelection: (FeedItem) -> Void
        private let onNavigationFinished: () -> Void
        private var observations: [NSKeyValueObservation] = []
        private var latestContext: [String: String]?
        private var contextPanel: NSPanel?
        private var contextEventMonitor: Any?

        init(
            browser: PornHubBrowserViewModel,
            downloadedItems: [LibraryItem],
            isSelected: @escaping (FeedItem) -> Bool,
            toggleSelection: @escaping (FeedItem) -> Void,
            onNavigationFinished: @escaping () -> Void
        ) {
            self.browser = browser
            self.downloadedItems = downloadedItems
            self.isSelected = isSelected
            self.toggleSelection = toggleSelection
            self.onNavigationFinished = onNavigationFinished
        }

        func updateDownloadedIndicators(in webView: WKWebView, items: [LibraryItem]) {
            downloadedItems = items
            let payload = PornHubBrowserWebView.downloadedIndicatorPayload(for: items)
            guard payload != lastDownloadedPayload else { return }
            lastDownloadedPayload = payload
            let script = PornHubBrowserWebView.downloadedIndicatorScript.replacingOccurrences(of: "__PAYLOAD__", with: payload)
            webView.evaluateJavaScript(script)
        }

        func attach(to webView: WKWebView) {
            self.webView = webView as? PornHubContextMenuWebView
            observations = [
                webView.observe(\.estimatedProgress, options: [.new]) { [weak self] webView, _ in
                    Task { @MainActor in self?.browser?.updateState(from: webView) }
                },
                webView.observe(\.title, options: [.new]) { [weak self] webView, _ in
                    Task { @MainActor in self?.browser?.updateState(from: webView) }
                },
                webView.observe(\.url, options: [.new]) { [weak self] webView, _ in
                    Task { @MainActor in self?.browser?.updateState(from: webView) }
                }
            ]
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            browser?.updateState(from: webView)
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            guard let url = navigationAction.request.url,
                  let scheme = url.scheme?.lowercased(),
                  ["http", "https"].contains(scheme),
                  let site = browser?.site else {
                decisionHandler(.cancel)
                return
            }

            if URLTrustPolicy.isAllowed(url) && site.allows(url) {
                decisionHandler(.allow)
            } else {
                decisionHandler(.cancel)
            }
        }

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            browser?.updateState(from: webView)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            browser?.updateState(from: webView)
            webView.evaluateJavaScript(PornHubBrowserWebView.rentryLayoutScript)
            updateDownloadedIndicators(in: webView, items: downloadedItems)
            onNavigationFinished()
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            browser?.updateState(from: webView)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            browser?.updateState(from: webView)
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.frameInfo.isMainFrame,
                  let rawContext = message.body as? [String: Any] else { return }
            latestContext = rawContext.reduce(into: [String: String]()) { output, element in
                output[element.key] = String(describing: element.value)
            }
            showContextMenu(for: rawContext)
        }

        func viddlContext(for webView: WKWebView) -> (url: URL, title: String)? {
            let targetURL = latestContext.flatMap { contextURL(from: $0) } ?? webView.url
            guard let targetURL,
                  let site = browser?.site,
                  site.allows(targetURL) else {
                return nil
            }

            let title = latestContext?["title"]?.trimmingCharacters(in: .whitespacesAndNewlines)
                ?? webView.title?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (
                targetURL,
                title?.isEmpty == false ? title ?? targetURL.absoluteString : targetURL.absoluteString
            )
        }

        private func showContextMenu(for rawContext: [String: Any]) {
            guard let webView,
                  let context = viddlContext(for: webView),
                  let item = feedItem(for: context) else { return }

            let x = rawContext["x"] as? Double ?? 12
            let y = rawContext["y"] as? Double ?? 12
            let point = webView.contextMenuAnchorPoint(clientX: x, clientY: y)
            let windowPoint = webView.convert(point, to: nil)
            let screenPoint = webView.window?.convertPoint(toScreen: windowPoint) ?? NSEvent.mouseLocation
            let menuSize = NSSize(width: 252, height: 332)
            let visibleFrame = (webView.window?.screen ?? NSScreen.main)?.visibleFrame ?? .zero
            let menuOrigin = NSPoint(
                x: min(max(screenPoint.x, visibleFrame.minX + 8), visibleFrame.maxX - menuSize.width - 8),
                y: min(max(screenPoint.y - menuSize.height, visibleFrame.minY + 8), visibleFrame.maxY - menuSize.height - 8)
            )

            dismissContextMenu()
            let panel = NSPanel(
                contentRect: NSRect(origin: menuOrigin, size: menuSize),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.backgroundColor = NSColor.clear
            panel.collectionBehavior = NSWindow.CollectionBehavior([.transient, .ignoresCycle])
            panel.hasShadow = false
            panel.isMovable = false
            panel.isOpaque = false
            panel.level = NSWindow.Level.popUpMenu
            let accent = FeedSiteTheme.theme(for: browser?.site.host ?? PornHubFeedScraper.supportedHost).accent
            var actions = [
                AppContextMenuAction(isSelected(item) ? "Deselect" : "Select", systemImage: isSelected(item) ? "checkmark.circle.fill" : "circle", action: { [weak self] in self?.performToggleSelection(item) }),
                AppContextMenuAction("Extract with LustreStudio", systemImage: "bolt.fill", action: { [weak self] in self?.performExtract(context) }),
                AppContextMenuAction("Toggle Watchlist", systemImage: "bookmark.fill", action: { [weak self] in self?.performToggleFavorite(context) })
            ]
            if DownloadedFeedIndex(items: VideoLibrary.shared.items).match(for: item) != nil {
                actions.append(AppContextMenuAction("Open in Library", systemImage: "checkmark.circle.fill", action: { [weak self] in self?.performOpenLibrary(context) }))
            }
            panel.contentView = NSHostingView(rootView: AppContextMenuView(
                title: context.title,
                subtitle: context.url.hostAndPathDisplay,
                accent: accent,
                actions: actions,
                dismiss: { [weak self] in self?.dismissContextMenu() }
            ))
            contextPanel = panel
            panel.orderFront(nil as Any?)
            contextEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
                if event.type == .keyDown || event.window !== self?.contextPanel {
                    self?.dismissContextMenu()
                }
                return event
            }
        }

        private func contextURL(from context: [String: String]) -> URL? {
            guard let rawURL = context["url"] else { return nil }
            return URL(string: rawURL)
        }

        private func dismissContextMenu() {
            contextPanel?.close()
            contextPanel = nil
            if let contextEventMonitor {
                NSEvent.removeMonitor(contextEventMonitor)
                self.contextEventMonitor = nil
            }
        }

        private func performExtract(_ context: (url: URL, title: String)) {
            dismissContextMenu()
            guard let item = feedItem(for: context) else { return }
            Task { @MainActor in
                AppStateManager.shared.pendingExtractThumbnailURL = item.thumbnailURL
                AppStateManager.shared.pendingExtractShouldStart = true
                AppStateManager.shared.pendingExtractURL = item.url
                AppStateManager.shared.select(.home)
            }
        }

        private func performToggleFavorite(_ context: (url: URL, title: String)) {
            dismissContextMenu()
            guard let item = feedItem(for: context) else { return }
            Task { @MainActor in
                WatchlistStore.shared.toggle(feedItem: item)
            }
        }

        private func performOpenLibrary(_ context: (url: URL, title: String)) {
            dismissContextMenu()
            guard let item = feedItem(for: context) else { return }
            Task { @MainActor in
                guard let match = DownloadedFeedIndex(items: VideoLibrary.shared.items).match(for: item) else { return }
                AppStateManager.shared.pendingLibraryItemID = match.libraryID
                AppStateManager.shared.select(.library)
            }
        }

        private func performToggleSelection(_ item: FeedItem) {
            dismissContextMenu()
            Task { @MainActor in
                toggleSelection(item)
            }
        }

        private func feedItem(for context: (url: URL, title: String)) -> FeedItem? {
            guard let site = browser?.site else { return nil }
            return PornHubBrowserFeedMapper.item(title: context.title, url: context.url, site: site)
        }
    }
}

struct PornHubBrowserLoadingOverlay: View {
    let progress: Double
    let accent: Color

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.performanceProfile) private var performanceProfile

    private var allowsMotion: Bool {
        !reduceMotion && performanceProfile.allowsLoadingAnimation
    }

    var body: some View {
        VStack(spacing: 10) {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.black.opacity(0.28))
                    Capsule()
                        .fill(accent.opacity(0.72))
                        .frame(width: max(36, proxy.size.width * max(0.08, min(progress, 1))))
                        .shadow(color: accent.opacity(allowsMotion ? 0.22 : 0), radius: 5)
                }
            }
            .frame(width: 180, height: 4)

            Text("Loading")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.textSecondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.black.opacity(0.54), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(accent.opacity(0.22), lineWidth: 0.7))
        .opacity(allowsMotion ? 0.92 : 0.78)
        .transition(allowsMotion ? .opacity.combined(with: .scale(scale: 0.985)) : .opacity)
        .allowsHitTesting(false)
    }
}

private final class PornHubContextMenuWebView: WKWebView {
    func contextMenuAnchorPoint(clientX: Double, clientY: Double) -> NSPoint {
        let x = min(max(CGFloat(clientX), bounds.minX), bounds.maxX)
        let rawY = CGFloat(clientY)
        let y = isFlipped
            ? min(max(rawY, bounds.minY), bounds.maxY)
            : min(max(bounds.height - rawY, bounds.minY), bounds.maxY)
        return NSPoint(x: x, y: y)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        nil
    }
}

private extension URL {
    var isPornHubURL: Bool {
        guard let host = host?.lowercased() else { return false }
        return host == "pornhub.com" || host.hasSuffix(".pornhub.com")
    }
}
