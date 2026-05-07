import AppKit
import AVKit
import CryptoKit
import Foundation

actor ThumbnailCache {
    static let shared = ThumbnailCache()

    private let memoryCache = NSCache<NSString, NSImage>()
    private let diskDirectory: URL

    private init() {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        diskDirectory = base.appendingPathComponent("VidDL/thumbnails")
        try? FileManager.default.createDirectory(at: diskDirectory, withIntermediateDirectories: true)
        memoryCache.countLimit = 100
    }

    static func cacheKey(for identity: String) -> String {
        let normalized = identity.trimmingCharacters(in: .whitespacesAndNewlines)
        let digest = SHA256.hash(data: Data(normalized.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "viddl_thumb_\(hex).jpg"
    }

    static func cacheKey(for libraryItem: LibraryItem) -> String {
        cacheKey(for: libraryItem.mp4Url ?? libraryItem.url)
    }

    static func legacyCacheKey(for identity: String) -> String {
        "viddl_thumb_\(identity.hashValue).jpg"
    }

    func cachedImage(for url: String) -> NSImage? {
        let key = Self.cacheKey(for: url)
        if let image = cachedImage(forKey: key) { return image }

        let legacyKey = Self.legacyCacheKey(for: url)
        guard legacyKey != key else { return nil }
        return cachedImage(forKey: legacyKey)
    }

    func cachedImage(forIdentity identity: String) -> NSImage? {
        cachedImage(for: identity)
    }

    func store(_ image: NSImage, for url: String) {
        store(image, forKey: Self.cacheKey(for: url))
    }

    func store(_ image: NSImage, forIdentity identity: String) {
        store(image, for: identity)
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

    private func store(_ image: NSImage, forKey key: String) {
        memoryCache.setObject(image, forKey: key as NSString)

        let fileURL = diskDirectory.appendingPathComponent(key)
        if let tiff = image.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff),
           let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.8]) {
            try? jpeg.write(to: fileURL)
        }
    }
}

// MARK: - Synchronous local-file thumbnail generation (called from upload flows)
extension ThumbnailCache {
    /// Generate a thumbnail from a local video file and cache it.
    /// Uses a sync dispatch queue so the result can be accessed synchronously.
    static func cachedThumbnail(forKey key: String) -> NSImage? {
        let diskDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("VidDL/thumbnails")
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
        let key = ThumbnailCache.cacheKey(for: url)
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
                .appendingPathComponent("VidDL/thumbnails")
            let fileURL = diskDir.appendingPathComponent(key)
            try? jpeg.write(to: fileURL)
        }
    }

    static func generateAndCacheImage(fromLocalFile localPath: String, forRemoteUrl url: String) async -> NSImage? {
        if let cached = await shared.cachedImage(for: url) { return cached }

        let fileURL = URL(fileURLWithPath: localPath)
        let asset = AVAsset(url: fileURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 320, height: 180)

        guard let duration = try? await asset.load(.duration) else { return nil }
        let time = CMTime(seconds: min(1.0, duration.seconds * 0.05), preferredTimescale: 600)

        guard let (cgImage, _) = try? await generator.image(at: time) else { return nil }
        let image = NSImage(cgImage: cgImage, size: CGSize(width: cgImage.width, height: cgImage.height))

        await shared.store(image, for: url)
        return image
    }

    /// Download first 2 MB of a remote video and generate a thumbnail (for backfill).
    static func generateAndCache(fromRemoteURL url: String, headers: [String: String]? = nil) async throws -> NSImage {
        // Check cache first
        if let cached = await shared.cachedImage(for: url) { return cached }

        guard let remoteURL = URL(string: url) else { throw ThumbnailError.invalidURL(url) }
        var request = URLRequest(url: remoteURL)
        request.setValue("bytes=0-2097151", forHTTPHeaderField: "Range")
        request.setValue(NetworkConstants.chromeUserAgent, forHTTPHeaderField: "User-Agent")
        headers?.forEach { field, value in
            guard field.caseInsensitiveCompare("Range") != .orderedSame else { return }
            request.setValue(value, forHTTPHeaderField: field)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse,
           !(200...299).contains(http.statusCode) {
            throw ThumbnailError.httpStatus(http.statusCode)
        }
        guard !data.isEmpty else { throw ThumbnailError.emptyResponse }

        let tempBase = ThumbnailCache.cacheKey(for: url).replacingOccurrences(of: ".jpg", with: "")
        let tempFile = FileManager.default.temporaryDirectory.appendingPathComponent("\(tempBase).mp4")
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

    static func downloadAndCacheImage(
        fromImageURL imageURLString: String,
        cacheIdentity: String? = nil,
        referer: String? = nil
    ) async throws -> NSImage {
        let trimmed = imageURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let imageURL = URL(string: trimmed) else {
            throw ThumbnailError.invalidURL(trimmed)
        }

        let identity = cacheIdentity ?? trimmed
        if let cached = await shared.cachedImage(forIdentity: identity) {
            return cached
        }

        var request = URLRequest(url: imageURL)
        request.setValue(NetworkConstants.chromeUserAgent, forHTTPHeaderField: "User-Agent")
        if let referer, !referer.isEmpty {
            request.setValue(referer, forHTTPHeaderField: "Referer")
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse,
           !(200...299).contains(http.statusCode) {
            throw ThumbnailError.httpStatus(http.statusCode)
        }

        guard let image = NSImage(data: data) else {
            throw ThumbnailError.invalidImage
        }

        await shared.store(image, forIdentity: identity)
        return image
    }
}

enum ThumbnailError: LocalizedError {
    case emptyResponse
    case invalidURL(String)
    case httpStatus(Int)
    case invalidImage
    case noThumbnailCandidate

    var errorDescription: String? {
        switch self {
        case .emptyResponse:
            return "No data received"
        case .invalidURL(let value):
            return "Invalid thumbnail URL: \(value)"
        case .httpStatus(let status):
            return "Thumbnail request failed with HTTP \(status)"
        case .invalidImage:
            return "Thumbnail response was not a valid image"
        case .noThumbnailCandidate:
            return "No thumbnail candidate was available"
        }
    }
}
