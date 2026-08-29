import SwiftUI
import AppKit

/// Displays a single tile from a sprite sheet, with the active tile selected by
/// a 0...1 hover progress value. Used for hover-scrub video previews.
///
/// Renders only the active tile (one frame) per body invocation via
/// `ImageRenderer` over a `NSImage.draw`-only path. This avoids the cost of
/// compositing the full sprite sheet each frame at 30fps.
struct SpriteSheetView: View {
    let image: NSImage
    let metadata: SpriteSheet
    let progress: Double

    var body: some View {
        let frameWidth = CGFloat(metadata.frameWidth)
        let frameHeight = CGFloat(metadata.frameHeight)
        let totalTiles = max(metadata.frameCount, 1)
        let columns = max(metadata.columns, 1)
        let rows = max(metadata.rows, 1)
        let index = max(0, min(metadata.frameIndex(forProgress: progress), totalTiles - 1))
        let column = index % columns
        let row = index / columns
        let clampedRow = min(row, rows - 1)

        // Build a tile-only NSImage at the sprite's native resolution, then
        // hand it to SwiftUI as a single normal Image. Result: SwiftUI
        // composites one frame-sized bitmap, not the full sheet.
        SpriteTileImage(image: image, column: column, row: clampedRow,
                        frameWidth: frameWidth, frameHeight: frameHeight)
            .frame(width: frameWidth, height: frameHeight)
            .clipped()
    }
}

/// `NSView` wrapper that draws only the requested tile of a sprite sheet into
/// its backing layer. AppKit composes one tile per frame instead of the full
/// sheet, which is the dominant cost at 30fps on large sheets.
private struct SpriteTileImage: NSViewRepresentable {
    let image: NSImage
    let column: Int
    let row: Int
    let frameWidth: CGFloat
    let frameHeight: CGFloat

    func makeNSView(context: Context) -> NSImageView {
        let view = NSImageView()
        view.wantsLayer = true
        view.imageScaling = .scaleNone
        view.imageAlignment = .alignTopLeft
        view.translatesAutoresizingMaskIntoConstraints = true
        view.layer?.drawsAsynchronously = true
        view.layer?.contentsGravity = .resizeAspect
        return view
    }

    func updateNSView(_ nsView: NSImageView, context: Context) {
        // Cache the CGImage so we don't re-decode the JPEG every frame.
        let cgImage: CGImage? = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        guard let cgImage else { return }
        let rect = CGRect(
            x: CGFloat(column) * frameWidth,
            y: CGFloat(row) * frameHeight,
            width: frameWidth,
            height: frameHeight
        )
        let cropped = cgImage.cropping(to: rect) ?? cgImage
        let size = NSSize(width: frameWidth, height: frameHeight)
        nsView.image = NSImage(cgImage: cropped, size: size)
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
