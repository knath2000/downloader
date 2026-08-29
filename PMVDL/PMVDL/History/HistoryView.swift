import AppKit
import SwiftUI

struct HistoryView: View {
    @StateObject private var history = HistoryManager.shared
    @State private var searchText = ""
    @State private var selectedProviderKey: String?
    @State private var streamFilter: HistoryStreamFilter = .all
    @State private var showingClearConfirmation = false
    @FocusState private var searchFocused: Bool

    private var totalCount: Int {
        history.items.count + history.completedUploads.count
    }

    private var providerFilters: [HistoryProviderFilter] {
        let providers = history.items.map(\.provider) + history.completedUploads.map(\.provider)
        let grouped = Dictionary(grouping: providers, by: ProviderTint.key(for:))
        return grouped.map { key, values in
            HistoryProviderFilter(
                key: key,
                name: ProviderTint.displayName(for: values.first ?? key),
                count: values.count
            )
        }
        .sorted {
            if $0.count == $1.count { return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            return $0.count > $1.count
        }
        .prefix(6)
        .map { $0 }
    }

    private var filteredEntries: [HistoryEntry] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let entries = history.items.map(HistoryEntry.link) + history.completedUploads.map(HistoryEntry.upload)
        return entries.filter { entry in
            let providerMatches = selectedProviderKey == nil || ProviderTint.key(for: entry.provider) == selectedProviderKey
            let streamMatches: Bool = {
                switch streamFilter {
                case .all: return true
                case .links: return entry.isLink
                case .uploads: return entry.isUpload
                }
            }()
            let queryMatches = query.isEmpty || entry.searchText.contains(query)
            return providerMatches && streamMatches && queryMatches
        }
        .sorted { $0.timestamp > $1.timestamp }
    }

    private var dayBuckets: [HistoryDayBucket] {
        Dictionary(grouping: filteredEntries) { entry in
            Calendar.current.startOfDay(for: entry.timestamp)
        }
        .map { date, entries in
            HistoryDayBucket(date: date, entries: entries.sorted { $0.timestamp > $1.timestamp })
        }
        .sorted { $0.date > $1.date }
    }

    var body: some View {
        VStack(spacing: 10) {
            HistoryToolbar(
                searchText: $searchText,
                selectedProviderKey: $selectedProviderKey,
                streamFilter: $streamFilter,
                providerFilters: providerFilters,
                visibleCount: filteredEntries.count,
                totalCount: totalCount,
                searchFocused: $searchFocused,
                clearAction: { showingClearConfirmation = true }
            )

            content
        }
        .confirmationDialog(
            "Clear all history?",
            isPresented: $showingClearConfirmation,
            titleVisibility: .visible
        ) {
            Button("Clear All", role: .destructive) {
                history.clear()
                clearFilters()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes \(history.items.count) recent links and \(history.completedUploads.count) completed uploads. This cannot be undone.")
        }
        .onExitCommand {
            guard searchFocused else { return }
            if searchText.isEmpty {
                searchFocused = false
            } else {
                searchText = ""
            }
        }
        .background(
            Button("") { searchFocused = true }
                .keyboardShortcut(ShortcutManager.shared.binding(for: .search),
                                  modifiers: ShortcutManager.shared.modifiers(for: .search))
                .opacity(0)
                .frame(width: 0, height: 0)
        )
    }

    @ViewBuilder
    private var content: some View {
        if totalCount == 0 {
            EmptyStateView.historyEmpty()
                .frame(maxWidth: CGFloat.infinity, maxHeight: CGFloat.infinity)
        } else if dayBuckets.isEmpty {
            let providerName = selectedProviderKey.flatMap { key in providerFilters.first { $0.key == key }?.name }
            EmptyStateView.historyNoResults(
                searchText: searchText,
                providerName: providerName,
                streamFilter: streamFilter,
                clearAction: clearFilters
            )
            .frame(maxWidth: CGFloat.infinity, maxHeight: CGFloat.infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 6, pinnedViews: [.sectionHeaders]) {
                    ForEach(dayBuckets) { bucket in
                        Section {
                            ForEach(bucket.entries) { entry in
                                HistoryEntryRow(
                                    entry: entry,
                                    extractAgain: { extractAgain($0) },
                                    removeLink: { history.remove($0) },
                                    removeUpload: { history.removeCompletedUpload($0) }
                                )
                            }
                        } header: {
                            HistoryDayHeader(date: bucket.date, count: bucket.entries.count)
                        }
                    }
                }
                .padding(.top, 2)
                .padding(.bottom, 18)
            }
        }
    }

    private func clearFilters() {
        searchText = ""
        selectedProviderKey = nil
        streamFilter = .all
    }

    private func extractAgain(_ item: HistoryItem) {
        AppStateManager.shared.pendingExtractTitles = [item.url: item.title]
        AppStateManager.shared.pendingExtractURL = item.url
        AppStateManager.shared.select(.home)
    }
}

private struct HistoryToolbar: View {
    @Binding var searchText: String
    @Binding var selectedProviderKey: String?
    @Binding var streamFilter: HistoryStreamFilter

    let providerFilters: [HistoryProviderFilter]
    let visibleCount: Int
    let totalCount: Int
    let searchFocused: FocusState<Bool>.Binding
    let clearAction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                searchField
                Spacer(minLength: 10)
                trailingControls
            }

            HStack(spacing: 10) {
                providerScroller
                streamPicker
                    .fixedSize()
            }
        }
        .padding(12)
        .glassCard(tint: Theme.gold.opacity(0.15), cornerRadius: 14)
        .shadow(color: .black.opacity(0.25), radius: 10, x: 0, y: 4)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
            TextField("Search title, provider, or URL", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused(searchFocused)
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Theme.textSecondary.opacity(0.8))
                }
                .buttonStyle(.plain)
                .help("Clear search")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Theme.accentDim.opacity(0.4), in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.gold.opacity(0.25), lineWidth: 0.5))
        .frame(maxWidth: 320)
    }

    private var providerScroller: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                HistoryFilterChip(
                    title: "All",
                    count: totalCount,
                    tint: Theme.gold,
                    isSelected: selectedProviderKey == nil
                ) {
                    selectedProviderKey = nil
                }

                ForEach(providerFilters) { provider in
                    HistoryFilterChip(
                        title: provider.name,
                        count: provider.count,
                        tint: ProviderTint.color(forKey: provider.key),
                        isSelected: selectedProviderKey == provider.key
                    ) {
                        selectedProviderKey = provider.key
                    }
                }
            }
            .padding(.vertical, 1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var streamPicker: some View {
        HistoryStreamFilterControl(selection: $streamFilter)
    }

    private var trailingControls: some View {
        HStack(spacing: 8) {
            Text(countText)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Theme.gold)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Theme.gold.opacity(0.12), in: Capsule())
                .overlay(Capsule().strokeBorder(Theme.gold.opacity(0.25), lineWidth: 0.5))

            Button(action: clearAction) {
                Label("Clear", systemImage: "trash")
                    .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(totalCount == 0 ? Theme.textSecondary.opacity(0.45) : Theme.textSecondary)
            .disabled(totalCount == 0)
            .help("Clear all history")
        }
    }

    private var countText: String {
        visibleCount == totalCount ? "\(totalCount)" : "\(visibleCount) / \(totalCount)"
    }
}

private struct HistoryFilterChip: View {
    let title: String
    let count: Int
    let tint: Color
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(title)
                Text("\(count)")
                    .font(.system(size: 9, weight: .black))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(.white.opacity(isSelected ? 0.24 : 0.12), in: Capsule())
            }
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background((isSelected ? tint : tint.opacity(0.45)), in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(isSelected ? 0.28 : 0.12), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
    }
}

private struct HistoryStreamFilterControl: View {
    @Binding var selection: HistoryStreamFilter

    var body: some View {
        HStack(spacing: 2) {
            ForEach(HistoryStreamFilter.allCases) { filter in
                Button {
                    selection = filter
                } label: {
                    Text(filter.title)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(selection == filter ? Theme.textPrimary : Theme.textSecondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(
                            Capsule()
                                .fill(selection == filter ? Theme.gold.opacity(0.22) : Color.clear)
                        )
                }
                .buttonStyle(.plain)
                .help("Show \(filter.title.lowercased())")
            }
        }
        .padding(3)
        .background(Theme.accentDim.opacity(0.36), in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.gold.opacity(0.22), lineWidth: 0.5))
    }
}

private struct HistoryDayHeader: View {
    let date: Date
    let count: Int

    var body: some View {
        HStack {
            HStack(spacing: 6) {
                Text(HistoryDateFormatter.dayLabel(for: date))
                    .font(.system(size: 11, weight: .bold))
                Text("\(count)")
                    .font(.system(size: 9, weight: .black))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Theme.gold.opacity(0.18), in: Capsule())
            }
            .foregroundStyle(Theme.gold)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Theme.surface0.opacity(0.86), in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.gold.opacity(0.25), lineWidth: 0.5))

            Spacer()
        }
        .padding(.vertical, 4)
        .background(
            LinearGradient(
                colors: [Theme.meshMidnight.opacity(0.9), Theme.meshMidnight.opacity(0.0)],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }
}

private struct HistoryEntryRow: View {
    let entry: HistoryEntry
    let extractAgain: (HistoryItem) -> Void
    let removeLink: (HistoryItem) -> Void
    let removeUpload: (CompletedUploadItem) -> Void

    @State private var isHovering = false

    private var providerColor: Color {
        ProviderTint.color(for: entry.provider)
    }

    var body: some View {
        HStack(spacing: 10) {
            iconTile

            VStack(alignment: .leading, spacing: 4) {
                titleLine
                detailLine
            }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)

            Text(HistoryDateFormatter.timeLabel(for: entry.timestamp))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)

            actions
                .opacity(isHovering ? 1 : 0)
                .allowsHitTesting(isHovering)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .glassCard(tint: providerColor.opacity(0.18), cornerRadius: 14)
        .contentShape(RoundedRectangle(cornerRadius: 14))
        .onHover { isHovering = $0 }
        .help(entry.url)
        .appContextMenu(title: historyMenuTitle, subtitle: historyMenuSubtitle, accent: providerColor, actions: contextActions)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(entry.accessibilityLabel))
    }

    private var iconTile: some View {
        let tileColor = entry.isUpload ? Theme.success : providerColor
        return RoundedRectangle(cornerRadius: 8)
            .fill(
                LinearGradient(
                    colors: [tileColor.opacity(0.95), tileColor.opacity(0.55)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .frame(width: 28, height: 28)
            .overlay(
                Image(systemName: entry.isUpload ? "checkmark.icloud.fill" : "play.rectangle.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
            )
            .shadow(color: tileColor.opacity(0.35), radius: 5, x: 0, y: 2)
    }

    private var titleLine: some View {
        HStack(spacing: 6) {
            Text(entry.title)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)

            HistoryProviderPill(provider: entry.provider)

            if case .upload(let item) = entry {
                HistoryDestinationChip(destination: item.destination)
            }
        }
    }

    @ViewBuilder
    private var detailLine: some View {
        switch entry {
        case .link(let item):
            Text(HistoryURLFormatter.prettyURL(item.url))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
        case .upload(let item):
            Text("up \(HistoryDestinationFormatter.displayName(for: item.destination)) · \(item.remotePath)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private var actions: some View {
        HStack(spacing: 4) {
            switch entry {
            case .link(let item):
                HistoryIconButton(systemName: "arrow.clockwise", help: "Extract again") {
                    extractAgain(item)
                }
                HistoryIconButton(systemName: "doc.on.doc", help: "Copy link") {
                    ClipboardManager.copy(item.url)
                }
            case .upload(let item):
                HistoryIconButton(systemName: "arrow.up.right.square", help: "Copy remote path") {
                    ClipboardManager.copy(item.remotePath)
                }
                HistoryIconButton(systemName: "doc.on.doc", help: "Copy source link") {
                    ClipboardManager.copy(item.url)
                }
            }
        }
    }

    private var historyMenuTitle: String {
        entry.title
    }

    private var historyMenuSubtitle: String {
        entry.url
    }

    private var contextActions: [AppContextMenuAction] {
        switch entry {
        case .link(let item):
            var actions = [
                AppContextMenuAction("Extract Again", systemImage: "arrow.clockwise", action: { extractAgain(item) }),
                AppContextMenuAction("Copy Link", systemImage: "doc.on.doc", action: { ClipboardManager.copy(item.url) })
            ]
            if let url = URL(string: item.url), url.scheme?.hasPrefix("http") == true {
                actions.append(AppContextMenuAction("Open Link", systemImage: "safari", action: { NSWorkspace.shared.open(url) }))
            }
            actions.append(AppContextMenuAction("Remove", systemImage: "trash", role: .destructive, action: { removeLink(item) }))
            return actions
        case .upload(let item):
            var actions = [
                AppContextMenuAction("Copy Remote Path", systemImage: "folder", action: { ClipboardManager.copy(item.remotePath) }),
                AppContextMenuAction("Copy Source Link", systemImage: "doc.on.doc", action: { ClipboardManager.copy(item.url) })
            ]
            if let url = URL(string: item.url), url.scheme?.hasPrefix("http") == true {
                actions.append(AppContextMenuAction("Open Source Link", systemImage: "safari", action: { NSWorkspace.shared.open(url) }))
            }
            actions.append(AppContextMenuAction("Remove", systemImage: "trash", role: .destructive, action: { removeUpload(item) }))
            return actions
        }
    }
}

private struct HistoryIconButton: View {
    let systemName: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

private struct HistoryProviderPill: View {
    let provider: String

    var body: some View {
        Text(ProviderTint.displayName(for: provider))
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.white)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(ProviderTint.color(for: provider).opacity(0.85), in: Capsule())
    }
}

private struct HistoryDestinationChip: View {
    let destination: String

    private var tint: Color {
        HistoryDestinationFormatter.color(for: destination)
    }

    var body: some View {
        Text(HistoryDestinationFormatter.shortName(for: destination))
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.white)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(tint.opacity(0.86), in: Capsule())
    }
}

private struct EmptyHistoryState: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "clock")
                .resizable()
                .scaledToFit()
                .frame(width: 40, height: 40)
                .foregroundStyle(Theme.gold.opacity(0.5))
                .padding()
            Text("No recent links yet")
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
            Text("Extract a video URL to add it here")
                .font(.caption2)
                .foregroundStyle(Theme.textSecondary.opacity(0.65))
        }
    }
}

private struct NoHistoryResultsState: View {
    let searchText: String
    let providerName: String?
    let streamFilter: HistoryStreamFilter
    let clearAction: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .resizable()
                .scaledToFit()
                .frame(width: 34, height: 34)
                .foregroundStyle(Theme.gold.opacity(0.5))
                .padding(.bottom, 2)

            Text(message)
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)

            Button(action: clearAction) {
                Label("Clear filters", systemImage: "xmark.circle")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [Theme.gold, Theme.coral],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Theme.accentDim, in: Capsule())
                    .overlay(Capsule().strokeBorder(Theme.gold.opacity(0.25), lineWidth: 0.5))
            }
            .buttonStyle(.plain)
        }
    }

    private var message: String {
        var parts: [String] = []
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
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
    }
}

enum HistoryStreamFilter: String, CaseIterable, Identifiable {
    case all
    case links
    case uploads

    var id: Self { self }

    var title: String {
        switch self {
        case .all: return "All"
        case .links: return "Links"
        case .uploads: return "Uploads"
        }
    }
}

private struct HistoryProviderFilter: Identifiable {
    let key: String
    let name: String
    let count: Int

    var id: String { key }
}

private struct HistoryDayBucket: Identifiable {
    let date: Date
    let entries: [HistoryEntry]

    var id: Date { date }
}

private enum HistoryEntry: Identifiable {
    case link(HistoryItem)
    case upload(CompletedUploadItem)

    var id: String {
        switch self {
        case .link(let item): return "link-\(item.id.uuidString)"
        case .upload(let item): return "upload-\(item.id.uuidString)"
        }
    }

    var title: String {
        switch self {
        case .link(let item): return item.title
        case .upload(let item): return item.title
        }
    }

    var provider: String {
        switch self {
        case .link(let item): return item.provider
        case .upload(let item): return item.provider
        }
    }

    var url: String {
        switch self {
        case .link(let item): return item.url
        case .upload(let item): return item.url
        }
    }

    var timestamp: Date {
        switch self {
        case .link(let item): return item.recordedAt
        case .upload(let item): return item.completedAt
        }
    }

    var isLink: Bool {
        if case .link = self { return true }
        return false
    }

    var isUpload: Bool {
        if case .upload = self { return true }
        return false
    }

    var searchText: String {
        switch self {
        case .link(let item):
            return "\(item.title) \(item.provider) \(item.url)".lowercased()
        case .upload(let item):
            return "\(item.title) \(item.provider) \(item.destination) \(item.remotePath) \(item.url)".lowercased()
        }
    }

    var accessibilityLabel: String {
        let date = timestamp.formatted(date: .abbreviated, time: .omitted)
        let time = HistoryDateFormatter.timeLabel(for: timestamp)
        switch self {
        case .link:
            return "\(ProviderTint.displayName(for: provider)) link, \(title), \(time), \(date)"
        case .upload(let item):
            return "\(HistoryDestinationFormatter.shortName(for: item.destination)) upload, \(title), \(time), \(date)"
        }
    }
}

private enum ProviderTint {
    static func key(for provider: String) -> String {
        provider.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    static func color(for provider: String) -> Color {
        color(forKey: key(for: provider))
    }

    static func color(forKey key: String) -> Color {
        switch key {
        case "pornhub":
            return Theme.coral
        case "streamtape":
            return Theme.skyBlue
        case "video site", "nativevideopage":
            return Theme.gold
        case "providerlink", "all porn stream":
            return Theme.lavender
        case "vidara":
            return Theme.electricLime
        case "lulustream", "lulu stream", "luluvid":
            return Theme.hotPink
        case "doodstream", "playmogo":
            return Theme.taoRed
        default:
            return Theme.textSecondary
        }
    }

    static func displayName(for provider: String) -> String {
        switch key(for: provider) {
        case "pornhub":
            return "PornHub"
        case "streamtape":
            return "StreamTape"
        case "video site", "nativevideopage":
            return "Video Site"
        case "providerlink":
            return "Provider Link"
        case "all porn stream":
            return "All Porn Stream"
        case "vidara":
            return "Vidara"
        case "lulustream", "lulu stream", "luluvid":
            return "LuluStream"
        case "doodstream":
            return "DoodStream"
        case "playmogo":
            return "Playmogo"
        case "generic":
            return "Generic"
        default:
            let trimmed = provider.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "Unknown" : trimmed
        }
    }
}

private enum HistoryURLFormatter {
    static func prettyURL(_ raw: String) -> String {
        guard let url = URL(string: raw), let host = url.host?.replacingOccurrences(of: "www.", with: "") else {
            return raw
        }
        guard let shortID = shortIdentifier(from: raw) else {
            return host
        }
        return "\(host) · \(shortID)"
    }

    private static func shortIdentifier(from raw: String) -> String? {
        guard let components = URLComponents(string: raw) else { return nil }
        let queryKeys = ["viewkey", "id", "v", "video", "file"]
        for key in queryKeys {
            if let value = components.queryItems?.first(where: { $0.name.lowercased() == key })?.value,
               !value.isEmpty {
                return value.count > 10 ? String(value.prefix(6)) : value
            }
        }

        if let path = components.path.split(separator: "/").last.map(String.init),
           !path.isEmpty {
            return path.count > 18 ? String(path.suffix(8)) : path
        }
        return nil
    }
}

private enum HistoryDateFormatter {
    static func dayLabel(for date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        return date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
    }

    static func timeLabel(for date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }
}

private enum HistoryDestinationFormatter {
    static func shortName(for destination: String) -> String {
        let lower = destination.lowercased()
        if lower.contains("mega") { return "MEGA" }
        if lower.contains("drive") || lower.contains("gdrive") { return "Drive" }
        if lower.contains("seedbox") { return "Seedbox" }
        let trimmed = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Remote" : trimmed
    }

    static func displayName(for destination: String) -> String {
        shortName(for: destination)
    }

    static func color(for destination: String) -> Color {
        let lower = destination.lowercased()
        if lower.contains("mega") { return Theme.success }
        if lower.contains("drive") || lower.contains("gdrive") { return Theme.skyBlue }
        if lower.contains("seedbox") { return Theme.lavender }
        return Theme.textSecondary
    }
}
