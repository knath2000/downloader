import AppKit
import SwiftUI

@MainActor
enum LibraryFavoritesActions {
    static func extract(_ item: FeedFavoriteItem) {
        extract(item, appState: .shared)
    }

    static func extract(_ item: FeedFavoriteItem, appState: AppStateManager) {
        appState.pendingExtractTitles = [item.url: item.title]
        appState.pendingExtractURL = item.url
        appState.pendingExtractShouldStart = true
        appState.select(.home)
    }
}

@MainActor
struct FavoritesView: View {
    @StateObject private var favorites = FeedFavoritesStore.shared

    @State private var searchText = ""
    @State private var sortMode: FavoritesSortMode = .newestFavorited
    @State private var pendingDeleteItem: FeedFavoriteItem?
    @FocusState private var searchFocused: Bool

    private var filteredItems: [FeedFavoriteItem] {
        FavoritesDisplay.filteredAndSorted(
            items: favorites.items,
            query: searchText,
            sortMode: sortMode
        )
    }

    var body: some View {
        VStack(spacing: 12) {
            FavoritesToolbar(
                searchText: $searchText,
                sortMode: $sortMode,
                visibleCount: filteredItems.count,
                totalCount: favorites.items.count,
                searchFocused: $searchFocused,
                clearSearch: { searchText = "" }
            )

            content
        }
        .confirmationDialog(
            "Remove from Favorites?",
            isPresented: Binding(
                get: { pendingDeleteItem != nil },
                set: { if !$0 { pendingDeleteItem = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) {
                if let item = pendingDeleteItem {
                    withAnimation {
                        favorites.remove(id: item.id)
                    }
                }
                pendingDeleteItem = nil
            }

            Button("Cancel", role: .cancel) {
                pendingDeleteItem = nil
            }
        } message: {
            Text(pendingDeleteItem.map { "Remove \"\($0.title)\" from Favorites?" } ?? "")
        }
        .onExitCommand {
            if searchFocused {
                if searchText.isEmpty {
                    searchFocused = false
                } else {
                    searchText = ""
                }
            }
        }
        .background(
            Button("") { searchFocused = true }
                .keyboardShortcut("f", modifiers: .command)
                .opacity(0)
                .frame(width: 0, height: 0)
        )
    }

    @ViewBuilder
    private var content: some View {
        if favorites.items.isEmpty {
            FavoritesEmptyState()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if filteredItems.isEmpty {
            FavoritesNoResultsState(
                searchText: searchText,
                clearAction: { searchText = "" }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            GeometryReader { proxy in
                let minimum = proxy.size.width >= 1500 ? 300.0 : 260.0
                ScrollView {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: minimum), spacing: 14)],
                        alignment: .leading,
                        spacing: 14
                    ) {
                        ForEach(filteredItems) { item in
                            FavoriteCardView(
                                item: item,
                                extract: { extract(item) },
                                openSource: { openSource(item) },
                                copyLink: { ClipboardManager.copy(item.url) },
                                remove: { pendingDeleteItem = item }
                            )
                        }
                    }
                    .padding(.top, 2)
                    .padding(.bottom, 18)
                }
            }
        }
    }

    private func extract(_ item: FeedFavoriteItem) {
        LibraryFavoritesActions.extract(item)
    }

    private func openSource(_ item: FeedFavoriteItem) {
        guard let url = URL(string: item.url) else { return }
        NSWorkspace.shared.open(url)
    }
}

private struct FavoritesToolbar: View {
    @Binding var searchText: String
    @Binding var sortMode: FavoritesSortMode
    let visibleCount: Int
    let totalCount: Int
    var searchFocused: FocusState<Bool>.Binding
    let clearSearch: () -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            horizontal
            vertical
        }
        .padding(12)
        .glassCard(tint: Theme.hotPink.opacity(0.14), cornerRadius: 16)
    }

    private var horizontal: some View {
        HStack(spacing: 10) {
            title
            countBadge
            searchField
            sortPicker
            clearButton
        }
    }

    private var vertical: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                title
                countBadge
                sortPicker
            }
            HStack(spacing: 8) {
                searchField
                clearButton
            }
        }
    }

    private var title: some View {
        Label("Favorites", systemImage: "heart.fill")
            .font(.system(.title3, design: .rounded).weight(.black))
            .foregroundStyle(Theme.hotPink)
    }

    private var countBadge: some View {
        Text(totalCount == visibleCount ? "\(totalCount)" : "\(visibleCount) / \(totalCount)")
            .font(.caption.bold())
            .foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Theme.hotPink.opacity(0.16), in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.hotPink.opacity(0.22), lineWidth: 0.5))
            .accessibilityLabel(Text("\(visibleCount) visible out of \(totalCount) favorites"))
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Theme.textSecondary)
            TextField("Search favorites", text: $searchText)
                .textFieldStyle(.plain)
                .focused(searchFocused)
        }
        .font(.caption)
        .foregroundStyle(Theme.textPrimary)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Theme.surface2.opacity(0.65), in: Capsule())
        .frame(minWidth: 220, idealWidth: 300, maxWidth: 360)
    }

    private var sortPicker: some View {
        Picker("Sort", selection: $sortMode) {
            ForEach(FavoritesSortMode.allCases) { mode in
                Text(mode.title).tag(mode)
            }
        }
        .labelsHidden()
        .frame(width: 150)
    }

    @ViewBuilder
    private var clearButton: some View {
        if !searchText.isEmpty {
            Button("Clear", action: clearSearch)
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
    }
}

private struct FavoritesEmptyState: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "heart")
                .font(.system(size: 42, weight: .bold))
                .foregroundStyle(Theme.hotPink)

            Text("No Favorites Yet")
                .font(.system(.title3, design: .rounded).weight(.black))
                .foregroundStyle(Theme.textPrimary)

            Text("Favorite videos from the Feed to save them here.")
                .font(.callout)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)

            Button {
                AppStateManager.shared.select(.feed)
            } label: {
                Label("Browse Feed", systemImage: "antenna.radiowaves.left.and.right")
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.hotPink)
        }
        .padding(28)
        .glassCard(tint: Theme.hotPink.opacity(0.16), cornerRadius: 18)
    }
}

private struct FavoritesNoResultsState: View {
    let searchText: String
    let clearAction: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 34, weight: .bold))
                .foregroundStyle(Theme.textSecondary)

            Text("No matching favorites")
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)

            Text("No saved video matches \"\(searchText)\"")
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)

            Button("Clear Search", action: clearAction)
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .padding(24)
        .glassCard(tint: Theme.hotPink.opacity(0.12), cornerRadius: 16)
    }
}
