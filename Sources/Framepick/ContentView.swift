import SwiftUI
import UniformTypeIdentifiers
import FramepickCore

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @State private var dropTarget = false
    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 226)
            VStack(spacing: 0) {
                if !model.isShowingViewer {
                    header
                    Divider()
                }
                Group {
                    if model.page == .video { VideoWorkspace() }
                    else { PhotoWorkspace() }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                if !model.isShowingViewer { statusBar }
            }.background(Palette.background)
        }
        .frame(minWidth: 1060, minHeight: 740)
        .tint(Palette.accent)
        .preferredColorScheme(.light)
        .overlay {
            if dropTarget {
                RoundedRectangle(cornerRadius: 14).fill(Palette.accent.opacity(0.12))
                    .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Palette.accent, style: StrokeStyle(lineWidth: 3, dash: [10])))
                    .overlay(Label("사진 폴더나 파일을 여기에 놓으세요", systemImage: "folder.badge.plus")
                        .font(.title2.bold()).padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)))
                    .padding(10).allowsHitTesting(false)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $dropTarget) { providers in
            guard model.libraryReady, !model.isImporting else { return false }
            Task {
                var urls: [URL] = []
                for provider in providers {
                    let url: URL? = await withCheckedContinuation { continuation in
                        _ = provider.loadObject(ofClass: URL.self) { url, _ in continuation.resume(returning: url) }
                    }
                    if let url { urls.append(url) }
                }
                await model.importFiles(urls)
            }
            return true
        }
        .alert("작업을 완료하지 못했습니다", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("확인", role: .cancel) { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
        .sheet(item: $model.editingPhoto) { photo in PhotoEditor(photo: photo).environmentObject(model) }
        .sheet(isPresented: $model.showAISettings) { AISettingsView() }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "viewfinder").font(.system(size: 25, weight: .medium)).foregroundStyle(Color(red: 0.59, green: 0.77, blue: 1))
                Text("Framepick").font(.system(size: 23, weight: .semibold, design: .rounded)).tracking(-0.7)
            }.foregroundStyle(.white).padding(.horizontal, 22).padding(.top, 25)
            Text("좋은 순간만, 한 장씩.").font(.system(size: 11)).foregroundStyle(.white.opacity(0.55))
                .padding(.leading, 22).padding(.top, 8).padding(.bottom, 31)
            Text("보관함").font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.45)).padding(.horizontal, 24).padding(.bottom, 10)
            navItem(.video, symbol: "film", count: model.library.videos.count)
            navItem(.photos, symbol: "square.grid.2x2", count: model.availablePhotos.count)
            navItem(.favorites, symbol: "heart", count: model.favorites.count)
            Rectangle().fill(.white.opacity(0.09)).frame(height: 1).padding(.horizontal, 20).padding(.vertical, 24)
            HStack {
                Text("폴더와 동영상").font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.45))
                Spacer()
                Button(action: model.chooseFolder) { Image(systemName: "plus").foregroundStyle(.white.opacity(0.7)) }
                    .buttonStyle(.plain).help("사진 폴더 열기")
            }.padding(.horizontal, 24).padding(.bottom, 10)
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(model.library.folders) { folder in
                        Button { Task { await model.openFolder(folder.resolvedURL(), includesSubfolders: folder.includesSubfolders) } } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "folder").foregroundStyle(Color(red: 0.59, green: 0.77, blue: 1))
                                Text(folder.name).font(.system(size: 12)).lineLimit(1)
                                Spacer(minLength: 0)
                            }.foregroundStyle(.white.opacity(model.selectedFolderID == folder.id ? 1 : 0.65))
                                .padding(.horizontal, 12).padding(.vertical, 10)
                                .background(model.selectedFolderID == folder.id ? .white.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 7))
                        }.buttonStyle(.plain).disabled(model.isImporting).help(folder.path)
                            .contextMenu { Button("Finder에서 폴더 열기") { NSWorkspace.shared.open(folder.resolvedURL()) } }
                    }
                    ForEach(model.library.videos) { video in
                        Button { model.openVideo(video) } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "play.rectangle").foregroundStyle(.white.opacity(0.55))
                                Text(video.name).font(.system(size: 11)).lineLimit(2).multilineTextAlignment(.leading)
                                Spacer(minLength: 0)
                            }.foregroundStyle(.white.opacity(model.selectedVideoID == video.id ? 1 : 0.65))
                                .padding(.horizontal, 12).padding(.vertical, 10).frame(maxWidth: .infinity, alignment: .leading)
                                .background(model.selectedVideoID == video.id ? .white.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 7))
                        }.buttonStyle(.plain).contextMenu {
                            Button("Finder에서 보기") { NSWorkspace.shared.activateFileViewerSelecting([video.resolvedURL()]) }
                        }
                    }
                    if model.library.videos.isEmpty && model.library.folders.isEmpty {
                        Text("사진 폴더를 열면\n이곳에서 다시 찾을 수 있어요.").font(.system(size: 11)).lineSpacing(5)
                            .foregroundStyle(.white.opacity(0.35)).frame(maxWidth: .infinity, alignment: .leading).padding(12)
                    }
                }.padding(.horizontal, 12)
            }
            Spacer(minLength: 20)
            VStack(alignment: .leading, spacing: 9) {
                shortcut("프레임 이동", key: "←  →")
                shortcut("좋아요", key: "L")
                shortcut("사진 추출", key: "⌘ E")
            }.padding(14).background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 9)).padding(16)
            Button(action: model.chooseFolder) {
                HStack { Image(systemName: "folder.badge.plus"); Text("폴더 열기"); Spacer(); Text("⌘O").opacity(0.4) }
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.85)).padding(13)
                    .background(.white.opacity(0.09), in: RoundedRectangle(cornerRadius: 8))
            }.buttonStyle(.plain).disabled(!model.libraryReady || model.isImporting).padding(.horizontal, 16).padding(.bottom, 18)
        }.background(Palette.sidebar)
    }

    private func navItem(_ page: LibraryPage, symbol: String, count: Int) -> some View {
        Button { model.navigate(to: page) } label: {
            HStack(spacing: 11) {
                Image(systemName: model.page == page && page == .favorites ? "heart.fill" : symbol).frame(width: 18)
                Text(page.rawValue).font(.system(size: 13, weight: .medium))
                Spacer()
                Text("\(count)").font(.system(size: 11, design: .rounded)).foregroundStyle(.white.opacity(0.55))
            }.foregroundStyle(model.page == page && model.selectedFolderID == nil ? .white : .white.opacity(0.6))
                .padding(.horizontal, 13).padding(.vertical, 12)
                .background(model.page == page && model.selectedFolderID == nil ? Palette.accent.opacity(0.7) : .clear, in: RoundedRectangle(cornerRadius: 8))
        }.buttonStyle(.plain).padding(.horizontal, 12).padding(.vertical, 2)
    }

    private func shortcut(_ title: String, key: String) -> some View {
        HStack { Text(title); Spacer(); Text(key).font(.system(size: 10, design: .monospaced)) }
            .font(.system(size: 10)).foregroundStyle(.white.opacity(0.42))
    }

    private var header: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                Text(model.selectedFolder?.name ?? (model.page == .video ? "순간을 사진으로" : model.page == .photos ? "폴더에서 사진 고르기" : "좋아요한 순간"))
                    .font(.system(size: 21, weight: .semibold)).tracking(-0.5).foregroundStyle(Palette.ink)
                    .lineLimit(1)
                Text(model.page == .video ? "프레임마다 살펴보고, 마음에 드는 장면을 남기세요." : model.page == .photos ? "폴더를 열어 고르고, 다듬고, 마음에 드는 사진만 나누세요." : "마음에 든 사진만 모아, 가볍게 전하세요.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            if model.isImporting { ProgressView().controlSize(.small) }
            ActionButton(title: "파일 추가", symbol: "plus", action: model.chooseFiles).disabled(!model.libraryReady || model.isImporting)
            ActionButton(title: "폴더 열기", symbol: "folder", prominent: true, action: model.chooseFolder).disabled(!model.libraryReady || model.isImporting)
        }.padding(.horizontal, 26).padding(.vertical, 20).background(.white)
    }

    private var statusBar: some View {
        HStack(spacing: 7) {
            if let notice = model.notice {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.accent)
                Text(notice).foregroundStyle(Palette.ink)
            } else {
                Image(systemName: "internaldrive").foregroundStyle(.secondary)
                Text(model.isImporting ? model.importStatus : model.selectedFolderID != nil ? "원본 폴더에서 열기 · 좋아요는 이 Mac에 저장" : "이 Mac에 보관됨").foregroundStyle(.secondary)
            }
            Spacer()
            Text(model.page == .video ? "← → 한 프레임  ·  ⇧← → 10프레임  ·  Space 재생" : "클릭으로 크게 보기  ·  ⌘클릭으로 여러 장 선택")
                .foregroundStyle(.secondary)
        }.font(.system(size: 10)).padding(.horizontal, 20).frame(height: 32).background(.white)
    }
}
