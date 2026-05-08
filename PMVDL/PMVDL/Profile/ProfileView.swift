import SwiftUI

struct ProfileView: View {
    @StateObject private var model = ProfileViewModel.shared
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
                    .font(.caption.weight(.semibold))
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

            LazyVGrid(columns: [
                GridItem(.flexible(), spacing: 12),
                GridItem(.flexible(), spacing: 12)
            ], spacing: 12) {
                rankingCard("Top Performers", icon: "person.2.fill", entries: result.stats.topPerformers)
                rankingCard("Top Categories", icon: "square.grid.2x2.fill", entries: result.stats.topCategories)
                rankingCard("Top Studios", icon: "building.2.fill", entries: result.stats.topStudios)
            }

            tagsCard(result.stats.topTags)
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

    private func rankingCard(_ title: String, icon: String, entries: [ProfileStats.RankedEntry]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            cardHeader(title, icon: icon)
            if entries.isEmpty {
                Text("No signal yet")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
            } else {
                VStack(spacing: 8) {
                    ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                        rankedRow(index: index, entry: entry)
                    }
                }
            }
        }
        .padding(14)
        .glassCard(tint: Theme.gold.opacity(0.08), cornerRadius: 14)
    }

    private func rankedRow(index: Int, entry: ProfileStats.RankedEntry) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Text("\(index + 1)")
                .font(.system(size: 11, weight: .black))
                .foregroundStyle(Theme.surface0)
                .frame(width: 22, height: 22)
                .background(Theme.gold, in: Circle())

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(entry.name)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text("×\(entry.count)")
                        .font(.caption.weight(.heavy))
                        .foregroundStyle(Theme.gold)
                }

                if !entry.sourceSummary.isEmpty {
                    Text("↳ \(entry.sourceSummary)")
                        .font(.caption2)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(2)
                }
            }
        }
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

            MarkdownText(result.narrative)
                .font(.system(size: 13))
                .foregroundStyle(Theme.textPrimary)
                .lineSpacing(4)
                .textSelection(.enabled)
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

private struct MarkdownText: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        if let attributed = try? AttributedString(markdown: text) {
            Text(attributed)
        } else {
            Text(text)
        }
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
