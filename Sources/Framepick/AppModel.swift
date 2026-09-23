import AppKit
import AVKit
import SwiftUI
import UniformTypeIdentifiers
import FramepickCore

enum LibraryPage: String, CaseIterable { case video = "동영상", photos = "모든 사진", favorites = "좋아요" }

@MainActor
final class AppModel: ObservableObject {
    @Published var library = LibrarySnapshot()
    @Published var page: LibraryPage = .photos
    @Published var selectedFolderID: UUID?
    @Published var favoritesOnly = false
    @Published var minimumRating = 0
    @Published var rejectionFilter: PhotoRejectionFilter = .all
    @Published var photoSortOrder: PhotoSortOrder = .automatic
    @Published var comparisonPhotoIDs: [UUID] = []
    @Published var copiedAdjustments: PhotoAdjustments?
    @Published var isBatchEditing = false
    @Published var batchProgress = ""
    @Published var showAISettings = false
    @Published var importStatus = ""
    @Published var editingPhoto: PhotoRecord?
    @Published var selectedVideoID: UUID?
    @Published var videoIndex: VideoIndex?
    @Published var frameNumber = 0
    @Published var videoRotation = 0
    @Published var isIndexing = false
    @Published var indexProgress = 0.0
    @Published var isPlaying = false
    @Published var isImporting = false
    @Published var isCapturing = false
    @Published var isExporting = false
    @Published var isSavingEdit = false
    @Published var libraryReady = false
    @Published var errorMessage: String?
    @Published var notice: String?
    @Published var selectedPhotos: Set<UUID> = []
    @Published var focusedPhotoID: UUID?
    @Published var captureFormat: CaptureFormat = .png
    @Published var showAllFrames = false
    @Published var framePage = 0
    @Published var search = ""
    @Published var thumbnailSize = 190.0
    let disk: LibraryDisk
    let player = AVPlayer()
    var thumbnailRenderer: FrameRenderer?
    var fullRenderer: FrameRenderer?
    private var observer: Any?
    private var indexTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?
    private var noticeTask: Task<Void, Never>?
    private var batchTask: Task<Void, Never>?
    private var scopedURLs: [URL] = []
    private let sharing = AirDropCoordinator()
    let framesPerPage = 120

    init(root: URL? = nil) {
        let standardRoot = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Framepick", isDirectory: true)
        let override = ProcessInfo.processInfo.environment["FRAMEPICK_LIBRARY_PATH"].map { URL(fileURLWithPath: $0) }
        disk = LibraryDisk(root: root ?? override ?? standardRoot)
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, self.isPlaying, let index = self.videoIndex else { return }
                self.frameNumber = index.frame(at: time.seconds)
                self.framePage = self.frameNumber / self.framesPerPage
                if self.player.rate == 0 && time.seconds >= index.duration - 0.1 { self.pause() }
            }
        }
    }

    deinit {
        if let observer { player.removeTimeObserver(observer) }
        indexTask?.cancel(); noticeTask?.cancel()
        for url in scopedURLs { url.stopAccessingSecurityScopedResource() }
    }

    func load() async {
        do {
            library = try await disk.load(); libraryReady = true
            for folder in library.folders {
                let url = folder.resolvedURL()
                retainAccess(to: url)
                for index in library.photos.indices where library.photos[index].folderID == folder.id {
                    if let relativePath = library.photos[index].relativePath, library.photos[index].sourcePath != nil {
                        library.photos[index].sourcePath = url.appendingPathComponent(relativePath).path
                    }
                }
            }
        }
        catch { errorMessage = "보관함을 열지 못했습니다. 기존 데이터를 보호하기 위해 저장을 중지했습니다.\n\(error.localizedDescription)" }
    }

    var selectedVideo: VideoRecord? { library.videos.first { $0.id == selectedVideoID } }
    var availablePhotos: [PhotoRecord] { library.photos.filter { $0.isMissing != true } }
    var favorites: [PhotoRecord] { availablePhotos.filter(\.isFavorite) }
    var selectedFolder: FolderRecord? { library.folders.first { $0.id == selectedFolderID } }
    var focusedPhoto: PhotoRecord? { visiblePhotos.first { $0.id == focusedPhotoID } }
    var focusedPhotoPosition: Int { visiblePhotos.firstIndex { $0.id == focusedPhotoID } ?? 0 }
    var isShowingViewer: Bool { page == .video ? videoIndex != nil : focusedPhoto != nil || comparisonPhotos.count == 2 }
    var folderVideos: [VideoRecord] { guard let selectedFolderID else { return [] }; return library.videos.filter { $0.folderID == selectedFolderID } }
    var visiblePhotos: [PhotoRecord] {
        let source = page == .favorites || favoritesOnly ? favorites : availablePhotos
        let filtered = source.filter { (selectedFolderID == nil || $0.folderID == selectedFolderID) && (search.isEmpty || $0.displayName.localizedCaseInsensitiveContains(search)) }
        return applyCulling(to: filtered)
    }
    var exportPhotos: [PhotoRecord] {
        selectedPhotos.isEmpty ? visiblePhotos : visiblePhotos.filter { selectedPhotos.contains($0.id) }
    }
    var airDropPhotos: [PhotoRecord] {
        let source = page == .video ? favorites : visiblePhotos.filter(\.isFavorite)
        return selectedPhotos.isEmpty ? source : source.filter { selectedPhotos.contains($0.id) }
    }
    var currentCapture: PhotoRecord? {
        library.photos.first { $0.videoID == selectedVideoID && $0.frameNumber == frameNumber && ($0.captureQuarterTurns ?? 0) == videoRotation && $0.editedFromID == nil }
    }
    var totalFramePages: Int { max(1, ((videoIndex?.frames.count ?? 0) + framesPerPage - 1) / framesPerPage) }
    var pagedFrames: Range<Int> {
        let total = videoIndex?.frames.count ?? 0
        let start = min(framePage * framesPerPage, total)
        return start..<min(start + framesPerPage, total)
    }

    func navigate(to page: LibraryPage) {
        pause(); self.page = page; selectedFolderID = nil; favoritesOnly = false; selectedPhotos.removeAll(); focusedPhotoID = nil; comparisonPhotoIDs = []; search = ""
    }

    func chooseFolder() {
        guard libraryReady, !isImporting else { return }
        let panel = NSOpenPanel()
        panel.title = "사진과 동영상이 있는 폴더 열기"; panel.prompt = "폴더 열기"
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        let checkbox = NSButton(checkboxWithTitle: "하위 폴더도 포함", target: nil, action: nil)
        checkbox.state = .on; checkbox.frame = NSRect(x: 0, y: 0, width: 240, height: 28)
        panel.accessoryView = checkbox
        panel.begin { [weak self] result in
            guard result == .OK, let url = panel.url else { return }
            Task { @MainActor in await self?.openFolder(url, includesSubfolders: checkbox.state == .on) }
        }
    }

    func openFolder(_ url: URL, includesSubfolders: Bool = true) async {
        guard libraryReady, !isImporting else { return }
        isImporting = true; importStatus = "\(url.lastPathComponent) 폴더 읽는 중…"
        defer { isImporting = false; importStatus = "" }
        retainAccess(to: url)
        do {
            let scan = try await Task.detached(priority: .userInitiated) { try FolderScanner.scan(url, includesSubfolders: includesSubfolders) }.value
            let existing = library.folders.first { $0.resolvedURL().standardizedFileURL == url.standardizedFileURL }
            var folder = existing ?? FolderRecord(url: url, includesSubfolders: includesSubfolders)
            folder.includesSubfolders = includesSubfolders; folder.path = url.path
            if let offset = library.folders.firstIndex(where: { $0.id == folder.id }) { library.folders[offset] = folder }
            else { library.folders.append(folder) }
            var oldPhotos: [String: Int] = [:]
            for offset in library.photos.indices where library.photos[offset].folderID == folder.id && library.photos[offset].sourcePath != nil {
                if let path = library.photos[offset].relativePath { oldPhotos[path] = offset }
                // Keep missing-file metadata so likes return if a drive is reconnected.
                if scan.warnings.isEmpty { library.photos[offset].isMissing = true }
            }
            for entry in scan.entries {
                if entry.isVideo {
                    if let offset = library.videos.firstIndex(where: { $0.resolvedURL().standardizedFileURL == entry.url.standardizedFileURL }) { library.videos[offset].folderID = folder.id }
                    else { library.videos.append(VideoRecord(url: entry.url, folderID: folder.id)) }
                } else if let offset = oldPhotos[entry.relativePath] {
                    library.photos[offset].sourcePath = entry.url.path
                    library.photos[offset].sourceModifiedAt = entry.modifiedAt
                    library.photos[offset].isMissing = false
                } else {
                    library.photos.append(PhotoRecord(filename: entry.url.lastPathComponent, displayName: entry.url.lastPathComponent,
                                                      folderID: folder.id, sourcePath: entry.url.path, relativePath: entry.relativePath, sourceModifiedAt: entry.modifiedAt))
                }
            }
            pause(); page = .photos; selectedFolderID = folder.id; favoritesOnly = false; search = ""; selectedPhotos.removeAll(); focusedPhotoID = nil; comparisonPhotoIDs = []
            persist()
            showNotice("\(folder.name) · 사진 \(scan.entries.filter { !$0.isVideo }.count)장, 동영상 \(scan.entries.filter(\.isVideo).count)개")
            if !scan.warnings.isEmpty { errorMessage = "일부 파일을 읽지 못했습니다.\n" + scan.warnings.prefix(5).joined(separator: "\n") }
        } catch { errorMessage = error.localizedDescription }
    }

    func refreshFolder() {
        guard let folder = selectedFolder else { return }
        Task { await openFolder(folder.resolvedURL(), includesSubfolders: folder.includesSubfolders) }
    }
    private func retainAccess(to url: URL) {
        guard !scopedURLs.contains(url), url.startAccessingSecurityScopedResource() else { return }
        scopedURLs.append(url)
    }

    func chooseFiles() {
        guard libraryReady, !isImporting else { return }
        let panel = NSOpenPanel()
        panel.title = "동영상 또는 사진 가져오기"
        panel.prompt = "가져오기"
        panel.allowedContentTypes = [.movie, .image]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.begin { [weak self] result in
            guard result == .OK else { return }
            Task { @MainActor in await self?.importFiles(panel.urls) }
        }
    }

    func importFiles(_ urls: [URL]) async {
        guard libraryReady, !isImporting else { return }
        var files: [URL] = []
        for url in urls {
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true { await openFolder(url) }
            else { files.append(url) }
        }
        guard !files.isEmpty else { return }
        isImporting = true
        defer { isImporting = false }
        var errors: [String] = [], firstVideo: VideoRecord?, photoCount = 0
        for url in files {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let type = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType ?? UTType(filenameExtension: url.pathExtension)
            if type?.conforms(to: .movie) == true {
                let record: VideoRecord
                if let existing = library.videos.first(where: { $0.resolvedURL().standardizedFileURL == url.standardizedFileURL }) { record = existing }
                else { record = VideoRecord(url: url); library.videos.append(record) }
                if firstVideo == nil { firstVideo = record }
            } else if type?.conforms(to: .image) == true {
                do { library.photos.append(try await disk.importPhoto(from: url)); photoCount += 1 }
                catch { errors.append(error.localizedDescription) }
            } else { errors.append("지원하지 않는 파일: \(url.lastPathComponent)") }
        }
        persist()
        if let firstVideo { openVideo(firstVideo) }
        else if photoCount > 0 { navigate(to: .photos) }
        if photoCount > 0 { showNotice("사진 \(photoCount)장을 보관함에 추가했습니다") }
        if !errors.isEmpty { errorMessage = errors.prefix(5).joined(separator: "\n") + (errors.count > 5 ? "\n외 \(errors.count - 5)개 오류" : "") }
    }

    func openVideo(_ video: VideoRecord) {
        indexTask?.cancel(); pause()
        player.replaceCurrentItem(with: nil)
        selectedVideoID = video.id; videoIndex = nil; frameNumber = 0; framePage = 0
        videoRotation = video.quarterTurns ?? 0
        thumbnailRenderer = nil; fullRenderer = nil
        page = .video; focusedPhotoID = nil; comparisonPhotoIDs = []; selectedFolderID = nil; favoritesOnly = false; selectedPhotos.removeAll(); search = ""; isIndexing = true; indexProgress = 0
        let url = video.resolvedURL()
        retainAccess(to: url)
        indexTask = Task {
            let work = Task.detached(priority: .userInitiated) {
                try await VideoIndexer.read(url: url) { [weak self] progress in
                    Task { @MainActor in
                        guard self?.selectedVideoID == video.id else { return }
                        self?.indexProgress = progress
                    }
                }
            }
            do {
                let index = try await withTaskCancellationHandler(operation: { try await work.value }, onCancel: { work.cancel() })
                try Task.checkCancellation()
                videoIndex = index
                thumbnailRenderer = FrameRenderer(url: url, maxPixelSize: 360)
                fullRenderer = FrameRenderer(url: url, maxPixelSize: 0)
                player.replaceCurrentItem(with: AVPlayerItem(url: url))
                isIndexing = false
            } catch is CancellationError {} catch {
                guard !Task.isCancelled else { return }
                isIndexing = false
                errorMessage = "동영상을 열지 못했습니다. 원본 파일이 이동되었다면 다시 가져와 주세요.\n\(error.localizedDescription)"
            }
        }
    }

    func cancelIndexing() { indexTask?.cancel(); isIndexing = false }
    func selectFrame(_ number: Int) {
        guard let index = videoIndex else { return }
        pause(); frameNumber = max(0, min(number, index.frames.count - 1))
        framePage = frameNumber / framesPerPage
    }
    func step(_ offset: Int) { selectFrame(frameNumber + offset) }
    func rotateVideo(_ amount: Int) {
        guard videoIndex != nil else { return }
        pause(); videoRotation = (videoRotation + amount + 4) % 4
        if let offset = library.videos.firstIndex(where: { $0.id == selectedVideoID }) { library.videos[offset].quarterTurns = videoRotation; persist() }
    }
    func pause() { player.pause(); isPlaying = false }
    func togglePlayback() {
        guard let index = videoIndex else { return }
        if isPlaying { pause(); framePage = frameNumber / framesPerPage }
        else {
            if frameNumber == index.frames.count - 1 { frameNumber = 0 }
            player.seek(to: index.frames[frameNumber].time, toleranceBefore: .zero, toleranceAfter: .zero)
            isPlaying = true; player.play()
        }
    }

    func capture(favorite: Bool = false) {
        guard !isCapturing, libraryReady, let index = videoIndex, let video = selectedVideo, let renderer = fullRenderer else { return }
        pause()
        if let existing = currentCapture {
            if favorite { toggleFavorite(existing.id) }
            else { showNotice("이미 저장한 프레임입니다. ‘모든 사진’에서 확인하세요") }
            return
        }
        let number = frameNumber, stamp = index.frames[frameNumber], format = captureFormat, rotation = videoRotation
        isCapturing = true
        Task {
            defer { isCapturing = false }
            do {
                let image = try await renderer.image(at: stamp, quarterTurns: rotation)
                let photo = try await disk.capture(image: image, video: video, frame: number, stamp: stamp, format: format, favorite: favorite, quarterTurns: rotation)
                library.photos.append(photo); persist()
                showNotice(favorite ? "원본 크기로 저장하고 좋아요에 추가했습니다" : "원본 크기의 사진을 보관함에 저장했습니다")
            } catch { errorMessage = error.localizedDescription }
        }
    }

    func toggleFavorite(_ id: UUID) {
        guard libraryReady, let index = library.photos.firstIndex(where: { $0.id == id }) else { return }
        library.photos[index].isFavorite.toggle(); persist()
        if (page == .favorites || favoritesOnly) && !library.photos[index].isFavorite { selectedPhotos.remove(id) }
        reconcilePhotoFocus()
    }
    func selectPhoto(_ id: UUID, extending: Bool) {
        if extending {
            if selectedPhotos.contains(id) { selectedPhotos.remove(id) } else { selectedPhotos.insert(id) }
        } else { selectedPhotos = [id] }
        focusedPhotoID = id
    }
    func stepPhoto(_ offset: Int) {
        let photos = visiblePhotos
        guard !photos.isEmpty else { return }
        let next = max(0, min(photos.count - 1, focusedPhotoPosition + offset))
        selectPhoto(photos[next].id, extending: false)
    }
    func showPhotoGrid() { focusedPhotoID = nil; comparisonPhotoIDs = [] }
    func reconcilePhotoFocus() {
        guard let focusedPhotoID else { return }
        let visible = visiblePhotos
        if !visible.contains(where: { $0.id == focusedPhotoID }) {
            self.focusedPhotoID = visible.first?.id
            selectedPhotos = Set(visible.prefix(1).map(\.id))
        }
    }
    func selectAllPhotos() { selectedPhotos = Set(visiblePhotos.map(\.id)) }
    func toggleSelectedFavorites() {
        let records = library.photos.filter { selectedPhotos.contains($0.id) }
        guard !records.isEmpty else { return }
        let value = !records.allSatisfy(\.isFavorite)
        for index in library.photos.indices where selectedPhotos.contains(library.photos[index].id) { library.photos[index].isFavorite = value }
        if (page == .favorites || favoritesOnly) && !value { selectedPhotos.removeAll() }
        reconcilePhotoFocus()
        persist()
    }

    func editSelection() {
        guard selectedPhotos.count == 1, let id = selectedPhotos.first else { return }
        editingPhoto = library.photos.first { $0.id == id }
    }
    func editSource(for photo: PhotoRecord) -> PhotoRecord {
        guard photo.savedAdjustments != nil, let id = photo.editedFromID,
              let source = library.photos.first(where: { $0.id == id }) else { return photo }
        return source
    }
    func copyAdjustments(_ adjustments: PhotoAdjustments) {
        var colorOnly = adjustments.normalized()
        colorOnly.crop = .full; colorOnly.quarterTurns = 0; colorOnly.straighten = 0
        copiedAdjustments = colorOnly
        showNotice("색상·얼굴 보정 설정을 복사했습니다. 여러 사진에 적용할 수 있어요")
    }
    func saveEdits(for original: PhotoRecord, adjustments: PhotoAdjustments, format: CaptureFormat) async throws {
        guard libraryReady, !isSavingEdit, !isBatchEditing else { throw MediaError.message("다른 사진을 저장하는 중입니다.") }
        isSavingEdit = true
        defer { isSavingEdit = false }
        let source = editSource(for: original)
        let image = try await ImageEditor.shared.render(url: disk.url(for: source), adjustments: adjustments)
        let updatedOriginal = library.photos.first { $0.id == original.id } ?? original
        let photo = try await disk.saveEditedCopy(image, original: updatedOriginal, format: format, adjustments: adjustments, sourceID: source.id)
        library.photos.append(photo); selectedPhotos = [photo.id]; comparisonPhotoIDs = []; focusedPhotoID = photo.id; persist()
        await flush()
        showNotice("편집한 사진을 복사본으로 저장했습니다")
    }

    func batchApplyCopiedAdjustments() {
        guard libraryReady, let adjustments = copiedAdjustments, !isBatchEditing, !isSavingEdit else { return }
        let originals = visiblePhotos.filter { selectedPhotos.contains($0.id) }
        guard !originals.isEmpty else { return }
        isBatchEditing = true
        batchTask = Task {
            var completed: [UUID] = []
            defer { isBatchEditing = false; batchProgress = ""; selectedPhotos = Set(completed); batchTask = nil }
            do {
                for (index, original) in originals.enumerated() {
                    try Task.checkCancellation()
                    batchProgress = "\(index + 1) / \(originals.count)장 보정 중"
                    let source = editSource(for: original)
                    var applied = adjustments
                    if let previous = original.savedAdjustments {
                        applied.crop = previous.crop; applied.quarterTurns = previous.quarterTurns; applied.straighten = previous.straighten
                    }
                    let image = try await ImageEditor.shared.render(url: disk.url(for: source), adjustments: applied)
                    try Task.checkCancellation()
                    let photo = try await disk.saveEditedCopy(image, original: original, format: .jpeg, adjustments: applied, sourceID: source.id)
                    library.photos.append(photo); completed.append(photo.id); persist()
                }
                showNotice("\(completed.count)장의 보정 복사본을 저장했습니다")
            } catch is CancellationError { showNotice("일괄 보정을 중지했습니다. 완료한 \(completed.count)장은 보관함에 남습니다") }
            catch { errorMessage = "\(completed.count)장 보정 후 중단되었습니다.\n\(error.localizedDescription)" }
            await flush()
        }
    }
    func cancelBatchEdits() { batchTask?.cancel() }

    func exportSelection() {
        let photos = exportPhotos
        guard !photos.isEmpty, !isExporting else { return }
        let panel = NSOpenPanel()
        panel.title = "사진 \(photos.count)장을 저장할 폴더 선택"
        panel.prompt = "여기에 저장"; panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true
        panel.begin { [weak self] response in
            guard response == .OK, let directory = panel.url else { return }
            Task { @MainActor in
                guard let self else { return }
                self.isExporting = true
                let scoped = directory.startAccessingSecurityScopedResource()
                defer { self.isExporting = false; if scoped { directory.stopAccessingSecurityScopedResource() } }
                do {
                    let urls = try await self.disk.export(photos, to: directory)
                    self.showNotice("사진 \(urls.count)장을 저장했습니다")
                    NSWorkspace.shared.activateFileViewerSelecting(urls)
                } catch { self.errorMessage = error.localizedDescription }
            }
        }
    }

    func airDropFavorites() {
        let photos = airDropPhotos
        guard !photos.isEmpty, !isExporting else { return }
        isExporting = true
        Task {
            defer { isExporting = false }
            do {
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Framepick-Share-\(UUID().uuidString)")
                let files = try await disk.export(photos, to: directory)
                try sharing.send(files) { [weak self] error in
                    if let error { self?.errorMessage = error }
                }
            } catch { errorMessage = error.localizedDescription }
        }
    }

    func persist() {
        guard libraryReady else { return }
        let snapshot = library, previous = saveTask
        saveTask = Task {
            await previous?.value
            do { try await disk.save(snapshot) }
            catch { errorMessage = "변경사항을 저장하지 못했습니다.\n\(error.localizedDescription)" }
        }
    }
    func flush() async { await saveTask?.value }
    func finishPendingOperations() async {
        indexTask?.cancel()
        batchTask?.cancel()
        while isImporting || isCapturing || isExporting || isSavingEdit || isBatchEditing { try? await Task.sleep(for: .milliseconds(50)) }
        await flush()
    }
    func showNotice(_ text: String) {
        noticeTask?.cancel(); notice = text
        noticeTask = Task {
            try? await Task.sleep(for: .seconds(3))
            if !Task.isCancelled { notice = nil }
        }
    }
}

@MainActor
final class AirDropCoordinator: NSObject, NSSharingServiceDelegate {
    private var active: NSSharingService?
    private var completion: ((String?) -> Void)?
    func send(_ files: [URL], completion: @escaping (String?) -> Void) throws {
        guard active == nil else { throw MediaError.message("열려 있는 AirDrop 창에서 전송을 완료하거나 취소해 주세요.") }
        guard let service = NSSharingService(named: .sendViaAirDrop), service.canPerform(withItems: files) else {
            throw MediaError.message("이 Mac에서 AirDrop을 사용할 수 없습니다. Wi-Fi와 Bluetooth를 켜고 Finder의 AirDrop을 확인해 주세요. 사진은 ‘폴더에 저장’으로 내보낼 수 있습니다.")
        }
        self.completion = completion; active = service; service.delegate = self
        service.perform(withItems: files)
    }
    func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) { finish(nil) }
    func sharingService(_ sharingService: NSSharingService, didFailToShareItems items: [Any], error: Error) {
        let nsError = error as NSError
        finish(nsError.code == NSUserCancelledError ? nil : error.localizedDescription)
    }
    private func finish(_ error: String?) { completion?(error); completion = nil; active = nil }
}
