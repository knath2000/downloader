import AppKit
import AVKit
import Foundation

actor ThumbnailCache {
    static let shared = ThumbnailCache()

    private let memoryCache = NSCache<NSString, NSImage>()
    private let diskDirectory: URL

    private init() {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        diskDirectory = base.appendingPathComponent("PMVDL/thumbnails")
        try? FileManager.default.createDirectory(at: diskDirectory, withIntermediateDirectories: true)
        memoryCache.countLimit = 100
    }

    func cachedImage(for url: String) -> NSImage? {
        let key = "pmvdl_thumb_\(url.hashValue).jpg"
        if let img = memoryCache.object(forKey: key as NSString) { return img }

        let fileURL = diskDirectory.appendingPathComponent(key)
        if FileManager.default.fileExists(atPath: fileURL.path),
           let data = try? Data(contentsOf: fileURL),
           let img = NSImage(data: data) {
            memoryCache.setObject(img, forKey: key as NSString)
            return img
        }
        return nil
    }

    func store(_ image: NSImage, for url: String) {
        let key = "pmvdl_thumb_\(url.hashValue).jpg"
        memoryCache.setObject(image, forKey: key as NSString)

        let fileURL = diskDirectory.appendingPathComponent(key)
        if let tiff = image.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff),
           let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.8]) {
            try? jpeg.write(to: fileURL)
        }
    }

    /// Synchronous disk read for direct cache-key lookup (used by LibraryView).
    func cachedImage(forKey key: String) -> NSImage? {
        if let img = memoryCache.object(forKey: key as NSString) { return img }
        let fileURL = diskDirectory.appendingPathComponent(key)
        if FileManager.default.fileExists(atPath: fileURL.path),
           let data = try? Data(contentsOf: fileURL),
           let img = NSImage(data: data) {
            memoryCache.setObject(img, forKey: key as NSString)
            return img
        }
        return nil
    }
}

// MARK: - Synchronous local-file thumbnail generation (called from upload flows)
extension ThumbnailCache {
    /// Generate a thumbnail from a local video file and cache it.
    /// Uses a sync dispatch queue so the result can be accessed synchronously.
    static func cachedThumbnail(forKey key: String) -> NSImage? {
        let diskDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("PMVDL/thumbnails")
        let fileURL = diskDir.appendingPathComponent(key)
        if let data = try? Data(contentsOf: fileURL),
           let img = NSImage(data: data) {
            return img
        }
        return nil
    }

    /// Generate a thumbnail from a local video file and cache it by remote URL.
    /// Called during mega/gdrive upload when the file is already on disk.
    static func generateAndCache(fromLocalFile localPath: String, forRemoteUrl url: String) {
        // Check cache first — synchronous disk read
        let key = "pmvdl_thumb_\(url.hashValue).jpg"
        if cachedThumbnail(forKey: key) != nil { return }

        let fileURL = URL(fileURLWithPath: localPath)
        let asset = AVAsset(url: fileURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 320, height: 180)

        var time = CMTime(seconds: 1.0, preferredTimescale: 600)
        let rawTime = CMTimeGetSeconds(asset.duration)
        if rawTime > 0 {
            time = CMTime(seconds: min(1.0, rawTime * 0.05), preferredTimescale: 600)
        }

        guard let cgImage = try? generator.copyCGImage(at: time, actualTime: nil) else { return }
        let image = NSImage(cgImage: cgImage, size: CGSize(width: cgImage.width, height: cgImage.height))

        // Write directly to disk + memory cache
        if let tiff = image.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff),
           let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.8]) {
            let diskDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
                .appendingPathComponent("PMVDL/thumbnails")
            let fileURL = diskDir.appendingPathComponent(key)
            try? jpeg.write(to: fileURL)
        }
    }

    /// Download first 2 MB of a remote video and generate a thumbnail (for backfill).
    static func generateAndCache(fromRemoteURL url: String) async throws -> NSImage {
        // Check cache first
        if let cached = await shared.cachedImage(for: url) { return cached }

        var request = URLRequest(url: URL(string: url)!)
        request.setValue("bytes=0-2097151", forHTTPHeaderField: "Range")
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")
        let (data, _) = try await URLSession.shared.data(for: request)
        guard !data.isEmpty else { throw ThumbnailError.emptyResponse }

        let tempFile = FileManager.default.temporaryDirectory.appendingPathComponent("pmvdl_thumb_\(url.hashValue).mp4")
        try data.write(to: tempFile)
        defer { try? FileManager.default.removeItem(at: tempFile) }

        let asset = AVAsset(url: tempFile)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 320, height: 180)

        let duration = try await asset.load(.duration)
        let time = CMTime(seconds: min(1.0, duration.seconds * 0.05), preferredTimescale: 600)
        let (cgImage, _) = try await generator.image(at: time)
        let image = NSImage(cgImage: cgImage, size: CGSize(width: cgImage.width, height: cgImage.height))

        await shared.store(image, for: url)
        return image
    }
}

enum ThumbnailError: LocalizedError {
    case emptyResponse
    var errorDescription: String? { "No data received" }
}
