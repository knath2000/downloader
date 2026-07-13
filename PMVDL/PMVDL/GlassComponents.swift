import AppKit
import SwiftUI

enum PerformanceProfile: Equatable {
    case normal
    case reducedEffects

    static func automatic(reduceMotion: Bool, isLowPowerModeEnabled: Bool) -> PerformanceProfile {
        if reduceMotion || isLowPowerModeEnabled || isIntelBuild {
            return .reducedEffects
        }
        return .normal
    }

    var allowsExpensiveEffects: Bool {
        self == .normal
    }

    var allowsLoadingAnimation: Bool {
        self == .normal
    }

    private static var isIntelBuild: Bool {
        #if arch(x86_64)
        true
        #else
        false
        #endif
    }
}

private struct PerformanceProfileKey: EnvironmentKey {
    static let defaultValue: PerformanceProfile = .normal
}

extension EnvironmentValues {
    var performanceProfile: PerformanceProfile {
        get { self[PerformanceProfileKey.self] }
        set { self[PerformanceProfileKey.self] = newValue }
    }
}

private struct AppShellWindowSizeKey: EnvironmentKey {
    static let defaultValue = CGSize.zero
}

extension EnvironmentValues {
    var appShellWindowSize: CGSize {
        get { self[AppShellWindowSizeKey.self] }
        set { self[AppShellWindowSizeKey.self] = newValue }
    }
}

enum AppShellSurfaceMetrics {
    /// Inset reserved for the titlebar / traffic lights behind a full-window modal.
    static let appModalBackdropInset: CGFloat = 6
    static let appModalTitlebarClearance: CGFloat = 34
    static let appModalCloseButtonReserve: CGFloat = 52

    // MARK: Shared app-modal visual shell

    /// Hit-test scrim behind the modal. Keep it visually transparent so the
    /// reserved titlebar/nav chrome does not become black bands.
    static let appModalScrimOpacity: CGFloat = 0.001
    /// Corner radius of the modal surface.
    static let appModalCornerRadius: CGFloat = 18
    /// Outer tinted fill so the modal body reads as a solid surface, not glass.
    static let appModalFillOpacity: CGFloat = 0.98
    /// Outer stroke + inner highlight that give the surface a crisp boundary.
    static let appModalOuterStrokeOpacity: CGFloat = 0.16
    static let appModalInnerHighlightOpacity: CGFloat = 0.10
    /// Layered drop shadow for depth separation from the dimmed background.
    static let appModalShadowOpacity: CGFloat = 0.65
    static let appModalShadowRadius: CGFloat = 32
    static let appModalShadowY: CGFloat = 18

    // MARK: Floating tab switcher (bottom nav) chrome

    /// Distance the floating nav pill sits above the window bottom.
    static let floatingNavBottomOffset: CGFloat = 20
    static let floatingNavExpandedHeight: CGFloat = 76
    static let floatingNavCollapsedHeight: CGFloat = 60
    /// Trailing gap below the nav pill before usable content ends.
    static let floatingNavTrailingGap: CGFloat = 18

    /// Total vertical space the floating nav occupies at the window bottom for a given state.
    static func floatingNavClearance(isExpanded: Bool) -> CGFloat {
        floatingNavBottomOffset + (isExpanded ? floatingNavExpandedHeight : floatingNavCollapsedHeight) + floatingNavTrailingGap
    }

    /// Safe default reserve: assume the expanded nav so modals never collide in either state.
    static var appModalBottomNavClearance: CGFloat {
        floatingNavClearance(isExpanded: true)
    }

    static func pageMaxWidth(for windowSize: CGSize) -> CGFloat {
        clamped(windowSize.width * 0.96, min: 1180, max: 1900)
    }

    static func mainPanelWidth(for windowSize: CGSize) -> CGFloat {
        clamped(windowSize.width * 0.90, min: 848, max: 1680)
    }

    static func mainPanelHeight(for windowSize: CGSize) -> CGFloat {
        clamped(windowSize.height * 0.70, min: 560, max: 820)
    }

    static func browserSurfaceWidth(for windowSize: CGSize) -> CGFloat {
        appModalSurfaceWidth(for: windowSize)
    }

    static func browserSurfaceHeight(for windowSize: CGSize, reservedBottomInset: CGFloat = 0) -> CGFloat {
        let available = windowSize.height
            - appModalBackdropInset * 2
            - reservedBottomInset
        return max(available, 1)
    }

    static func appModalSurfaceWidth(for windowSize: CGSize) -> CGFloat {
        max(windowSize.width - appModalBackdropInset * 2, 760)
    }

    static func appModalWidth(for windowSize: CGSize, size: AppModalSize) -> CGFloat {
        switch size {
        case .full:
            return appModalSurfaceWidth(for: windowSize)
        case .detail:
            return min(appModalSurfaceWidth(for: windowSize) - 48, detailModalWidth(for: windowSize))
        }
    }

    static func appModalSurfaceHeight(for windowSize: CGSize, reservedTopInset: CGFloat = 0) -> CGFloat {
        appModalAvailableHeight(
            for: windowSize,
            reservedTopInset: reservedTopInset,
            reservedBottomInset: 0
        )
    }

    /// Maximum modal content height after reserving space for the backdrop, the
    /// titlebar/traffic lights (top) and the floating nav pill (bottom). Never
    /// exceeds the truly available safe area, so large modals scroll internally
    /// instead of colliding with app chrome. The `560` floor keeps extremely
    /// small windows usable.
    static func appModalAvailableHeight(
        for windowSize: CGSize,
        reservedTopInset: CGFloat,
        reservedBottomInset: CGFloat
    ) -> CGFloat {
        let available = windowSize.height
            - appModalBackdropInset * 2
            - reservedTopInset
            - reservedBottomInset
        return max(available, 560)
    }

    static func workflowModalWidth(for windowSize: CGSize) -> CGFloat {
        clamped(windowSize.width * 0.78, min: 900, max: 1440)
    }

    static func workflowModalHeight(for windowSize: CGSize) -> CGFloat {
        clamped(windowSize.height * 0.76, min: 620, max: 900)
    }

    static func detailModalWidth(for windowSize: CGSize) -> CGFloat {
        clamped(windowSize.width * 0.52, min: 620, max: 960)
    }

    static func detailModalHeight(for windowSize: CGSize) -> CGFloat {
        clamped(windowSize.height * 0.74, min: 720, max: 860)
    }

    private static func clamped(_ value: CGFloat, min minimum: CGFloat, max maximum: CGFloat) -> CGFloat {
        Swift.min(Swift.max(value, minimum), maximum)
    }
}

enum AppModalSize {
    case full
    case detail
}

struct RefererAwareAsyncImage<Content: View>: View {
    let url: URL
    let referer: String?
    let content: (AsyncImagePhase) -> Content

    @State private var phase: AsyncImagePhase = .empty

    init(
        url: URL,
        referer: String? = nil,
        @ViewBuilder content: @escaping (AsyncImagePhase) -> Content
    ) {
        self.url = url
        self.referer = referer
        self.content = content
    }

    var body: some View {
        content(phase)
            .task(id: "\(url.absoluteString)|\(normalizedReferer ?? "")") {
                await load(referer: normalizedReferer)
            }
    }

    private var normalizedReferer: String? {
        let value = referer?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? nil : value
    }

    @MainActor
    private func load(referer: String?) async {
        phase = .empty

        do {
            let identity = url.absoluteString
            let image: NSImage
            if let cached = await ThumbnailCache.shared.cachedImage(forIdentity: identity) {
                image = cached
            } else {
                image = try await ThumbnailCache.downloadAndCacheImage(
                    fromImageURL: identity,
                    cacheIdentity: identity,
                    referer: referer
                )
            }
            guard !Task.isCancelled else { return }
            phase = .success(Image(nsImage: image))
        } catch {
            guard !Task.isCancelled else { return }
            phase = .failure(error)
        }
    }
}

// MARK: - MeshGradientBackground

struct MeshGradientBackground: View {
    let isActive: Bool

    @Environment(\.performanceProfile) private var performanceProfile

    var body: some View {
        if shouldAnimate {
            TimelineView(.animation(minimumInterval: 1 / 8)) { timeline in
                let t = timeline.date.timeIntervalSinceReferenceDate * 0.06
                meshContent(t: t)
            }
            .ignoresSafeArea()
        } else {
            meshContent(t: 0)
                .ignoresSafeArea()
        }
    }

    private var shouldAnimate: Bool {
        isActive && performanceProfile.allowsExpensiveEffects
    }

    @ViewBuilder
    private func meshContent(t: Double) -> some View {
        if #available(macOS 15, *) {
            MeshGradient(
                width: 3, height: 3,
                points: [
                    [0.0, 0.0],
                    [0.5 + Float(sin(t) * 0.05), 0.0],
                    [1.0, 0.0],
                    [0.0, 0.5 + Float(cos(t * 0.7) * 0.05)],
                    [0.5 + Float(sin(t * 1.3) * 0.06), 0.5 + Float(cos(t * 0.9) * 0.06)],
                    [1.0, 0.5 + Float(sin(t * 0.5) * 0.05)],
                    [0.0, 1.0],
                    [0.5 + Float(cos(t * 0.8) * 0.04), 1.0],
                    [1.0, 1.0]
                ],
                colors: [
                    Theme.meshMidnight, Theme.meshDeepPurple, Theme.meshNavy,
                    Theme.meshIndigo,   Theme.meshDeepPurple, Theme.meshMidnight,
                    Theme.meshNavy,     Theme.meshCoral,      Theme.meshIndigo
                ]
            )
        } else {
            LinearGradient(
                colors: [Theme.meshMidnight, Theme.meshDeepPurple, Theme.meshNavy, Theme.meshIndigo],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }
}

// MARK: - GlassCard

struct GlassCard: ViewModifier {
    var tint: Color = .clear
    var cornerRadius: CGFloat = 16

    @Environment(\.performanceProfile) private var performanceProfile

    func body(content: Content) -> some View {
        glassBody(content: content)
    }

    private var shadowOpacity: Double {
        performanceProfile == .reducedEffects ? 0.16 : 0.28
    }

    private var shadowRadius: CGFloat {
        performanceProfile == .reducedEffects ? 6 : 10
    }

    private var shadowY: CGFloat {
        performanceProfile == .reducedEffects ? 2 : 4
    }

    @ViewBuilder
    private func glassBody(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius)
        let border = shape.stroke(
            LinearGradient(
                colors: [.white.opacity(0.28), .white.opacity(0.04)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            ),
            lineWidth: 1
        )
        if #available(macOS 26, *) {
            if performanceProfile.allowsExpensiveEffects {
                content
                    .glassEffect(.regular.tint(tint), in: shape)
                    .overlay(border)
                    .shadow(color: .black.opacity(shadowOpacity), radius: shadowRadius, x: 0, y: shadowY)
            } else {
                content
                    .background(
                        ZStack {
                            shape.fill(Theme.surface0.opacity(0.82))
                            shape.fill(tint.opacity(0.08))
                        }
                    )
                    .clipShape(shape)
                    .overlay(border)
                    .shadow(color: .black.opacity(shadowOpacity), radius: shadowRadius, x: 0, y: shadowY)
            }
        } else {
            content
                .background(
                    ZStack {
                        if performanceProfile.allowsExpensiveEffects {
                            shape.fill(.ultraThinMaterial)
                        } else {
                            shape.fill(Theme.surface0.opacity(0.82))
                        }
                        shape.fill(tint.opacity(0.08))
                    }
                )
                .clipShape(shape)
                .overlay(border)
                .shadow(color: .black.opacity(shadowOpacity), radius: shadowRadius, x: 0, y: shadowY)
        }
    }
}

extension View {
    func glassCard(tint: Color = .clear, cornerRadius: CGFloat = 16) -> some View {
        modifier(GlassCard(tint: tint, cornerRadius: cornerRadius))
    }
}

// MARK: - CartoonBadge

/// Taobao-style floating pill badge — bold all-caps label with a slight tilt.
struct CartoonBadge: View {
    let label: String
    var color: Color = Theme.taoRed
    var animated: Bool = false

    @State private var isPulsing = false

    private var tiltDegrees: Double {
        let hash = label.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
        return Double(hash % 13) - 6.0
    }

    var body: some View {
        Text(label.uppercased())
            .font(Theme.badgeLabel)
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.4), radius: 1, x: 0, y: 1)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color, in: Capsule())
            .shadow(color: color.opacity(0.6), radius: 5, x: 0, y: 2)
            .rotationEffect(.degrees(tiltDegrees))
            .scaleEffect(isPulsing ? 1.06 : 1.0)
            .onAppear {
                guard animated else { return }
                withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                    isPulsing = true
                }
            }
    }
}

// MARK: - MarketplaceButton

/// Prominent glass button with gradient label text and shimmer-on-appear effect.
struct MarketplaceButton: View {
    let title: String
    var icon: String? = nil
    var prominent: Bool = true
    let action: () -> Void

    @State private var shimmerOffset: CGFloat = -200

    private var labelView: some View {
        HStack(spacing: 6) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .bold))
            }
            Text(title)
                .font(.system(.body).weight(.bold))
        }
        .foregroundStyle(
            LinearGradient(
                colors: [Theme.gold, Theme.coral, Theme.taoRed],
                startPoint: .leading,
                endPoint: .trailing
            )
        )
        .frame(maxWidth: .infinity)
        .padding(.vertical, 2)
        .overlay(shimmerOverlay)
    }

    var body: some View {
        buttonBody
            .controlSize(.large)
            .onAppear { playShimmer() }
    }

    @ViewBuilder
    private var buttonBody: some View {
        if #available(macOS 26, *) {
            if prominent {
                Button(action: action) { labelView }
                    .buttonStyle(.glassProminent)
            } else {
                Button(action: action) { labelView }
                    .buttonStyle(.glass)
            }
        } else {
            Button(action: action) { labelView }
                .buttonStyle(.borderedProminent)
        }
    }

    private var shimmerOverlay: some View {
        GeometryReader { _ in
            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [.clear, .white.opacity(0.18), .clear],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .frame(width: 60)
                .offset(x: shimmerOffset)
        }
        .allowsHitTesting(false)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func playShimmer() {
        shimmerOffset = -200
        withAnimation(.linear(duration: 0.9).delay(0.3)) {
            shimmerOffset = 400
        }
    }
}

// MARK: - GradientProgressBar

/// Colorful animated barberpole progress bar for download cells.
struct GradientProgressBar: View {
    var progress: Double  // 0.0 – 1.0
    var height: CGFloat = 6
    var isAnimated = true

    @State private var stripeOffset: CGFloat = 0

    private let gradient = LinearGradient(
        colors: [Theme.electricLime, Theme.coral, Theme.taoRed],
        startPoint: .leading,
        endPoint: .trailing
    )

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: height / 2)
                    .fill(.ultraThinMaterial)
                    .frame(height: height)

                let fillWidth = max(0, geo.size.width * min(progress, 1))
                RoundedRectangle(cornerRadius: height / 2)
                    .fill(gradient)
                    .frame(width: fillWidth, height: height)
                    .overlay {
                        if isAnimated {
                            stripeLayer(width: fillWidth)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: height / 2))
                    .animation(isAnimated ? .spring(response: 0.4, dampingFraction: 0.8) : nil, value: progress)
            }
        }
        .frame(height: height)
        .onAppear {
            guard isAnimated else { return }
            withAnimation(.linear(duration: 1.5).repeatForever(autoreverses: false)) {
                stripeOffset = 24
            }
        }
    }

    private func stripeLayer(width: CGFloat) -> some View {
        Rectangle()
            .fill(
                LinearGradient(
                    colors: [.clear, .white.opacity(0.15), .clear, .white.opacity(0.15), .clear],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .frame(width: max(width + 48, 0))
            .offset(x: stripeOffset)
            .allowsHitTesting(false)
    }
}

// MARK: - AppModalOverlay

struct AppModalOverlay<Content: View>: View {
    @ObservedObject private var appState = AppStateManager.shared
    @Environment(\.appModalBottomNavClearance) private var bottomNavClearance
    let dismiss: () -> Void
    var size: AppModalSize = .full
    /// Top reserve defaults to the titlebar/traffic-light clearance so callers
    /// no longer need to pass it. Content is always top-aligned.
    var reservedTopInset: CGFloat = AppShellSurfaceMetrics.appModalTitlebarClearance

    @ViewBuilder let content: () -> Content

    var body: some View {
        ZStack(alignment: .top) {
            // Outside-tap layer. Visual separation belongs to the modal surface,
            // not to a full-window black wash over reserved app chrome.
            Color.black.opacity(AppShellSurfaceMetrics.appModalScrimOpacity)
                .ignoresSafeArea()
                .onTapGesture { dismiss() }

            // Opaque-ish modal surface that owns the outer shell so modal
            // bodies no longer paint their own translucent gradient.
            content()
                .padding(.trailing, AppShellSurfaceMetrics.appModalCloseButtonReserve)
                .frame(
                    width: AppShellSurfaceMetrics.appModalWidth(for: appState.windowSize, size: size),
                    height: AppShellSurfaceMetrics.appModalAvailableHeight(
                        for: appState.windowSize,
                        reservedTopInset: reservedTopInset,
                        reservedBottomInset: bottomNavClearance
                    )
                )
                .background(
                    LinearGradient(
                        colors: [
                            Theme.surface0.opacity(AppShellSurfaceMetrics.appModalFillOpacity),
                            Theme.surface1.opacity(AppShellSurfaceMetrics.appModalFillOpacity)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .clipShape(RoundedRectangle(cornerRadius: AppShellSurfaceMetrics.appModalCornerRadius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: AppShellSurfaceMetrics.appModalCornerRadius, style: .continuous)
                        .stroke(Color.white.opacity(AppShellSurfaceMetrics.appModalOuterStrokeOpacity), lineWidth: 1)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: AppShellSurfaceMetrics.appModalCornerRadius, style: .continuous)
                        .stroke(Color.white.opacity(AppShellSurfaceMetrics.appModalInnerHighlightOpacity), lineWidth: 1)
                        .padding(1)
                )
                .shadow(
                    color: Color.black.opacity(AppShellSurfaceMetrics.appModalShadowOpacity),
                    radius: AppShellSurfaceMetrics.appModalShadowRadius,
                    y: AppShellSurfaceMetrics.appModalShadowY
                )
                .contentShape(Rectangle())
                .onTapGesture {}
                .overlay(alignment: .topTrailing) {
                    AppModalCloseButton(action: dismiss)
                        .padding(.top, 12)
                        .padding(.trailing, 12)
                }
                .padding(.top, reservedTopInset)
        }
        .padding(AppShellSurfaceMetrics.appModalBackdropInset)
        .ignoresSafeArea()
        .onExitCommand(perform: dismiss)
    }
}

struct AppModalCloseButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 12, weight: .bold))
                .frame(width: 30, height: 30)
                .foregroundStyle(Theme.textSecondary)
                .background(Theme.surface2.opacity(0.78), in: Circle())
                .overlay(Circle().strokeBorder(Theme.borderSubtle, lineWidth: 0.7))
        }
        .buttonStyle(.plain)
        .contentShape(Circle())
        .help("Close")
        .accessibilityLabel("Close")
    }
}

enum AppContextMenuActionRole {
    case normal
    case destructive
}

struct AppContextMenuAction {
    let title: String
    let systemImage: String
    let role: AppContextMenuActionRole
    let isEnabled: Bool
    let showsSeparatorBefore: Bool
    let action: () -> Void

    init(
        _ title: String,
        systemImage: String,
        role: AppContextMenuActionRole = .normal,
        isEnabled: Bool = true,
        showsSeparatorBefore: Bool = false,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.systemImage = systemImage
        self.role = role
        self.isEnabled = isEnabled
        self.showsSeparatorBefore = showsSeparatorBefore
        self.action = action
    }
}

private final class AppContextMenuPresenter {
    static let shared = AppContextMenuPresenter()

    private var panel: NSPanel?
    private var monitor: Any?

    func present(
        at screenPoint: NSPoint,
        title: String,
        subtitle: String,
        accent: Color,
        actions: [AppContextMenuAction]
    ) {
        dismiss()
        let content = NSHostingView(rootView: AppContextMenuView(
            title: title,
            subtitle: subtitle,
            accent: accent,
            actions: actions,
            dismiss: { [weak self] in self?.dismiss() }
        ))
        content.frame = NSRect(x: 0, y: 0, width: 260, height: 1)
        content.layoutSubtreeIfNeeded()
        let fittingSize = content.fittingSize
        let menuSize = NSSize(width: 260, height: max(120, fittingSize.height))
        let visibleFrame = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? .zero
        let origin = NSPoint(
            x: min(max(screenPoint.x, visibleFrame.minX + 8), visibleFrame.maxX - menuSize.width - 8),
            y: min(max(screenPoint.y - menuSize.height, visibleFrame.minY + 8), visibleFrame.maxY - menuSize.height - 8)
        )
        let panel = NSPanel(
            contentRect: NSRect(origin: origin, size: menuSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.level = .popUpMenu
        panel.collectionBehavior = [.transient, .ignoresCycle]
        panel.contentView = content
        self.panel = panel
        panel.orderFront(nil)
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
            guard let self else { return event }
            guard event.type != .keyDown,
                  event.window === self.panel else {
                self.dismiss()
                return event
            }
            return event
        }
    }

    func dismiss() {
        panel?.close()
        panel = nil
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }
}

struct AppContextMenuView: View {
    let title: String
    let subtitle: String
    let accent: Color
    let actions: [AppContextMenuAction]
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 9) {
                Image(systemName: "cursorarrow.click.2")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.caption.weight(.bold)).foregroundStyle(.white).lineLimit(1)
                    Text(subtitle).font(.caption2).foregroundStyle(.white.opacity(0.58)).lineLimit(1)
                }
            }
            .padding(.bottom, 3)

            ForEach(Array(actions.enumerated()), id: \.offset) { _, action in
                if action.showsSeparatorBefore {
                    Divider().overlay(.white.opacity(0.10))
                }
                Button {
                    dismiss()
                    action.action()
                } label: {
                    HStack(spacing: 9) {
                        Image(systemName: action.systemImage)
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(action.role == .destructive ? Theme.error : accent)
                            .frame(width: 18)
                        Text(action.title)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(action.role == .destructive ? Theme.error : .white.opacity(0.92))
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 32)
                    .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(accent.opacity(0.16), lineWidth: 0.5))
                }
                .buttonStyle(.plain)
                .disabled(!action.isEnabled)
                .opacity(action.isEnabled ? 1 : 0.42)
            }
        }
        .padding(12)
        .frame(width: 260)
        .background(LinearGradient(colors: [Color(red: 0.11, green: 0.07, blue: 0.03), Color(red: 0.05, green: 0.04, blue: 0.07)], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(accent.opacity(0.42), lineWidth: 1))
        .shadow(color: .black.opacity(0.45), radius: 18, y: 10)
    }
}

private struct AppContextMenuAnchor: NSViewRepresentable {
    let title: String
    let subtitle: String
    let accent: Color
    let actions: [AppContextMenuAction]

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.postsFrameChangedNotifications = true
        context.coordinator.attach(to: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.update(title: title, subtitle: subtitle, accent: accent, actions: actions)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        weak var view: NSView?
        var title = ""
        var subtitle = ""
        var accent = Color.white
        var actions: [AppContextMenuAction] = []
        var monitor: Any?

        func attach(to view: NSView) {
            self.view = view
            monitor = NSEvent.addLocalMonitorForEvents(matching: .rightMouseDown) { [weak self] event in
                guard let self, let view = self.view, event.window === view.window else { return event }
                let point = view.convert(event.locationInWindow, from: nil)
                guard view.bounds.contains(point), let window = view.window else { return event }
                let windowPoint = view.convert(point, to: nil)
                let screenPoint = window.convertPoint(toScreen: windowPoint)
                AppContextMenuPresenter.shared.present(at: screenPoint, title: self.title, subtitle: self.subtitle, accent: self.accent, actions: self.actions)
                return event
            }
        }

        func update(title: String, subtitle: String, accent: Color, actions: [AppContextMenuAction]) {
            self.title = title
            self.subtitle = subtitle
            self.accent = accent
            self.actions = actions
        }

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
    }
}

extension View {
    func appContextMenu(
        title: String,
        subtitle: String,
        accent: Color = Theme.lavender,
        actions: [AppContextMenuAction]
    ) -> some View {
        background(AppContextMenuAnchor(title: title, subtitle: subtitle, accent: accent, actions: actions))
    }
}

// MARK: - App-shell chrome environment

private struct AppModalBottomNavClearanceKey: EnvironmentKey {
    static let defaultValue: CGFloat = AppShellSurfaceMetrics.appModalBottomNavClearance
}

extension EnvironmentValues {
    /// Bottom reserve (window-space) the floating nav pill occupies, so a full-window
    /// modal can keep its content above the nav. Defaults to the expanded-nav clearance.
    var appModalBottomNavClearance: CGFloat {
        get { self[AppModalBottomNavClearanceKey.self] }
        set { self[AppModalBottomNavClearanceKey.self] = newValue }
    }
}

// MARK: - QuirkyPopup

/// Cartoon-styled overlay popup for errors, success, and confirmations.
struct QuirkyPopup: View {
    let emoji: String
    let title: String
    var subtitle: String? = nil
    var badgeLabel: String? = nil
    var badgeColor: Color = Theme.taoRed
    let primaryLabel: String
    let primaryAction: () -> Void
    var secondaryLabel: String? = nil
    var secondaryAction: (() -> Void)? = nil
    let dismiss: () -> Void

    @State private var appeared = false

    var body: some View {
        ZStack {
            Color.black.opacity(0.001)
                .ignoresSafeArea()
                .onTapGesture { dismiss() }

            popupCard
                .scaleEffect(appeared ? 1.0 : 0.3)
                .opacity(appeared ? 1.0 : 0)
                .onAppear {
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.6)) {
                        appeared = true
                    }
                }
        }
    }

    private var popupCard: some View {
        VStack(spacing: 16) {
            ZStack(alignment: .topTrailing) {
                Text(emoji).font(.system(size: 56))
                if let badgeLabel {
                    CartoonBadge(label: badgeLabel, color: badgeColor, animated: true)
                        .offset(x: 16, y: -12)
                }
            }

            Text(title)
                .font(Theme.marketplaceTitle)
                .foregroundStyle(Theme.textPrimary)
                .multilineTextAlignment(.center)

            if let subtitle {
                Text(subtitle)
                    .font(.body)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .opacity(0.75)
            }

            HStack(spacing: 12) {
                if let secLabel = secondaryLabel, let secAction = secondaryAction {
                    Button(secLabel, action: secAction)
                        .buttonStyle(.bordered)
                }
                MarketplaceButton(title: primaryLabel, action: primaryAction)
                    .frame(maxWidth: 200)
            }
        }
        .padding(28)
        .glassCard(tint: Theme.lavender, cornerRadius: 24)
        .padding(40)
    }
}

// MARK: - ColoredAccentStrip

/// 4pt left-edge strip for video result cards indicating site type.
struct ColoredAccentStrip: View {
    let color: Color

    var body: some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(
                LinearGradient(colors: [color, color.opacity(0.4)], startPoint: .top, endPoint: .bottom)
            )
            .frame(width: 4)
    }
}

// MARK: - SiteAccentColor

/// Maps a video source domain/URL to a marketplace accent color for card tinting.
func siteAccentColor(for url: String) -> Color {
    let lower = url.lowercased()
    if lower.contains("youtube") || lower.contains("youtu.be") { return Theme.taoRed }
    if lower.contains("twitter") || lower.contains("x.com")    { return Theme.skyBlue }
    if lower.contains("tiktok")                                 { return Theme.hotPink }
    if lower.contains("vimeo")                                  { return Theme.skyBlue }
    if lower.contains("lulu") || lower.contains("luluvid")     { return Theme.lavender }
    if lower.contains("streamtape")                             { return Theme.amber }
    if lower.contains("mixdrop")                                { return Theme.coral }
    if lower.contains("dood")                                   { return Theme.gold }
    return Theme.coral
}

// MARK: - PressEffect (Taobao spring-bounce on tap)

/// Scales down on press and springs back — gives every tappable surface tactile feedback.
struct PressEffect: ViewModifier {
    var scale: CGFloat = 0.95

    @State private var pressed = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(pressed ? scale : 1.0)
            .animation(.spring(response: 0.25, dampingFraction: 0.55), value: pressed)
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in pressed = true }
                    .onEnded   { _ in pressed = false }
            )
    }
}

extension View {
    func pressEffect(scale: CGFloat = 0.95) -> some View {
        modifier(PressEffect(scale: scale))
    }
}

// MARK: - ScrollEntrance (Tmall scroll-triggered slide-in)

/// Cards fade + slide up into view when they first appear on screen.
struct ScrollEntrance: ViewModifier {
    var delay: Double = 0

    @State private var visible = false

    func body(content: Content) -> some View {
        content
            .opacity(visible ? 1 : 0)
            .offset(y: visible ? 0 : 18)
            .onAppear {
                withAnimation(.spring(response: 0.45, dampingFraction: 0.72).delay(delay)) {
                    visible = true
                }
            }
    }
}

extension View {
    func scrollEntrance(delay: Double = 0) -> some View {
        modifier(ScrollEntrance(delay: delay))
    }
}

// MARK: - ShimmerCard (skeleton loading placeholder)

/// Taobao-style shimmer skeleton shown while content is loading.
struct ShimmerCard: View {
    var height: CGFloat = 72
    @State private var phase: CGFloat = -1

    var body: some View {
        RoundedRectangle(cornerRadius: 14)
            .fill(Theme.surface1)
            .frame(height: height)
            .overlay(
                GeometryReader { geo in
                    Rectangle()
                        .fill(
                            LinearGradient(
                                stops: [
                                    .init(color: .clear,                       location: 0),
                                    .init(color: .white.opacity(0.07),         location: 0.4),
                                    .init(color: .white.opacity(0.13),         location: 0.5),
                                    .init(color: .white.opacity(0.07),         location: 0.6),
                                    .init(color: .clear,                       location: 1),
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: geo.size.width * 2)
                        .offset(x: phase * geo.size.width * 2)
                }
                .clipped()
            )
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .onAppear {
                withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) {
                    phase = 1
                }
            }
    }
}

// MARK: - TaobaoSectionHeader

/// Bold section header with a colored slide-indicator line and optional "See All" button.
/// Mirrors the visual rhythm of Taobao/Tmall section dividers.
struct TaobaoSectionHeader: View {
    let title: String
    var accentColor: Color = Theme.taoRed
    var seeAllAction: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            // Colored vertical accent bar
            RoundedRectangle(cornerRadius: 2)
                .fill(
                    LinearGradient(colors: [accentColor, accentColor.opacity(0.5)],
                                   startPoint: .top, endPoint: .bottom)
                )
                .frame(width: 4, height: 20)

            Text(title)
                .font(Theme.sectionHeader)
                .foregroundStyle(Theme.textPrimary)

            Spacer()

            if let action = seeAllAction {
                Button(action: action) {
                    HStack(spacing: 3) {
                        Text("See all")
                            .font(.caption.weight(.semibold))
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.bold))
                    }
                    .foregroundStyle(accentColor)
                }
                .buttonStyle(.plain)
                .pressEffect(scale: 0.92)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 4)
    }
}

// MARK: - CategoryIconRail

/// Horizontal scrolling row of circular category shortcut icons, like Taobao's top nav strip.
struct CategoryIconRail: View {
    struct Item: Identifiable {
        let id: String
        let icon: String
        let label: String
        let color: Color
    }

    let items: [Item]
    var onSelect: (Item) -> Void = { _ in }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 18) {
                ForEach(items) { item in
                    CategoryIconButton(item: item, onSelect: onSelect)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 4)
        }
    }
}

private struct CategoryIconButton: View {
    let item: CategoryIconRail.Item
    var onSelect: (CategoryIconRail.Item) -> Void

    @State private var tapped = false

    var body: some View {
        Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.5)) { tapped = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) { tapped = false }
            }
            onSelect(item)
        } label: {
            VStack(spacing: 5) {
                ZStack {
                    Circle()
                        .fill(item.color.opacity(0.18))
                        .frame(width: 48, height: 48)
                    Circle()
                        .strokeBorder(item.color.opacity(0.35), lineWidth: 1)
                        .frame(width: 48, height: 48)
                    Image(systemName: item.icon)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(item.color)
                }
                .scaleEffect(tapped ? 0.88 : 1.0)
                .shadow(color: item.color.opacity(tapped ? 0.5 : 0.2), radius: tapped ? 8 : 4, x: 0, y: 2)

                Text(item.label)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - FlipDigit (Tmall-style animated count digit)

/// A single digit that flips with a 3D rotation when its value changes — used in download counters.
struct FlipDigit: View {
    let value: Int

    @State private var displayed: Int = 0
    @State private var rotation: Double = 0

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 5)
                .fill(Theme.surface1)
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(Theme.border, lineWidth: 0.5)
                )

            Text("\(displayed)")
                .font(.system(size: 16, weight: .black, design: .monospaced))
                .foregroundStyle(Theme.textPrimary)
                .rotation3DEffect(.degrees(rotation), axis: (x: 1, y: 0, z: 0))
        }
        .frame(width: 22, height: 28)
        .onChange(of: value) { _, newVal in
            withAnimation(.easeIn(duration: 0.12)) { rotation = 90 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                displayed = newVal
                rotation = -90
                withAnimation(.spring(response: 0.25, dampingFraction: 0.65)) { rotation = 0 }
            }
        }
        .onAppear { displayed = value }
    }
}

/// Displays a number using `FlipDigit` tiles — like a Tmall countdown or download counter.
struct FlipCounter: View {
    let count: Int
    var label: String = ""
    var color: Color = Theme.coral

    private var digits: [Int] {
        let s = "\(max(0, count))"
        return s.map { Int(String($0)) ?? 0 }
    }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(digits.enumerated()), id: \.offset) { _, d in
                FlipDigit(value: d)
            }
            if !label.isEmpty {
                Text(label)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(color)
                    .padding(.leading, 2)
            }
        }
    }
}

// MARK: - BounceOnAppear

/// Bounces a view into existence — used for badges, icons, and CTAs.
struct BounceOnAppear: ViewModifier {
    var delay: Double = 0
    @State private var scale: CGFloat = 0.01

    func body(content: Content) -> some View {
        content
            .scaleEffect(scale)
            .onAppear {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.55).delay(delay)) {
                    scale = 1.0
                }
            }
    }
}

extension View {
    func bounceOnAppear(delay: Double = 0) -> some View {
        modifier(BounceOnAppear(delay: delay))
    }
}

// MARK: - SlidingTabBar

/// Taobao/Tmall-style tab bar with a sliding capsule underline indicator.
struct SlidingTabBar: View {
    let tabs: [String]
    @Binding var selected: Int
    var accentColor: Color = Theme.taoRed

    @Namespace private var tabNamespace

    var body: some View {
        HStack(spacing: 0) {
            ForEach(tabs.indices, id: \.self) { idx in
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                        selected = idx
                    }
                } label: {
                    VStack(spacing: 4) {
                        Text(tabs[idx])
                            .font(.system(.subheadline, design: .default)
                                .weight(selected == idx ? .bold : .regular))
                            .foregroundStyle(selected == idx ? Theme.textPrimary : Theme.textSecondary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)

                        if selected == idx {
                            Capsule()
                                .fill(accentColor)
                                .frame(height: 3)
                                .matchedGeometryEffect(id: "tab_indicator", in: tabNamespace)
                                .padding(.horizontal, 16)
                        } else {
                            Capsule()
                                .fill(Color.clear)
                                .frame(height: 3)
                                .padding(.horizontal, 16)
                        }
                    }
                }
                .buttonStyle(.plain)
                .pressEffect(scale: 0.93)
            }
        }
        .background(
            Capsule()
                .fill(Theme.surface1.opacity(0.5))
                .padding(.bottom, 6)
        )
    }
}

// MARK: - PulsingDot

/// An animated pulsing dot used to indicate active/live state (like a live indicator on Taobao).
struct PulsingDot: View {
    var color: Color = Theme.taoRed
    var size: CGFloat = 8

    @State private var pulse = false

    var body: some View {
        ZStack {
            Circle()
                .fill(color.opacity(0.3))
                .frame(width: size * 2.2, height: size * 2.2)
                .scaleEffect(pulse ? 1.4 : 0.8)
                .opacity(pulse ? 0 : 0.6)
            Circle()
                .fill(color)
                .frame(width: size, height: size)
        }
        .onAppear {
            withAnimation(.easeOut(duration: 1.1).repeatForever(autoreverses: false)) {
                pulse = true
            }
        }
    }
}
