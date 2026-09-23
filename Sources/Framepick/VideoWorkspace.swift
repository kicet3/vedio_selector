import SwiftUI
import AVKit
import FramepickCore

struct VideoWorkspace: View {
    @EnvironmentObject var model: AppModel
    @State private var jumpInput = "1"
    @StateObject private var zoom = ImageZoom()
    var body: some View {
        Group {
            if model.isIndexing { indexing }
            else if let index = model.videoIndex {
                HSplitView {
                    preview(index)
                        .overlay(alignment: .bottom) { transport(index).padding(12) }
                        .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
                    frameSidebar(index).frame(minWidth: 244, idealWidth: 258, maxWidth: 340, maxHeight: .infinity)
                }
            } else { welcome }
        }
        .onChange(of: model.frameNumber) { _, value in jumpInput = String(value + 1) }
        .onChange(of: model.selectedVideoID) { _, _ in jumpInput = "1" }
    }

    private var indexing: some View {
        VStack(spacing: 18) {
            Image(systemName: "film.stack").font(.system(size: 44, weight: .ultraLight)).foregroundStyle(Palette.accent)
            Text("모든 프레임을 확인하고 있어요").font(.title3.weight(.semibold))
            Text(model.selectedVideo?.name ?? "").font(.caption).foregroundStyle(.secondary)
            ProgressView(value: model.indexProgress).frame(width: 280)
            Text("영상 길이에 따라 잠시 걸릴 수 있습니다.").font(.caption).foregroundStyle(.secondary)
            Button("취소", action: model.cancelIndexing)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var welcome: some View {
        VStack(spacing: 0) {
            Spacer()
            HStack(spacing: 12) {
                filmCell("play.fill", selected: false).rotationEffect(.degrees(-7)).offset(y: 10)
                filmCell("viewfinder", selected: true).zIndex(1)
                filmCell("heart.fill", selected: false).rotationEffect(.degrees(7)).offset(y: 10)
            }.padding(.bottom, 36)
            Text("지나간 장면도, 간직할 수 있도록.").font(.system(size: 27, weight: .semibold)).tracking(-0.8).foregroundStyle(Palette.ink)
            Text("동영상의 모든 프레임에서 가장 좋은 한 장을 찾아보세요.\n사진을 함께 가져와 좋아요로 고르고, AirDrop으로 나눌 수 있어요.")
                .font(.system(size: 13)).lineSpacing(7).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.top, 15)
            ActionButton(title: "동영상 또는 사진 가져오기", symbol: "plus", prominent: true, action: model.chooseFiles)
                .disabled(!model.libraryReady).padding(.top, 27)
            Text("파일을 이 창에 끌어다 놓아도 됩니다").font(.system(size: 11)).foregroundStyle(.tertiary).padding(.top, 12)
            Spacer()
            HStack(alignment: .top, spacing: 45) {
                feature("rectangle.split.3x1", "빠짐없는 프레임", "한 프레임씩 이동하고\n전체 장면을 펼쳐보세요.")
                feature("photo.badge.plus", "원본 크기로 추출", "선택한 장면을 PNG 또는\nJPEG 사진으로 저장하세요.")
                feature("heart", "고르고, 나누고", "좋아요한 사진만 모아\nAirDrop으로 전달하세요.")
            }.padding(.bottom, 44)
        }.padding(30).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private func filmCell(_ icon: String, selected: Bool) -> some View {
        VStack(spacing: 8) {
            HStack(spacing: 13) { ForEach(0..<6) { _ in RoundedRectangle(cornerRadius: 1).frame(width: 7, height: 4) } }.opacity(0.18)
            Image(systemName: icon).font(.system(size: selected ? 36 : 25, weight: .ultraLight))
                .frame(width: 135, height: 85).background(selected ? Palette.accent.opacity(0.09) : .white.opacity(0.07), in: RoundedRectangle(cornerRadius: 4))
            HStack(spacing: 13) { ForEach(0..<6) { _ in RoundedRectangle(cornerRadius: 1).frame(width: 7, height: 4) } }.opacity(0.18)
        }.padding(9).foregroundStyle(selected ? Palette.accent : .white.opacity(0.65))
            .background(selected ? .white : Palette.sidebar, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(selected ? Palette.accent.opacity(0.3) : .clear))
            .shadow(color: .black.opacity(0.07), radius: 14, y: 6)
    }
    private func feature(_ icon: String, _ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Image(systemName: icon).font(.system(size: 20, weight: .light)).foregroundStyle(Palette.accent).padding(.bottom, 3)
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.ink)
            Text(detail).font(.system(size: 11)).lineSpacing(4).foregroundStyle(.secondary)
        }.frame(width: 165, alignment: .leading)
    }

    private func frameSidebar(_ index: VideoIndex) -> some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("프레임 리스트").font(.system(size: 13, weight: .semibold))
                    Spacer()
                    IconButton(symbol: model.showAllFrames ? "rectangle.grid.1x2" : "square.grid.2x2", label: "프레임 목록 한 열 / 두 열 전환") { model.showAllFrames.toggle() }
                }
                Text(model.selectedVideo?.name ?? "동영상").font(.system(size: 11, weight: .medium)).lineLimit(1).help(model.selectedVideo?.name ?? "")
                Text("\(model.videoRotation % 2 == 0 ? index.width : index.height) × \(model.videoRotation % 2 == 0 ? index.height : index.width) · \(String(format: "%.2f", index.nominalFPS)) fps")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                HStack {
                    Text("총 \(index.frames.count.formatted())프레임").font(.system(size: 10)).foregroundStyle(.secondary)
                    Spacer()
                    IconButton(symbol: "chevron.left", label: "이전 프레임 페이지") { model.pause(); model.framePage -= 1 }.disabled(model.framePage == 0)
                    Text("\(model.framePage + 1)/\(model.totalFramePages)").font(.system(size: 10)).monospacedDigit()
                    IconButton(symbol: "chevron.right", label: "다음 프레임 페이지") { model.pause(); model.framePage += 1 }.disabled(model.framePage + 1 >= model.totalFramePages)
                }
            }.padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 6)
            Divider()
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    VStack(spacing: 10) {
                        let columns = model.showAllFrames ? 2 : 1
                        ForEach(Array(stride(from: model.pagedFrames.lowerBound, to: model.pagedFrames.upperBound, by: columns)), id: \.self) { first in
                            HStack(spacing: 8) {
                                ForEach(first..<min(first + columns, model.pagedFrames.upperBound), id: \.self) { number in
                                    frameTile(index, number: number).frame(maxWidth: .infinity).frame(height: model.showAllFrames ? 92 : 148).id(number)
                                }
                            }
                        }
                    }.frame(maxWidth: .infinity).padding(10)
                }
                .onChange(of: model.frameNumber) { _, value in proxy.scrollTo(value, anchor: .center) }
                .onChange(of: model.framePage) { _, _ in
                    let target = model.pagedFrames.contains(model.frameNumber) ? model.frameNumber : model.pagedFrames.lowerBound
                    proxy.scrollTo(target, anchor: .top)
                }
            }
            Divider()
            VStack(spacing: 8) {
                HStack {
                    Text("프레임").font(.system(size: 10)).foregroundStyle(.secondary)
                    TextField("번호", text: $jumpInput).textFieldStyle(.roundedBorder).font(.system(size: 11, design: .monospaced))
                        .accessibilityLabel("이동할 프레임 번호").onSubmit(jumpToFrame)
                    Text("/ \(index.frames.count.formatted())").font(.system(size: 10)).foregroundStyle(.secondary)
                }
                HStack {
                    IconButton(symbol: "rotate.left", label: "동영상 왼쪽으로 90도 회전") { model.rotateVideo(-1) }
                    Text("\(model.videoRotation * 90)°").font(.system(size: 10)).monospacedDigit().frame(width: 28)
                    IconButton(symbol: "rotate.right", label: "동영상 오른쪽으로 90도 회전") { model.rotateVideo(1) }
                    Spacer()
                    Button("세로 맞춤", action: zoom.fitHeight).buttonStyle(.borderless).font(.system(size: 10)).disabled(model.isPlaying)
                }
                ZoomControls(zoom: zoom, compact: true).disabled(model.isPlaying)
                HStack(spacing: 7) {
                    Picker("추출 형식", selection: $model.captureFormat) {
                        ForEach(CaptureFormat.allCases) { format in Text(format.rawValue).tag(format) }
                    }.labelsHidden().frame(width: 70).help("추출할 사진 형식")
                    Spacer(minLength: 0)
                    IconButton(symbol: model.currentCapture?.isFavorite == true ? "heart.fill" : "heart", label: "이 프레임 저장하고 좋아요 (L)", active: model.currentCapture?.isFavorite == true) { model.capture(favorite: true) }.disabled(model.isCapturing)
                    ActionButton(title: model.isCapturing ? "저장 중" : "추출", symbol: "camera", prominent: true) { model.capture() }
                        .disabled(model.isCapturing).help("원본 크기로 사진 추출 (⌘E)")
                }
            }.padding(12)
        }.background(Palette.background)
    }

    private func preview(_ index: VideoIndex) -> some View {
        ZStack {
            Palette.canvas
            if model.isPlaying {
                GeometryReader { geometry in
                    let vertical = model.videoRotation % 2 == 1
                    PlayerSurface(player: model.player)
                        .frame(width: vertical ? geometry.size.height : geometry.size.width, height: vertical ? geometry.size.width : geometry.size.height)
                        .rotationEffect(.degrees(Double(model.videoRotation * 90)))
                        .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
                }
            }
            else if let renderer = model.fullRenderer {
                let stamp = index.frames[model.frameNumber]
                let rotation = model.videoRotation
                ZoomableAsyncImage(identity: "\(model.selectedVideoID?.uuidString ?? "")-\(model.frameNumber)-\(rotation)",
                                   zoomIdentity: "\(model.selectedVideoID?.uuidString ?? "")-rotation-\(rotation)", zoom: zoom) { try await renderer.image(at: stamp, quarterTurns: rotation) }
            }
            VStack {
                HStack {
                    Text(model.isPlaying ? "재생 중" : "프레임 \((model.frameNumber + 1).formatted())")
                        .font(.system(size: 10, weight: .medium)).padding(.horizontal, 9).padding(.vertical, 5)
                        .background(.black.opacity(0.4), in: Capsule())
                    Spacer()
                    Text(index.frames[model.frameNumber].label).font(.system(size: 10, design: .monospaced)).padding(8).background(.black.opacity(0.4), in: Capsule())
                    if model.currentCapture != nil { Image(systemName: "checkmark.circle.fill").font(.caption).padding(8).background(.black.opacity(0.4), in: Capsule()) }
                }
                Spacer()
            }.foregroundStyle(.white.opacity(0.85)).padding(14).allowsHitTesting(false)
        }.clipped().frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func transport(_ index: VideoIndex) -> some View {
        VStack(spacing: 0) {
            Slider(value: Binding(get: { Double(model.frameNumber) }, set: { model.selectFrame(Int($0)) }), in: 0...Double(max(1, index.frames.count - 1)), step: 1)
                .disabled(index.frames.count < 2).accessibilityLabel("프레임 탐색")
            HStack(spacing: 2) {
                IconButton(symbol: "backward.end", label: "첫 프레임") { model.selectFrame(0) }.disabled(model.frameNumber == 0)
                IconButton(symbol: "chevron.left", label: "이전 프레임 (←)") { model.step(-1) }.disabled(model.frameNumber == 0)
                IconButton(symbol: model.isPlaying ? "pause.fill" : "play.fill", label: "재생 또는 일시정지 (Space)", action: model.togglePlayback)
                IconButton(symbol: "chevron.right", label: "다음 프레임 (→)") { model.step(1) }.disabled(model.frameNumber == index.frames.count - 1)
                IconButton(symbol: "forward.end", label: "마지막 프레임") { model.selectFrame(index.frames.count - 1) }.disabled(model.frameNumber == index.frames.count - 1)
                Spacer()
                Text("\(model.frameNumber + 1) / \(index.frames.count)").font(.system(size: 10)).monospacedDigit().foregroundStyle(.secondary)
            }
        }.padding(.horizontal, 10).padding(.vertical, 6).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9))
            .overlay(alignment: .top) {
                if let notice = model.notice {
                    Text(notice).font(.system(size: 11)).padding(10).background(.regularMaterial, in: Capsule()).offset(y: -44)
                }
            }
    }
    private func jumpToFrame() {
        if let number = Int(jumpInput.replacingOccurrences(of: ",", with: "")) { model.selectFrame(number - 1) }
        jumpInput = String(model.frameNumber + 1)
        NSApp.keyWindow?.makeFirstResponder(nil)
    }

    private func frameTile(_ index: VideoIndex, number: Int) -> some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topTrailing) {
                Palette.canvas
                if let renderer = model.thumbnailRenderer {
                    let stamp = index.frames[number]
                    let rotation = model.videoRotation
                    AsyncMediaImage(identity: "\(model.selectedVideoID?.uuidString ?? "")-\(number)-\(rotation)", quiet: true) { try await renderer.image(at: stamp, quarterTurns: rotation) }
                }
                if model.library.photos.contains(where: { $0.videoID == model.selectedVideoID && $0.frameNumber == number && $0.isFavorite && ($0.captureQuarterTurns ?? 0) == model.videoRotation }) {
                    Image(systemName: "heart.fill").font(.system(size: 11)).foregroundStyle(.white).shadow(radius: 2).padding(6)
                }
            }.frame(maxHeight: .infinity).clipped()
            HStack {
                Text("\(number + 1)").fontWeight(.medium)
                Spacer()
                Text(String(format: "%.3fs", index.frames[number].seconds)).foregroundStyle(.secondary)
            }.font(.system(size: 9, design: .monospaced)).padding(.horizontal, 6).frame(height: 24).background(.white)
        }.clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(model.frameNumber == number ? Palette.accent : .black.opacity(0.08), lineWidth: model.frameNumber == number ? 2 : 1))
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { model.selectFrame(number); zoom.fit() }
            .onTapGesture { model.selectFrame(number) }
            .accessibilityElement(children: .ignore).accessibilityLabel("프레임 \(number + 1), \(index.frames[number].label)")
            .accessibilityAddTraits(.isButton).accessibilityAction { model.selectFrame(number) }
    }
}

struct PlayerSurface: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView(); view.player = player; view.controlsStyle = .none; view.videoGravity = .resizeAspect
        return view
    }
    func updateNSView(_ view: AVPlayerView, context: Context) { view.player = player }
}
