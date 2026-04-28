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

    var urlLines: [String] {
        urlText
            .split(separator: "\n")
            .map { String($0) }
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    var batchTargetLinks: [String] {
        results.compactMap { $0.source?.mp4 }.filter { tracker.localDownloads[$0] == nil }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "photo.on.rectangle.angled").foregroundStyle(.blue)
                Text("Video Downloader").font(.subheadline).bold()
                if ScraperEngine.isYTDLPAvailable {
                    Text("Powered by yt-dlp").font(.caption2).foregroundStyle(.secondary)
                } else {
                    Text("Install yt-dlp for full features").font(.caption2).foregroundStyle(.orange)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal)
            .padding(.top, 6)

            // URL input label
            Text("URLs (one per line)").font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)
                .padding(.top, 4)
                .padding(.bottom, 2)

            // TextEditor
            TextEditor(text: $urlText)
                .frame(height: 60)
                .font(.system(size: 11, design: .monospaced))
                .border(Color.gray.opacity(0.4), width: 0.5)
                .padding(.horizontal)

            // Action buttons row
            HStack(spacing: 8) {
                Button("Extract All", action: extractAll)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(isLoading || urlLines.isEmpty)
                Button("Paste", systemImage: "clipboard", action: pasteFromClipboard)
                    .buttonStyle(.bordered)
                Button("Clear", systemImage: "xmark", action: { urlText = "" })
                    .buttonStyle(.bordered)
            }
            .padding(.horizontal)
            .padding(.top, 6)

            // Loading indicator
            if isLoading {
                VStack(spacing: 4) {
                    ProgressView().frame(width: 80)
                    if !loadProgress.isEmpty {
                        Text(loadProgress)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal)
                    }
                }.padding(.vertical, 6)
            }

            // Results list
            if !results.isEmpty {
                Divider().padding(.vertical, 2)
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(results.enumerated()), id: \.offset) { _, result in
                            VideoResultRow(
                                result: result,
                                localState: tracker.localDownloads[result.source?.mp4 ?? ""],
                                megaState: tracker.megaUploads[result.source?.mp4 ?? ""],
                                gdriveState: tracker.gdriveUploads[result.source?.mp4 ?? ""],
                                onLocal: { url in Task { await startDownload(url: url, cloud: .local) } },
                                onMega: { url in Task { await startDownload(url: url, cloud: .mega) } },
                                onGDrive: { url in Task { await startDownload(url: url, cloud: .gdrive) } }
                            )
                            Divider().padding(.leading, 20)
                        }
                    }
                }.frame(maxHeight: 220)

                // Batch download button for local
                if !batchTargetLinks.isEmpty {
                    Divider().padding(.vertical, 2)
                    if tracker.isBatchDownloading {
                        Text(loadProgress)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal)
                    }
                    Button("Download All to Local (\(batchTargetLinks.count))",
                           action: batchDownloadAll)
                        .buttonStyle(.borderedProminent)
                        .disabled(tracker.isBatchDownloading)
                        .padding(.horizontal)
                        .padding(.bottom, 4)
                }
            }

            Spacer()
        }
        .onAppear {
            // Check for pending URL from previous session
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
                }
            }
            NotificationManager.shared.notifyScrapeComplete(count: ordered.filter { $0.source != nil }.count)

            isLoading = false; loadProgress = ""
        }
    }

    private func batchDownloadAll() {
        let links = batchTargetLinks
        guard !links.isEmpty else { return }
        tracker.isBatchDownloading = true
        loadProgress = "Downloading 0/\(links.count)…"

        Task {
            let semaphore = DispatchSemaphore(value: 3)

            await withTaskGroup(of: (String, Bool, String?).self) { group in
                for url in links {
                    group.addTask {
                        semaphore.wait(); defer { semaphore.signal() }
                        do {
                            let result = try await MegaManager.upload(url: url, remotePath: megaRemotePath) { msg in
                                Task { @MainActor in
                                    tracker.localDownloads[url] = .uploading("\(self.fileName(of: url)) — \(msg)")
                                }
                            }
                            Task { @MainActor in tracker.megaFilenames[url] = result.remotePath }
                            return (url, true, nil)
                        } catch {
                            return (url, false, error.localizedDescription)
                        }
                    }
                }

                var done = 0
                for await (url, ok, err) in group {
                    done += 1
                    if ok {
                        tracker.localDownloads[url] = .done("Uploaded to \(megaRemotePath)")
                        if results.first(where: { $0.source?.mp4 == url })?.source != nil {
                            NotificationManager.shared.notifyUploadComplete(filename: fileName(of: url), destination: megaRemotePath)
                        }
                    } else {
                        tracker.localDownloads[url] = .failed(err ?? "Unknown")
                        NotificationManager.shared.notifyUploadFailed(filename: fileName(of: url), reason: err ?? "Unknown")
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
        let isHLS = url.contains(".m3u8")
        let isYtDlpSite = source.mp4 == nil && !isHLS

        // Look up any custom headers that came with this quality entry (e.g. LuluStream referer)
        let hlsHeaders = source.hls.first(where: { $0.url == url })?.headers

        // For .pageUrl entries (e.g. StreamTape/MixDrop/DoodStream from AllPornStream),
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
                                updateQueue(id: queueId, status: event.phase == .completing ? .completed : .downloading, progress: event.percent)
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
                    // Update library with local path
                    let libraryItem = libraryItem(for: result)
                    VideoLibrary.shared.updateRemotePaths(for: libraryItem, cloud: .local, path: destFile.path)
                    Task { @MainActor in
                        DownloadQueue.shared.updateProgress(id: queueId, status: .completed, progress: 100)
                        if var idx = DownloadQueue.shared.queue.firstIndex(where: { $0.id == queueId }) {
                            DownloadQueue.shared.queue[idx].finalPath = destFile.path
                            DownloadQueue.shared.save()
                        }
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
                                updateQueue(id: queueId, status: event.phase == .completing ? .completed : .downloading, progress: event.percent)
                                Task { @MainActor in tracker.megaUploads[key] = .uploading(event.message) }
                            })
                        tracker.megaUploads[key] = .uploading("Uploading to Mega…")
                        let uploadResult = try await MegaManager.uploadLocalFile(mp4File, remotePath: megaRemotePath) { event in
                            updateQueue(id: queueId, status: event.phase == .completing ? .completed : .uploading, progress: event.percent)
                            Task { @MainActor in tracker.megaUploads[key] = .uploading(event.message) }
                        }
                        Task { @MainActor in
                            try? FileManager.default.removeItem(at: mp4File)
                            DownloadQueue.shared.updateProgress(id: queueId, status: .completed, progress: 100)
                            if var idx = DownloadQueue.shared.queue.firstIndex(where: { $0.id == queueId }) {
                                DownloadQueue.shared.queue[idx].finalPath = uploadResult.remotePath
                                DownloadQueue.shared.save()
                            }
                            tracker.megaUploads[key] = .done("Uploaded to \(megaRemotePath)")
                            tracker.megaFilenames[key] = uploadResult.remotePath
                            NotificationManager.shared.notifyUploadComplete(filename: mp4File.lastPathComponent, destination: megaRemotePath)
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
                tracker.megaUploads[key] = .uploading("Downloading… 0%")
                Task {
                    do {
                        updateQueue(id: queueId, status: .downloading, progress: 0)
                        let uploadResult = try await MegaManager.upload(url: finalUrl, remotePath: megaRemotePath, headers: finalHlsHeaders) { event in
                            updateQueue(id: queueId, status: event.phase == .completing ? .completed : event.phase == .uploading ? .uploading : .downloading, progress: event.percent)
                            Task { @MainActor in tracker.megaUploads[key] = .uploading(event.message) }
                        }
                        Task { @MainActor in
                            DownloadQueue.shared.updateProgress(id: queueId, status: .completed, progress: 100)
                            if var idx = DownloadQueue.shared.queue.firstIndex(where: { $0.id == queueId }) {
                                DownloadQueue.shared.queue[idx].finalPath = uploadResult.remotePath
                                DownloadQueue.shared.save()
                            }
                            tracker.megaUploads[key] = .done("Uploaded to \(megaRemotePath)")
                            tracker.megaFilenames[key] = uploadResult.remotePath
                            NotificationManager.shared.notifyUploadComplete(filename: fileName(of: url), destination: megaRemotePath)
                        }
                    } catch {
                        Task { @MainActor in
                            DownloadQueue.shared.updateProgress(id: queueId, status: .failed(error.localizedDescription), progress: 0)
                            tracker.megaUploads[key] = .failed(error.localizedDescription)
                            NotificationManager.shared.notifyUploadFailed(filename: fileName(of: url), reason: error.localizedDescription)
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
                        try await GDriveManager.upload(url: finalUrl, remoteName: gdriveRemoteName, remotePath: gdriveRemotePath, headers: finalHlsHeaders) { msg in
                            Task { @MainActor in tracker.gdriveUploads[key] = .uploading(msg) }
                        }
                        if let megaPath = megaRemote {
                            try? await MegaManager.delete(remotePath: megaPath)
                            Task { @MainActor in tracker.megaFilenames.removeValue(forKey: megaPath) }
                        }
                        Task { @MainActor in
                            DownloadQueue.shared.updateProgress(id: queueId, status: .completed, progress: 100)
                            let destPath = "\(gdriveRemoteName):\(gdriveRemotePath)\(fileName(of: url))"
                            if var idx = DownloadQueue.shared.queue.firstIndex(where: { $0.id == queueId }) {
                                DownloadQueue.shared.queue[idx].finalPath = destPath
                                DownloadQueue.shared.save()
                            }
                            tracker.gdriveUploads[key] = .done("Uploaded to GDrive")
                            NotificationManager.shared.notifyUploadComplete(filename: fileName(of: url), destination: gdriveRemotePath)
                        }
                    } catch {
                        Task { @MainActor in
                            DownloadQueue.shared.updateProgress(id: queueId, status: .failed(error.localizedDescription), progress: 0)
                            tracker.gdriveUploads[key] = .failed(error.localizedDescription)
                            NotificationManager.shared.notifyUploadFailed(filename: fileName(of: url), reason: error.localizedDescription)
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
                    .foregroundStyle(result.error == nil ? .green : .red)
                    .font(.title3)

                VStack(alignment: .leading, spacing: 3) {
                    Text(result.source?.title ?? result.url)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(2)

                    Text(result.source?.siteName ?? URL(string: result.url)?.host ?? result.url)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if let error = result.error {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }

                Spacer(minLength: 0)
            }

            if let source = result.source {
                sourceButtons(for: source)
            }

            statusSummary
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    private func copyToClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
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
                .foregroundStyle(.secondary)
        case .done(let msg):
            Text("\(label): \(msg)")
                .font(.caption)
                .foregroundStyle(.green)
        case .failed(let msg):
            Text("\(label): \(msg)")
                .font(.caption)
                .foregroundStyle(.red)
        }
    }
}
