import AppKit
import SwiftUI
import FramepickCore

@MainActor
final class ImageZoom: ObservableObject {
    @Published private(set) var scale: CGFloat = 1
    @Published private(set) var fitScale: CGFloat = 1
    @Published private(set) var ready = false
    weak var scrollView: ImageScrollView?
    func zoomIn() { setScale(scale * 1.5) }
    func zoomOut() { setScale(scale / 1.5) }
    func fit() { scrollView?.fitImage() }
    func fitHeight() { scrollView?.fitHeight() }
    func actualSize() { setScale(1) }
    func setScale(_ value: CGFloat) { scrollView?.zoom(to: value) }
    func update(scale: CGFloat, fitScale: CGFloat, ready: Bool) {
        if self.scale != scale { self.scale = scale }
        if self.fitScale != fitScale { self.fitScale = fitScale }
        if self.ready != ready { self.ready = ready }
    }
}

struct ZoomControls: View {
    @ObservedObject var zoom: ImageZoom
    var compact = false
    var body: some View {
        HStack(spacing: 2) {
            IconButton(symbol: "minus.magnifyingglass", label: "축소", action: zoom.zoomOut)
            Menu {
                Button("화면에 맞추기", action: zoom.fit)
                Button("세로에 맞추기", action: zoom.fitHeight)
                ForEach([25, 50, 100, 200, 400, 800, 1600], id: \.self) { value in
                    Button("\(value)%") { zoom.setScale(CGFloat(value) / 100) }
                }
            } label: {
                Text("\(Int((zoom.scale * 100).rounded()))%").font(.system(size: 11).monospacedDigit()).frame(width: 48)
            }.menuStyle(.borderlessButton).frame(width: 65).help("확대 배율 선택")
            IconButton(symbol: "plus.magnifyingglass", label: "확대", action: zoom.zoomIn)
            if !compact { Button("100%", action: zoom.actualSize).buttonStyle(.borderless).font(.system(size: 10)).help("사진 1픽셀을 화면 1픽셀로 보기") }
            Button("화면 맞춤", action: zoom.fit).buttonStyle(.borderless).font(.system(size: 10)).padding(.horizontal, 6)
        }.disabled(!zoom.ready)
    }
}

struct ZoomableImage: NSViewRepresentable {
    let image: CGImage
    let identity: String
    @ObservedObject var zoom: ImageZoom
    var crop: Binding<PhotoCrop>?
    var isCropping = false

    func makeNSView(context: Context) -> ImageScrollView {
        let view = ImageScrollView()
        view.zoomState = zoom; zoom.scrollView = view
        return view
    }
    func updateNSView(_ view: ImageScrollView, context: Context) {
        view.zoomState = zoom; zoom.scrollView = view
        view.imageDocument.crop = crop?.wrappedValue
        view.imageDocument.isCropping = isCropping
        view.imageDocument.onCropChange = { value in crop?.wrappedValue = value }
        view.setImage(image, identity: identity)
        view.imageDocument.needsDisplay = true
    }
    static func dismantleNSView(_ view: ImageScrollView, coordinator: ()) { view.zoomState?.scrollView = nil }
}

struct ZoomableAsyncImage: View {
    let identity: String
    var zoomIdentity: String? = nil
    @ObservedObject var zoom: ImageZoom
    let load: () async throws -> CGImage
    @State private var image: CGImage?
    @State private var failure: String?
    var body: some View {
        ZStack {
            Palette.canvas
            if let image { ZoomableImage(image: image, identity: zoomIdentity ?? identity, zoom: zoom) }
            else if let failure { Text(failure).font(.caption).foregroundStyle(.white.opacity(0.7)).padding(24) }
            else { ProgressView().tint(.white) }
        }
        .task(id: identity) {
            failure = nil
            // Keep the document alive while stepping video frames, preserving the viewport.
            if zoomIdentity == nil { image = nil }
            do {
                let result = try await load(); try Task.checkCancellation(); image = result
            } catch is CancellationError {} catch { if !Task.isCancelled { failure = error.localizedDescription; image = nil } }
        }
    }
}

/// Centers small documents and clamps panning to the image when magnified.
final class CenteredImageClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var result = super.constrainBoundsRect(proposedBounds)
        guard let documentView else { return result }
        let size = documentView.frame.size
        result.origin.x = size.width < result.width ? (size.width - result.width) / 2 : min(max(0, result.minX), size.width - result.width)
        result.origin.y = size.height < result.height ? (size.height - result.height) / 2 : min(max(0, result.minY), size.height - result.height)
        return result
    }
}

@MainActor
final class ImageScrollView: NSScrollView {
    let imageDocument = ImageCanvasView()
    weak var zoomState: ImageZoom?
    private var imageIdentity: String?
    private var needsInitialFit = false
    private var fitting = true
    private var previousViewport = CGSize.zero
    private var backingScale: CGFloat = 1
    private(set) var fitMagnification: CGFloat = 1
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        contentView = CenteredImageClipView()
        documentView = imageDocument
        drawsBackground = true
        backgroundColor = NSColor(red: 0.09, green: 0.13, blue: 0.18, alpha: 1)
        hasHorizontalScroller = true; hasVerticalScroller = true; autohidesScrollers = true
        scrollerStyle = .overlay
        horizontalScrollElasticity = .none; verticalScrollElasticity = .none
        allowsMagnification = true; minMagnification = 0.01; maxMagnification = 16
        imageDocument.imageScrollView = self
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var acceptsFirstResponder: Bool { true }

    func setImage(_ image: CGImage, identity: String) {
        let changed = imageIdentity != identity
        imageIdentity = identity
        imageDocument.cgImage = image
        backingScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let size = CGSize(width: CGFloat(image.width) / backingScale, height: CGFloat(image.height) / backingScale)
        if imageDocument.frame.size != size {
            imageDocument.setFrameSize(size)
            needsInitialFit = true
        }
        if changed { needsInitialFit = true; fitting = true }
        needsLayout = true
        imageDocument.needsDisplay = true
    }

    override func layout() {
        super.layout()
        guard imageDocument.cgImage != nil, contentSize.width > 0, contentSize.height > 0 else { return }
        let resized = contentSize != previousViewport
        previousViewport = contentSize
        fitMagnification = min(contentSize.width / imageDocument.frame.width, contentSize.height / imageDocument.frame.height)
        minMagnification = min(0.01, fitMagnification)
        maxMagnification = max(16, fitMagnification * 4)
        if needsInitialFit || (resized && fitting) {
            needsInitialFit = false; fitImage()
        }
        publish()
    }

    func fitImage() {
        guard imageDocument.frame.width > 0, contentSize.width > 0 else { return }
        fitMagnification = min(contentSize.width / imageDocument.frame.width, contentSize.height / imageDocument.frame.height)
        fitting = true
        applyMagnification(fitMagnification, center: CGPoint(x: imageDocument.frame.midX, y: imageDocument.frame.midY))
    }

    func zoom(to value: CGFloat, center: CGPoint? = nil) {
        guard value.isFinite, imageDocument.cgImage != nil else { return }
        fitting = false
        let anchor = center ?? CGPoint(x: contentView.bounds.midX, y: contentView.bounds.midY)
        applyMagnification(value, center: anchor)
    }
    func fitHeight() {
        guard imageDocument.frame.height > 0 else { return }
        zoom(to: contentSize.height / imageDocument.frame.height, center: CGPoint(x: imageDocument.frame.midX, y: imageDocument.frame.midY))
    }

    private func applyMagnification(_ value: CGFloat, center: CGPoint) {
        let target = min(maxMagnification, max(minMagnification, value))
        setMagnification(target, centeredAt: center)
        contentView.scroll(to: contentView.constrainBoundsRect(contentView.bounds).origin)
        reflectScrolledClipView(contentView)
        imageDocument.needsDisplay = true
        publish()
    }

    override func magnify(with event: NSEvent) {
        fitting = false
        super.magnify(with: event)
        imageDocument.needsDisplay = true
        publish()
    }
    override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            let point = imageDocument.convert(event.locationInWindow, from: nil)
            zoom(to: magnification * exp(-event.scrollingDeltaY * 0.015), center: point)
        } else { super.scrollWheel(with: event) }
    }
    override func keyDown(with event: NSEvent) {
        switch event.charactersIgnoringModifiers {
        case "+", "=": zoom(to: magnification * 1.5)
        case "-": zoom(to: magnification / 1.5)
        case "0": fitImage()
        case "1": zoom(to: 1)
        default: super.keyDown(with: event)
        }
    }
    func toggleZoom(at point: CGPoint) {
        if abs(magnification - fitMagnification) < 0.01 { zoom(to: max(1, fitMagnification * 2), center: point) }
        else { fitImage() }
    }
    func pan(from origin: CGPoint, byWindowDelta delta: CGSize) {
        let point = CGPoint(x: origin.x - delta.width / magnification, y: origin.y + delta.height / magnification)
        let proposed = CGRect(origin: point, size: contentView.bounds.size)
        contentView.scroll(to: contentView.constrainBoundsRect(proposed).origin)
        reflectScrolledClipView(contentView)
    }
    private func publish() {
        let scale = magnification, fit = fitMagnification, ready = imageDocument.cgImage != nil
        // Publishing inside updateNSView/layout would mutate SwiftUI during its update pass.
        DispatchQueue.main.async { [weak self] in self?.zoomState?.update(scale: scale, fitScale: fit, ready: ready) }
    }
}

@MainActor
final class ImageCanvasView: NSView {
    weak var imageScrollView: ImageScrollView?
    var cgImage: CGImage?
    var crop: PhotoCrop?
    var isCropping = false
    var onCropChange: ((PhotoCrop) -> Void)?
    private var dragStart: CGPoint?
    private var panOrigin: CGPoint?
    private var cropStart: CGPoint?
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        guard let cgImage else { return }
        NSImage(cgImage: cgImage, size: bounds.size).draw(in: bounds, from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high.rawValue])
        guard let crop else { return }
        let rectangle = CGRect(x: crop.x * bounds.width, y: crop.y * bounds.height, width: crop.width * bounds.width, height: crop.height * bounds.height)
        let mask = NSBezierPath(rect: bounds); mask.appendRect(rectangle); mask.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(0.62).setFill(); mask.fill()
        if isCropping {
            let width = 1 / (imageScrollView?.magnification ?? 1)
            NSColor.white.setStroke()
            let border = NSBezierPath(rect: rectangle); border.lineWidth = width; border.stroke()
            let grid = NSBezierPath(); grid.lineWidth = width * 0.5
            for fraction in [1.0 / 3, 2.0 / 3] {
                grid.move(to: CGPoint(x: rectangle.minX + rectangle.width * fraction, y: rectangle.minY))
                grid.line(to: CGPoint(x: rectangle.minX + rectangle.width * fraction, y: rectangle.maxY))
                grid.move(to: CGPoint(x: rectangle.minX, y: rectangle.minY + rectangle.height * fraction))
                grid.line(to: CGPoint(x: rectangle.maxX, y: rectangle.minY + rectangle.height * fraction))
            }
            NSColor.white.withAlphaComponent(0.45).setStroke(); grid.stroke()
        }
    }
    override func resetCursorRects() { addCursorRect(visibleRect, cursor: isCropping ? .crosshair : .openHand) }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(imageScrollView)
        let point = convert(event.locationInWindow, from: nil)
        if event.clickCount == 2 && !isCropping { imageScrollView?.toggleZoom(at: point); return }
        if isCropping && !event.modifierFlags.contains(.option) { cropStart = normalized(point) }
        else { dragStart = event.locationInWindow; panOrigin = imageScrollView?.contentView.bounds.origin; NSCursor.closedHand.set() }
    }
    override func mouseDragged(with event: NSEvent) {
        if let start = cropStart {
            let end = normalized(convert(event.locationInWindow, from: nil))
            guard abs(end.x - start.x) >= 0.001, abs(end.y - start.y) >= 0.001 else { return }
            let selection = PhotoCrop(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))
            crop = selection; needsDisplay = true; onCropChange?(selection)
        } else if let start = dragStart, let origin = panOrigin {
            imageScrollView?.pan(from: origin, byWindowDelta: CGSize(width: event.locationInWindow.x - start.x, height: event.locationInWindow.y - start.y))
        }
    }
    override func mouseUp(with event: NSEvent) {
        dragStart = nil; panOrigin = nil; cropStart = nil
        (isCropping ? NSCursor.crosshair : NSCursor.openHand).set()
    }
    private func normalized(_ point: CGPoint) -> CGPoint {
        CGPoint(x: min(1, max(0, point.x / bounds.width)), y: min(1, max(0, point.y / bounds.height)))
    }
}
