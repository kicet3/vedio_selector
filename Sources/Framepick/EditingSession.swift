import SwiftUI
import FramepickCore

@MainActor
final class EditingSession: ObservableObject {
    @Published private(set) var adjustments: PhotoAdjustments
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false
    private var past: [PhotoAdjustments] = []
    private var future: [PhotoAdjustments] = []
    private var lastControl: String?
    private var lastChange = Date.distantPast
    init(_ adjustments: PhotoAdjustments = PhotoAdjustments()) { self.adjustments = adjustments }
    func change(_ control: String, _ update: (inout PhotoAdjustments) -> Void) {
        var next = adjustments; update(&next)
        guard next != adjustments else { return }
        if lastControl != control || Date().timeIntervalSince(lastChange) > 0.45 { past.append(adjustments) }
        if past.count > 120 { past.removeFirst(past.count - 120) }
        future.removeAll(); adjustments = next; lastControl = control; lastChange = Date(); sync()
    }
    func replace(_ value: PhotoAdjustments) { lastControl = nil; change(UUID().uuidString) { $0 = value }; lastControl = nil }
    func binding(_ path: WritableKeyPath<PhotoAdjustments, Double>, id: String) -> Binding<Double> {
        Binding(get: { self.adjustments[keyPath: path] }, set: { value in self.change(id) { $0[keyPath: path] = value } })
    }
    func undo() {
        guard let previous = past.popLast() else { return }
        future.append(adjustments); adjustments = previous; lastControl = nil; sync()
    }
    func redo() {
        guard let next = future.popLast() else { return }
        past.append(adjustments); adjustments = next; lastControl = nil; sync()
    }
    private func sync() { canUndo = !past.isEmpty; canRedo = !future.isEmpty }
}

enum BuiltInLook: String, CaseIterable {
    case natural = "자연스럽게", portrait = "부드러운 인물", vivid = "선명한 풍경", film = "필름", monochrome = "흑백"
    var adjustments: PhotoAdjustments {
        var result = PhotoAdjustments()
        switch self {
        case .natural: result.autoEnhance = true; result.vibrance = 0.1
        case .portrait: result.contrast = 0.96; result.shadows = 0.12; result.faceSmoothing = 0.3; result.faceBrightness = 0.1; result.vibrance = 0.06
        case .vivid: result.contrast = 1.1; result.vibrance = 0.3; result.sharpness = 0.35; result.highlights = -0.15
        case .film: result.contrast = 0.92; result.saturation = 0.88; result.temperature = 10; result.blackPoint = -0.035; result.curveShadows = 0.15; result.vignette = 0.15
        case .monochrome: result.saturation = 0; result.contrast = 1.12; result.curveShadows = -0.12; result.sharpness = 0.25
        }
        return result
    }
}

struct HistogramView: View {
    let data: PhotoHistogram?
    var body: some View {
        VStack(spacing: 5) {
            Canvas { context, size in
                guard let data else { return }
                for (values, color) in [(data.red, Color.red), (data.green, Color.green), (data.blue, Color.blue)] {
                    var path = Path(); path.move(to: CGPoint(x: 0, y: size.height))
                    for (index, value) in values.enumerated() {
                        path.addLine(to: CGPoint(x: CGFloat(index) / 63 * size.width, y: size.height * (1 - CGFloat(value))))
                    }
                    path.addLine(to: CGPoint(x: size.width, y: size.height)); path.closeSubpath()
                    context.fill(path, with: .color(color.opacity(0.35)))
                }
            }.frame(height: 70).background(Palette.canvas, in: RoundedRectangle(cornerRadius: 5))
            HStack {
                Text("암부 \(Int((data?.clippedShadows ?? 0) * 100))%")
                Spacer(); Text("히스토그램"); Spacer()
                Text("명부 \(Int((data?.clippedHighlights ?? 0) * 100))%")
            }.font(.system(size: 9)).foregroundStyle(.secondary)
        }
    }
}
