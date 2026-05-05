import SwiftUI

struct ContentView: View {
    @StateObject private var appState = AppStateManager.shared
    @StateObject private var downloadQueue = DownloadQueue.shared
    @StateObject private var updateManager = UpdateManager.shared
    @StateObject private var licenseManager = LicenseManager.shared
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

    var body: some View {
        ZStack {
            // Animated mesh gradient background
            MeshGradientBackground()
                .zIndex(-1)

            navigationBody
                .zIndex(0)

            if showUpgradeOverlay {
                UpgradeOverlay { showUpgradeOverlay = false }
                    .zIndex(1)
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
                ForEach(Array(NavDestination.allCases.enumerated()), id: \.element) { idx, dest in
                    SidebarNavItem(
                        dest: dest,
                        isSelected: appState.selectedDestination == dest,
                        badge: navBadge(for: dest),
                        namespace: sidebarGlass
                    ) {
                        appState.select(dest)
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
                             onUpgradeRequired: { showUpgradeOverlay = true })
                        .padding()
                case .library:
                    LibraryView()
                        .padding()
                case .history:
                    HistoryView()
                        .padding()
                case .downloads:
                    DownloadQueueViewNew(onUpgradeRequired: { showUpgradeOverlay = true })
                        .padding()
                case .mega:
                    MegaView(megaRemotePath: $megaRemotePath)
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
                                 seedboxWebdavPassword: $seedboxWebdavPassword)
                }
            }
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

    private func navBadge(for dest: NavDestination) -> Int? {
        switch dest {
        case .downloads:
            let q = downloadQueue.queue.filter { $0.isVisibleInDownloads && !$0.status.isTerminal }
            return q.isEmpty ? nil : q.count
        default:
            return nil
        }
    }

    private var upgradeButton: some View {
        Button {
            appState.select(.settings)
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
}

// MARK: - SidebarNavItem

private struct SidebarNavItem: View {
    let dest: NavDestination
    let isSelected: Bool
    let badge: Int?
    let namespace: Namespace.ID
    let action: () -> Void

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
