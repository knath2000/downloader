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
    @Namespace private var tabSwitcherGlass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    private let floatingTabContentInset: CGFloat = 0

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
            contentForDestination(displayedDestination)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            FloatingTabSwitcher(
                destinations: sidebarDestinations,
                selected: displayedDestination,
                badge: { navBadge(for: $0) },
                namespace: tabSwitcherGlass,
                select: selectDestination
            )
            .padding(.bottom, 20)
            .zIndex(10)
        }
        .onAppear {
            NotificationManager.shared.requestAuthorization()
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

        withAnimation(performanceProfile == .reducedEffects ? nil : .easeOut(duration: 0.12)) {
            appState.select(destination)
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

private struct FloatingTabSwitcher: View {
    let destinations: [NavDestination]
    let selected: NavDestination
    let badge: (NavDestination) -> Int?
    let namespace: Namespace.ID
    let select: (NavDestination) -> Void

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

    var body: some View {
        HStack(spacing: 0) {
            ForEach(destinations, id: \.self) { dest in
                tabButton(dest)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .background { pillBackground }
        .clipShape(Capsule())
        .overlay(
            Capsule().strokeBorder(
                LinearGradient(
                    colors: [.white.opacity(0.30), .white.opacity(0.06)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                lineWidth: 1
            )
        )
        .shadow(color: .black.opacity(shadowOpacity), radius: shadowRadius, x: 0, y: shadowY)
    }

    private func tabButton(_ dest: NavDestination) -> some View {
        let isSelected = dest == selected
        let color = Theme.destinationColor(dest)
        let isLocked = dest.requiresPro && !ProFeatureGate.canAccess(dest)

        return Button {
            select(dest)
        } label: {
            ZStack(alignment: .topTrailing) {
                VStack(spacing: 3) {
                    Image(systemName: dest.icon)
                        .font(.system(size: 16, weight: isSelected ? .semibold : .regular))
                        .foregroundStyle(isSelected ? color : .white.opacity(0.45))
                        .scaleEffect(isSelected && !reduceMotion ? 1.08 : 1)

                    Text(dest.rawValue)
                        .font(.system(size: 9, weight: isSelected ? .semibold : .regular))
                        .foregroundStyle(isSelected ? color : .white.opacity(0.38))
                        .lineLimit(1)
                }
                .frame(width: 56, height: 44)
                .background {
                    if isSelected {
                        if #available(macOS 26, *), performanceProfile.allowsExpensiveEffects {
                            Capsule()
                                .fill(.clear)
                                .glassEffect(.regular.tint(color.opacity(0.5)), in: Capsule())
                                .glassEffectID(dest.rawValue, in: namespace)
                        } else {
                            Capsule()
                                .fill(color.opacity(0.20))
                        }
                    }
                }
                .animation(performanceProfile == .reducedEffects ? nil : .easeOut(duration: 0.12), value: isSelected)

                if isLocked {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 8, weight: .heavy))
                        .foregroundStyle(Theme.surface0)
                        .frame(width: 16, height: 16)
                        .background(Theme.gold.opacity(0.95), in: Circle())
                        .offset(x: -2, y: 2)
                } else if let count = badge(dest) {
                    Text("\(count)")
                        .font(.system(size: 8, weight: .heavy))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(color, in: Capsule())
                        .offset(x: -2, y: 2)
                        .contentTransition(.numericText())
                        .animation(performanceProfile == .reducedEffects ? nil : .easeOut(duration: 0.12), value: count)
                }
            }
        }
        .buttonStyle(.plain)
        .pressEffect(scale: 0.96)
    }

    @ViewBuilder
    private var pillBackground: some View {
        if #available(macOS 26, *), performanceProfile.allowsExpensiveEffects {
            Color.clear
                .glassEffect(.regular.tint(Color.black.opacity(0.3)), in: Capsule())
        } else {
            if performanceProfile.allowsExpensiveEffects {
                PillBlurBackground()
            } else {
                Capsule()
                    .fill(Theme.surface0.opacity(0.76))
            }
        }
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
