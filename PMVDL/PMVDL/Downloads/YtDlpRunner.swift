import Foundation

struct YtDlpRunner {
    // MARK: - yt-dlp site download (for YouTube etc.)

    /// Download via yt-dlp directly. Works for ANY yt-dlp supported site.
    /// Used when no direct URL is available (e.g. YouTube).
    func downloadViaYTDLPSite(pageUrl: String, title: String? = nil,
                              preferredFormat: String = "mp4",
                              onProgress: @escaping (String) -> Void) async throws -> URL {
        guard let ytDlp = findYTDLPath() else {
            throw DownloadError.toolNotFound("yt-dlp")
        }

        let baseName = sanitizeFilename(title ?? URL(string: pageUrl)?.host ?? "video")
        let uniqueTag = UUID().uuidString.prefix(8).lowercased()
        let outPattern = DownloadPaths.downloadDir.appendingPathComponent("\(baseName)_\(uniqueTag).%(ext)s").path

        var args = ["--no-playlist", "--merge-output-format", preferredFormat, "-o", outPattern]

        if DownloadPreferences.subtitlesEnabled {
            if DownloadPreferences.embeddedSubsMode {
                args.append("--embed-subs")
            } else {
                args.append(contentsOf: ["--write-subs", "--sub-lang", "en,ja,zh,ko,es,fr"])
            }
        }

        args.append(pageUrl)

        onProgress("Downloading via yt-dlp…")
        do {
            _ = try await SubprocessRunner.run(
                executable: URL(fileURLWithPath: ytDlp),
                arguments: args,
                timeout: 7200,
                stderrHandler: { text in
                    if let message = DownloadProgressParsers.ytDlpProgressMessage(from: text) {
                        onProgress(message)
                    }
                }
            )
        } catch SubprocessRunnerError.timedOut {
            throw DownloadError.timedOut
        }

        // Find the downloaded file
        if let file = findDownloadedFile(in: DownloadPaths.downloadDir, prefix: "\(baseName)_\(uniqueTag)") {
            return DownloadPaths.downloadDir.appendingPathComponent(file)
        }

        throw DownloadError.downloadFailed("yt-dlp completed but output file not found")
    }

    // MARK: - Audio-only via yt-dlp

    /// Download audio-only using yt-dlp --extract-audio.
    func downloadAudio(pageUrl: String, title: String? = nil,
                       format: String = "mp3",
                       onProgress: @escaping (String) -> Void) async throws -> URL {
        guard let ytDlp = findYTDLPath() else {
            throw DownloadError.toolNotFound("yt-dlp")
        }
        let baseName = sanitizeFilename(title ?? "audio")
        let uniqueTag = UUID().uuidString.prefix(8).lowercased()
        let outPattern = DownloadPaths.downloadDir.appendingPathComponent("\(baseName)_\(uniqueTag).%(ext)s").path

        let args = [
            "--extract-audio", "--audio-format", format,
            "--audio-quality", "0", "--no-playlist",
            "-o", outPattern, "--progress", pageUrl
        ]

        onProgress("Downloading audio…")
        do {
            _ = try await SubprocessRunner.run(
                executable: URL(fileURLWithPath: ytDlp),
                arguments: args,
                timeout: 7200,
                stderrHandler: { text in
                    if let message = DownloadProgressParsers.ytDlpProgressMessage(from: text) {
                        onProgress(message)
                    }
                }
            )
        } catch SubprocessRunnerError.timedOut {
            throw DownloadError.timedOut
        }

        if let file = findDownloadedFile(in: DownloadPaths.downloadDir, prefix: "\(baseName)_\(uniqueTag)") {
            return DownloadPaths.downloadDir.appendingPathComponent(file)
        }

        throw DownloadError.downloadFailed("yt-dlp completed but output file not found")
    }

    // MARK: - Download with subtitles via yt-dlp

    /// Download video with subtitles using yt-dlp.
    func downloadWithSubtitles(pageUrl: String, title: String? = nil,
                               onProgress: @escaping (String) -> Void) async throws -> URL {
        guard let ytDlp = findYTDLPath() else {
            throw DownloadError.toolNotFound("yt-dlp")
        }
        let baseName = sanitizeFilename(title ?? "video")
        let uniqueTag = UUID().uuidString.prefix(8).lowercased()
        let outPattern = DownloadPaths.downloadDir.appendingPathComponent("\(baseName)_\(uniqueTag).%(ext)s").path

        var args = ["--no-playlist", "--merge-output-format", "mp4", "-o", outPattern]
        if DownloadPreferences.subtitlesEnabled {
            if DownloadPreferences.embeddedSubsMode {
                args.append("--embed-subs")
            } else {
                args.append(contentsOf: ["--write-subs", "--sub-lang", "en,ja,zh,ko,es,fr"])
            }
        }
        args.append(pageUrl)

        onProgress("Downloading with subtitles…")
        do {
            _ = try await SubprocessRunner.run(
                executable: URL(fileURLWithPath: ytDlp),
                arguments: args,
                timeout: 7200,
                stderrHandler: { text in
                    if let message = DownloadProgressParsers.ytDlpProgressMessage(from: text) {
                        onProgress(message)
                    }
                }
            )
        } catch SubprocessRunnerError.timedOut {
            throw DownloadError.timedOut
        }

        if let file = findDownloadedFile(in: DownloadPaths.downloadDir, prefix: "\(baseName)_\(uniqueTag)") {
            return DownloadPaths.downloadDir.appendingPathComponent(file)
        }

        throw DownloadError.downloadFailed("yt-dlp completed but output file not found")
    }

    // MARK: - Helpers

    private func findDownloadedFile(in dir: URL, prefix: String) -> String? {
        (try? FileManager.default.contentsOfDirectory(atPath: dir.path))?
            .first { $0.hasPrefix(prefix) }
    }

    private func sanitizeFilename(_ title: String) -> String {
        VideoFileNaming.sanitizedBaseName(title: title, fallback: "video")
    }

    private func findYTDLPath() -> String? {
        ToolLocator.find("yt-dlp")?.path
    }

}
