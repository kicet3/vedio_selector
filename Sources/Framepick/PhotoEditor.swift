import SwiftUI
import FramepickCore

struct PhotoEditor: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) var dismiss
    let photo: PhotoRecord
    @StateObject private var session: EditingSession
    @StateObject private var zoom = ImageZoom()
    @ObservedObject private var ai = CodexAIService.shared
    @State private var preview: CGImage?
    @State private var histogram: PhotoHistogram?
    @State private var cropping = false
    @State private var showsBefore = false
    @State private var format: CaptureFormat = .png
    @State private var errorMessage: String?
    @State private var rendering = false
    @State private var faces: [DetectedFace] = []
    @State private var faceStatus = "얼굴 확인 중…"
    @State private var presets: [AdjustmentPreset] = []
    @State private var namingPreset = false
    @State private var presetName = ""
    @State private var showAISettings = false
    @State private var faceExpanded = true
    @State private var lightExpanded = true
    @State private var aiInstructions = "자연스러운 색감과 피부 질감을 유지하며 인물과 노출을 보정해 줘."
    @State private var suggestion: AIAdjustmentSuggestion?
    @State private var suggestionTask: Task<Void, Never>?

    init(photo: PhotoRecord) {
        self.photo = photo
        _session = StateObject(wrappedValue: EditingSession(photo.savedAdjustments ?? PhotoAdjustments()))
    }
    private var edits: PhotoAdjustments { session.adjustments }
    private var sourceURL: URL { model.disk.url(for: model.editSource(for: photo)) }
    private var previewAdjustments: PhotoAdjustments {
        var value = showsBefore ? PhotoAdjustments() : edits
        value.quarterTurns = edits.quarterTurns; value.straighten = edits.straighten
        value.crop = .full
        return value
    }
    private var cropBinding: Binding<PhotoCrop> {
        Binding(get: { edits.crop }, set: { value in session.change("crop") { $0.crop = value } })
    }
    var body: some View {
        VStack(spacing: 0) {
            header
            HStack(spacing: 0) {
                editorCanvas
                ScrollView { controls.padding(18) }.frame(width: 292).background(Palette.background)
            }
            footer
        }
        .frame(minWidth: 1000, idealWidth: 1140, maxWidth: 1400, minHeight: 680, idealHeight: 790, maxHeight: 1000)
        .background(.white).preferredColorScheme(.light)
        .interactiveDismissDisabled(model.isSavingEdit)
        .task(id: previewAdjustments) { await render() }
        .task {
            do {
                faces = try await ImageEditor.shared.faces(url: sourceURL)
                faceStatus = faces.isEmpty ? "감지된 얼굴이 없습니다" : "얼굴 \(faces.count)명 감지됨"
            } catch { if !Task.isCancelled { faceStatus = "얼굴을 감지하지 못했습니다" } }
            do { presets = try await model.disk.loadPresets() }
            catch { if !Task.isCancelled { errorMessage = "프리셋을 불러오지 못했습니다. \(error.localizedDescription)" } }
        }
        .onDisappear { suggestionTask?.cancel(); if ai.isBusy { ai.cancelSuggestion() } }
        .sheet(isPresented: $showAISettings) { AISettingsView() }
        .alert("편집을 완료하지 못했습니다", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("확인", role: .cancel) { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
        .alert("프리셋 저장", isPresented: $namingPreset) {
            TextField("프리셋 이름", text: $presetName)
            Button("취소", role: .cancel) {}
            Button("저장", action: savePreset).disabled(presetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } message: { Text("색상·명암·얼굴 보정값을 저장합니다. 자르기와 회전은 포함하지 않습니다.") }
    }

    private var header: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("사진 보정").font(.system(size: 16, weight: .semibold))
                Text(photo.displayName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Button(action: session.undo) { Image(systemName: "arrow.uturn.backward") }.help("실행 취소 (⌘Z)")
                .keyboardShortcut("z").disabled(!session.canUndo || model.isSavingEdit)
            Button(action: session.redo) { Image(systemName: "arrow.uturn.forward") }.help("다시 실행 (⇧⌘Z)")
                .keyboardShortcut("z", modifiers: [.command, .shift]).disabled(!session.canRedo || model.isSavingEdit)
            Toggle("보정 전", isOn: $showsBefore).toggleStyle(.button).help("같은 구도로 보정 전후 비교")
            Divider().frame(height: 20)
            Button("닫기") { dismiss() }.keyboardShortcut(.cancelAction).disabled(model.isSavingEdit)
            ActionButton(title: model.isSavingEdit ? "저장 중…" : "복사본 저장", symbol: "square.and.arrow.down", prominent: true, action: save)
                .disabled(model.isSavingEdit || model.isBatchEditing || preview == nil || edits.isUnchanged)
        }.padding(16)
    }
    private var editorCanvas: some View {
        ZStack {
            Palette.canvas
            if let preview {
                ZoomableImage(image: preview, identity: "\(photo.imageIdentity)-rotation-\(edits.quarterTurns)",
                              zoom: zoom, crop: cropBinding, isCropping: cropping && !model.isSavingEdit)
            } else { ProgressView().tint(.white) }
        }
        .overlay(alignment: .topLeading) {
            if showsBefore {
                Text("보정 전 · 구도 유지").font(.system(size: 11, weight: .medium)).foregroundStyle(.white)
                    .padding(10).background(.black.opacity(0.5), in: Capsule()).padding(12).allowsHitTesting(false)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private var footer: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.shield")
            Text(cropping ? "드래그로 자르기 · ⌥드래그로 이동 · 핀치로 확대" : "원본 유지 · 핀치로 확대 · 드래그로 이동")
            Spacer()
            if rendering { ProgressView().controlSize(.small) }
            Button("세로 맞춤", action: zoom.fitHeight).buttonStyle(.borderless)
            ZoomControls(zoom: zoom)
        }.font(.system(size: 10)).foregroundStyle(.secondary).padding(12)
    }
    private var controls: some View {
        VStack(alignment: .leading, spacing: 17) {
            HistogramView(data: histogram)
            presetControls
            Toggle("자동 색상 보정", isOn: Binding(get: { edits.autoEnhance }, set: { value in session.change("auto") { $0.autoEnhance = value } }))
                .toggleStyle(.switch).font(.system(size: 12))
            Divider()
            DisclosureGroup("얼굴 보정", isExpanded: $faceExpanded) { faceControls.padding(.top, 10) }
            Divider()
            DisclosureGroup("빛 · 명암", isExpanded: $lightExpanded) {
                VStack(spacing: 10) {
                    slider("노출", \.exposure, -4...4, suffix: " EV")
                    slider("대비", \.contrast, 0.5...1.5)
                    slider("밝은 영역", \.highlights, -1...1)
                    slider("어두운 영역", \.shadows, -1...1)
                    slider("블랙 포인트", \.blackPoint, -0.2...0.2)
                }.padding(.top, 10)
            }
            Divider()
            DisclosureGroup("색상") {
                VStack(spacing: 10) {
                    slider("색온도", \.temperature, -100...100)
                    slider("틴트", \.tint, -100...100)
                    slider("채도", \.saturation, 0...2)
                    slider("생동감", \.vibrance, -1...1)
                }.padding(.top, 10)
            }
            DisclosureGroup("톤 커브") {
                VStack(spacing: 10) {
                    Text("세 구간의 밝기를 조절합니다").font(.caption).foregroundStyle(.secondary)
                    slider("암부", \.curveShadows, -1...1)
                    slider("중간톤", \.curveMidtones, -1...1)
                    slider("명부", \.curveHighlights, -1...1)
                }.padding(.top, 10)
            }
            DisclosureGroup("디테일 · 효과") {
                VStack(spacing: 10) {
                    slider("선명도", \.sharpness, 0...2)
                    slider("노이즈 감소", \.noiseReduction, 0...1)
                    slider("비네트", \.vignette, 0...1)
                }.padding(.top, 10)
            }
            DisclosureGroup("회전 · 자르기") { geometryControls.padding(.top, 10) }
            Divider()
            aiControls
            Divider()
            HStack {
                Button("보정값 복사") { model.copyAdjustments(edits) }
                Button("붙여넣기") { if let copied = model.copiedAdjustments { applyLook(copied) } }
                    .disabled(model.copiedAdjustments == nil)
            }.controlSize(.small)
            Text("복사한 색상·얼굴 보정값은 사진 목록에서 여러 장에 일괄 적용할 수 있습니다.")
                .font(.system(size: 10)).foregroundStyle(.secondary).lineSpacing(3)
            Picker("저장 형식", selection: $format) { ForEach(CaptureFormat.allCases) { Text($0.rawValue).tag($0) } }
            Button("전체 보정 초기화") { session.replace(PhotoAdjustments()); cropping = false; showsBefore = false }
                .disabled(edits.isUnchanged)
        }.font(.system(size: 12)).disabled(model.isSavingEdit)
    }
    private var faceControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(faceStatus, systemImage: "face.smiling").font(.system(size: 11)).foregroundStyle(.secondary)
            VStack(spacing: 10) {
                slider("피부 매끄러움", \.faceSmoothing, 0...1)
                slider("얼굴 밝기", \.faceBrightness, -1...1)
                slider("피부 톤 · 따뜻함", \.faceWarmth, -1...1)
            }.disabled(faces.isEmpty)
            Text("이 Mac에서 처리 · 감지된 모든 얼굴에 적용\n눈·눈썹·코·입 디테일 보호")
                .font(.system(size: 10)).foregroundStyle(.secondary).lineSpacing(3)
        }
    }
    private var presetControls: some View {
        HStack {
            Menu {
                ForEach(BuiltInLook.allCases, id: \.self) { look in Button(look.rawValue) { applyLook(look.adjustments) } }
                if !presets.isEmpty {
                    Divider()
                    ForEach(presets) { preset in Button(preset.name) { applyLook(preset.adjustments) } }
                    Menu("프리셋 삭제") {
                        ForEach(presets) { preset in Button(preset.name) { deletePreset(preset.id) } }
                    }
                }
            } label: { Label("프리셋", systemImage: "camera.filters") }
            Button { presetName = ""; namingPreset = true } label: { Image(systemName: "plus") }.help("현재 보정값을 프리셋으로 저장")
        }
    }
    private var geometryControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button { rotate(-1) } label: { Label("왼쪽", systemImage: "rotate.left") }
                Button { rotate(1) } label: { Label("오른쪽", systemImage: "rotate.right") }
            }
            slider("수평 맞추기", \.straighten, -15...15, suffix: "°")
            Toggle("자르기", isOn: $cropping).toggleStyle(.switch)
            if cropping {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 7) {
                    Button("전체") { session.change("crop") { $0.crop = .full } }
                    Button("1:1") { setCropRatio(1) }
                    Button("4:3") { setCropRatio(4.0 / 3) }
                    Button("3:2") { setCropRatio(1.5) }
                    Button("16:9") { setCropRatio(16.0 / 9) }
                    Button("9:16") { setCropRatio(9.0 / 16) }
                }
            }
        }
    }
    private var aiControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("ChatGPT 보정 제안", systemImage: "sparkles").fontWeight(.semibold)
                Spacer()
                Button { showAISettings = true } label: { Image(systemName: "gearshape") }.help("ChatGPT 로그인 및 AI 설정")
            }
            Text("분석을 누르면 이 사진의 축소본을 OpenAI로 전송합니다. 얼굴·색상 보정값을 제안받고 직접 적용할 수 있어요.")
                .font(.system(size: 10)).foregroundStyle(.secondary).lineSpacing(3)
            TextField("원하는 보정 방향", text: $aiInstructions, axis: .vertical).lineLimit(2...4).textFieldStyle(.roundedBorder)
            if ai.isBusy {
                HStack { ProgressView().controlSize(.small); Text("보정값 분석 중…"); Spacer(); Button("취소") { suggestionTask?.cancel(); ai.cancelSuggestion() } }
            } else if ai.isSignedIn {
                Button("이 사진 분석", action: requestSuggestion).disabled(aiInstructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } else {
                Button("ChatGPT 로그인…") { showAISettings = true }
            }
            if let suggestion {
                Text(suggestion.explanation).font(.system(size: 11)).textSelection(.enabled)
                Button("제안 적용") { session.replace(suggestion.applying(to: edits)); showsBefore = false }
            }
            if let message = ai.errorMessage { Text(message).font(.system(size: 10)).foregroundStyle(.red) }
        }
    }
    private func slider(_ title: String, _ path: WritableKeyPath<PhotoAdjustments, Double>, _ range: ClosedRange<Double>, suffix: String = "") -> some View {
        VStack(spacing: 2) {
            HStack { Text(title); Spacer(); Text(String(format: "%+.2f", edits[keyPath: path]) + suffix).monospacedDigit().foregroundStyle(.secondary) }
                .font(.system(size: 11))
            Slider(value: session.binding(path, id: title), in: range).accessibilityLabel(title)
        }
    }
    private func render() async {
        rendering = true
        do {
            try await Task.sleep(for: .milliseconds(90))
            let image = try await ImageEditor.shared.render(url: sourceURL, adjustments: previewAdjustments)
            try Task.checkCancellation()
            let stats = await Task.detached(priority: .utility) { PhotoStatistics.histogram(image) }.value
            try Task.checkCancellation()
            preview = image; histogram = stats; rendering = false
        } catch is CancellationError {} catch {
            if !Task.isCancelled { errorMessage = error.localizedDescription; rendering = false }
        }
    }
    private func applyLook(_ value: PhotoAdjustments) {
        var next = value
        next.quarterTurns = edits.quarterTurns; next.crop = edits.crop; next.straighten = edits.straighten
        session.replace(next.normalized()); showsBefore = false
    }
    private func rotate(_ amount: Int) {
        session.change("rotate") { $0.quarterTurns = ($0.quarterTurns + amount + 4) % 4; $0.crop = .full }
    }
    private func setCropRatio(_ ratio: Double) {
        guard let preview else { return }
        let imageRatio = Double(preview.width) / Double(preview.height)
        let width = min(1, ratio / imageRatio), height = min(1, imageRatio / ratio)
        session.change("crop") { $0.crop = PhotoCrop(x: (1 - width) / 2, y: (1 - height) / 2, width: width, height: height) }
    }
    private func savePreset() {
        var value = edits; value.crop = .full; value.quarterTurns = 0; value.straighten = 0
        let next = presets + [AdjustmentPreset(name: String(presetName.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80)), adjustments: value)]
        Task { do { try await model.disk.savePresets(next); presets = next } catch { errorMessage = error.localizedDescription } }
    }
    private func deletePreset(_ id: UUID) {
        let next = presets.filter { $0.id != id }
        Task { do { try await model.disk.savePresets(next); presets = next } catch { errorMessage = error.localizedDescription } }
    }
    private func requestSuggestion() {
        suggestion = nil
        suggestionTask = Task {
            do { suggestion = try await ai.suggest(imageURL: sourceURL, instructions: aiInstructions) }
            catch is CancellationError {} catch { if !Task.isCancelled { errorMessage = error.localizedDescription } }
        }
    }
    private func save() {
        Task {
            do { try await model.saveEdits(for: photo, adjustments: edits, format: format); dismiss() }
            catch { errorMessage = error.localizedDescription }
        }
    }
}

extension AIAdjustmentSuggestion {
    func applying(to existing: PhotoAdjustments) -> PhotoAdjustments {
        var next = PhotoAdjustments()
        next.crop = existing.crop; next.quarterTurns = existing.quarterTurns; next.straighten = existing.straighten
        let paths: [String: WritableKeyPath<PhotoAdjustments, Double>] = [
            "exposure": \.exposure, "contrast": \.contrast, "saturation": \.saturation,
            "vibrance": \.vibrance, "temperature": \.temperature, "tint": \.tint,
            "highlights": \.highlights, "shadows": \.shadows, "blackPoint": \.blackPoint,
            "sharpness": \.sharpness, "noiseReduction": \.noiseReduction, "vignette": \.vignette,
            "faceSmoothing": \.faceSmoothing, "faceBrightness": \.faceBrightness, "faceWarmth": \.faceWarmth
        ]
        for (key, value) in values { if let path = paths[key], value.isFinite { next[keyPath: path] = value } }
        return next.normalized()
    }
}
