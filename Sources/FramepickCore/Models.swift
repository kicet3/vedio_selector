import Foundation
import CoreMedia

public struct FrameStamp: Codable, Hashable, Sendable {
    public let value: Int64
    public let timescale: Int32
    public init(_ time: CMTime) { value = time.value; timescale = time.timescale }
    public var time: CMTime { CMTime(value: value, timescale: timescale) }
    public var seconds: Double { time.seconds }
    public var label: String { Self.format(seconds) }
    public static func format(_ seconds: Double) -> String {
        let ms = Int((max(0, seconds.isFinite ? seconds : 0) * 1000).rounded())
        return String(format: "%02d:%02d:%02d.%03d", ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60, ms % 1000)
    }
}

public struct VideoIndex: Sendable {
    public let frames: [FrameStamp]
    public let duration: Double
    public let width: Int
    public let height: Int
    public let nominalFPS: Float
    public init(frames: [FrameStamp], duration: Double, width: Int, height: Int, nominalFPS: Float) {
        self.frames = frames; self.duration = duration; self.width = width; self.height = height; self.nominalFPS = nominalFPS
    }
    /// Last presented frame at a playback time, with bounded results at either end.
    public func frame(at seconds: Double) -> Int {
        guard !frames.isEmpty else { return 0 }
        var low = 0, high = frames.count
        while low < high {
            let middle = (low + high) / 2
            if frames[middle].seconds <= seconds { low = middle + 1 } else { high = middle }
        }
        return max(0, low - 1)
    }
}

public enum CaptureFormat: String, CaseIterable, Identifiable, Sendable {
    case png = "PNG", jpeg = "JPEG"
    public var id: String { rawValue }
    public var fileExtension: String { self == .png ? "png" : "jpg" }
}

public struct PhotoRecord: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public let filename: String
    public let displayName: String
    public let addedAt: Date
    public var isFavorite: Bool
    public let videoID: UUID?
    public let frameNumber: Int?
    public let timestamp: FrameStamp?
    public var folderID: UUID?
    public var sourcePath: String?
    public var relativePath: String?
    public var sourceModifiedAt: Date?
    public var isMissing: Bool?
    public var editedFromID: UUID?
    public var captureQuarterTurns: Int?
    /// Optional fields keep libraries written before photo culling/edit recipes readable.
    public var rating: Int?
    public var isRejected: Bool?
    public var savedAdjustments: PhotoAdjustments?
    public init(id: UUID = UUID(), filename: String, displayName: String, isFavorite: Bool = false,
                videoID: UUID? = nil, frameNumber: Int? = nil, timestamp: FrameStamp? = nil,
                folderID: UUID? = nil, sourcePath: String? = nil, relativePath: String? = nil, sourceModifiedAt: Date? = nil) {
        self.id = id; self.filename = filename; self.displayName = displayName; self.addedAt = Date()
        self.isFavorite = isFavorite; self.videoID = videoID; self.frameNumber = frameNumber; self.timestamp = timestamp
        self.folderID = folderID; self.sourcePath = sourcePath; self.relativePath = relativePath; self.sourceModifiedAt = sourceModifiedAt
    }
    public var imageIdentity: String { "\(id.uuidString)-\(sourceModifiedAt?.timeIntervalSince1970 ?? 0)" }
}

public struct VideoRecord: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public let name: String
    public var path: String
    public var bookmark: Data?
    public var folderID: UUID?
    public var quarterTurns: Int?
    public init(url: URL, folderID: UUID? = nil) {
        id = UUID(); name = url.lastPathComponent; path = url.path
        self.folderID = folderID
        bookmark = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
    }
    public func resolvedURL() -> URL {
        if let bookmark {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI],
                                  relativeTo: nil, bookmarkDataIsStale: &stale) { return url }
        }
        return URL(fileURLWithPath: path)
    }
}

public struct FolderRecord: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var path: String
    public var bookmark: Data?
    public var includesSubfolders: Bool
    public var name: String { URL(fileURLWithPath: path).lastPathComponent }
    public init(url: URL, includesSubfolders: Bool) {
        id = UUID(); path = url.path; self.includesSubfolders = includesSubfolders
        bookmark = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
    }
    public func resolvedURL() -> URL {
        if let bookmark {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale) { return url }
        }
        return URL(fileURLWithPath: path)
    }
}

public struct LibrarySnapshot: Codable, Sendable {
    public var version = 1
    public var photos: [PhotoRecord] = []
    public var videos: [VideoRecord] = []
    public var folders: [FolderRecord] = []
    public init() {}
    private enum CodingKeys: String, CodingKey { case version, photos, videos, folders }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        photos = try container.decode([PhotoRecord].self, forKey: .photos)
        videos = try container.decode([VideoRecord].self, forKey: .videos)
        folders = try container.decodeIfPresent([FolderRecord].self, forKey: .folders) ?? []
    }
}

public enum MediaError: LocalizedError {
    case message(String)
    public var errorDescription: String? { if case let .message(text) = self { return text }; return nil }
}
