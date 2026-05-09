import AppKit
import Combine
import SwiftUI

struct ContentView: View {
    @StateObject private var appState = AppStateManager.shared
    @StateObject private var activeQueueBadge = DownloadQueueActiveCountProjection(queue: .shared)
    @StateObject private var favorites = FeedFavoritesStore.shared
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
    @Namespace private var tabSwitcherGlass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    private let floatingTabContentInset: CGFloat = 0

    private var performanceProfile: PerformanceProfile {
        reduceMotion || isLowPowerModeEnabled ? .reducedEffects : .normal
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
            if !favorites.hasFavorites && appState.selectedDestination == .favorites {
                appState.select(.feed)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name.NSProcessInfoPowerStateDidChange)) { _ in
            isLowPowerModeEnabled = ProcessInfo.processInfo.isLowPowerModeEnabled
        }
        .onChange(of: favorites.hasFavorites) { _, hasFavorites in
            if !hasFavorites && appState.selectedDestination == .favorites {
                appState.select(.feed)
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
            contentForDestination(appState.selectedDestination)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .transition(.opacity)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: appState.selectedDestination)

            FloatingTabSwitcher(
                destinations: sidebarDestinations,
                selected: appState.selectedDestination,
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
                .padding()
                .padding(.bottom, floatingTabContentInset)
        case .feed:
            FeedView()
                .padding()
                .padding(.bottom, floatingTabContentInset)
        case .favorites:
            FavoritesView()
                .padding()
                .padding(.bottom, floatingTabContentInset)
        case .files:
            RemoteFilesView(
                seedboxTransferMode: seedboxTransferMode,
                seedboxRemoteName: seedboxRemoteName,
                seedboxRemotePath: seedboxRemotePath,
                seedboxWebdavURL: seedboxWebdavURL,
                seedboxWebdavUser: seedboxWebdavUser,
                seedboxWebdavPassword: seedboxWebdavPassword
            )
            .padding()
            .padding(.bottom, floatingTabContentInset)
        case .profile:
            ProfileView()
                .padding()
                .padding(.bottom, floatingTabContentInset)
        case .settings:
            SettingsView(gdriveRemoteName: $gdriveRemoteName,
                         gdriveRemotePath: $gdriveRemotePath,
                         megaRemotePath: $megaRemotePath,
                         seedboxTransferMode: $seedboxTransferMode,
                         seedboxRemoteName: $seedboxRemoteName,
                         seedboxRemotePath: $seedboxRemotePath,
                         seedboxWebdavURL: $seedboxWebdavURL,
                         seedboxWebdavUser: $seedboxWebdavUser,
                         seedboxWebdavPassword: $seedboxWebdavPassword,
                         onUpgradeRequired: presentUpgradeOverlay)
                .padding()
                .padding(.bottom, floatingTabContentInset)
        }
    }

    private var sidebarDestinations: [NavDestination] {
        NavDestination.allCases.filter { destination in
            switch destination {
            case .favorites:
                return favorites.hasFavorites
            default:
                return true
            }
        }
    }

    private func navBadge(for dest: NavDestination) -> Int? {
        switch dest {
        case .home:
            return activeQueueBadge.activeCount == 0 ? nil : activeQueueBadge.activeCount
        case .favorites:
            return favorites.count == 0 ? nil : favorites.count
        default:
            return nil
        }
    }

    private func selectDestination(_ destination: NavDestination) {
        withAnimation(reduceMotion ? nil : .spring(response: 0.25, dampingFraction: 0.7)) {
            appState.select(destination)
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
                        if #available(macOS 26, *) {
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
                .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.72), value: isSelected)

                if let count = badge(dest) {
                    Text("\(count)")
                        .font(.system(size: 8, weight: .heavy))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(color, in: Capsule())
                        .offset(x: -2, y: 2)
                        .contentTransition(.numericText())
                        .animation(reduceMotion ? nil : .spring(response: 0.3), value: count)
                }
            }
        }
        .buttonStyle(.plain)
        .pressEffect(scale: 0.96)
    }

    @ViewBuilder
    private var pillBackground: some View {
        if #available(macOS 26, *) {
            Color.clear
                .glassEffect(.regular.tint(Color.black.opacity(0.3)), in: Capsule())
        } else {
            if performanceProfile == .normal {
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
        }
    }
}
