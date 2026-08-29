import SwiftUI

/// Displays a single tile from a sprite sheet, with the active tile selected by
/// a 0...1 hover progress value. Used for hover-scrub video previews.
struct SpriteSheetView: View {
    let image: NSImage
    let metadata: SpriteSheet
    let progress: Double

    var body: some View {
        let frameWidth = CGFloat(metadata.frameWidth)
        let frameHeight = CGFloat(metadata.frameHeight)
        let columns = metadata.columns
        let rows = max(metadata.rows, 1)
        let totalTiles = max(metadata.frameCount, 1)
        let index = max(0, min(metadata.frameIndex(forProgress: progress), totalTiles - 1))
        let column = index % columns
        let row = index / columns
        let clampedRow = min(row, rows - 1)

        Image(nsImage: image)
            .resizable()
            .interpolation(.medium)
            .frame(
                width: frameWidth * CGFloat(columns),
                height: frameHeight * CGFloat(rows)
            )
            .offset(
                x: -CGFloat(column) * frameWidth,
                y: -CGFloat(clampedRow) * frameHeight
            )
            .frame(width: frameWidth, height: frameHeight)
            .clipped()
    }
}

/// Pair of preloaded sprite image + metadata, ready for fast `SpriteSheetView` rendering.
struct HoverSprite: Equatable {
    let image: NSImage
    let metadata: SpriteSheet

    static func == (lhs: HoverSprite, rhs: HoverSprite) -> Bool {
        lhs.metadata == rhs.metadata && lhs.image === rhs.image
    }
}
