import SwiftUI

struct ContentView: View {
    @StateObject private var appState = AppStateManager.shared
    @StateObject private var downloadQueue = DownloadQueue.shared
    @StateObject private var updateManager = UpdateManager.shared
    @StateObject private var licenseManager = LicenseManager.shared
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
    @Namespace private var sidebarGlass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            // Animated mesh gradient background
            MeshGradientBackground()
                .zIndex(-1)

            navigationBody
                .zIndex(0)

            if showUpgradeOverlay {
                UpgradeOverlay { dismissUpgradeOverlay() }
                    .transition(.opacity)
                    .zIndex(1)
            }
        }
        .onAppear {
            if !favorites.hasFavorites && appState.selectedDestination == .favorites {
                appState.select(.feed)
            }
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
            splitView
                .backgroundExtensionEffect()
        } else {
            splitView
        }
    }

    private var splitView: some View {
        NavigationSplitView {
            // SIDEBAR — marketplace-style with colored icon bubbles
            VStack(spacing: 2) {
                ForEach(Array(sidebarDestinations.enumerated()), id: \.element) { idx, dest in
                    SidebarNavItem(
                        dest: dest,
                        isSelected: appState.selectedDestination == dest,
                        badge: navBadge(for: dest),
                        namespace: sidebarGlass
                    ) {
                        selectDestination(dest)
                    }
                    .scrollEntrance(delay: Double(idx) * 0.04)
                }
                Spacer()
                if !ProFeatureGate.isPro {
                    upgradeButton
                }
            }
            .padding(.horizontal, 6)
            .padding(.top, 8)
            .navigationSplitViewColumnWidth(min: 160, ideal: 180)
        } detail: {
            Group {
                switch appState.selectedDestination {
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
                case .library:
                    LibraryView(onUpgradeRequired: presentUpgradeOverlay)
                        .padding()
                case .feed:
                    FeedView()
                        .padding()
                case .favorites:
                    FavoritesView()
                        .padding()
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
                }
            }
            .transition(.opacity)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: appState.selectedDestination)
            .navigationTitle(appState.selectedDestination.rawValue)
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    HStack(spacing: 6) {
                        Button(action: { updateManager.checkForUpdates() }) {
                            Label(updateManager.currentVersion, systemImage: "arrow.triangle.2.circlepath")
                        }
                        .buttonStyle(.plain)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help("Current version — click to check for updates")
                    }
                }
            }
            .onAppear {
                NotificationManager.shared.requestAuthorization()
            }
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
            let q = downloadQueue.queue.filter {
                switch $0.status {
                case .downloading, .verifying, .uploading, .processing:
                    return true
                default:
                    return false
                }
            }
            return q.isEmpty ? nil : q.count
        case .favorites:
            return favorites.count == 0 ? nil : favorites.count
        default:
            return nil
        }
    }

    private var upgradeButton: some View {
        Button {
            selectDestination(.settings)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "crown.fill")
                    .foregroundStyle(Theme.gold)
                Text("Upgrade to Pro")
                    .font(.caption.bold())
                    .foregroundStyle(
                        LinearGradient(colors: [Theme.gold, Theme.amber], startPoint: .leading, endPoint: .trailing)
                    )
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .glassCard(tint: Theme.gold, cornerRadius: 10)
        .padding(.bottom, 8)
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

// MARK: - SidebarNavItem

private struct SidebarNavItem: View {
    let dest: NavDestination
    let isSelected: Bool
    let badge: Int?
    let namespace: Namespace.ID
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var destColor: Color { Theme.destinationColor(dest) }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                // Colored icon bubble
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(destColor.opacity(isSelected ? 0.35 : 0.18))
                        .frame(width: 30, height: 30)
                    Image(systemName: dest.icon)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(destColor)
                }

                Text(dest.rawValue)
                    .font(.system(.body, design: .default).weight(isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? Theme.textPrimary : Theme.textSecondary)

                Spacer()

                if let badge {
                    Text("\(badge)")
                        .font(.system(size: 10, weight: .heavy))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(destColor, in: Capsule())
                        .contentTransition(.numericText())
                        .animation(.spring(response: 0.3), value: badge)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(selectionBackground)
            .animation(reduceMotion ? nil : .spring(response: 0.25, dampingFraction: 0.7), value: isSelected)
        }
        .buttonStyle(.plain)
        .pressEffect(scale: 0.96)
    }

    @ViewBuilder
    private var selectionBackground: some View {
        if isSelected {
            if #available(macOS 26, *) {
                Capsule()
                    .fill(.clear)
                    .glassEffect(.regular.tint(destColor), in: Capsule())
                    .glassEffectID(dest.rawValue, in: namespace)
            } else {
                Capsule()
                    .fill(destColor.opacity(0.18))
            }
        } else {
            Color.clear
        }
    }
}
