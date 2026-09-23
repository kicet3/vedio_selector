import Foundation
import ImageIO

public actor LibraryDisk {
    public nonisolated let root: URL
    public nonisolated var photosDirectory: URL { root.appendingPathComponent("Photos", isDirectory: true) }
    public init(root: URL) { self.root = root }
    public nonisolated func url(for photo: PhotoRecord) -> URL {
        photo.sourcePath.map { URL(fileURLWithPath: $0) } ?? photosDirectory.appendingPathComponent(photo.filename)
    }
    public func load() throws -> LibrarySnapshot {
        try FileManager.default.createDirectory(at: photosDirectory, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("library.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return LibrarySnapshot() }
        let snapshot = try JSONDecoder().decode(LibrarySnapshot.self, from: Data(contentsOf: file))
        guard snapshot.version == 1 else { throw MediaError.message("이 보관함은 더 새로운 버전의 Framepick에서 생성했습니다.") }
        return snapshot
    }
    public func save(_ snapshot: LibrarySnapshot) throws {
        try FileManager.default.createDirectory(at: photosDirectory, withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(snapshot).write(to: root.appendingPathComponent("library.json"), options: .atomic)
    }
    public func importPhoto(from source: URL) throws -> PhotoRecord {
        try Task.checkCancellation()
        guard let imageSource = CGImageSourceCreateWithURL(source as CFURL, nil), CGImageSourceGetCount(imageSource) > 0,
              CGImageSourceCreateThumbnailAtIndex(imageSource, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 32
              ] as CFDictionary) != nil else {
            throw MediaError.message("지원하지 않거나 손상된 사진입니다: \(source.lastPathComponent)")
        }
        let filename = UUID().uuidString + "." + (source.pathExtension.isEmpty ? "image" : source.pathExtension)
        try FileManager.default.createDirectory(at: photosDirectory, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: source, to: photosDirectory.appendingPathComponent(filename))
        return PhotoRecord(filename: filename, displayName: source.lastPathComponent)
    }
    public func capture(image: CGImage, video: VideoRecord, frame: Int, stamp: FrameStamp,
                        format: CaptureFormat, favorite: Bool, quarterTurns: Int = 0) throws -> PhotoRecord {
        let id = UUID()
        let filename = "\(id.uuidString).\(format.fileExtension)"
        let rotation = quarterTurns == 0 ? "" : "_rot\(quarterTurns * 90)"
        let name = "\(URL(fileURLWithPath: video.name).deletingPathExtension().lastPathComponent)_frame-\(String(format: "%06d", frame + 1))\(rotation).\(format.fileExtension)"
        try FileManager.default.createDirectory(at: photosDirectory, withIntermediateDirectories: true)
        try ImageEncoder.write(image, to: photosDirectory.appendingPathComponent(filename), format: format)
        var photo = PhotoRecord(id: id, filename: filename, displayName: name, isFavorite: favorite,
                           videoID: video.id, frameNumber: frame, timestamp: stamp, folderID: video.folderID)
        photo.captureQuarterTurns = quarterTurns
        return photo
    }
    public func saveEditedCopy(_ image: CGImage, original: PhotoRecord, format: CaptureFormat, adjustments: PhotoAdjustments? = nil,
                               sourceID: UUID? = nil) throws -> PhotoRecord {
        try FileManager.default.createDirectory(at: photosDirectory, withIntermediateDirectories: true)
        let filename = UUID().uuidString + "." + format.fileExtension
        try ImageEncoder.write(image, to: photosDirectory.appendingPathComponent(filename), format: format)
        let name = URL(fileURLWithPath: original.displayName).deletingPathExtension().lastPathComponent + "_edited." + format.fileExtension
        var photo = PhotoRecord(filename: filename, displayName: name, isFavorite: original.isFavorite,
                                videoID: original.videoID, frameNumber: original.frameNumber, timestamp: original.timestamp, folderID: original.folderID)
        photo.editedFromID = sourceID ?? original.id
        photo.savedAdjustments = adjustments
        photo.rating = original.rating
        photo.isRejected = original.isRejected
        photo.captureQuarterTurns = original.captureQuarterTurns
        return photo
    }
    public func export(_ photos: [PhotoRecord], to directory: URL) throws -> [URL] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var written: [URL] = []
        for photo in photos {
            try Task.checkCancellation()
            let destination = Self.availableURL(in: directory, name: photo.displayName)
            do { try FileManager.default.copyItem(at: url(for: photo), to: destination) }
            catch { throw MediaError.message("\(written.count)장 저장 후 중단되었습니다. \(photo.displayName): \(error.localizedDescription)") }
            written.append(destination)
        }
        return written
    }
    public nonisolated static func availableURL(in directory: URL, name: String) -> URL {
        let safeName = URL(fileURLWithPath: name).lastPathComponent
        var result = directory.appendingPathComponent(safeName)
        let stem = result.deletingPathExtension().lastPathComponent
        let ext = result.pathExtension
        var suffix = 2
        while FileManager.default.fileExists(atPath: result.path) {
            result = directory.appendingPathComponent("\(stem) (\(suffix))" + (ext.isEmpty ? "" : ".\(ext)"))
            suffix += 1
        }
        return result
    }
}
