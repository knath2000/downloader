import AppKit
import SwiftUI

private enum FeedLayout {
    static let contentMaxWidth: CGFloat = 2400
    static let outerSpacing: CGFloat = 12
    static let sectionSpacing: CGFloat = 8
    static let selectionBarMinimumBottomInset: CGFloat = 96
    static let selectionBarGap: CGFloat = 14
}

struct DownloadedFeedMatch: Hashable, Identifiable {
    let libraryID: UUID
    let title: String
    let url: String
    let downloadedAt: Date

    var id: UUID { libraryID }

    var tooltip: String {
        "Downloaded as \(title) on \(downloadedAt.formatted(date: .abbreviated, time: .shortened))"
    }
}

struct DownloadedFeedIndex: Equatable {
    private let urlMatches: [String: DownloadedFeedMatch]
    private let pornHubViewkeyMatches: [String: DownloadedFeedMatch]

    init(items: [LibraryItem]) {
        var urlMatches: [String: DownloadedFeedMatch] = [:]
        var pornHubViewkeyMatches: [String: DownloadedFeedMatch] = [:]

        for item in items {
            let match = DownloadedFeedMatch(
                libraryID: item.id,
                title: LibraryDisplayTitle.title(for: item),
                url: item.url,
                downloadedAt: item.extractedAt
            )
            let normalized = Self.normalizedURL(item.url)
            if !normalized.isEmpty, urlMatches[normalized] == nil {
                urlMatches[normalized] = match
            }
            if let viewkey = Self.pornHubViewkey(item.url),
               pornHubViewkeyMatches[viewkey] == nil {
                pornHubViewkeyMatches[viewkey] = match
            }
        }

        self.urlMatches = urlMatches
        self.pornHubViewkeyMatches = pornHubViewkeyMatches
    }

    func match(for item: FeedItem) -> DownloadedFeedMatch? {
        if let viewkey = Self.pornHubViewkey(item.url),
           let match = pornHubViewkeyMatches[viewkey] {
            return match
        }
        return urlMatches[Self.normalizedURL(item.url)]
    }

    static func normalizedURL(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              var components = URLComponents(string: trimmed) else { return trimmed }
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        components.fragment = nil
        return components.string ?? trimmed
    }

    static func pornHubViewkey(_ raw: String) -> String? {
        let lower = raw.lowercased()
        guard lower.contains("pornhub.com") else { return nil }
        guard let components = URLComponents(string: raw),
              let value = components.queryItems?.first(where: { $0.name.caseInsensitiveCompare("viewkey") == .orderedSame })?.value,
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

enum FeedSelectionStore {
    static func key(for item: FeedItem) -> String {
        DownloadedFeedIndex.normalizedURL(item.url).lowercased()
    }

    static func toggled(_ item: FeedItem, in selectedItems: [String: FeedItem]) -> [String: FeedItem] {
        var next = selectedItems
        let key = key(for: item)
        if next[key] == nil {
            next[key] = item
        } else {
            next.removeValue(forKey: key)
        }
        return next
    }

    static func adding(_ items: [FeedItem], to selectedItems: [String: FeedItem]) -> [String: FeedItem] {
        var next = selectedItems
        for item in items {
            next[key(for: item)] = item
        }
        return next
    }
}

@MainActor
private final class FeedSessionSelectionStore: ObservableObject {
    static let shared = FeedSessionSelectionStore()

    @Published private(set) var selectedItems: [String: FeedItem] = [:]

    private init() {}

    func isSelected(_ item: FeedItem) -> Bool {
        selectedItems[FeedSelectionStore.key(for: item)] != nil
    }

    func toggle(_ item: FeedItem) {
        selectedItems = FeedSelectionStore.toggled(item, in: selectedItems)
    }

    func clear() {
        selectedItems = [:]
    }
}

private enum LibraryDisplayTitle {
    static func title(for item: LibraryItem) -> String {
        let stripped = item.title.replacingOccurrences(
            of: #"_[0-9A-Fa-f][0-9A-Fa-f_-]{10,}.*$"#,
            with: "",
            options: .regularExpression
        )
        let trimmed = stripped.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? item.url : trimmed
    }
}

struct FeedView: View {
    var bottomChromeInset: CGFloat = 0

    @StateObject private var appState = AppStateManager.shared
    @StateObject private var model = FeedViewModel.shared
    @StateObject private var favorites = FeedFavoritesStore.shared
    @StateObject private var library = VideoLibrary.shared
    @StateObject private var pornHubSession = PornHubSessionManager.shared
    @StateObject private var epornerSession = EpornerSessionManager.shared
    @StateObject private var feedBrowser = PornHubBrowserViewModel()
    @StateObject private var selectionStore = FeedSessionSelectionStore.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.performanceProfile) private var performanceProfile

    private var isSelecting: Bool { !selectionStore.selectedItems.isEmpty }
    private var selectionBarBottomInset: CGFloat {
        max(FeedLayout.selectionBarMinimumBottomInset, bottomChromeInset + FeedLayout.selectionBarGap)
    }
    private var siteTheme: FeedSiteTheme {
        FeedSiteTheme.theme(for: model.selectedSite)
    }

    var body: some View {
        GeometryReader { _ in
            VStack(spacing: FeedLayout.outerSpacing) {
                feedBrowserArea
            }
            .frame(maxWidth: FeedLayout.contentMaxWidth, maxHeight: .infinity, alignment: .topLeading)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.horizontal, FeedLayout.outerSpacing)
            .padding(.top, 6)
            .background(siteTheme.backgroundTint.opacity(0.18).ignoresSafeArea())
            .animation(reduceMotion ? nil : .spring(response: 0.24, dampingFraction: 0.82), value: isSelecting)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: model.selectedSite)
        }
        .task {
            await model.loadPornHubSubscriptionsIfNeeded()
            await model.loadEpornerSubscriptionsIfNeeded()
        }
        .onChange(of: model.selectedSite) { _, newSite in
            if newSite != PornHubFeedScraper.supportedHost {
                model.clearPornHubContext()
            } else {
                Task { await model.loadPornHubSubscriptionsIfNeeded() }
            }
            if let browserSite = FeedBrowserSite(host: newSite) {
                feedBrowser.configure(site: browserSite)
                if let request = appState.pendingFeedNavigation,
                   request.site == browserSite {
                    feedBrowser.load(request.url)
                    appState.pendingFeedNavigation = nil
                } else {
                    feedBrowser.loadHome(feedModel: model)
                }
            }
            if newSite != EpornerFeedScraper.supportedHost {
                model.clearEpornerContext()
            } else {
                Task { await model.loadEpornerSubscriptionsIfNeeded() }
            }
        }
        .onChange(of: model.selectedPornHubSection) { _, _ in
            if model.selectedSite == PornHubFeedScraper.supportedHost {
                feedBrowser.loadHome(feedModel: model)
            }
        }
        .onChange(of: model.pornHubUploaderURL) { _, _ in
            if model.selectedSite == PornHubFeedScraper.supportedHost {
                feedBrowser.loadHome(feedModel: model)
            }
        }
        .onChange(of: model.selectedEpornerSection) { _, _ in
            if model.selectedSite == EpornerFeedScraper.supportedHost {
                feedBrowser.loadHome(feedModel: model)
            }
        }
        .onChange(of: pornHubSession.isLoggedIn) { _, isLoggedIn in
            if isLoggedIn && model.selectedSite == PornHubFeedScraper.supportedHost {
                Task { await model.loadPornHubSubscriptionsIfNeeded() }
            } else if !isLoggedIn {
                model.pornHubSubscriptions = []
                model.pornHubSubscriptionsError = nil
            }
        }
        .onChange(of: epornerSession.isLoggedIn) { _, isLoggedIn in
            if isLoggedIn && model.selectedSite == EpornerFeedScraper.supportedHost {
                Task { await model.loadEpornerSubscriptionsIfNeeded() }
            } else if !isLoggedIn {
                model.epornerSubscriptions = []
                model.epornerSubscriptionsError = nil
            }
        }
    }

    private var feedBrowserArea: some View {
        VStack(spacing: FeedLayout.sectionSpacing) {
            let currentItem = feedBrowser.currentFeedItem
            let downloadedIndex = DownloadedFeedIndex(items: library.items)
            let currentDownloadedMatch = currentItem.flatMap { downloadedIndex.match(for: $0) }

            if model.selectedSite == PornHubFeedScraper.supportedHost ||
                model.selectedSite == EpornerFeedScraper.supportedHost {
                inlineSubscriptionPicker
            }

            PornHubBrowserChrome(
                browser: feedBrowser,
                selectedSite: $model.selectedSite,
                accent: siteTheme.accent,
                currentPageIsFavorite: currentItem.map { favorites.contains(url: $0.url) } ?? false,
                currentPageDownloadedMatch: currentDownloadedMatch,
                goHome: { feedBrowser.loadHome(feedModel: model) },
                extractCurrentPage: extractCurrentBrowserPage,
                toggleFavoriteCurrentPage: toggleFavoriteCurrentBrowserPage
            )

            PornHubBrowserWebView(
                browser: feedBrowser,
                initialURL: feedBrowser.homeURL(feedModel: model),
                isSelected: { item in selectionStore.isSelected(item) },
                toggleSelection: { item in toggleSelection(item) },
                onNavigationFinished: {
                    Task { @MainActor in
                        if model.selectedSite == PornHubFeedScraper.supportedHost {
                            await PornHubSessionManager.shared.syncFromWebView()
                        } else if model.selectedSite == EpornerFeedScraper.supportedHost {
                            await EpornerSessionManager.shared.syncFromWebView()
                        }
                    }
                }
            )
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(siteTheme.accent.opacity(0.18), lineWidth: 0.8))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .bottom) {
                if isSelecting {
                    FeedBrowserSelectionBar(
                        count: selectionStore.selectedItems.count,
                        accent: siteTheme.accent,
                        clear: { selectionStore.clear() },
                        extract: extractSelected
                    )
                    .padding(.horizontal, 20)
                    .padding(.bottom, selectionBarBottomInset)
                    .transition(selectionBarTransition)
                    .zIndex(2)
                }
            }
            .overlay {
                if feedBrowser.isLoading {
                    PornHubBrowserLoadingOverlay(
                        progress: feedBrowser.estimatedProgress,
                        accent: siteTheme.accent
                    )
                    .animation(selectionBarAnimation, value: feedBrowser.isLoading)
                }
            }
            .animation(selectionBarAnimation, value: isSelecting)
        }
        .frame(
            width: AppShellSurfaceMetrics.browserSurfaceWidth(for: appState.windowSize),
            height: AppShellSurfaceMetrics.browserSurfaceHeight(
                for: appState.windowSize,
                reservedBottomInset: bottomChromeInset
            )
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            if let browserSite = FeedBrowserSite(host: model.selectedSite) {
                feedBrowser.configure(site: browserSite)
            }
            openPendingFeedNavigationIfNeeded()
            if appState.pendingFeedNavigation == nil && feedBrowser.currentURL == nil {
                feedBrowser.loadHome(feedModel: model)
            }
        }
        .onChange(of: appState.pendingFeedNavigation) { _, _ in
            openPendingFeedNavigationIfNeeded()
        }
    }

    private func openPendingFeedNavigationIfNeeded() {
        guard let request = appState.pendingFeedNavigation else { return }
        guard model.selectedSite == request.site.host else {
            model.selectedSite = request.site.host
            return
        }
        feedBrowser.configure(site: request.site)
        feedBrowser.load(request.url)
        appState.pendingFeedNavigation = nil
    }

    @ViewBuilder
    private var inlineSubscriptionPicker: some View {
        if shouldShowInlineSubscriptionPicker {
            if model.selectedSite == EpornerFeedScraper.supportedHost {
                EpornerSubscriptionsInlinePicker(model: model, accent: siteTheme.accent)
            } else {
                PornHubSubscriptionsInlinePicker(model: model, accent: siteTheme.accent)
            }
        }
    }

    private var shouldShowInlineSubscriptionPicker: Bool {
        (model.selectedSite == PornHubFeedScraper.supportedHost &&
            pornHubSession.isLoggedIn &&
            model.selectedPornHubSection == .subscriptions &&
            model.pornHubUploaderURL == nil) ||
            (model.selectedSite == EpornerFeedScraper.supportedHost &&
            epornerSession.isLoggedIn &&
            model.selectedEpornerSection == .subscriptions &&
            model.epornerUploaderURL == nil)
    }

    private var selectionBarTransition: AnyTransition {
        if reduceMotion || performanceProfile == .reducedEffects {
            return .opacity
        }
        return .opacity.combined(with: .move(edge: .bottom))
    }

    private var selectionBarAnimation: Animation? {
        reduceMotion || performanceProfile == .reducedEffects ? nil : .spring(response: 0.24, dampingFraction: 0.82)
    }

    private func extract(_ item: FeedItem) {
        AppStateManager.shared.pendingExtractThumbnailURL = item.thumbnailURL
        AppStateManager.shared.pendingExtractShouldStart = true
        AppStateManager.shared.pendingExtractURL = item.url
        AppStateManager.shared.select(.home)
    }

    private func extractCurrentBrowserPage() {
        guard let item = feedBrowser.currentFeedItem else { return }
        extract(item)
    }

    private func toggleFavoriteCurrentBrowserPage() {
        guard let item = feedBrowser.currentFeedItem else { return }
        withAnimation {
            favorites.toggle(feedItem: item)
        }
    }

    private func toggleSelection(_ item: FeedItem) {
        selectionStore.toggle(item)
    }

    private func extractSelected() {
        let selected = Array(selectionStore.selectedItems.values)
        guard !selected.isEmpty else { return }

        AppStateManager.shared.pendingExtractThumbnailURL = nil
        AppStateManager.shared.pendingExtractShouldStart = true
        AppStateManager.shared.pendingExtractURL = selected.map(\.url).joined(separator: "\n")
        selectionStore.clear()
        AppStateManager.shared.select(.home)
    }
}

private struct FeedBrowserSelectionBar: View {
    let count: Int
    let accent: Color
    let clear: () -> Void
    let extract: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Label("\(count) selected", systemImage: "checkmark.circle.fill")
                .font(.caption.weight(.bold))
                .foregroundStyle(Theme.textPrimary)

            Spacer(minLength: 16)

            Button(action: clear) {
                Label("Clear", systemImage: "xmark")
            }
            .buttonStyle(.plain)
            .font(.caption.weight(.semibold))
            .foregroundStyle(Theme.textSecondary)
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5))
            .pressEffect(scale: 0.97)

            Button(action: extract) {
                Label("Extract Selected", systemImage: "bolt.fill")
            }
            .buttonStyle(.plain)
            .font(.caption.weight(.bold))
            .foregroundStyle(Color.black.opacity(0.86))
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(accent, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5))
            .pressEffect(scale: 0.97)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.black.opacity(0.78))
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(.ultraThinMaterial.opacity(0.54))
            }
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(accent.opacity(0.34), lineWidth: 0.8)
        )
        .shadow(color: .black.opacity(0.30), radius: 16, x: 0, y: 8)
        .frame(maxWidth: 520)
        .accessibilityElement(children: .combine)
    }
}

private struct PornHubSubscriptionsInlinePicker: View {
    @ObservedObject var model: FeedViewModel

    let accent: Color

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                if model.isLoadingPornHubSubscriptions {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.65)
                        .padding(.horizontal, 8)
                } else if model.pornHubSubscriptions.isEmpty {
                    Text(model.pornHubSubscriptionsError ?? "No subscriptions found")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.textSecondary)
                        .padding(.horizontal, 2)
                } else {
                    ForEach(model.pornHubSubscriptions) { subscription in
                        Button {
                            Task {
                                await model.navigateToPornHubUploader(url: subscription.url, name: subscription.name)
                            }
                        } label: {
                            Text(subscription.name)
                                .font(.caption.weight(.bold))
                                .foregroundStyle(Theme.textPrimary)
                                .lineLimit(1)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(Color.white.opacity(0.06), in: Capsule())
                                .overlay(Capsule().strokeBorder(accent.opacity(0.18), lineWidth: 0.5))
                        }
                        .buttonStyle(.plain)
                        .pressEffect(scale: 0.98)
                        .help(subscription.name)
                    }
                }
            }
            .padding(.horizontal, 2)
            .padding(.vertical, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task {
            await model.loadPornHubSubscriptionsIfNeeded()
        }
    }
}

private struct EpornerSubscriptionsInlinePicker: View {
    @ObservedObject var model: FeedViewModel

    let accent: Color

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                if model.isLoadingEpornerSubscriptions {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.65)
                        .padding(.horizontal, 8)
                } else if model.epornerSubscriptions.isEmpty {
                    Text(model.epornerSubscriptionsError ?? "No subscriptions found")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.textSecondary)
                        .padding(.horizontal, 2)
                } else {
                    ForEach(model.epornerSubscriptions) { subscription in
                        Button {
                            Task {
                                await model.navigateToEpornerUploader(url: subscription.url, name: subscription.name)
                            }
                        } label: {
                            Text(subscription.name)
                                .font(.caption.weight(.bold))
                                .foregroundStyle(Theme.textPrimary)
                                .lineLimit(1)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(Color.white.opacity(0.06), in: Capsule())
                                .overlay(Capsule().strokeBorder(accent.opacity(0.18), lineWidth: 0.5))
                        }
                        .buttonStyle(.plain)
                        .pressEffect(scale: 0.98)
                        .help(subscription.name)
                    }
                }
            }
            .padding(.horizontal, 2)
            .padding(.vertical, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task {
            await model.loadEpornerSubscriptionsIfNeeded()
        }
    }
}
