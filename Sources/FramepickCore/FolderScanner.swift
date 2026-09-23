import Foundation
import UniformTypeIdentifiers

public struct FolderEntry: Sendable {
    public let url: URL
    public let relativePath: String
    public let isVideo: Bool
    public let modifiedAt: Date?
}

public struct FolderScan: Sendable {
    public let entries: [FolderEntry]
    public let warnings: [String]
}

public enum FolderScanner {
    /// Enumerates metadata only; thumbnails are decoded lazily by the visible grid.
    public static func scan(_ root: URL, includesSubfolders: Bool) throws -> FolderScan {
        let manager = FileManager.default
        guard try root.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
            throw MediaError.message("폴더를 선택해 주세요.")
        }
        guard manager.isReadableFile(atPath: root.path) else { throw MediaError.message("폴더를 읽을 권한이 없습니다: \(root.lastPathComponent)") }
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .contentTypeKey, .contentModificationDateKey]
        var options: FileManager.DirectoryEnumerationOptions = [.skipsHiddenFiles, .skipsPackageDescendants]
        if !includesSubfolders { options.insert(.skipsSubdirectoryDescendants) }
        var warnings: [String] = []
        guard let enumerator = manager.enumerator(at: root, includingPropertiesForKeys: keys, options: options, errorHandler: { url, error in
            warnings.append("\(url.lastPathComponent): \(error.localizedDescription)"); return true
        }) else { throw MediaError.message("폴더를 열 수 없습니다: \(root.lastPathComponent)") }
        var entries: [FolderEntry] = []
        for case let url as URL in enumerator {
            try Task.checkCancellation()
            do {
                let values = try url.resourceValues(forKeys: Set(keys))
                guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
                let type = values.contentType ?? UTType(filenameExtension: url.pathExtension)
                let video = type?.conforms(to: .movie) == true
                guard video || type?.conforms(to: .image) == true else { continue }
                let prefix = root.standardizedFileURL.path + "/"
                let path = url.standardizedFileURL.path
                guard path.hasPrefix(prefix) else { continue }
                entries.append(FolderEntry(url: url, relativePath: String(path.dropFirst(prefix.count)), isVideo: video, modifiedAt: values.contentModificationDate))
            } catch { warnings.append("\(url.lastPathComponent): \(error.localizedDescription)") }
        }
        entries.sort { $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending }
        return FolderScan(entries: entries, warnings: warnings)
    }
}
