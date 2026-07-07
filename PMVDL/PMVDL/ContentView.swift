import AppKit
import Combine
import SwiftUI

struct ContentView: View {
    @StateObject private var appState = AppStateManager.shared
    @StateObject private var activeQueueBadge = DownloadQueueActiveCountProjection(queue: .shared)
    @StateObject private var license = LicenseManager.shared
    @AppStorage("megaRemotePath") var megaRemotePath = "/Cloud/VidDL/"
    @AppStorage("gdriveRemoteName") var gdriveRemoteName = "gdrive"
    @AppStorage("gdriveRemotePath") var gdriveRemotePath = "VidDL/"
    @AppStorage("seedboxTransferMode") var seedboxTransferMode = "rclone"
    @AppStorage("seedboxRemoteName") var seedboxRemoteName = "seedbox"
    @AppStorage("seedboxRemotePath") var seedboxRemotePath = "/"
    @AppStorage("seedboxWebdavURL") var seedboxWebdavURL = ""
    @AppStorage("seedboxWebdavUser") var seedboxWebdavUser = ""
    @AppStorage("seedboxWebdavPassword") var seedboxWebdavPassword = ""
    @State private var showUpgradeOverlay = false
    @State private var isLowPowerModeEnabled = ProcessInfo.processInfo.isLowPowerModeEnabled
    @State private var lastAccessibleDestination: NavDestination = .home
    @State private var warmedDestinations: Set<NavDestination> = [.home]
    @State private var coldOpeningDestination: NavDestination?
    @State private var didScheduleCheapStartupWarmup = false
    @State private var isTabSwitcherExpanded = true
    @Namespace private var tabSwitcherGlass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    private var floatingTabContentInset: CGFloat {
        FloatingTabSwitcherMetrics.contentInset(isExpanded: isTabSwitcherExpanded)
    }

    private var performanceProfile: PerformanceProfile {
        PerformanceProfile.automatic(
            reduceMotion: reduceMotion,
            isLowPowerModeEnabled: isLowPowerModeEnabled
        )
    }

    private var displayedDestination: NavDestination {
        ProFeatureGate.canAccess(appState.selectedDestination) ? appState.selectedDestination : fallbackDestination
    }

    private var fallbackDestination: NavDestination {
        ProFeatureGate.canAccess(lastAccessibleDestination) ? lastAccessibleDestination : .home
    }

    var body: some View {
        ZStack {
            MeshGradientBackground(isActive: scenePhase == .active)
                .ignoresSafeArea()
                .zIndex(-1)

            navigationBody
                .zIndex(0)

            if showUpgradeOverlay {
                UpgradeOverlay { dismissUpgradeOverlay() }
                    .transition(.opacity)
                    .zIndex(1)
            }
        }
        .background(WindowConfigurator())
        .environment(\.performanceProfile, performanceProfile)
        .onAppear {
            isLowPowerModeEnabled = ProcessInfo.processInfo.isLowPowerModeEnabled
            enforceAccess(to: appState.selectedDestination)
            scheduleCheapStartupWarmup()
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name.NSProcessInfoPowerStateDidChange)) { _ in
            isLowPowerModeEnabled = ProcessInfo.processInfo.isLowPowerModeEnabled
        }
        .onChange(of: appState.selectedDestination) { _, destination in
            enforceAccess(to: destination)
        }
        .onChange(of: license.isPro) { _, isPro in
            if !isPro {
                enforceAccess(to: appState.selectedDestination)
            }
        }
    }

    @ViewBuilder
    private var navigationBody: some View {
        if #available(macOS 26, *) {
            mainLayout
                .backgroundExtensionEffect()
        } else {
            mainLayout
        }
    }

    private var mainLayout: some View {
        ZStack(alignment: .bottom) {
            contentLayer(for: displayedDestination)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            FloatingTabSwitcher(
                destinations: sidebarDestinations,
                selected: displayedDestination,
                badge: { navBadge(for: $0) },
                isExpanded: isTabSwitcherExpanded,
                namespace: tabSwitcherGlass,
                select: selectDestination,
                toggleExpanded: toggleTabSwitcherExpansion
            )
            .padding(.bottom, FloatingTabSwitcherMetrics.bottomOffset)
            .zIndex(10)
        }
        .onAppear {
            NotificationManager.shared.requestAuthorization()
        }
    }

    @ViewBuilder
    private func contentLayer(for dest: NavDestination) -> some View {
        if shouldShowOpeningPlaceholder(for: dest) {
            TabOpeningPlaceholder(destination: dest)
                .padding(dest == .settings || dest == .home ? 16 : 0)
                .padding(.bottom, floatingTabContentInset)
                .transition(.opacity)
        } else {
            contentForDestination(dest)
        }
    }

    @ViewBuilder
    private func contentForDestination(_ dest: NavDestination) -> some View {
        switch dest {
        case .home:
            HomeView(appState: appState,
                     megaRemotePath: megaRemotePath,
                     gdriveRemoteName: gdriveRemoteName,
                     gdriveRemotePath: gdriveRemotePath,
                     seedboxTransferMode: seedboxTransferMode,
                     seedboxRemoteName: seedboxRemoteName,
                     seedboxRemotePath: seedboxRemotePath,
                     seedboxWebdavURL: seedboxWebdavURL,
                     seedboxWebdavUser: seedboxWebdavUser,
                     seedboxWebdavPassword: seedboxWebdavPassword,
                     onUpgradeRequired: presentUpgradeOverlay)
                .padding()
                .padding(.bottom, floatingTabContentInset)
        case .library:
            LibraryView(onUpgradeRequired: presentUpgradeOverlay)
                .padding(.bottom, floatingTabContentInset)
        case .feed:
            FeedView()
                .padding(.bottom, floatingTabContentInset)
        case .settings:
            SettingsView(gdriveRemoteName: $gdriveRemoteName,
                         gdriveRemotePath: $gdriveRemotePath,
                         onUpgradeRequired: presentUpgradeOverlay)
                .padding()
                .padding(.bottom, floatingTabContentInset)
        }
    }

    private var sidebarDestinations: [NavDestination] {
        NavDestination.allCases
    }

    private func navBadge(for dest: NavDestination) -> Int? {
        switch dest {
        case .home:
            return activeQueueBadge.activeCount == 0 ? nil : activeQueueBadge.activeCount
        default:
            return nil
        }
    }

    private func selectDestination(_ destination: NavDestination) {
        guard ProFeatureGate.canAccess(destination) else {
            presentUpgradeOverlay()
            return
        }

        if !warmedDestinations.contains(destination) {
            coldOpeningDestination = destination
        }

        withAnimation(performanceProfile == .reducedEffects ? nil : .easeOut(duration: 0.12)) {
            appState.select(destination)
        }

        scheduleMountIfNeeded(destination)
    }

    private func toggleTabSwitcherExpansion() {
        withAnimation(performanceProfile == .reducedEffects ? nil : .easeOut(duration: 0.16)) {
            isTabSwitcherExpanded.toggle()
        }
    }

    private func enforceAccess(to destination: NavDestination) {
        guard ProFeatureGate.canAccess(destination) else {
            presentUpgradeOverlay()
            let fallback = fallbackDestination
            if appState.selectedDestination != fallback {
                appState.select(fallback)
            }
            return
        }

        lastAccessibleDestination = destination
    }

    private func shouldShowOpeningPlaceholder(for destination: NavDestination) -> Bool {
        destination != .home &&
            coldOpeningDestination == destination &&
            !warmedDestinations.contains(destination)
    }

    private func scheduleMountIfNeeded(_ destination: NavDestination) {
        guard destination != .home,
              !warmedDestinations.contains(destination) else {
            coldOpeningDestination = nil
            return
        }

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 80_000_000)
            warmedDestinations.insert(destination)
            if coldOpeningDestination == destination {
                withAnimation(performanceProfile == .reducedEffects ? nil : .easeOut(duration: 0.16)) {
                    coldOpeningDestination = nil
                }
            }
        }
    }

    private func scheduleCheapStartupWarmup() {
        guard !didScheduleCheapStartupWarmup else { return }
        didScheduleCheapStartupWarmup = true

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 250_000_000)
            _ = VideoLibrary.shared
            _ = HistoryManager.shared
            _ = FeedFavoritesStore.shared
            _ = FeedViewModel.shared
            _ = SettingsDependencyStore.shared
        }
    }

    private func presentUpgradeOverlay() {
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
            showUpgradeOverlay = true
        }
    }

    private func dismissUpgradeOverlay() {
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
            showUpgradeOverlay = false
        }
    }
}

// MARK: - FloatingTabSwitcher

private enum FloatingTabSwitcherMetrics {
    static let bottomOffset: CGFloat = 20
    static let expandedHeight: CGFloat = 76
    static let collapsedHeight: CGFloat = 60
    static let tabWidth: CGFloat = 74
    static let tabHeight: CGFloat = 58
    static let menuWidth: CGFloat = 54
    static let menuHeight: CGFloat = 58

    static func contentInset(isExpanded: Bool) -> CGFloat {
        bottomOffset + (isExpanded ? expandedHeight : collapsedHeight) + 18
    }
}

private struct FloatingTabSwitcher: View {
    let destinations: [NavDestination]
    let selected: NavDestination
    let badge: (NavDestination) -> Int?
    let isExpanded: Bool
    let namespace: Namespace.ID
    let select: (NavDestination) -> Void
    let toggleExpanded: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.performanceProfile) private var performanceProfile

    private var shadowOpacity: Double {
        performanceProfile == .reducedEffects ? 0.30 : 0.55
    }

    private var shadowRadius: CGFloat {
        performanceProfile == .reducedEffects ? 12 : 24
    }

    private var shadowY: CGFloat {
        performanceProfile == .reducedEffects ? 4 : 8
    }

    private var toggleAnimation: Animation? {
        performanceProfile == .reducedEffects ? nil : .easeOut(duration: 0.16)
    }

    var body: some View {
        HStack(spacing: 0) {
            hamburgerButton

            if isExpanded {
                divider
                    .padding(.vertical, 13)
                    .transition(expandedControlsTransition)

                ForEach(destinations, id: \.self) { dest in
                    tabButton(dest)
                        .transition(expandedControlsTransition)
                }
            }
        }
        .frame(height: isExpanded ? FloatingTabSwitcherMetrics.expandedHeight : FloatingTabSwitcherMetrics.collapsedHeight)
        .padding(.horizontal, isExpanded ? 10 : 3)
        .background { pillBackground }
        .clipShape(Capsule())
        .overlay(pillBorder)
        .shadow(color: .black.opacity(shadowOpacity), radius: shadowRadius, x: 0, y: shadowY)
        .animation(toggleAnimation, value: isExpanded)
    }

    private var hamburgerButton: some View {
        Button {
            toggleExpanded()
        } label: {
            ZStack {
                Capsule()
                    .fill(Theme.surfaceGlass.opacity(isExpanded ? 0.40 : 0.58))
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 19, weight: .bold))
                    .foregroundStyle(Theme.textPrimary.opacity(0.92))
            }
            .frame(width: FloatingTabSwitcherMetrics.menuWidth, height: FloatingTabSwitcherMetrics.menuHeight)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .pressEffect(scale: 0.94)
        .help(isExpanded ? "Collapse navigation" : "Expand navigation")
    }

    private var divider: some View {
        Rectangle()
            .fill(Theme.borderSubtle)
            .frame(width: 1)
            .padding(.horizontal, 8)
    }

    private var expandedControlsTransition: AnyTransition {
        if performanceProfile == .reducedEffects {
            return .opacity
        }
        return .opacity.combined(with: .scale(scale: 0.96, anchor: .leading))
    }

    private var pillBorder: some View {
        Capsule().strokeBorder(
            LinearGradient(
                colors: [.white.opacity(0.32), .white.opacity(0.07)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            lineWidth: 1
        )
    }

    private var pillBackground: some View {
        Group {
            if #available(macOS 26, *), performanceProfile.allowsExpensiveEffects {
                Color.clear
                    .glassEffect(.regular.tint(Color.black.opacity(isExpanded ? 0.34 : 0.42)), in: Capsule())
            } else {
                if performanceProfile.allowsExpensiveEffects {
                    PillBlurBackground()
                } else {
                    Capsule()
                        .fill(Theme.surface0.opacity(isExpanded ? 0.80 : 0.86))
                }
            }
        }
    }

    private func tabButton(_ dest: NavDestination) -> some View {
        let isSelected = dest == selected
        let color = Theme.destinationColor(dest)
        let isLocked = dest.requiresPro && !ProFeatureGate.canAccess(dest)

        return Button {
            select(dest)
        } label: {
            ZStack(alignment: .topTrailing) {
                VStack(spacing: 5) {
                    Image(systemName: dest.icon)
                        .font(.system(size: 19, weight: isSelected ? .bold : .semibold))
                        .foregroundStyle(isSelected ? color : .white.opacity(0.48))
                        .scaleEffect(isSelected && !reduceMotion ? 1.10 : 1)

                    Text(dest.rawValue)
                        .font(.system(size: 10, weight: isSelected ? .bold : .semibold))
                        .foregroundStyle(isSelected ? color : .white.opacity(0.42))
                        .lineLimit(1)
                }
                .frame(width: FloatingTabSwitcherMetrics.tabWidth, height: FloatingTabSwitcherMetrics.tabHeight)
                .background {
                    if isSelected {
                        if #available(macOS 26, *), performanceProfile.allowsExpensiveEffects {
                            Capsule()
                                .fill(.clear)
                                .glassEffect(.regular.tint(color.opacity(0.58)), in: Capsule())
                                .glassEffectID(dest.rawValue, in: namespace)
                        } else {
                            Capsule()
                                .fill(color.opacity(0.24))
                        }
                    }
                }
                .animation(performanceProfile == .reducedEffects ? nil : .easeOut(duration: 0.12), value: isSelected)

                if isLocked {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 9, weight: .heavy))
                        .foregroundStyle(Theme.surface0)
                        .frame(width: 17, height: 17)
                        .background(Theme.gold.opacity(0.95), in: Circle())
                        .offset(x: -4, y: 4)
                } else if let count = badge(dest) {
                    Text("\(count)")
                        .font(.system(size: 9, weight: .heavy))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(color, in: Capsule())
                        .offset(x: -4, y: 4)
                        .contentTransition(.numericText())
                        .animation(performanceProfile == .reducedEffects ? nil : .easeOut(duration: 0.12), value: count)
                }
            }
        }
        .buttonStyle(.plain)
        .pressEffect(scale: 0.95)
    }
}

private struct TabOpeningPlaceholder: View {
    let destination: NavDestination

    @Environment(\.performanceProfile) private var performanceProfile
    @State private var shimmerPhase: CGFloat = -1

    private var accent: Color {
        Theme.destinationColor(destination)
    }

    private var allowsAnimation: Bool {
        performanceProfile.allowsLoadingAnimation
    }

    var body: some View {
        VStack(spacing: 16) {
            placeholderHeader
            placeholderBody
        }
        .frame(maxWidth: AppShellSurfaceMetrics.appModalSurfaceWidth(for: AppStateManager.shared.windowSize))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.top, 18)
        .onAppear {
            guard allowsAnimation else { return }
            withAnimation(.linear(duration: 1.35).repeatForever(autoreverses: false)) {
                shimmerPhase = 1
            }
        }
    }

    private var placeholderHeader: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(accent.opacity(0.15))
                    .frame(width: 38, height: 38)
                Image(systemName: destination.icon)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(accent)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(destination.rawValue)
                    .font(.headline.weight(.bold))
                    .foregroundStyle(Theme.textPrimary)
                Text("Opening...")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
            }

            Spacer()

            ProgressView()
                .controlSize(.small)
                .scaleEffect(0.72)
                .tint(accent)
        }
        .padding(16)
        .background(Theme.obsidian.opacity(0.70), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(accent.opacity(0.16), lineWidth: 0.8)
        )
    }

    @ViewBuilder
    private var placeholderBody: some View {
        switch destination {
        case .feed:
            browserPlaceholder
        case .library:
            libraryPlaceholder
        case .settings:
            settingsPlaceholder
        case .home:
            EmptyView()
        }
    }

    private var browserPlaceholder: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                placeholderPill(width: 82, height: 26)
                placeholderPill(width: 116, height: 26)
                Spacer()
                placeholderPill(width: 34, height: 26)
                placeholderPill(width: 34, height: 26)
            }
            .padding(12)

            Rectangle()
                .fill(Theme.borderSubtle)
                .frame(height: 0.5)

            VStack(alignment: .leading, spacing: 14) {
                placeholderLine(width: 0.44, height: 18)
                placeholderLine(width: 0.78, height: 12)
                placeholderLine(width: 0.62, height: 12)
                Spacer()
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(height: AppShellSurfaceMetrics.browserSurfaceHeight(for: AppStateManager.shared.windowSize))
        .background(Theme.obsidian.opacity(0.62), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(accent.opacity(0.16), lineWidth: 0.8)
        )
    }

    private var libraryPlaceholder: some View {
        VStack(alignment: .leading, spacing: 12) {
            placeholderLine(width: 0.34, height: 22)
            placeholderLine(width: 0.58, height: 12)
            ForEach(0..<5, id: \.self) { index in
                HStack(spacing: 12) {
                    placeholderBlock(width: 70, height: 52)
                    VStack(alignment: .leading, spacing: 8) {
                        placeholderLine(width: index.isMultiple(of: 2) ? 0.48 : 0.64, height: 12)
                        placeholderLine(width: index.isMultiple(of: 2) ? 0.28 : 0.38, height: 10)
                    }
                    Spacer()
                    placeholderPill(width: 56, height: 22)
                }
                .padding(12)
                .background(Theme.obsidian.opacity(0.52), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
        .padding(18)
        .background(Theme.obsidian.opacity(0.62), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(accent.opacity(0.16), lineWidth: 0.8)
        )
    }

    private var settingsPlaceholder: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 220, maximum: 340), spacing: 12)], spacing: 12) {
            ForEach(0..<5, id: \.self) { index in
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        placeholderBlock(width: 32, height: 32)
                        Spacer()
                        placeholderPill(width: index == 0 ? 72 : 42, height: 20)
                    }
                    placeholderLine(width: index.isMultiple(of: 2) ? 0.62 : 0.44, height: 13)
                    placeholderLine(width: index.isMultiple(of: 2) ? 0.86 : 0.72, height: 10)
                }
                .padding(14)
                .frame(minHeight: 118, alignment: .topLeading)
                .background(Theme.obsidian.opacity(0.58), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Theme.borderSubtle, lineWidth: 0.8)
                )
            }
        }
    }

    private func placeholderLine(width: CGFloat, height: CGFloat) -> some View {
        GeometryReader { geo in
            placeholderBlock(width: max(geo.size.width * width, 1), height: height)
        }
        .frame(height: height)
    }

    private func placeholderPill(width: CGFloat, height: CGFloat) -> some View {
        placeholderBlock(width: width, height: height, cornerRadius: height / 2)
    }

    private func placeholderBlock(width: CGFloat, height: CGFloat, cornerRadius: CGFloat = 8) -> some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(Theme.surfaceGlass.opacity(0.58))
            .frame(width: width, height: height)
            .overlay {
                if allowsAnimation {
                    placeholderShimmer
                        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                }
            }
    }

    private var placeholderShimmer: some View {
        GeometryReader { geo in
            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [.clear, .white.opacity(0.08), .clear],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .frame(width: max(geo.size.width * 1.8, 1))
                .offset(x: shimmerPhase * geo.size.width * 1.8)
        }
        .allowsHitTesting(false)
    }
}

@MainActor
private final class DownloadQueueActiveCountProjection: ObservableObject {
    @Published private(set) var activeCount: Int

    private var cancellable: AnyCancellable?

    init(queue: DownloadQueue) {
        activeCount = queue.activeDownloadCount
        cancellable = queue.$queue
            .map { _ in queue.activeDownloadCount }
            .removeDuplicates()
            .sink { [weak self] count in
                self?.activeCount = count
            }
    }
}

private struct PillBlurBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        view.isEmphasized = true
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

private struct WindowConfigurator: NSViewRepresentable {
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        NSView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let window = nsView.window else { return }
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.styleMask.insert(.fullSizeContentView)
            window.backgroundColor = .clear
            window.isOpaque = false
            window.toolbar = nil
            context.coordinator.track(window)
        }
    }

    @MainActor
    final class Coordinator {
        private weak var trackedWindow: NSWindow?
        private var resizeObserver: NSObjectProtocol?

        deinit {
            if let resizeObserver {
                NotificationCenter.default.removeObserver(resizeObserver)
            }
        }

        func track(_ window: NSWindow) {
            guard trackedWindow !== window else {
                updateWindowSize(window)
                return
            }

            if let resizeObserver {
                NotificationCenter.default.removeObserver(resizeObserver)
            }

            trackedWindow = window
            updateWindowSize(window)
            resizeObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didResizeNotification,
                object: window,
                queue: .main
            ) { [weak self] notification in
                guard let window = notification.object as? NSWindow else { return }
                Task { @MainActor in
                    self?.updateWindowSize(window)
                }
            }
        }

        private func updateWindowSize(_ window: NSWindow) {
            let size = window.frame.size
            if AppStateManager.shared.windowSize != size {
                AppStateManager.shared.windowSize = size
            }
        }
    }
}
