import SwiftUI

struct EmptyStateView: View {
    let icon: String
    let title: String
    let subtitle: String?
    let primaryAction: EmptyStateAction?
    let secondaryAction: EmptyStateAction?
    let tint: Color
    let isSearchEmpty: Bool
    let searchText: String?
    let clearSearchAction: (() -> Void)?

    init(
        icon: String,
        title: String,
        subtitle: String? = nil,
        primaryAction: EmptyStateAction? = nil,
        secondaryAction: EmptyStateAction? = nil,
        tint: Color = Theme.gold,
        isSearchEmpty: Bool = false,
        searchText: String? = nil,
        clearSearchAction: (() -> Void)? = nil
    ) {
        self.icon = icon
        self.title = title
        self.subtitle = subtitle
        self.primaryAction = primaryAction
        self.secondaryAction = secondaryAction
        self.tint = tint
        self.isSearchEmpty = isSearchEmpty
        self.searchText = searchText
        self.clearSearchAction = clearSearchAction
    }

    var body: some View {
        VStack(spacing: isSearchEmpty ? 10 : 12) {
            Image(systemName: icon)
                .font(.system(size: isSearchEmpty ? 34 : 42, weight: .bold))
                .foregroundStyle(tint)

            Text(title)
                .font(.system(.title3, design: .rounded).weight(.black))
                .foregroundStyle(Theme.textPrimary)
                .multilineTextAlignment(.center)

            if let subtitle {
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
            }

            if isSearchEmpty, let searchText, !searchText.isEmpty {
                Text("No matches for \"\(searchText)\"")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
            }

            if let primaryAction {
                Button(action: primaryAction.action) {
                    Label(primaryAction.label, systemImage: primaryAction.systemImage)
                }
                .buttonStyle(.borderedProminent)
                .tint(primaryAction.tint ?? tint)
            }

            if let secondaryAction {
                Button(action: secondaryAction.action) {
                    Label(secondaryAction.label, systemImage: secondaryAction.systemImage)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            if isSearchEmpty, let clearSearchAction {
                Button("Clear Search", action: clearSearchAction)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(isSearchEmpty ? 24 : 28)
        .glassCard(tint: tint.opacity(isSearchEmpty ? 0.12 : 0.16), cornerRadius: isSearchEmpty ? 16 : 18)
    }
}

struct EmptyStateAction {
    let label: String
    let systemImage: String
    let action: () -> Void
    let tint: Color?
    let isDestructive: Bool

    init(
        label: String,
        systemImage: String,
        tint: Color? = nil,
        isDestructive: Bool = false,
        action: @escaping () -> Void
    ) {
        self.label = label
        self.systemImage = systemImage
        self.action = action
        self.tint = tint
        self.isDestructive = isDestructive
    }
}

// Convenience initializers for common empty states
extension EmptyStateView {
    static func libraryEmpty(clearAction: @escaping () -> Void) -> EmptyStateView {
        EmptyStateView(
            icon: "books.vertical",
            title: "No library activity yet",
            subtitle: "Extract or download a video to add it here",
            tint: Theme.gold
        )
    }

    static func libraryNoResults(searchText: String, filter: LibraryTimelineFilter, clearAction: @escaping () -> Void) -> EmptyStateView {
        let message: String = {
            let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            if query.isEmpty, filter == .all {
                return "No matching library activity"
            }
            var parts: [String] = []
            if !query.isEmpty { parts.append("\"\(query)\"") }
            if filter != .all { parts.append("in \(filter.title)") }
            return "No matches for \(parts.joined(separator: " "))"
        }()

        return EmptyStateView(
            icon: "magnifyingglass",
            title: message,
            tint: Theme.gold,
            isSearchEmpty: true,
            searchText: searchText,
            clearSearchAction: clearAction
        )
    }

    static func favoritesEmpty() -> EmptyStateView {
        EmptyStateView(
            icon: "heart",
            title: "No Favorites Yet",
            subtitle: "Favorite videos from the Feed to save them here.",
            primaryAction: EmptyStateAction(
                label: "Browse Feed",
                systemImage: "antenna.radiowaves.left.and.right",
                tint: Theme.hotPink
            ) { AppStateManager.shared.select(.feed) },
            tint: Theme.hotPink
        )
    }

    static func favoritesNoResults(searchText: String, clearAction: @escaping () -> Void) -> EmptyStateView {
        EmptyStateView(
            icon: "magnifyingglass",
            title: "No matching favorites",
            subtitle: "No saved video matches \"\(searchText)\"",
            tint: Theme.hotPink,
            isSearchEmpty: true,
            searchText: searchText,
            clearSearchAction: clearAction
        )
    }

    static func downloadsEmpty() -> EmptyStateView {
        EmptyStateView(
            icon: "arrow.down.circle",
            title: "No Downloads Yet",
            subtitle: "Extract a video from the Home tab to start downloading.",
            primaryAction: EmptyStateAction(
                label: "Go to Home",
                systemImage: "house.fill",
                tint: Theme.skyBlue
            ) { AppStateManager.shared.select(.home) },
            tint: Theme.skyBlue
        )
    }

    static func downloadsNoResults(searchText: String, filter: DownloadStatusFilter, clearAction: @escaping () -> Void) -> EmptyStateView {
        let message: String = {
            let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            if query.isEmpty, filter == .all {
                return "No matching downloads"
            }
            var parts: [String] = []
            if !query.isEmpty { parts.append("\"\(query)\"") }
            if filter != .all { parts.append("in \(filter.title)") }
            return "No matches for \(parts.joined(separator: " "))"
        }()

        return EmptyStateView(
            icon: "magnifyingglass",
            title: message,
            tint: Theme.skyBlue,
            isSearchEmpty: true,
            searchText: searchText,
            clearSearchAction: clearAction
        )
    }

    static func downloadsNoResults(filter: DownloadStatusFilter, completedCount: Int, clearAction: @escaping () -> Void, showDone: @escaping () -> Void) -> EmptyStateView {
        let message: String = {
            if filter == .active {
                return "No active downloads. \(completedCount) completed today."
            }
            return "No downloads match the current filter."
        }()

        return EmptyStateView(
            icon: "magnifyingglass",
            title: message,
            subtitle: nil,
            primaryAction: nil,
            secondaryAction: EmptyStateAction(
                label: completedCount > 0 ? "Show Done" : "Clear filters",
                systemImage: completedCount > 0 ? "checkmark.circle" : "xmark.circle",
                tint: completedCount > 0 ? Theme.success : Theme.textSecondary,
                action: completedCount > 0 ? showDone : clearAction
            ),
            tint: Theme.skyBlue,
            isSearchEmpty: false
        )
    }

    static func historyEmpty() -> EmptyStateView {
        EmptyStateView(
            icon: "clock",
            title: "No recent links yet",
            subtitle: "Extract a video URL to add it here",
            tint: Theme.gold
        )
    }

    static func historyNoResults(searchText: String?, providerName: String?, streamFilter: HistoryStreamFilter, clearAction: @escaping () -> Void) -> EmptyStateView {
        let message: String = {
            var parts: [String] = []
            let query = (searchText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !query.isEmpty {
                parts.append("\"\(query)\"")
            }
            if let providerName {
                parts.append("in \(providerName)")
            }
            if streamFilter != .all {
                parts.append("for \(streamFilter.title.lowercased())")
            }
            return parts.isEmpty ? "No matching history" : "No matches for \(parts.joined(separator: " "))"
        }()

        return EmptyStateView(
            icon: "magnifyingglass",
            title: message,
            tint: Theme.gold,
            isSearchEmpty: true,
            searchText: searchText,
            clearSearchAction: clearAction
        )
    }

    static func watchlistEmpty() -> EmptyStateView {
        EmptyStateView(
            icon: "list.bullet.clipboard",
            title: "Watchlist is empty",
            subtitle: "Add videos from the Feed or Library to track them here.",
            primaryAction: EmptyStateAction(
                label: "Browse Feed",
                systemImage: "antenna.radiowaves.left.and.right",
                tint: Theme.hotPink
            ) { AppStateManager.shared.select(.feed) },
            tint: Theme.hotPink
        )
    }

    static func feedEmpty() -> EmptyStateView {
        EmptyStateView(
            icon: "antenna.radiowaves.left.and.right",
            title: "No feed items",
            subtitle: "Sign in to a provider to load videos.",
            primaryAction: EmptyStateAction(
                label: "Sign In",
                systemImage: "person.crop.circle.badge.plus",
                tint: Theme.skyBlue
            ) { AppStateManager.shared.select(.feed) },
            tint: Theme.skyBlue
        )
    }
}