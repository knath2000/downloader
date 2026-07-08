import SwiftUI

struct ExtractionModalView: View {
    @ObservedObject private var appState = AppStateManager.shared
    @Binding var addURLText: String
    @Binding var batchTarget: CloudTarget
    let isLoading: Bool
    let loadProgress: String
    let extractionSlots: [ExtractionSlot]
    let results: [ExtractResult]
    let retryingResultIndices: Set<Int>
    let batchQueuedCount: Int
    let isBatchSubmitting: Bool
    let batchProgressText: String
    let canRetryFailed: Bool
    let canRetryWithVPN: Bool
    let isYtDlpReady: Bool
    let localState: (String) -> UploadState?
    let megaState: (String) -> UploadState?
    let gdriveState: (String) -> UploadState?
    let seedboxState: (String) -> UploadState?
    let onAddURL: () -> Void
    let onRetryFailed: () -> Void
    let onRetry: (Int) -> Void
    let onVPNRetry: (Int) -> Void
    let onLocal: (String) -> Void
    let onMega: (String) -> Void
    let onGDrive: (String) -> Void
    let onSeedbox: (String) -> Void
    let onBatchDownload: () -> Void
    let onClose: () -> Void

    @FocusState private var isAddURLFocused: Bool

    private var addModel: HomeURLInputModel {
        HomeURLInputModel(rawText: addURLText)
    }

    private var canAddURL: Bool {
        addModel.readyCount == 1 && addModel.invalidLines.isEmpty && !isLoading
    }

    private var subtitle: String {
        if extractionSlots.isEmpty {
            if isLoading {
                return loadProgress.isEmpty ? "Extracting sources..." : loadProgress
            }
            return "Add a URL to extract downloadable sources."
        }
        let countText = "\(results.count) extracted URL\(results.count == 1 ? "" : "s") ready"
        guard isLoading else { return countText }
        let progressText = loadProgress.isEmpty ? "Extracting another URL..." : loadProgress
        return "\(countText) • \(progressText)"
    }

    private var displayRows: [ExtractionDisplayRow] {
        var completedIndex = 0
        return extractionSlots.map { slot in
            if let result = slot.result {
                let row = ExtractionDisplayRow(
                    id: slot.id,
                    url: slot.url,
                    resultIndex: completedIndex,
                    result: result
                )
                completedIndex += 1
                return row
            }
            return ExtractionDisplayRow(id: slot.id, url: slot.url, resultIndex: nil, result: nil)
        }
    }

    private var usesLightweightResultRows: Bool {
        !isLoading && results.count >= 8
    }

    var body: some View {
        VStack(spacing: 14) {
            addURLBar
            contentRows
            footer
        }
        .padding(24)
        .frame(
            width: AppShellSurfaceMetrics.appModalSurfaceWidth(for: appState.windowSize),
            height: AppShellSurfaceMetrics.appModalSurfaceHeight(
                for: appState.windowSize,
                reservedTopInset: AppShellSurfaceMetrics.appModalTitlebarClearance
            )
        )
        .background(
            LinearGradient(
                colors: [
                    Theme.surfaceGlass.opacity(0.88),
                    Theme.surface0.opacity(0.96)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
    }

    private var addURLBar: some View {
        HStack(spacing: 12) {
            Text("Add URL")
                .font(.title3.weight(.semibold))
                .foregroundStyle(Theme.textPrimary)
                .frame(width: 112, alignment: .leading)

            TextField("https://...", text: $addURLText)
                .textFieldStyle(.plain)
                .font(.system(size: 15, weight: .medium, design: .monospaced))
                .foregroundStyle(Theme.textPrimary)
                .focused($isAddURLFocused)
                .onSubmit(addURLIfPossible)
                .padding(.horizontal, 14)
                .frame(height: 38)
                .background(Theme.surface0.opacity(0.48), in: RoundedRectangle(cornerRadius: 10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(isAddURLFocused ? Theme.skyBlue.opacity(0.72) : Theme.borderSubtle, lineWidth: 1)
                )

            Button("Add", action: addURLIfPossible)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(Theme.surfaceGlass)
                .disabled(!canAddURL)
        }
        .padding(12)
        .background(Theme.surfaceGlass.opacity(0.46), in: RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Theme.borderSubtle, lineWidth: 1)
        )
    }

    private var contentRows: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                if extractionSlots.isEmpty {
                    emptyState
                } else {
                    ForEach(Array(displayRows.enumerated()), id: \.element.id) { rowIndex, row in
                        ExtractionRevealRow(
                            id: row.id,
                            rowIndex: rowIndex,
                            isResolved: row.result != nil,
                            tint: row.result?.error == nil ? Theme.skyBlue : Theme.error
                        ) {
                            if let result = row.result, let resultIndex = row.resultIndex {
                                ExtractionResultRow(
                                    row: ExtractionResultRowModel(id: row.id, index: resultIndex, result: result),
                                    isRetrying: retryingResultIndices.contains(resultIndex),
                                    usesLightweightThumbnail: usesLightweightResultRows,
                                    localState: localState,
                                    megaState: megaState,
                                    gdriveState: gdriveState,
                                    seedboxState: seedboxState,
                                    onRetry: { onRetry(resultIndex) },
                                    canRetryWithVPN: canRetryWithVPN,
                                    onVPNRetry: { onVPNRetry(resultIndex) },
                                    onLocal: onLocal,
                                    onMega: onMega,
                                    onGDrive: onGDrive,
                                    onSeedbox: onSeedbox
                                )
                            } else {
                                ExtractionLoadingRow(subtitle: loadingSubtitle(for: row.url))
                            }
                        }
                    }
                }
            }
            .padding(.vertical, 2)
        }
        .frame(maxHeight: .infinity)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            statusPill

            Text(subtitle)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)

            Spacer(minLength: 8)

            if !isLoading, canRetryFailed {
                Button {
                    onRetryFailed()
                } label: {
                    Label("Retry Failed", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            if batchQueuedCount > 0 {
                Picker("Batch target", selection: $batchTarget) {
                    ForEach(CloudTarget.allCases, id: \.self) { target in
                        Label(target.homeDisplayName, systemImage: target.icon).tag(target)
                    }
                }
                .labelsHidden()
                .frame(width: 128)

                Button {
                    onBatchDownload()
                } label: {
                    if isBatchSubmitting {
                        ProgressView()
                            .controlSize(.small)
                            .scaleEffect(0.7)
                        Text("Adding")
                    } else {
                        Label("Download All", systemImage: batchTarget.icon)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .tint(Theme.skyBlue)
                .disabled(isBatchSubmitting)
                .help(isBatchSubmitting ? batchProgressText : batchTarget.homeBatchButtonTitle)
            }

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .frame(width: 28, height: 28)
                    .background(Theme.surface2.opacity(0.72), in: Circle())
            }
            .buttonStyle(.plain)
            .help("Close")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Theme.surface0.opacity(0.48), in: RoundedRectangle(cornerRadius: 13))
        .overlay(
            RoundedRectangle(cornerRadius: 13)
                .stroke(Theme.borderSubtle, lineWidth: 1)
        )
    }

    private var statusPill: some View {
        HStack(spacing: 5) {
            Text("yt-dlp")
                .font(.caption.weight(.semibold))
            Text(isYtDlpReady ? "OK" : "Missing")
                .font(.caption.weight(.bold))
                .foregroundStyle(isYtDlpReady ? Theme.success : Theme.warning)
        }
        .foregroundStyle(Theme.textPrimary)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "rectangle.stack.badge.play")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(Theme.skyBlue)
            Text("No extracted results yet")
                .font(.headline.weight(.semibold))
                .foregroundStyle(Theme.textPrimary)
            Text("Add a URL above or extract from Home to review downloadable sources here.")
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity, minHeight: 260)
        .background(Theme.surface0.opacity(0.28), in: RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Theme.borderSubtle, lineWidth: 1)
        )
    }

    private func addURLIfPossible() {
        guard canAddURL else { return }
        onAddURL()
    }

    private func loadingSubtitle(for url: String) -> String {
        let text = loadProgress.isEmpty ? "Extracting sources..." : loadProgress
        guard let host = URL(string: url)?.host else { return text }
        return "\(text) • \(host)"
    }
}

private struct ExtractionDisplayRow: Identifiable, Equatable {
    let id: UUID
    let url: String
    let resultIndex: Int?
    let result: ExtractResult?
}

enum ExtractionRevealAnimationSupport {
    static let maxDelay: Double = 0.22
    static let rowDelayStep: Double = 0.045

    static func delay(forRowIndex index: Int, reduceMotion: Bool) -> Double {
        guard !reduceMotion else { return 0 }
        return min(maxDelay, Double(max(index, 0)) * rowDelayStep)
    }
}

private struct ExtractionRevealRow<Content: View>: View {
    let id: UUID
    let rowIndex: Int
    let isResolved: Bool
    let tint: Color
    @ViewBuilder let content: () -> Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.performanceProfile) private var performanceProfile
    @State private var isVisible = false
    @State private var glow = false

    private var revealDelay: Double {
        ExtractionRevealAnimationSupport.delay(forRowIndex: rowIndex, reduceMotion: reduceMotion)
    }

    private var allowsMotion: Bool {
        !reduceMotion
    }

    private var allowsGlow: Bool {
        allowsMotion && performanceProfile.allowsExpensiveEffects
    }

    private var contentAnimation: Animation? {
        guard allowsMotion else { return .easeOut(duration: 0.14).delay(revealDelay) }
        return .spring(response: 0.34, dampingFraction: 0.82).delay(revealDelay)
    }

    var body: some View {
        content()
            .id("\(id.uuidString)-\(isResolved ? "result" : "loading")")
            .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .bottom)).combined(with: .scale(scale: 0.985)))
            .opacity(isVisible ? 1 : (allowsMotion ? 0.76 : 1))
            .offset(y: isVisible || !allowsMotion ? 0 : 7)
            .scaleEffect(isVisible || !allowsMotion ? 1 : 0.99)
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(tint.opacity(glow ? 0.5 : 0), lineWidth: 1.2)
                    .shadow(color: tint.opacity(glow ? 0.28 : 0), radius: glow ? 9 : 0)
            )
            .animation(contentAnimation, value: isResolved)
            .animation(contentAnimation, value: isVisible)
            .animation(allowsGlow ? .easeOut(duration: 0.2).delay(revealDelay) : nil, value: glow)
            .onAppear {
                reveal()
                if isResolved {
                    pulseGlow()
                }
            }
            .onChange(of: isResolved) { _, newValue in
                guard newValue else { return }
                reveal()
                pulseGlow()
            }
    }

    private func reveal() {
        guard !isVisible else { return }
        if allowsMotion {
            withAnimation(contentAnimation) {
                isVisible = true
            }
        } else {
            isVisible = true
        }
    }

    private func pulseGlow() {
        guard allowsGlow else { return }
        glow = false
        DispatchQueue.main.asyncAfter(deadline: .now() + revealDelay) {
            withAnimation(.easeOut(duration: 0.16)) {
                glow = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.34) {
                withAnimation(.easeOut(duration: 0.42)) {
                    glow = false
                }
            }
        }
    }
}

private struct ExtractionResultRowModel: Identifiable, Equatable {
    let id: UUID
    let index: Int
    let result: ExtractResult
    let presentation: VideoResultPresentation

    init(id: UUID, index: Int, result: ExtractResult) {
        self.id = id
        self.index = index
        self.result = result
        self.presentation = VideoResultPresentation(result: result)
    }
}

private struct ExtractionResultRow: View {
    let row: ExtractionResultRowModel
    let isRetrying: Bool
    let usesLightweightThumbnail: Bool
    let localState: (String) -> UploadState?
    let megaState: (String) -> UploadState?
    let gdriveState: (String) -> UploadState?
    let seedboxState: (String) -> UploadState?
    let onRetry: () -> Void
    let canRetryWithVPN: Bool
    let onVPNRetry: () -> Void
    let onLocal: (String) -> Void
    let onMega: (String) -> Void
    let onGDrive: (String) -> Void
    let onSeedbox: (String) -> Void

    @State private var selectedQualityID: String?
    @State private var selectedTarget: CloudTarget = .local

    private var result: ExtractResult {
        row.result
    }

    private var presentation: VideoResultPresentation {
        row.presentation
    }

    private var selectedQuality: VideoQualityChoice? {
        presentation.qualities.first { $0.id == selectedQualityID } ?? presentation.qualities.first
    }

    private var selectedState: UploadState? {
        guard let url = selectedQuality?.url else { return nil }
        switch selectedTarget {
        case .local: return localState(url)
        case .mega: return megaState(url)
        case .gdrive: return gdriveState(url)
        case .seedbox: return seedboxState(url)
        }
    }

    private var tint: Color {
        if result.error != nil { return Theme.error }
        if selectedState != nil { return stateColor(selectedState!) }
        return Theme.skyBlue
    }

    var body: some View {
        HStack(spacing: 12) {
            thumbnail

            VStack(alignment: .leading, spacing: 9) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(presentation.title)
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)

                    Spacer(minLength: 12)

                    statusBadge
                }

                if result.source != nil {
                    progressLine
                    controls
                } else {
                    failedContent
                }
            }
        }
        .padding(12)
        .background(Theme.surfaceGlass.opacity(0.38), in: RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Theme.borderSubtle, lineWidth: 1)
        )
        .onAppear {
            if selectedQualityID == nil {
                selectedQualityID = presentation.recommendedQualityID
            }
        }
    }

    private var thumbnail: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(tint.opacity(0.15))
                .frame(width: 110, height: 76)

            if !usesLightweightThumbnail,
               let value = presentation.thumbnailURL,
               let url = URL(string: value),
               result.error == nil {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFill()
                    case .failure:
                        fallbackThumbnail
                    case .empty:
                        ProgressView()
                            .controlSize(.small)
                            .scaleEffect(0.7)
                    @unknown default:
                        fallbackThumbnail
                    }
                }
                .frame(width: 110, height: 76)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                fallbackThumbnail
            }

            if result.error == nil {
                Image(systemName: "play.fill")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(.black.opacity(0.52), in: Circle())
            }
        }
    }

    private var fallbackThumbnail: some View {
        Image(systemName: result.error == nil ? "film.fill" : "exclamationmark.triangle.fill")
            .font(.system(size: 24, weight: .bold))
            .foregroundStyle(tint)
    }

    private var progressLine: some View {
        VStack(alignment: .leading, spacing: 5) {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Theme.surface0.opacity(0.58))
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [tint, tint.opacity(0.62)],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: proxy.size.width * progressValue)
                }
            }
            .frame(height: 7)

            Text(detailText)
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
        }
    }

    private var controls: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                qualityPicker
                targetPicker
                primaryAction
                copyButton
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    qualityPicker
                    targetPicker
                }
                HStack(spacing: 8) {
                    primaryAction
                    copyButton
                }
            }
        }
    }

    private var qualityPicker: some View {
        Picker("Quality", selection: Binding(
            get: { selectedQualityID ?? presentation.recommendedQualityID ?? "" },
            set: { selectedQualityID = $0 }
        )) {
            ForEach(presentation.qualities) { quality in
                Text(quality.label).tag(quality.id)
            }
        }
        .labelsHidden()
        .frame(width: 126)
    }

    private var targetPicker: some View {
        Picker("Target", selection: $selectedTarget) {
            ForEach(CloudTarget.allCases, id: \.self) { target in
                Label(target.homeDisplayName, systemImage: target.icon).tag(target)
            }
        }
        .labelsHidden()
        .frame(width: 132)
    }

    private var primaryAction: some View {
        Button {
            guard let url = selectedQuality?.url else { return }
            switch selectedTarget {
            case .local: onLocal(url)
            case .mega: onMega(url)
            case .gdrive: onGDrive(url)
            case .seedbox: onSeedbox(url)
            }
        } label: {
            Label(selectedTarget.homeActionTitle, systemImage: selectedTarget.icon)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.small)
        .tint(tint)
        .disabled(selectedQuality == nil)
    }

    private var copyButton: some View {
        Button {
            if let url = selectedQuality?.url {
                ClipboardManager.copy(url)
            }
        } label: {
            Image(systemName: "doc.on.doc")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(selectedQuality == nil)
        .help("Copy selected source URL")
    }

    private var failedContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(result.error ?? "Extraction failed.")
                .font(.caption)
                .foregroundStyle(Theme.error)
                .lineLimit(2)

            if isRetrying {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Retrying...")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.textSecondary)
                }
            } else {
                HStack(spacing: 8) {
                    Button {
                        onRetry()
                    } label: {
                        Label("Retry", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    if canRetryWithVPN {
                        Button {
                            onVPNRetry()
                        } label: {
                            Label("Retry with VPN", systemImage: "network")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }
        }
    }

    private var statusBadge: some View {
        Text(statusLabel)
            .font(.caption.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(tint.opacity(0.13), in: Capsule())
            .overlay(
                Capsule()
                    .stroke(tint.opacity(0.32), lineWidth: 1)
            )
    }

    private var statusLabel: String {
        if let selectedState {
            return stateLabel(selectedState)
        }
        if result.error != nil {
            return isRetrying ? "Retrying" : "Failed"
        }
        return "Ready"
    }

    private var detailText: String {
        if let selectedState {
            switch selectedState {
            case .uploading(let message), .done(let message), .failed(let message):
                return message
            }
        }
        let site = presentation.siteName
        let quality = selectedQuality?.label ?? "Source"
        return "\(site) • \(quality) • Ready to download"
    }

    private var progressValue: CGFloat {
        guard let selectedState else { return 1 }
        switch selectedState {
        case .uploading:
            return 0.55
        case .done:
            return 1
        case .failed:
            return 0.18
        }
    }

    private func stateLabel(_ state: UploadState) -> String {
        switch state {
        case .uploading:
            return "Working"
        case .done:
            return "Done"
        case .failed:
            return "Failed"
        }
    }

    private func stateColor(_ state: UploadState) -> Color {
        switch state {
        case .uploading:
            return Theme.skyBlue
        case .done:
            return Theme.success
        case .failed:
            return Theme.error
        }
    }
}

private struct ExtractionLoadingRow: View {
    let subtitle: String

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.performanceProfile) private var performanceProfile
    @State private var isPresented = false
    @State private var shimmerPhase: CGFloat = -1
    @State private var sweepPhase: CGFloat = 0

    private var allowsAnimation: Bool {
        !reduceMotion && performanceProfile.allowsLoadingAnimation
    }

    private var tint: Color {
        Theme.skyBlue
    }

    private var titleWidth: CGFloat {
        310
    }

    private var staticProgress: CGFloat {
        0.55
    }

    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 8)
                .fill(Theme.surface2.opacity(0.48))
                .frame(width: 110, height: 76)
                .overlay(
                    ExtractionPlaceholderShimmer(phase: shimmerPhase, isActive: allowsAnimation)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                )
                .overlay(
                    Image(systemName: "play.fill")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white.opacity(0.7))
                        .frame(width: 30, height: 30)
                        .background(.black.opacity(0.38), in: Circle())
                )

            VStack(alignment: .leading, spacing: 10) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Theme.textPrimary.opacity(0.18))
                    .frame(width: titleWidth, height: 16)
                    .overlay(ExtractionPlaceholderShimmer(phase: shimmerPhase, isActive: allowsAnimation))
                    .clipShape(RoundedRectangle(cornerRadius: 4))

                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Theme.surface0.opacity(0.58))
                        if allowsAnimation {
                            Capsule()
                                .fill(tint)
                                .frame(width: max(44, proxy.size.width * 0.28))
                                .offset(x: sweepOffset(in: proxy.size.width))
                                .shadow(color: tint.opacity(0.28), radius: 4)
                        } else {
                            Capsule()
                                .fill(tint)
                                .frame(width: proxy.size.width * staticProgress)
                        }
                    }
                    .clipShape(Capsule())
                }
                .frame(height: 7)

                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
            }

            Spacer()

            Text("Extracting")
                .font(.caption.weight(.semibold))
                .foregroundStyle(tint)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(tint.opacity(0.13), in: Capsule())
                .overlay(
                    Capsule()
                        .stroke(tint.opacity(0.32), lineWidth: 1)
                )
        }
        .padding(12)
        .background(Theme.surfaceGlass.opacity(0.38), in: RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Theme.borderSubtle, lineWidth: 1)
        )
        .opacity(isPresented || !allowsAnimation ? 1 : 0.82)
        .offset(y: isPresented || !allowsAnimation ? 0 : 6)
        .onAppear {
            guard allowsAnimation else {
                isPresented = true
                return
            }
            withAnimation(.easeOut(duration: 0.18)) {
                isPresented = true
            }
            withAnimation(.linear(duration: 1.35).repeatForever(autoreverses: false)) {
                shimmerPhase = 1
            }
            withAnimation(.linear(duration: 1.55).repeatForever(autoreverses: false)) {
                sweepPhase = 1
            }
        }
    }

    private func sweepOffset(in width: CGFloat) -> CGFloat {
        let segment = max(44, width * 0.28)
        return (width + segment) * sweepPhase - segment
    }
}

private struct ExtractionPlaceholderShimmer: View {
    let phase: CGFloat
    let isActive: Bool

    var body: some View {
        GeometryReader { proxy in
            if isActive {
                Rectangle()
                    .fill(
                        LinearGradient(
                            stops: [
                                .init(color: .clear, location: 0),
                                .init(color: .white.opacity(0.05), location: 0.42),
                                .init(color: .white.opacity(0.16), location: 0.5),
                                .init(color: .white.opacity(0.05), location: 0.58),
                                .init(color: .clear, location: 1)
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: proxy.size.width * 1.8)
                    .offset(x: phase * proxy.size.width * 1.8)
            }
        }
        .clipped()
    }
}
