import SwiftUI
import AppKit

@main
struct FramepickApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel()
    var body: some Scene {
        Window("Framepick", id: "main") {
            ContentView().environmentObject(model)
                .task {
                    delegate.model = model
                    await model.load()
                    delegate.ready = true
                    if !delegate.pendingURLs.isEmpty {
                        await model.importFiles(delegate.pendingURLs); delegate.pendingURLs.removeAll()
                    }
                    if let argument = CommandLine.arguments.firstIndex(of: "--import") {
                        let paths = CommandLine.arguments.dropFirst(argument + 1).prefix { !$0.hasPrefix("--") }
                        await model.importFiles(paths.map { URL(fileURLWithPath: $0) })
                    }
                    if CommandLine.arguments.contains("--render-preview") { await delegate.renderPreview() }
                }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1320, height: 880)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("ChatGPT AI 설정…") { model.showAISettings = true }.keyboardShortcut(",")
            }
            CommandGroup(replacing: .newItem) {
                Button("사진 폴더 열기…", action: model.chooseFolder).keyboardShortcut("o")
                    .disabled(!model.libraryReady || model.isImporting)
                Button("동영상 또는 사진 파일 추가…", action: model.chooseFiles).keyboardShortcut("o", modifiers: [.command, .shift])
                    .disabled(!model.libraryReady || model.isImporting)
            }
            CommandMenu("사진") {
                Button("선택한 사진 편집…", action: model.editSelection).keyboardShortcut("e", modifiers: [.command, .shift])
                    .disabled(model.page == .video || model.selectedPhotos.count != 1)
                Button("현재 프레임 사진 추출") { model.capture() }.keyboardShortcut("e")
                    .disabled(model.page != .video || model.videoIndex == nil || model.isCapturing)
                Button("선택한 사진 모두 선택", action: model.selectAllPhotos).keyboardShortcut("a")
                    .disabled(model.page == .video)
                Button("선택한 두 사진 비교", action: model.startPhotoComparison).keyboardShortcut("c", modifiers: [.command, .shift])
                    .disabled(model.page == .video || model.selectedPhotos.count != 2)
                Button("복사한 보정값 일괄 적용", action: model.batchApplyCopiedAdjustments)
                    .disabled(model.page == .video || model.selectedPhotos.isEmpty || model.copiedAdjustments == nil || model.isBatchEditing)
                Button("선택한 사진 폴더에 저장…", action: model.exportSelection).keyboardShortcut("s", modifiers: [.command, .shift])
                    .disabled(model.page == .video || model.exportPhotos.isEmpty || model.isExporting)
                Button("좋아요한 사진 AirDrop…", action: model.airDropFavorites).keyboardShortcut("a", modifiers: [.command, .shift])
                    .disabled(model.airDropPhotos.isEmpty || model.isExporting)
            }
            CommandMenu("보관함") {
                Button("동영상") { model.navigate(to: .video) }.keyboardShortcut("1")
                Button("모든 사진") { model.navigate(to: .photos) }.keyboardShortcut("2")
                Button("좋아요") { model.navigate(to: .favorites) }.keyboardShortcut("3")
                Divider()
                Button("보관함 폴더 열기") { NSWorkspace.shared.open(model.disk.root) }
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?
    var ready = false
    var pendingURLs: [URL] = []
    private var keyMonitor: Any?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let consumed = MainActor.assumeIsolated { self?.handleKey(event) == nil }
            return consumed ? nil : event
        }
    }
    func application(_ application: NSApplication, open urls: [URL]) {
        guard ready, let model else { pendingURLs.append(contentsOf: urls); return }
        Task { await model.importFiles(urls) }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        model.pause()
        CodexAIService.shared.disconnect()
        Task { await model.finishPendingOperations(); sender.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
    private func handleKey(_ event: NSEvent) -> NSEvent? {
        guard let model, NSApp.keyWindow?.attachedSheet == nil, model.editingPhoto == nil, !model.showAISettings,
              !(NSApp.keyWindow?.firstResponder is NSTextView) else { return event }
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if model.page != .video, modifiers == [.control],
           let character = event.charactersIgnoringModifiers, let rating = Int(character), (0...5).contains(rating) {
            model.setPhotoRating(rating); return nil
        }
        guard modifiers.intersection([.command, .control, .option]).isEmpty else { return event }
        if model.page == .video, model.videoIndex != nil {
            let step = event.modifierFlags.contains(.shift) ? 10 : 1
            switch event.keyCode {
            case 123: model.step(-step)
            case 124: model.step(step)
            case 49: model.togglePlayback()
            case 37: model.capture(favorite: true)
            case 115: model.selectFrame(0)
            case 119: model.selectFrame((model.videoIndex?.frames.count ?? 1) - 1)
            default: return event
            }
            return nil
        } else if model.page != .video {
            switch event.keyCode {
            case 37:
                if model.selectedPhotos.count <= 1, let photo = model.focusedPhoto { model.toggleFavorite(photo.id) }
                else { model.toggleSelectedFavorites() }
                return nil
            case 123 where model.focusedPhotoID != nil: model.stepPhoto(-1); return nil
            case 124 where model.focusedPhotoID != nil: model.stepPhoto(1); return nil
            case 7: model.toggleSelectedRejection(); return nil
            case 53 where model.focusedPhotoID != nil || model.comparisonPhotos.count == 2: model.showPhotoGrid(); return nil
            default: break
            }
        }
        return event
    }

    /// Render this app's own view tree for repeatable visual checks; never captures other apps.
    func renderPreview() async {
        guard let model else { return }
        let mode = ProcessInfo.processInfo.environment["FRAMEPICK_PREVIEW_MODE"]
        if (mode == "video" || mode == "grid"), model.videoIndex == nil, let video = model.library.videos.first { model.openVideo(video) }
        while model.isIndexing || model.isCapturing { try? await Task.sleep(for: .milliseconds(100)) }
        try? await Task.sleep(for: .seconds(2))
        if mode == "grid" { model.showAllFrames = true }
        if mode == "favorites" { model.navigate(to: .favorites) }
        if mode == "editor" { model.editingPhoto = model.visiblePhotos.first }
        if mode == "photo", let photo = model.visiblePhotos.first { model.selectPhoto(photo.id, extending: false) }
        try? await Task.sleep(for: .seconds(2))
        let previewWindow = mode == "editor" ? NSApp.windows.first(where: { $0.sheetParent != nil }) : NSApp.windows.first(where: { $0.contentView?.bounds.width ?? 0 > 500 })
        guard let view = previewWindow?.contentView,
              let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            print("Preview rendering failed: no content view. Windows: \(NSApp.windows.map { $0.title })")
            return
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        if let data = bitmap.representation(using: .png, properties: [:]) {
            let path = ProcessInfo.processInfo.environment["FRAMEPICK_PREVIEW_PATH"] ?? "/tmp/framepick-preview.png"
            try? data.write(to: URL(fileURLWithPath: path))
            print("Preview saved: \(path)")
        }
        if CommandLine.arguments.contains("--quit-after-preview") {
            // Finish this actor task before AppKit enters its termination run loop,
            // so the delegate's asynchronous save can run on the main actor.
            RunLoop.main.perform { NSApp.terminate(nil) }
        }
    }
}
