import SwiftUI

extension String {
    /// Extract a percentage value from a string ending with "XX%".
    func parsePercent() -> Double? {
        guard let m = try? NSRegularExpression(pattern: "(\\d+)%$").firstMatch(in: self, range: NSRange(self.startIndex..., in: self)),
              let r = Range(m.range(at: 1), in: self) else { return nil }
        return Double(self[r])
    }
}

struct HomeView: View {
    @ObservedObject var appState: AppStateManager
    @ObservedObject private var tracker = ActiveWorkTracker.shared
    @State private var urlText: String = ""
    @State private var results: [ExtractResult] = []
    @State private var isLoading = false
    @State private var loadProgress = ""
    var megaRemotePath: String
    var gdriveRemoteName: String
    var gdriveRemotePath: String
    let onUpgradeRequired: () -> Void

    var urlLines: [String] {
        urlText
            .split(separator: "\n")
            .map { String($0) }
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    var batchTargetLinks: [String] {
        results.compactMap { $0.source?.mp4 }.filter { tracker.localDownloads[$0] == nil }
    }

    @FocusState private var urlFieldFocused: Bool
    @State private var activeTab: Int = 0

    // Category rail items — quick-paste shortcuts for common platforms
    private let categoryItems: [CategoryIconRail.Item] = [
        .init(id: "youtube",     icon: "play.rectangle.fill",       label: "YouTube",    color: Theme.taoRed),
        .init(id: "tiktok",      icon: "music.note",                label: "TikTok",     color: Theme.hotPink),
        .init(id: "twitter",     icon: "bird.fill",                 label: "Twitter/X",  color: Theme.skyBlue),
        .init(id: "vimeo",       icon: "film.fill",                 label: "Vimeo",      color: Theme.skyBlue),
        .init(id: "twitch",      icon: "gamecontroller.fill",       label: "Twitch",     color: Theme.lavender),
        .init(id: "reddit",      icon: "bubble.left.and.bubble.right.fill", label: "Reddit", color: Theme.coral),
        .init(id: "mega",        icon: "cloud.fill",                label: "Mega",       color: Theme.hotPink),
        .init(id: "other",       icon: "link",                      label: "Any URL",    color: Theme.amber),
    ]

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {

                // ── HEADER ───────────────────────────────────────────────
                HStack(alignment: .center, spacing: 10) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Theme.coral.opacity(0.2))
                            .frame(width: 36, height: 36)
                        Image(systemName: "photo.on.rectangle.angled")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(Theme.coral)
                    }
                    .bounceOnAppear(delay: 0)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Video Downloader")
                            .font(Theme.marketplaceTitle)
                            .foregroundStyle(
                                LinearGradient(colors: [Theme.gold, Theme.coral],
                                               startPoint: .leading, endPoint: .trailing)
                            )
                        HStack(spacing: 6) {
                            if ScraperEngine.isYTDLPAvailable {
                                PulsingDot(color: Theme.electricLime, size: 6)
                                CartoonBadge(label: "yt-dlp ready", color: Theme.electricLime.opacity(0.9))
                                    .bounceOnAppear(delay: 0.1)
                            } else {
                                CartoonBadge(label: "Install yt-dlp", color: Theme.taoRed, animated: true)
                            }
                        }
                    }

                    Spacer()

                    if ProFeatureGate.isPro {
                        CartoonBadge(label: "PRO", color: Theme.gold)
                            .bounceOnAppear(delay: 0.15)
                    }
                }
                .padding(.horizontal)
                .padding(.top, 12)
                .padding(.bottom, 10)
                .scrollEntrance(delay: 0)

                // ── CATEGORY ICON RAIL ───────────────────────────────────
                CategoryIconRail(items: categoryItems) { item in
                    let placeholder = "https://\(item.id).com/"
                    if !urlText.isEmpty { urlText += "\n" + placeholder }
                    else { urlText = placeholder }
                }
                .scrollEntrance(delay: 0.05)

                Divider()
                    .background(Theme.border)
                    .padding(.vertical, 8)

                // ── URL INPUT SECTION ────────────────────────────────────
                TaobaoSectionHeader(title: "Paste URLs", accentColor: Theme.coral)
                    .scrollEntrance(delay: 0.08)

                VStack(alignment: .leading, spacing: 6) {
                    TextEditor(text: $urlText)
                        .frame(height: 64)
                        .font(.system(size: 11, design: .monospaced).weight(.medium))
                        .foregroundStyle(Theme.textPrimary)
                        .scrollContentBackground(.hidden)
                        .background(.clear)
                        .focused($urlFieldFocused)
                        .padding(10)
                        .glassCard(tint: Theme.coral.opacity(urlFieldFocused ? 0.45 : 0.15),
                                   cornerRadius: 12)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(Theme.coral.opacity(urlFieldFocused ? 0.65 : 0),
                                        lineWidth: 1.5)
                        )
                        .animation(.easeInOut(duration: 0.2), value: urlFieldFocused)
                        .padding(.horizontal)

                    // Action row
                    HStack(spacing: 8) {
                        MarketplaceButton(title: "Extract All", icon: "bolt.fill",
                                         prominent: true, action: extractAll)
                            .keyboardShortcut(.return, modifiers: .command)
                            .disabled(isLoading || urlLines.isEmpty)
                            .opacity(isLoading || urlLines.isEmpty ? 0.5 : 1)
                            .pressEffect()

                        Button(action: pasteFromClipboard) {
                            Label("Paste", systemImage: "clipboard")
                        }
                        .buttonStyle(.bordered)
                        .pressEffect(scale: 0.93)

                        Button(action: { urlText = "" }) {
                            Label("Clear", systemImage: "xmark")
                        }
                        .buttonStyle(.bordered)
                        .pressEffect(scale: 0.93)
                    }
                    .padding(.horizontal)
                }
                .scrollEntrance(delay: 0.1)

                // ── LOADING STATE ─────────────────────────────────────────
                if isLoading {
                    VStack(spacing: 8) {
                        GradientProgressBar(progress: 0.6)
                            .padding(.horizontal)

                        HStack(spacing: 8) {
                            PulsingDot(color: Theme.coral, size: 7)
                            Text(loadProgress.isEmpty ? "Extracting…" : loadProgress)
                                .font(.caption.weight(.medium))
                                .foregroundStyle(Theme.textSecondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal)

                        // Shimmer skeleton placeholders
                        VStack(spacing: 8) {
                            ForEach(0..<3, id: \.self) { i in
                                ShimmerCard(height: 68)
                                    .padding(.horizontal)
                                    .scrollEntrance(delay: Double(i) * 0.07)
                            }
                        }
                    }
                    .padding(.vertical, 8)
                    .transition(.opacity)
                }

                // ── RESULTS ───────────────────────────────────────────────
                if !results.isEmpty {
                    VStack(spacing: 0) {
                        // Section header with flip counter
                        HStack {
                            TaobaoSectionHeader(
                                title: "Results",
                                accentColor: Theme.coral
                            )
                            Spacer()
                            HStack(spacing: 4) {
                                FlipCounter(count: results.count, label: "found",
                                            color: Theme.coral)
                            }
                            .padding(.trailing)
                        }
                        .scrollEntrance(delay: 0)

                        LazyVStack(spacing: 10) {
                            ForEach(Array(results.enumerated()), id: \.offset) { idx, result in
                                glassResultCard(for: result)
                                    .scrollEntrance(delay: Double(idx) * 0.06)
                                    .pressEffect(scale: 0.98)
                            }
                        }
                        .padding(.horizontal)
                        .padding(.bottom, 8)
                    }

                    // ── BATCH DOWNLOAD ────────────────────────────────────
                    if !batchTargetLinks.isEmpty {
                        VStack(spacing: 6) {
                            Divider().padding(.horizontal)

                            if tracker.isBatchDownloading {
                                HStack(spacing: 8) {
                                    PulsingDot(color: Theme.electricLime)
                                    Text(loadProgress)
                                        .font(.caption)
                                        .foregroundStyle(Theme.textSecondary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal)
                            }

                            HStack(spacing: 8) {
                                FlipCounter(count: batchTargetLinks.count, label: "queued",
                                            color: Theme.electricLime)
                                    .padding(.leading)
                                Spacer()
                            }

                            MarketplaceButton(
                                title: "Download All to Local",
                                icon: "arrow.down.circle.fill",
                                action: batchDownloadAll
                            )
                            .disabled(tracker.isBatchDownloading)
                            .opacity(tracker.isBatchDownloading ? 0.5 : 1)
                            .pressEffect()
                            .padding(.horizontal)
                            .padding(.bottom, 8)
                        }
                        .scrollEntrance(delay: 0.1)
                    }

                } else if !isLoading {
                    // ── EMPTY STATE ───────────────────────────────────────
                    VStack(spacing: 14) {
                        Text("🎬")
                            .font(.system(size: 52))
                            .bounceOnAppear(delay: 0.1)

                        Text("Drop a URL and smash Extract")
                            .font(Theme.sectionHeader)
                            .foregroundStyle(Theme.textSecondary)
                            .multilineTextAlignment(.center)

                        HStack(spacing: 8) {
                            CartoonBadge(label: "Cmd+Return", color: Theme.skyBlue)
                                .bounceOnAppear(delay: 0.2)
                            CartoonBadge(label: "1700+ sites", color: Theme.electricLime)
                                .bounceOnAppear(delay: 0.3)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 32)
                    .padding(.bottom, 20)
                    .scrollEntrance(delay: 0.15)
                }
            }
        }
        .onAppear {
            if let pending = appState.pendingExtractURL {
                urlText = pending
                appState.pendingExtractURL = nil
            } else if let clip = ClipboardManager.currentURL,
                      ClipboardManager.isLikelyVideoURL(clip) {
                urlText = clip
            }
        }
        .onChange(of: appState.pendingExtractURL) { _, newValue in
            if let url = newValue {
                urlText = url
                appState.pendingExtractURL = nil
            }
        }
    }

    // ===== GLASS RESULT CARD =====
    @ViewBuilder
    private func glassResultCard(for result: ExtractResult) -> some View {
        let accentColor = siteAccentColor(for: result.url)
        let mp4Key = result.source?.mp4 ?? ""
        let hlsKey = result.source?.hls.first?.url ?? ""
        let key = mp4Key.isEmpty ? hlsKey : mp4Key

        HStack(spacing: 0) {
            ColoredAccentStrip(color: accentColor)

            VideoResultRow(
                result: result,
                localState: tracker.localDownloads[key],
                megaState: tracker.megaUploads[key],
                gdriveState: tracker.gdriveUploads[key],
                onLocal: { url in Task { await startDownload(url: url, cloud: .local) } },
                onMega: { url in Task { await startDownload(url: url, cloud: .mega) } },
                onGDrive: { url in Task { await startDownload(url: url, cloud: .gdrive) } }
            )
        }
        .glassCard(tint: accentColor.opacity(0.3), cornerRadius: 14)
        .overlay(alignment: .topTrailing) {
            badgeForResult(result, key: key)
                .offset(x: 8, y: -8)
                .zIndex(1)
        }
    }

    @ViewBuilder
    private func badgeForResult(_ result: ExtractResult, key: String) -> some View {
        if let state = tracker.localDownloads[key] {
            switch state {
            case .uploading: CartoonBadge(label: "Downloading", color: Theme.coral, animated: true)
            case .done:      CartoonBadge(label: "Done", color: Theme.success)
            case .failed:    CartoonBadge(label: "Failed", color: Theme.taoRed)
            }
        } else if result.error != nil {
            CartoonBadge(label: "Error", color: Theme.taoRed)
        } else if result.source != nil {
            CartoonBadge(label: "Ready", color: Theme.electricLime)
        }
    }

    // ===== ACTIONS =====
    private func pasteFromClipboard() {
        if let clip = ClipboardManager.currentURL {
            if !urlText.isEmpty { urlText += "\n" + clip } else { urlText = clip }
        }
    }

    private func extractAll() {
        let urls = urlLines
        results = []
        isLoading = true
        loadProgress = ""
        tracker.clear(except: Set(tracker.megaUploads.keys).union(tracker.gdriveUploads.keys))
        loadProgress = "Extracting \(urls.count) URL(s)…"

        Task {
            var completed = 0
            var localResults: [Int: ExtractResult] = [:]

            await withTaskGroup(of: (Int, ExtractResult).self) { group in
                for (i, url) in urls.enumerated() {
                    group.addTask {
                        var src: VideoSource?; var err: String?
                        do { src = try await ScraperEngine.extract(from: url) }
                        catch { err = error.localizedDescription }
                        return (i, ExtractResult(url: url, source: src, error: err))
                    }
                }
                for await (idx, res) in group {
                    localResults[idx] = res; completed += 1
                    await MainActor.run { loadProgress = "Extracting… \(completed)/\(urls.count)" }
                }
            }

            var ordered: [ExtractResult] = []
            for i in 0 ..< urls.count { if let r = localResults[i] { ordered.append(r) } }
            results = ordered

            // Add to library
            for r in ordered {
                if let src = r.source {
                    let title = src.title ?? URL(string: r.url)?.pathComponents.last?.replacingOccurrences(of: "-", with: " ").capitalized ?? r.url
                    VideoLibrary.shared.addIfNew(LibraryItem(url: r.url, title: title, mp4Url: src.mp4, hlsUrls: src.hls))
                    HistoryManager.shared.record(url: r.url, source: src)
                }
            }
            NotificationManager.shared.notifyScrapeComplete(count: ordered.filter { $0.source != nil }.count)

            isLoading = false; loadProgress = ""
        }
    }

    private func batchDownloadAll() {
        let links = batchTargetLinks
        guard !links.isEmpty else { return }
        guard LicenseManager.shared.canStartDownload(count: links.count) else {
            onUpgradeRequired()
            return
        }
        let jobs = links.map { url in
            (url: url, title: title(for: url), displayName: displayName(for: url), uploadFileName: uploadFileName(for: url))
        }
        tracker.isBatchDownloading = true
        loadProgress = "Downloading 0/\(links.count)…"

        Task {
            let semaphore = DispatchSemaphore(value: 3)

            await withTaskGroup(of: (String, String, Bool, String?).self) { group in
                for job in jobs {
                    group.addTask {
                        semaphore.wait(); defer { semaphore.signal() }
                        do {
                            let result = try await MegaManager.upload(url: job.url, remotePath: megaRemotePath, title: job.title) { event in
                                Task { @MainActor in
                                    tracker.localDownloads[job.url] = .uploading("\(job.displayName) — \(event.message)")
                                }
                            }
                            Task { @MainActor in tracker.megaFilenames[job.url] = result.remotePath }
                            return (job.url, job.uploadFileName, true, nil)
                        } catch {
                            return (job.url, job.uploadFileName, false, error.localizedDescription)
                        }
                    }
                }

                var done = 0
                for await (url, uploadFileName, ok, err) in group {
                    done += 1
                    if ok {
                        LicenseManager.shared.recordSuccessfulDownload()
                        tracker.localDownloads[url] = .done("Uploaded to \(megaRemotePath)")
                        if results.first(where: { $0.source?.mp4 == url })?.source != nil {
                            NotificationManager.shared.notifyUploadComplete(filename: uploadFileName, destination: megaRemotePath)
                        }
                    } else {
                        tracker.localDownloads[url] = .failed(err ?? "Unknown")
                        NotificationManager.shared.notifyUploadFailed(filename: uploadFileName, reason: err ?? "Unknown")
                    }
                    await MainActor.run { loadProgress = "Downloading… \(done)/\(links.count)" }
                }
            }

            tracker.isBatchDownloading = false; loadProgress = ""
        }
    }

    private func startDownload(url: String, cloud: CloudTarget) async {
        let result = results.first { r in
            r.source?.mp4 == url || r.source?.hls.contains(where: { $0.url == url }) == true
        }
        guard let result = result, var source = result.source else { return }
        let title = source.title ?? fileName(of: url)
        if !LicenseManager.shared.canStartDownload() {
            if !LicenseManager.shared.activationEmail.isEmpty {
                _ = await LicenseManager.shared.refreshLicense()
            }
            guard LicenseManager.shared.canStartDownload() else {
                onUpgradeRequired()
                return
            }
        }
        let isHLS = url.contains(".m3u8")
        // A quality entry with kind .direct has a pre-resolved URL — don't treat it as a yt-dlp
        // site even if source.mp4 is nil (e.g. Playmogo, whose mp4 field is intentionally nil so
        // that batch-download paths don't skip per-URL headers).
        let qualityKind = source.hls.first(where: { $0.url == url })?.kind
        let isYtDlpSite = source.mp4 == nil && !isHLS && qualityKind != .direct

        // Look up any custom headers that came with this quality entry (e.g. LuluStream referer)
        let hlsHeaders = source.hls.first(where: { $0.url == url })?.headers

        // For .pageUrl entries (e.g. StreamTape/MixDrop/DoodStream from ProviderLink),
        // try native extraction via ScraperEngine first before falling back to yt-dlp.
        let qualityEntry = source.hls.first(where: { $0.url == url })
        let nativeCandidates = uniqueCandidates([qualityEntry?.sourcePageUrl, url])
        var resolvedUrl: String? = nil
        if qualityEntry?.kind == .pageUrl && isYtDlpSite {
            for candidate in nativeCandidates {
                if let resolved = try? await ScraperEngine.extract(from: candidate),
                   resolved.mp4 != nil || !resolved.hls.isEmpty {
                    source = resolved
                    resolvedUrl = resolved.mp4 ?? resolved.hls.first(where: { $0.kind != .pageUrl })?.url
                    break
                }
            }
        }

        if qualityEntry?.kind == .pageUrl, isProviderHost(qualityEntry?.sourcePageUrl ?? url), resolvedUrl == nil {
            NotificationManager.shared.notifyUploadFailed(filename: title, reason: "Provider URL could not be resolved: \(url)")
            return
        }

        // Determine final URL and whether we're still going through yt-dlp
        let finalUrl: String
        let stillYtDlp: Bool
        if let resolved = resolvedUrl {
            finalUrl = resolved
            stillYtDlp = false
        } else {
            finalUrl = url
            stillYtDlp = isYtDlpSite
        }

        // Look up any custom headers that came with this quality entry (e.g. LuluStream referer)
        let finalHlsHeaders = source.hls.first(where: { $0.url == url })?.headers

        if cloud == .local {
            let isAudio = source.isAudio
            let key = "\(url.hashValue)"
            let qualityLabel = isHLS ? "HLS" : (isAudio ? "Audio" : (stillYtDlp ? "yt-dlp" : "Video"))

            // Create queue item
            let queueId = DownloadQueue.shared.add(url: url, quality: qualityLabel, targetCloud: .local, displayTitle: title)

            if isHLS {
                tracker.localDownloads[key] = .uploading("Downloading HLS…")
            } else if stillYtDlp {
                tracker.localDownloads[key] = .uploading("Downloading via yt-dlp…")
            } else if isAudio {
                tracker.localDownloads[key] = .uploading("Downloading audio…")
            } else {
                tracker.localDownloads[key] = .uploading("Downloading…")
            }

            Task {
                do {
                    let destFile: URL
                    if stillYtDlp {
                        DownloadQueue.shared.updateProgress(id: queueId, status: .downloading, progress: 0)
                        destFile = try await DownloadManager.shared.downloadViaYTDLPSite(
                            pageUrl: finalUrl, title: title,
                            onProgress: { msg in
                                Task { @MainActor in tracker.localDownloads[key] = .uploading(msg) }
                            })
                    } else if isHLS {
                        let hlsSource = source.hls.first(where: { $0.url == url })
                        destFile = try await DownloadManager.shared.downloadHLS(
                            m3u8Url: finalUrl, title: title, headers: finalHlsHeaders,
                            sourcePageUrl: hlsSource?.sourcePageUrl,
                            onProgress: { event in
                                updateQueue(id: queueId, status: .downloading, progress: event.phase == .completing ? 99 : event.percent)
                                Task { @MainActor in tracker.localDownloads[key] = .uploading(event.message) }
                            }
                        )
                    } else if isAudio {
                        DownloadQueue.shared.updateProgress(id: queueId, status: .downloading, progress: 0)
                        destFile = try await DownloadManager.shared.downloadAudio(
                            pageUrl: finalUrl, title: title,
                            onProgress: { msg in
                                Task { @MainActor in tracker.localDownloads[key] = .uploading(msg) }
                            }
                        )
                    } else {
                        DownloadQueue.shared.updateProgress(id: queueId, status: .downloading, progress: 0)
                        let delegate = QueueDownloadProgressDelegate(
                            queueId: queueId,
                            onProgress: { pct in updateQueue(id: queueId, status: .downloading, progress: pct) }
                        )
                        destFile = try await DownloadManager.shared.downloadDirectWithDelegate(
                            url: finalUrl, title: title, headers: finalHlsHeaders, delegate: delegate
                        )
                    }
                    if !isAudio {
                        updateQueue(id: queueId, status: .downloading, progress: 99)
                        Task { @MainActor in tracker.localDownloads[key] = .uploading("Verifying video…") }
                        try await VideoProcessor.verifyForUpload(destFile)
                    }
                    // Update library with local path
                    let libraryItem = libraryItem(for: result)
                    VideoLibrary.shared.updateRemotePaths(for: libraryItem, cloud: .local, path: destFile.path)
                    Task { @MainActor in
                        DownloadQueue.shared.updateProgress(id: queueId, status: .completed, progress: 100)
                        if var idx = DownloadQueue.shared.queue.firstIndex(where: { $0.id == queueId }) {
                            DownloadQueue.shared.queue[idx].finalPath = destFile.path
                            DownloadQueue.shared.save()
                        }
                        LicenseManager.shared.recordSuccessfulDownload()
                        tracker.localDownloads[key] = .done("Saved to \(destFile.lastPathComponent)")
                        NSWorkspace.shared.activateFileViewerSelecting([destFile])
                        NotificationManager.shared.notifyUploadComplete(filename: destFile.lastPathComponent, destination: "Local")
                    }
                } catch {
                    Task { @MainActor in
                        saveFailedProgress(id: queueId, error: error)
                        tracker.localDownloads[key] = .failed(error.localizedDescription)
                        NotificationManager.shared.notifyUploadFailed(filename: title, reason: error.localizedDescription)
                    }
                }
            }
        } else if cloud == .mega {
            guard MegaManager.isAvailable else { tracker.megaUploads[url] = .failed("No Mega CLI"); return }
            guard MegaManager.isLoggedIn else { tracker.megaUploads[url] = .failed("Not logged in"); return }
            let key = "\(url.hashValue)"
            let queueId = DownloadQueue.shared.add(url: url, quality: "HLS → Mega", targetCloud: .mega, displayTitle: title)

            if isHLS {
                tracker.megaUploads[key] = .uploading("Materializing HLS…")
                Task {
                    do {
                        let hlsSource = source.hls.first(where: { $0.url == url })
                        let mp4File = try await DownloadManager.shared.downloadHLS(
                            m3u8Url: finalUrl, title: title, headers: finalHlsHeaders,
                            sourcePageUrl: hlsSource?.sourcePageUrl,
                            onProgress: { event in
                                updateQueue(id: queueId, status: .downloading, progress: event.phase == .completing ? 99 : event.percent)
                                Task { @MainActor in tracker.megaUploads[key] = .uploading(event.message) }
                            })
                        let uploadResult = try await MegaManager.uploadLocalFile(mp4File, remotePath: megaRemotePath, uploadID: queueId) { event in
                            updateQueue(id: queueId, status: queueStatus(for: event), progress: event.percent)
                            Task { @MainActor in tracker.megaUploads[key] = .uploading(event.message) }
                        }
                        Task { @MainActor in
                            let uploadedName = uploadResult.remotePath.split(separator: "/").last.map(String.init) ?? mp4File.lastPathComponent
                            try? FileManager.default.removeItem(at: mp4File)
                            HistoryManager.shared.recordCompletedUpload(url: url, source: source, destination: "Mega", remotePath: uploadResult.remotePath)
                            DownloadQueue.shared.remove(id: queueId)
                            LicenseManager.shared.recordSuccessfulDownload()
                            tracker.megaUploads[key] = .done("Uploaded to \(megaRemotePath)")
                            tracker.megaFilenames[key] = uploadResult.remotePath
                            NotificationManager.shared.notifyUploadComplete(filename: uploadedName, destination: megaRemotePath)
                        }
                    } catch {
                        Task { @MainActor in
                            saveFailedProgress(id: queueId, error: error)
                            tracker.megaUploads[key] = .failed(error.localizedDescription)
                            NotificationManager.shared.notifyUploadFailed(filename: title, reason: error.localizedDescription)
                        }
                    }
                }
            } else {
                tracker.megaUploads[key] = .uploading("Downloading... 0%")
                Task {
                    do {
                        updateQueue(id: queueId, status: .downloading, progress: 0)
                        let uploadResult = try await MegaManager.upload(url: finalUrl, remotePath: megaRemotePath, title: title, headers: finalHlsHeaders, uploadID: queueId) { event in
                            updateQueue(id: queueId, status: queueStatus(for: event), progress: event.percent)
                            Task { @MainActor in tracker.megaUploads[key] = .uploading(event.message) }
                        }
                        Task { @MainActor in
                            HistoryManager.shared.recordCompletedUpload(url: url, source: source, destination: "Mega", remotePath: uploadResult.remotePath)
                            DownloadQueue.shared.remove(id: queueId)
                            LicenseManager.shared.recordSuccessfulDownload()
                            tracker.megaUploads[key] = .done("Uploaded to \(megaRemotePath)")
                            tracker.megaFilenames[key] = uploadResult.remotePath
                            NotificationManager.shared.notifyUploadComplete(filename: uploadFileName(for: url), destination: megaRemotePath)
                        }
                    } catch {
                        Task { @MainActor in
                            DownloadQueue.shared.updateProgress(id: queueId, status: .failed(error.localizedDescription), progress: 0)
                            tracker.megaUploads[key] = .failed(error.localizedDescription)
                            NotificationManager.shared.notifyUploadFailed(filename: uploadFileName(for: url), reason: error.localizedDescription)
                        }
                    }
                }
            }
        } else {
            guard GDriveManager.isAvailable else { tracker.gdriveUploads[url] = .failed("rclone not installed"); return }
            let key = "\(url.hashValue)"
            let megaRemote = tracker.megaFilenames[url]
            let queueId = DownloadQueue.shared.add(url: url, quality: gdriveTargetLabel(isHLS), targetCloud: .gdrive, displayTitle: title)

            if isHLS {
                tracker.gdriveUploads[key] = .uploading("Materializing HLS…")
                Task {
                    do {
                        let hlsSource = source.hls.first(where: { $0.url == url })
                        updateQueue(id: queueId, status: .downloading, progress: 0)
                        let mp4File = try await DownloadManager.shared.downloadHLS(
                            m3u8Url: finalUrl, title: title, headers: finalHlsHeaders,
                            sourcePageUrl: hlsSource?.sourcePageUrl,
                            onProgress: { event in
                                updateQueue(id: queueId, status: event.phase == .completing ? .completed : .downloading, progress: event.percent)
                                Task { @MainActor in tracker.gdriveUploads[key] = .uploading(event.message) }
                            })
                        try await GDriveManager.uploadLocalFile(mp4File, remoteName: gdriveRemoteName, remotePath: gdriveRemotePath) { event in
                            updateQueue(id: queueId, status: event.phase == .completing ? .completed : .uploading, progress: event.percent)
                            Task { @MainActor in tracker.gdriveUploads[key] = .uploading(event.message) }
                        }
                        if let megaPath = megaRemote {
                            try? await MegaManager.delete(remotePath: megaPath)
                            Task { @MainActor in tracker.megaFilenames.removeValue(forKey: megaPath) }
                        }
                        try? FileManager.default.removeItem(at: mp4File)
                        Task { @MainActor in
                            DownloadQueue.shared.updateProgress(id: queueId, status: .completed, progress: 100)
                            let destPath = "\(gdriveRemoteName):\(gdriveRemotePath)\(mp4File.lastPathComponent)"
                            if var idx = DownloadQueue.shared.queue.firstIndex(where: { $0.id == queueId }) {
                                DownloadQueue.shared.queue[idx].finalPath = destPath
                                DownloadQueue.shared.save()
                            }
                            LicenseManager.shared.recordSuccessfulDownload()
                            tracker.gdriveUploads[key] = .done("Uploaded to GDrive")
                            NotificationManager.shared.notifyUploadComplete(filename: mp4File.lastPathComponent, destination: gdriveRemotePath)
                        }
                    } catch {
                        Task { @MainActor in
                            DownloadQueue.shared.updateProgress(id: queueId, status: .failed(error.localizedDescription), progress: 0)
                            tracker.gdriveUploads[key] = .failed(error.localizedDescription)
                            NotificationManager.shared.notifyUploadFailed(filename: title, reason: error.localizedDescription)
                        }
                    }
                }
            } else {
                tracker.gdriveUploads[key] = .uploading("Downloading… 0%")
                Task {
                    do {
                        DownloadQueue.shared.updateProgress(id: queueId, status: .downloading, progress: 0)
                        let uploadedPath = try await GDriveManager.upload(url: finalUrl, remoteName: gdriveRemoteName, remotePath: gdriveRemotePath, title: title, headers: finalHlsHeaders) { msg in
                            Task { @MainActor in tracker.gdriveUploads[key] = .uploading(msg) }
                        }
                        if let megaPath = megaRemote {
                            try? await MegaManager.delete(remotePath: megaPath)
                            Task { @MainActor in tracker.megaFilenames.removeValue(forKey: megaPath) }
                        }
                        Task { @MainActor in
                            DownloadQueue.shared.updateProgress(id: queueId, status: .completed, progress: 100)
                            let destPath = uploadedPath
                            if var idx = DownloadQueue.shared.queue.firstIndex(where: { $0.id == queueId }) {
                                DownloadQueue.shared.queue[idx].finalPath = destPath
                                DownloadQueue.shared.save()
                            }
                            LicenseManager.shared.recordSuccessfulDownload()
                            tracker.gdriveUploads[key] = .done("Uploaded to GDrive")
                            NotificationManager.shared.notifyUploadComplete(filename: uploadFileName(for: url), destination: gdriveRemotePath)
                        }
                    } catch {
                        Task { @MainActor in
                            DownloadQueue.shared.updateProgress(id: queueId, status: .failed(error.localizedDescription), progress: 0)
                            tracker.gdriveUploads[key] = .failed(error.localizedDescription)
                            NotificationManager.shared.notifyUploadFailed(filename: uploadFileName(for: url), reason: error.localizedDescription)
                        }
                    }
                }
            }
        }
    }

    private func libraryItem(for result: ExtractResult) -> LibraryItem {
        let title = result.source?.title ?? URL(string: result.url)?.pathComponents.last?.replacingOccurrences(of: "-", with: " ").capitalized ?? result.url
        let existing = VideoLibrary.shared.items.first(where: { $0.url == result.url })
        if let existing { return existing }
        let newItem = LibraryItem(url: result.url, title: title, mp4Url: result.source?.mp4, hlsUrls: result.source?.hls ?? [])
        VideoLibrary.shared.add(newItem)
        return newItem
    }

    private func gdriveTargetLabel(_ isHLS: Bool) -> String {
        isHLS ? "HLS → GDrive" : "GDrive"
    }

    private func fileName(of url: String) -> String {
        (url.split(separator: "/").last.map { String($0) }) ?? url
    }

    private func title(for url: String) -> String? {
        results.first {
            $0.source?.mp4 == url || $0.source?.hls.contains(where: { $0.url == url }) == true
        }?.source?.title
    }

    private func displayName(for url: String) -> String {
        title(for: url) ?? fileName(of: url)
    }

    private func uploadFileName(for url: String) -> String {
        VideoFileNaming.mp4FileName(title: title(for: url), fallback: fileName(of: url))
    }

    private func uniqueCandidates(_ candidates: [String?]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for candidate in candidates.compactMap({ $0 }) {
            if seen.insert(candidate).inserted {
                result.append(candidate)
            }
        }
        return result
    }

    private func isProviderHost(_ urlString: String) -> Bool {
        guard let host = URL(string: urlString)?.host?.lowercased() else { return false }
        return [
            "streamtape.com", "streamtape.net",
            "mixdrop.ag", "mixdrop.co", "mixdrop.sx", "mixdrop.pw", "m1xdrop.click",
            "doodstream.com", "doodstream.org", "dood.wf", "dood.pm", "dood.la", "dood.to", "dood.sh", "dood.ws", "dood.one", "dood.watch", "playmogo.com"
        ].contains(host)
    }

    private func parsePercent(from msg: String) -> Double? {
        if let m = try? NSRegularExpression(pattern: "(\\d+)%$").firstMatch(in: msg, range: NSRange(msg.startIndex..., in: msg)),
           let r = Range(m.range(at: 1), in: msg) {
            return Double(msg[r])
        }
        return nil
    }

    /// Main-actor-safe queue progress update.
    private func updateQueue(id: UUID, status: QueueStatus, progress: Double) {
        Task { @MainActor in
            DownloadQueue.shared.updateProgress(id: id, status: status, progress: progress)
        }
    }

    private func queueStatus(for event: ProgressEvent) -> QueueStatus {
        switch event.phase {
        case .downloading: return .downloading
        case .verifying: return .verifying
        case .uploading: return .uploading
        case .completing: return .completed
        }
    }

    /// Save last known progress on failure so the Downloads tab doesn't reset to 0.
    private func saveFailedProgress(id: UUID, error: Error) {
        guard let idx = DownloadQueue.shared.queue.firstIndex(where: { $0.id == id }) else { return }
        let lastPct = DownloadQueue.shared.queue[idx].progress
        DownloadQueue.shared.queue[idx].status = .failed(error.localizedDescription)
        // Retain last known progress so the bar doesn't jump to 0
        if lastPct > 0 {
            DownloadQueue.shared.queue[idx].progress = lastPct
        }
        DownloadQueue.shared.save()
    }
}

struct VideoResultRow: View {
    let result: ExtractResult
    let localState: UploadState?
    let megaState: UploadState?
    let gdriveState: UploadState?
    let onLocal: (String) -> Void
    let onMega: (String) -> Void
    let onGDrive: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: result.error == nil ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(result.error == nil ? Theme.success : Theme.error)
                    .font(.title3)

                VStack(alignment: .leading, spacing: 3) {
                    Text(displayTitle)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(2)

                    Text(result.source?.displaySiteName ?? "Video Site")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)

                    if let error = result.error {
                        Text(displayError(error))
                            .font(.caption)
                            .foregroundStyle(Theme.error)
                    }
                }

                Spacer(minLength: 0)
            }

            if let source = result.source {
                sourceButtons(for: source)
            }

            statusSummary
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private func copyToClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    private var displayTitle: String {
        guard let source = result.source else { return "Video URL" }
        let title = source.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return title.isEmpty ? "Untitled Video" : title
    }

    private func displayError(_ error: String) -> String {
        if error.localizedCaseInsensitiveContains("invalid url") {
            return error
        }
        return "Could not extract video sources from this page."
    }

    @ViewBuilder
    private func sourceButtons(for source: VideoSource) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let mp4 = source.mp4 {
                HStack(spacing: 8) {
                    Text("MP4")
                        .font(.caption.weight(.semibold))
                        .frame(width: 42, alignment: .leading)
                    Button("Local") { onLocal(mp4) }
                        .buttonStyle(.borderedProminent)
                    Button("Mega") { onMega(mp4) }
                        .buttonStyle(.bordered)
                    Button("GDrive") { onGDrive(mp4) }
                        .buttonStyle(.bordered)
                    Button("Copy") { copyToClipboard(mp4) }
                        .buttonStyle(.bordered)
                }
            }

            if !source.hls.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(source.hls, id: \.url) { quality in
                        HStack(spacing: 8) {
                            Text(quality.label)
                                .font(.caption.weight(.semibold))
                                .frame(width: 92, alignment: .leading)
                            Button("Local") { onLocal(quality.url) }
                                .buttonStyle(.borderedProminent)
                            Button("Mega") { onMega(quality.url) }
                                .buttonStyle(.bordered)
                            Button("GDrive") { onGDrive(quality.url) }
                                .buttonStyle(.bordered)
                            Button("Copy") { copyToClipboard(quality.url) }
                                .buttonStyle(.bordered)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var statusSummary: some View {
        if let localState {
            stateLine(label: "Local", state: localState)
        }
        if let megaState {
            stateLine(label: "Mega", state: megaState)
        }
        if let gdriveState {
            stateLine(label: "GDrive", state: gdriveState)
        }
    }

    @ViewBuilder
    private func stateLine(label: String, state: UploadState) -> some View {
        switch state {
        case .uploading(let msg):
            Text("\(label): \(msg)")
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
        case .done(let msg):
            Text("\(label): \(msg)")
                .font(.caption)
                .foregroundStyle(Theme.success)
        case .failed(let msg):
            Text("\(label): \(msg)")
                .font(.caption)
                .foregroundStyle(Theme.error)
        }
    }
}
