import Foundation

/// Preset configurations for video processing.
struct ProcessingProfile: Identifiable, Codable, Equatable, Hashable {
    let id: UUID
    let name: String
    let description: String
    let ffmpegArgs: [String]
    let outputExtension: String
    let isDefault: Bool

    init(id: UUID = UUID(), name: String, description: String,
         ffmpegArgs: [String], outputExtension: String, isDefault: Bool = false) {
        self.id = id; self.name = name; self.description = description
        self.ffmpegArgs = ffmpegArgs; self.outputExtension = outputExtension
        self.isDefault = isDefault
    }

    static let web = ProcessingProfile(
        name: "Web", description: "H.264, 1080p, optimized for web playback",
        ffmpegArgs: ["-c:v", "libx264", "-preset", "medium", "-crf", "23",
                      "-vf", "scale=-2:1080", "-c:a", "aac", "-b:a", "128k"],
        outputExtension: "mp4", isDefault: true)

    static let archive = ProcessingProfile(
        name: "Archive", description: "Lossless copy, MKV container",
        ffmpegArgs: ["-c", "copy"],
        outputExtension: "mkv")

    static let archiveSmall = ProcessingProfile(
        name: "Archive Small", description: "H.265, smaller file size",
        ffmpegArgs: ["-c:v", "libx265", "-preset", "medium", "-crf", "28",
                      "-c:a", "copy"],
        outputExtension: "mp4")

    static let thumbnail = ProcessingProfile(
        name: "Thumbnail", description: "Extract first frame as JPEG",
        ffmpegArgs: ["-vf", "select=eq(n\\,0)", "-vframes", "1", "-q:v", "2"],
        outputExtension: "jpg")

    static func downscale(_ height: Int) -> ProcessingProfile {
        ProcessingProfile(
            name: "\(height)p", description: "Downscale to \(height)p",
            ffmpegArgs: ["-vf", "scale=-2:\(height)", "-c:v", "libx264", "-crf", "23", "-c:a", "copy"],
            outputExtension: "mp4")
    }

    static var all: [ProcessingProfile] { [web, archive, archiveSmall, thumbnail] }
}
