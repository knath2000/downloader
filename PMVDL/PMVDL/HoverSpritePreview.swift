import SwiftUI

/// Drives hover-scrub preview state for a single card. Loads the sprite sheet on
/// first hover (if missing), runs a `Timer`-driven progress loop while hovered,
/// and cancels cleanly when the card scrolls off-screen or the view disappears.
@MainActor
final class HoverSpriteController: ObservableObject {
    /// 0...1 scrub progress for the current hover session. `nil` when not hovering.
    @Published private(set) var progress: Double?
    /// Loaded sprite, available once generation/caching completes.
    @Published private(set) var sprite: HoverSprite?

    /// Stable identity for cache lookup. Should match the `LibraryItem`/`FeedFavoriteItem`
    /// `url` (or a stable hash thereof).
    let identity: String
    /// Local file URL of the video, if available. Sprite generation requires a local
    /// file — remote-only items keep `sprite == nil` and fall back to the static thumbnail.
    let videoURL: URL?

    /// Seconds to scrub from 0% to 100%. Loops.
    let scrubDuration: TimeInterval
    private var scrubTask: Task<Void, Never>?
    private var generationTask: Task<Void, Never>?

    init(identity: String, videoURL: URL?, scrubDuration: TimeInterval = 2.5) {
        self.identity = identity
        self.videoURL = videoURL
        self.scrubDuration = scrubDuration
    }

    deinit {
        scrubTask?.cancel()
        generationTask?.cancel()
    }

    /// Begin a hover session. Idempotent if already hovering.
    func beginHover() {
        if progress == nil { progress = 0 }
        scheduleLoad()
        scheduleScrub()
    }

    /// End a hover session. Cancels timers; keeps the loaded sprite for next time.
    func endHover() {
        scrubTask?.cancel()
        scrubTask = nil
        progress = nil
    }

    private func scheduleLoad() {
        if let cached = ThumbnailCache.cachedSprite(for: identity) {
            sprite = HoverSprite(image: cached.image, metadata: cached.metadata)
            return
        }
        guard let videoURL else { return }
        let identity = self.identity
        if generationTask != nil { return }
        generationTask = Task { [weak self] in
            await Self.generateAndStore(videoURL: videoURL, identity: identity)
            guard let self else { return }
            await MainActor.run { self.generationTask = nil }
            if let cached = ThumbnailCache.cachedSprite(for: identity) {
                await MainActor.run { [weak self] in
                    self?.sprite = HoverSprite(image: cached.image, metadata: cached.metadata)
                }
            }
        }
    }

    private func scheduleScrub() {
        let duration = scrubDuration
        scrubTask = Task { [weak self] in
            let frameInterval: TimeInterval = 1.0 / 30.0
            let start = Date()
            while !Task.isCancelled {
                guard let self else { return }
                let elapsed = Date().timeIntervalSince(start)
                let next = min(elapsed / duration, 1.0)
                self.progress = next
                if next >= 1.0 {
                    // Loop: restart so the preview keeps scrubbing while hovered.
                    self.progress = 0
                    return await self.restartScrub()
                }
                try? await Task.sleep(nanoseconds: UInt64(frameInterval * 1_000_000_000))
            }
        }
    }

    private func restartScrub() async {
        scrubTask = nil
        // Only restart if still in a hover session (controller not torn down).
        // We rely on endHover() being called externally to fully stop.
        if progress != nil {
            scheduleScrub()
        }
    }

    /// Run ffmpeg to generate + persist a sprite sheet for `videoURL`. No-op if
    /// ffmpeg is unavailable or generation fails.
    ///
    /// Delegates to `SpriteGenerator` so the hover controller and the
    /// download-complete hook share a single code path.
    private static func generateAndStore(videoURL: URL, identity: String) async {
        await SpriteGenerator.generateIfNeeded(videoURL: videoURL, identity: identity)
    }
}

/// View modifier that overlays a sprite-scrub preview on top of a thumbnail view
/// when hovered. Local files only — remote items show the static thumbnail.
struct HoverSpritePreview: ViewModifier {
    let identity: String
    let videoURL: URL?
    @StateObject private var controller: HoverSpriteController

    init(identity: String, videoURL: URL?) {
        self.identity = identity
        self.videoURL = videoURL
        _controller = StateObject(wrappedValue: HoverSpriteController(identity: identity, videoURL: videoURL))
    }

    func body(content: Content) -> some View {
        content
            .overlay {
                if let progress = controller.progress, let sprite = controller.sprite {
                    SpriteSheetView(image: sprite.image, metadata: sprite.metadata, progress: progress)
                        .transition(.opacity.animation(.easeOut(duration: 0.10)))
                        .allowsHitTesting(false)
                }
            }
            .onHover { hovering in
                if hovering {
                    controller.beginHover()
                } else {
                    controller.endHover()
                }
            }
            .onDisappear {
                controller.endHover()
            }
    }
}

extension View {
    /// Attach a hover-scrub video preview on top of this thumbnail.
    /// - Parameters:
    ///   - identity: Stable string identity for cache lookup (typically the item's URL).
    ///   - videoURL: Local file URL of the video. `nil` for remote-only items —
    ///     in that case the modifier is a no-op and the static thumbnail is shown.
    func hoverSpritePreview(identity: String, videoURL: URL?) -> some View {
        modifier(HoverSpritePreview(identity: identity, videoURL: videoURL))
    }
}
