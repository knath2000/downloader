import Foundation
import SwiftUI

struct ProfileView: View {
    @StateObject private var model = ProfileViewModel.shared
    @State private var showAllPerformers = false
    @AppStorage("xaiAPIKey") private var xaiAPIKey = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                content
            }
            .frame(maxWidth: 1040, alignment: .top)
            .frame(maxWidth: .infinity, alignment: .top)
            .padding(20)
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Theme.gold.opacity(0.18))
                    .frame(width: 42, height: 42)
                Image(systemName: "person.crop.circle.fill")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(Theme.gold)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text("Your Taste Profile")
                        .font(.system(size: 24, weight: .black))
                        .foregroundStyle(Theme.textPrimary)
                    if currentResult?.isStale == true {
                        Text("STALE")
                            .font(.system(size: 9, weight: .black))
                            .foregroundStyle(Theme.warning)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Theme.warning.opacity(0.16), in: Capsule())
                    }
                }

                Text(headerSummary)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.textSecondary)
            }

            Spacer()

            Button {
                Task { await model.generate() }
            } label: {
                Label(currentResult == nil ? "Generate" : "Regenerate", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.gold)
            .disabled(isLoading)
        }
        .padding(16)
        .glassCard(tint: Theme.gold.opacity(0.12), cornerRadius: 16)
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .idle:
            if xaiAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                emptyState(
                    icon: "key.fill",
                    title: "Add your xAI API key in Settings to generate your profile.",
                    tint: Theme.gold
                )
            } else {
                emptyState(
                    icon: "sparkles",
                    title: "Generate your profile from favorites, PornHub sections, and download history.",
                    tint: Theme.gold
                )
            }
        case .loading:
            loadingState
        case .loaded(let result):
            loadedView(result)
        case .failed(let message):
            if xaiAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                emptyState(icon: "key.fill", title: message, tint: Theme.gold)
            } else {
                errorState(message)
            }
        }
    }

    private func loadedView(_ result: ProfileResult) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            sourceBadges(stats: result.stats)

            if !result.stats.topPerformers.isEmpty {
                rankingCard(
                    "Top Performers",
                    icon: "person.2.fill",
                    entries: result.stats.topPerformers,
                    showsAvatar: true,
                    maxVisible: 5,
                    showAll: $showAllPerformers
                )
            }

            if result.stats.topCategories.isEmpty,
               result.stats.topStudios.isEmpty,
               result.stats.topTags.isEmpty {
                metadataUnavailableCallout
            } else {
                metadataRankingSection(stats: result.stats)

                if !result.stats.topTags.isEmpty {
                    tagsCard(result.stats.topTags)
                }
            }

            viewingPatternsCard(result.stats)
            narrativeCard(result)
        }
    }

    private func sourceBadges(stats: ProfileStats) -> some View {
        HStack(spacing: 8) {
            sourceBadge(icon: "heart.fill", title: "Saved Favorites", count: stats.favoritesCount, tint: Theme.hotPink)
            sourceBadge(icon: "hand.thumbsup.fill", title: "PH Liked", count: stats.pornhubLikedCount, tint: Color(hex: "#FF9000"))
            sourceBadge(icon: "star.fill", title: "PH Favorites", count: stats.pornhubFavoritesCount, tint: Color(hex: "#FF9000"))
            sourceBadge(icon: "books.vertical.fill", title: "Downloads", count: stats.libraryCount, tint: Theme.skyBlue)
        }
    }

    private func sourceBadge(icon: String, title: String, count: Int, tint: Color) -> some View {
        HStack(spacing: 7) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .bold))
            Text("\(count)")
                .font(.caption.weight(.black))
                .contentTransition(.numericText())
            Text(title)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(tint.opacity(0.14), in: Capsule())
        .overlay(Capsule().strokeBorder(tint.opacity(0.18), lineWidth: 0.5))
    }

    @ViewBuilder
    private func metadataRankingSection(stats: ProfileStats) -> some View {
        if !stats.topCategories.isEmpty && !stats.topStudios.isEmpty {
            LazyVGrid(columns: [
                GridItem(.flexible(), spacing: 12),
                GridItem(.flexible(), spacing: 12)
            ], spacing: 12) {
                rankingCard("Top Categories", icon: "square.grid.2x2.fill", entries: stats.topCategories)
                rankingCard("Top Studios", icon: "building.2.fill", entries: stats.topStudios)
            }
        } else {
            if !stats.topCategories.isEmpty {
                rankingCard("Top Categories", icon: "square.grid.2x2.fill", entries: stats.topCategories)
            }
            if !stats.topStudios.isEmpty {
                rankingCard("Top Studios", icon: "building.2.fill", entries: stats.topStudios)
            }
        }
    }

    private var metadataUnavailableCallout: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "info.circle.fill")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Theme.gold)
            Text("No category, tag, or studio metadata available - this improves after PornHub scraper data is fetched.")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .glassCard(tint: Theme.gold.opacity(0.08), cornerRadius: 14)
    }

    private func rankingCard(
        _ title: String,
        icon: String,
        entries: [ProfileStats.RankedEntry],
        showsAvatar: Bool = false,
        maxVisible: Int? = nil,
        showAll: Binding<Bool>? = nil
    ) -> some View {
        let visibleEntries: [ProfileStats.RankedEntry]
        if let maxVisible = maxVisible, showAll?.wrappedValue == false {
            visibleEntries = Array(entries.prefix(maxVisible))
        } else {
            visibleEntries = entries
        }

        return VStack(alignment: .leading, spacing: 10) {
            cardHeader(title, icon: icon)

            VStack(spacing: 8) {
                ForEach(Array(visibleEntries.enumerated()), id: \.element.id) { index, entry in
                    rankedRow(index: index, entry: entry, showsAvatar: showsAvatar)
                }
            }

            if let maxVisible = maxVisible,
               let showAll = showAll,
               entries.count > maxVisible {
                Button {
                    showAll.wrappedValue.toggle()
                } label: {
                    Text(showAll.wrappedValue ? "Show fewer" : "Show all \(entries.count)")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Theme.gold)
                }
                .buttonStyle(.plain)
                .padding(.top, 2)
            }
        }
        .padding(14)
        .glassCard(tint: Theme.gold.opacity(0.08), cornerRadius: 14)
    }

    private func rankedRow(index: Int, entry: ProfileStats.RankedEntry, showsAvatar: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Text("\(index + 1)")
                .font(.system(size: 11, weight: .black))
                .foregroundStyle(Theme.gold)
                .frame(width: 22, height: 22)
                .overlay(Circle().strokeBorder(Theme.gold.opacity(0.72), lineWidth: 1))

            if let profileURL = showsAvatar ? validPornHubProfileURL(for: entry) : nil {
                Button {
                    Task {
                        await FeedViewModel.shared.openPornHubUploaderFromProfile(url: profileURL, name: entry.name)
                        AppStateManager.shared.select(.feed)
                    }
                } label: {
                    rankedRowContent(entry: entry, showsAvatar: showsAvatar, isClickable: true)
                }
                .buttonStyle(.plain)
                .help(entry.name)
            } else {
                rankedRowContent(entry: entry, showsAvatar: showsAvatar, isClickable: false)
            }
        }
    }

    private func rankedRowContent(entry: ProfileStats.RankedEntry, showsAvatar: Bool, isClickable: Bool) -> some View {
        HStack(alignment: .top, spacing: 9) {
            if showsAvatar {
                ProfilePerformerAvatar(entry: entry)
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(entry.name)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(isClickable ? Theme.gold : Theme.textPrimary)
                        .lineLimit(1)
                    if isClickable {
                        Image(systemName: "arrow.up.right.circle.fill")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Theme.gold.opacity(0.82))
                    }
                    Spacer(minLength: 4)
                    Text("×\(entry.count)")
                        .font(.caption.weight(.heavy))
                        .foregroundStyle(Theme.gold)
                }

                if !entry.sourceSummary.isEmpty {
                    HStack(alignment: .top, spacing: 6) {
                        RoundedRectangle(cornerRadius: 1)
                            .fill(Theme.gold.opacity(0.24))
                            .frame(width: 2, height: 18)
                            .padding(.top, 1)
                        Text(entry.sourceSummary)
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(2)
                    }
                    .padding(.leading, 1)
                }
            }
        }
    }

    private func validPornHubProfileURL(for entry: ProfileStats.RankedEntry) -> String? {
        guard let profileURL = entry.profileURL else { return nil }
        return PornHubFeedScraper.normalizedUploaderURL(profileURL)
    }

    private func tagsCard(_ entries: [ProfileStats.RankedEntry]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            cardHeader("Top Tags", icon: "tag.fill")
            if entries.isEmpty {
                Text("No tag signal yet")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
            } else {
                FlowLayout(spacing: 8, rowSpacing: 8) {
                    ForEach(entries) { entry in
                        Text("\(entry.name) ×\(entry.count)")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(Theme.gold)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Theme.gold.opacity(0.13), in: Capsule())
                            .overlay(Capsule().strokeBorder(Theme.gold.opacity(0.16), lineWidth: 0.5))
                            .help(entry.sourceSummary)
                    }
                }
            }
        }
        .padding(14)
        .glassCard(tint: Theme.gold.opacity(0.08), cornerRadius: 14)
    }

    private func viewingPatternsCard(_ stats: ProfileStats) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            cardHeader("Viewing Patterns", icon: "chart.bar.fill")

            HStack(spacing: 10) {
                patternMetric(
                    title: "Avg Duration",
                    value: stats.avgDurationMinutes.map { String(format: "%.1f min", $0) } ?? "No data",
                    detail: stats.durationSources.map(\.displayText).joined(separator: ", ")
                )
                patternMetric(
                    title: "Quality",
                    value: stats.preferredQuality.first?.name ?? "No data",
                    detail: stats.preferredQuality.first?.sourceSummary ?? ""
                )
                patternMetric(
                    title: "Total Signals",
                    value: "\(stats.totalItemCount)",
                    detail: "Favorites, PornHub, and downloads"
                )
            }
        }
        .padding(14)
        .glassCard(tint: Theme.gold.opacity(0.08), cornerRadius: 14)
    }

    private func patternMetric(title: String, value: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(.system(size: 9, weight: .black))
                .foregroundStyle(Theme.textSecondary)
            Text(value)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
            Rectangle()
                .fill(Theme.gold.opacity(0.72))
                .frame(width: 24, height: 1)
            if !detail.isEmpty {
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Theme.surface2.opacity(0.14), in: RoundedRectangle(cornerRadius: 10))
    }

    private func narrativeCard(_ result: ProfileResult) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                cardHeader("AI Analysis", icon: "brain.head.profile")
                Spacer()
                Text("Generated \(result.generatedAt.formatted(.dateTime.month(.abbreviated).day().hour().minute()))")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(result.isStale ? Theme.warning : Theme.textSecondary)
            }

            VStack(alignment: .leading, spacing: 14) {
                ForEach(ProfileNarrativeFormatter.sections(from: result.narrative)) { section in
                    ProfileNarrativeSectionView(section: section)
                }
            }
            .padding(.top, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .glassCard(tint: Theme.gold.opacity(0.08), cornerRadius: 14)
    }

    private var loadingState: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                Text("Analysing your taste…")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
            }

            ForEach(0..<4, id: \.self) { _ in
                RoundedRectangle(cornerRadius: 8)
                    .fill(Theme.surface2.opacity(0.30))
                    .frame(height: 38)
                    .redacted(reason: .placeholder)
            }
        }
        .padding(16)
        .glassCard(tint: Theme.gold.opacity(0.10), cornerRadius: 14)
    }

    private func emptyState(icon: String, title: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(tint)
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .glassCard(tint: tint.opacity(0.10), cornerRadius: 14)
    }

    private func errorState(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Theme.error)
                Text(message)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button {
                Task { await model.generate() }
            } label: {
                Label("Retry", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .glassCard(tint: Theme.error.opacity(0.10), cornerRadius: 14)
    }

    private func cardHeader(_ title: String, icon: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Theme.gold)
            Text(title)
                .font(.caption.weight(.black))
                .foregroundStyle(Theme.textPrimary)
        }
    }

    private var currentResult: ProfileResult? {
        if case .loaded(let result) = model.state {
            return result
        }
        return nil
    }

    private var isLoading: Bool {
        if case .loading = model.state {
            return true
        }
        return false
    }

    private var headerSummary: String {
        guard let result = currentResult else {
            return "Favorites · PornHub sections · Download history"
        }
        let stats = result.stats
        return "\(stats.favoritesCount) Favorites · \(stats.pornhubLikedCount) PH Liked · \(stats.pornhubFavoritesCount) PH Favorites · \(stats.libraryCount) Downloads"
    }

}

struct ProfileNarrativeSection: Hashable, Identifiable {
    let title: String
    let body: String

    var id: String {
        title.isEmpty ? body : title
    }
}

enum ProfileNarrativeFormatter {
    private struct HeadingVariant {
        let title: String
        let variant: String
        let order: Int
    }

    private struct HeadingMatch {
        let title: String
        let range: Range<String.Index>
        let location: Int
        let length: Int
        let order: Int
    }

    private static let headings: [(title: String, variants: [String])] = [
        (
            "What I Learned About Your Habits",
            ["What I Learned About Your Habits"]
        ),
        (
            "Top Performers (with source citations)",
            ["Top Performers (with source citations)", "Top Performers"]
        ),
        (
            "Preferred Categories & Themes (with source citations)",
            [
                "Preferred Categories & Themes (with source citations)",
                "Preferred Categories & Themes",
                "Preferred Categories (with source citations)",
                "Preferred Categories"
            ]
        ),
        (
            "Studio Preferences (with source citations)",
            ["Studio Preferences (with source citations)", "Studio Preferences"]
        ),
        (
            "Viewing Patterns (duration, quality, frequency)",
            ["Viewing Patterns (duration, quality, frequency)", "Viewing Patterns"]
        ),
        (
            "How This Profile Was Built (data sources used, counts, gaps/limitations)",
            [
                "How This Profile Was Built (data sources used, counts, gaps/limitations)",
                "How This Profile Was Built"
            ]
        )
    ]

    static func sections(from text: String) -> [ProfileNarrativeSection] {
        let normalized = normalizedText(text)
        guard !normalized.isEmpty else { return [] }

        let matches = headingMatches(in: normalized)
        guard !matches.isEmpty else {
            return fallbackSections(from: normalized)
        }

        let sections = matches.enumerated().compactMap { offset, match -> ProfileNarrativeSection? in
            let bodyStart = match.range.upperBound
            let bodyEnd = offset + 1 < matches.count ? matches[offset + 1].range.lowerBound : normalized.endIndex
            let body = cleanedBody(String(normalized[bodyStart..<bodyEnd]))
            guard !body.isEmpty else { return nil }
            return ProfileNarrativeSection(title: match.title, body: body)
        }

        return sections.isEmpty ? fallbackSections(from: normalized) : sections
    }

    private static func normalizedText(_ text: String) -> String {
        var output = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        if output.contains("\\n") {
            output = output.replacingOccurrences(of: "\\n", with: "\n")
        }

        output = output.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func fallbackSections(from text: String) -> [ProfileNarrativeSection] {
        let body = cleanedBody(text)
        return body.isEmpty ? [] : [ProfileNarrativeSection(title: "", body: body)]
    }

    private static func headingMatches(in text: String) -> [HeadingMatch] {
        var found: [HeadingMatch] = []
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)

        for variant in headingVariants {
            let escaped = NSRegularExpression.escapedPattern(for: variant.variant)
            let pattern = #"(?im)(?:^\s*|(?<=\n)\s*|(?<=[.!?])\s*)(?:#{1,6}\s*)?"# + escaped
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            for match in regex.matches(in: text, range: nsRange) {
                guard let range = Range(match.range, in: text) else { continue }
                found.append(HeadingMatch(
                    title: variant.title,
                    range: range,
                    location: match.range.location,
                    length: match.range.length,
                    order: variant.order
                ))
            }
        }

        return acceptedMatches(from: found)
    }

    private static var headingVariants: [HeadingVariant] {
        headings.enumerated().flatMap { order, heading in
            heading.variants.map { HeadingVariant(title: heading.title, variant: $0, order: order) }
        }
    }

    private static func acceptedMatches(from matches: [HeadingMatch]) -> [HeadingMatch] {
        let sorted = matches.sorted {
            if $0.location == $1.location {
                if $0.length == $1.length {
                    return $0.order < $1.order
                }
                return $0.length > $1.length
            }
            return $0.location < $1.location
        }

        var output: [HeadingMatch] = []
        var lastOrder = -1
        for match in sorted {
            guard !output.contains(where: { overlaps($0, match) }),
                  match.order > lastOrder else { continue }
            output.append(match)
            lastOrder = match.order
        }
        return output.sorted { $0.location < $1.location }
    }

    private static func overlaps(_ lhs: HeadingMatch, _ rhs: HeadingMatch) -> Bool {
        lhs.range.overlaps(rhs.range)
    }

    private static func cleanedBody(_ text: String) -> String {
        text
            .replacingOccurrences(of: #"^\s*[:\-–—]\s*"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private struct ProfileNarrativeSectionView: View {
    let section: ProfileNarrativeSection

    var body: some View {
        VStack(alignment: .leading, spacing: section.title.isEmpty ? 0 : 6) {
            if !section.title.isEmpty {
                Text(section.title)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(Theme.gold)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text(section.body)
                .font(.system(size: 13))
                .foregroundStyle(Theme.textPrimary)
                .lineSpacing(5)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ProfilePerformerAvatar: View {
    let entry: ProfileStats.RankedEntry

    private var imageURL: URL? {
        guard let value = entry.imageURL?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return URL(string: value)
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(Theme.surface1.opacity(0.86))

            if let imageURL {
                RefererAwareAsyncImage(url: imageURL, referer: entry.imageReferer) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFill()
                    case .empty:
                        ProgressView()
                            .controlSize(.small)
                            .scaleEffect(0.55)
                    case .failure:
                        placeholder
                    @unknown default:
                        placeholder
                    }
                }
            } else {
                placeholder
            }
        }
        .frame(width: 38, height: 38)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(Theme.gold.opacity(0.70), lineWidth: 1))
        .help(entry.imageSource == "profile" ? "Profile image" : "Evidence thumbnail")
    }

    private var placeholder: some View {
        Image(systemName: "person.fill")
            .font(.system(size: 15, weight: .bold))
            .foregroundStyle(Theme.gold)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct FlowLayout: Layout {
    var spacing: CGFloat
    var rowSpacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 0
        let rows = rows(in: width, subviews: subviews)
        return CGSize(
            width: width,
            height: rows.reduce(0) { $0 + $1.height } + max(0, CGFloat(rows.count - 1)) * rowSpacing
        )
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var origin = bounds.origin
        for row in rows(in: bounds.width, subviews: subviews) {
            origin.x = bounds.minX
            for item in row.items {
                item.subview.place(
                    at: origin,
                    proposal: ProposedViewSize(width: item.size.width, height: item.size.height)
                )
                origin.x += item.size.width + spacing
            }
            origin.y += row.height + rowSpacing
        }
    }

    private func rows(in width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        var remaining = width

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if !current.items.isEmpty && size.width > remaining {
                rows.append(current)
                current = Row()
                remaining = width
            }
            current.items.append(RowItem(subview: subview, size: size))
            current.height = max(current.height, size.height)
            remaining -= size.width + spacing
        }

        if !current.items.isEmpty {
            rows.append(current)
        }
        return rows
    }

    private struct Row {
        var items: [RowItem] = []
        var height: CGFloat = 0
    }

    private struct RowItem {
        let subview: LayoutSubview
        let size: CGSize
    }
}
