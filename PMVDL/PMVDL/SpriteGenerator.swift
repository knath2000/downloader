import Foundation

/// Generates and caches hover-scrub sprite sheets for local video files.
///
/// Used by two call sites:
/// 1. `HoverSpriteController.scheduleLoad` — generates on first hover if missing.
/// 2. `DownloadJobs.complete` — pre-generates eagerly after a successful download
///    so the first hover is instant.
///
/// All public methods are no-ops for missing files or ffmpeg failures — the
/// hover-scrub feature degrades gracefully to the static thumbnail.
enum SpriteGenerator {
    /// Default sprite sheet layout. 10x10 = 100 frames covers ~16 minutes at
    /// the default 10s interval, which is the common case.
    static let defaultOptions = VideoProcessor.SpriteSheetOptions()

    /// Generate and persist a sprite sheet for `videoURL`, identified by `identity`.
    /// If a sprite already exists on disk, this is a no-op.
    ///
    /// - Returns: `true` if a sprite was generated or already cached, `false` on
    ///   any failure (file missing, ffmpeg missing, etc).
    @discardableResult
    static func generateIfNeeded(videoURL: URL, identity: String) async -> Bool {
        if ThumbnailCache.cachedSprite(for: identity) != nil { return true }
        guard FileManager.default.fileExists(atPath: videoURL.path) else { return false }

        let baseName = ThumbnailCache.spriteCacheName(for: identity)
        let dir = spriteDirectory()
        let outputURL = dir.appendingPathComponent("\(baseName).jpg")
        if FileManager.default.fileExists(atPath: outputURL.path) {
            // File exists but cache lookup missed — write the metadata sidecar
            // and we're done.
            let metadata = SpriteSheetMetadata(
                columns: defaultOptions.columns,
                rows: defaultOptions.rows,
                frameWidth: defaultOptions.frameWidth,
                frameHeight: defaultOptions.frameHeight,
                interval: 0
            )
            try? ThumbnailCache.storeSprite(jpegData: Data(), metadata: metadata, for: identity)
            return true
        }

        do {
            let sprite = try await VideoProcessor.generateSpriteSheet(
                for: videoURL,
                options: defaultOptions,
                outputURL: outputURL
            )
            let jpegData = try Data(contentsOf: sprite.url)
            let metadata = SpriteSheetMetadata(spriteSheet: sprite)
            try ThumbnailCache.storeSprite(jpegData: jpegData, metadata: metadata, for: identity)
            return true
        } catch {
            return false
        }
    }

    /// File-system path to the sprite storage directory. Created lazily.
    private static func spriteDirectory() -> URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("VidDL/thumbnails/sprites", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
