import Foundation

/// Metadata for a generated video sprite sheet used for hover-scrub previews.
///
/// A sprite sheet packs N evenly-spaced frames from a video into a single JPEG grid
/// (`columns` × `rows` tiles). At hover time, the UI shows one tile at a time by
/// offsetting the image to the right row/column based on hover progress.
struct SpriteSheet: Hashable, Sendable {
    /// Local file URL of the generated sprite JPEG.
    let url: URL
    /// Grid columns (tiles per row).
    let columns: Int
    /// Grid rows (tiles per column).
    let rows: Int
    /// Per-tile width in pixels (matches the JPEG layout).
    let frameWidth: Int
    /// Per-tile height in pixels.
    let frameHeight: Int
    /// Seconds between sampled frames in the source video.
    let interval: Double
    /// Total sampled frames = `columns * rows`.
    var frameCount: Int { columns * rows }
    /// Total span in seconds covered by the sprite (last frame at `interval * (frameCount - 1)`).
    var coveredDuration: Double { interval * Double(max(frameCount - 1, 0)) }

    /// Map hover progress (0...1) to a frame index in the sprite.
    /// - Parameter progress: Hover progress where 0 = leftmost, 1 = rightmost tile.
    func frameIndex(forProgress progress: Double) -> Int {
        let clamped = max(0.0, min(progress, 1.0))
        let raw = clamped * Double(max(frameCount - 1, 0))
        return Int(raw.rounded())
    }
}

extension SpriteSheet {
    /// Default sampling plan used by the hover-preview pipeline.
    /// Targets 100 tiles for a balanced scrub resolution; clamps interval to a sensible
    /// floor so very short videos still produce a meaningful spread.
    static func defaultPlan(forDuration duration: Double?) -> (columns: Int, rows: Int, interval: Double) {
        let totalTiles = 100
        let columns = 10
        let rows = 10
        let targetInterval: Double
        if let duration, duration > 0 {
            targetInterval = max(duration / Double(totalTiles), 1.0)
        } else {
            targetInterval = 10.0
        }
        return (columns, rows, targetInterval)
    }
}
