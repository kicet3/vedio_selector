import XCTest
import AppKit
import ImageIO
@testable import Framepick
@testable import FramepickCore

final class ZoomRotationTests: XCTestCase {
    @MainActor
    func testNativeZoomChangesVisibleImageRegionAndPreservesCenter() throws {
        let scroll = ImageScrollView(frame: CGRect(x: 0, y: 0, width: 600, height: 400))
        scroll.setImage(Fixture.image(width: 2400, height: 1600), identity: "one")
        scroll.layoutSubtreeIfNeeded()
        scroll.fitImage()
        let fit = scroll.magnification
        let before = scroll.contentView.bounds
        scroll.zoom(to: fit * 2)
        let after = scroll.contentView.bounds
        XCTAssertEqual(scroll.magnification, fit * 2, accuracy: 0.001)
        XCTAssertEqual(after.width, before.width / 2, accuracy: 2)
        XCTAssertEqual(after.height, before.height / 2, accuracy: 2)
        XCTAssertEqual(after.midX, before.midX, accuracy: 2)
        XCTAssertEqual(after.midY, before.midY, accuracy: 2)
        scroll.zoom(to: 1)
        XCTAssertEqual(scroll.magnification, 1, accuracy: 0.001)
        scroll.fitImage()
        XCTAssertEqual(scroll.contentView.bounds.width, before.width, accuracy: 2)
    }

    @MainActor
    func testDragPanClampAndFrameUpdateKeepZoom() throws {
        let scroll = ImageScrollView(frame: CGRect(x: 0, y: 0, width: 600, height: 400))
        scroll.setImage(Fixture.image(width: 2400, height: 1600), identity: "same-video")
        scroll.layoutSubtreeIfNeeded(); scroll.zoom(to: 3)
        let origin = scroll.contentView.bounds.origin
        scroll.pan(from: origin, byWindowDelta: CGSize(width: -90, height: 60))
        XCTAssertEqual(scroll.contentView.bounds.minX, origin.x + 30, accuracy: 2)
        XCTAssertEqual(scroll.contentView.bounds.minY, origin.y + 20, accuracy: 2)
        scroll.setImage(Fixture.image(width: 2400, height: 1600), identity: "same-video")
        scroll.layoutSubtreeIfNeeded()
        XCTAssertEqual(scroll.magnification, 3, accuracy: 0.001)
        scroll.pan(from: .zero, byWindowDelta: CGSize(width: 1_000_000, height: -1_000_000))
        XCTAssertEqual(scroll.contentView.bounds.minX, 0, accuracy: 0.1)
        XCTAssertEqual(scroll.contentView.bounds.minY, 0, accuracy: 0.1)
        scroll.zoom(to: 1000)
        XCTAssertEqual(scroll.magnification, scroll.maxMagnification, accuracy: 0.001)
        scroll.setImage(Fixture.image(width: 1600, height: 2400), identity: "rotated-video")
        scroll.layoutSubtreeIfNeeded()
        XCTAssertEqual(scroll.magnification, scroll.fitMagnification, accuracy: 0.001)
    }

    @MainActor
    func testHeightFitFillsViewportAndAllowsHorizontalPanning() {
        let scroll = ImageScrollView(frame: CGRect(x: 0, y: 0, width: 400, height: 800))
        scroll.setImage(Fixture.image(width: 2400, height: 1200), identity: "landscape")
        scroll.layoutSubtreeIfNeeded()
        let fit = scroll.magnification
        scroll.fitHeight()
        XCTAssertGreaterThan(scroll.magnification, fit)
        XCTAssertEqual(scroll.contentView.bounds.height, scroll.imageDocument.frame.height, accuracy: 2)
        XCTAssertLessThan(scroll.contentView.bounds.width, scroll.imageDocument.frame.width)
        let origin = scroll.contentView.bounds.origin
        scroll.pan(from: origin, byWindowDelta: CGSize(width: -100, height: 0))
        XCTAssertGreaterThan(scroll.contentView.bounds.minX, origin.x)
    }

    func testPhotoViewerLoadsFullResolutionInsteadOfPreview() async throws {
        let dir = try Fixture.directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("detail.png")
        try ImageEncoder.write(Fixture.image(width: 4200, height: 2800), to: file, format: .png)
        let renderer = PhotoRenderer()
        let thumbnail = try await renderer.image(url: file, maxPixelSize: 600)
        let original = try await renderer.image(url: file, maxPixelSize: 0)
        XCTAssertEqual(thumbnail.width, 600)
        XCTAssertEqual(original.width, 4200); XCTAssertEqual(original.height, 2800)
    }

    @MainActor
    func testVideoRotationAffectsCaptureAndPersistsWithoutChangingOriginal() async throws {
        let dir = try Fixture.directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = try await Fixture.movie(in: dir, times: [0, 40, 80])
        let original = try Data(contentsOf: url)
        let model = AppModel(root: dir.appendingPathComponent("library")); await model.load(); await model.importFiles([url])
        for _ in 0..<500 where model.isIndexing { try await Task.sleep(for: .milliseconds(10)) }
        model.capture()
        for _ in 0..<500 where model.isCapturing { try await Task.sleep(for: .milliseconds(10)) }
        model.rotateVideo(1)
        XCTAssertEqual(model.videoRotation, 1); XCTAssertNil(model.currentCapture)
        model.capture(favorite: true)
        for _ in 0..<500 where model.isCapturing { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(model.library.photos.count, 2)
        let rotated = try XCTUnwrap(model.currentCapture)
        XCTAssertEqual(rotated.captureQuarterTurns, 1); XCTAssertTrue(rotated.isFavorite)
        let image = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(model.disk.url(for: rotated) as CFURL, nil)!, 0, nil)!
        XCTAssertEqual(image.width, 64); XCTAssertEqual(image.height, 96)
        model.rotateVideo(-1); XCTAssertEqual(model.videoRotation, 0); XCTAssertNotNil(model.currentCapture)
        model.rotateVideo(-1); XCTAssertEqual(model.videoRotation, 3)
        await model.flush()
        let restart = AppModel(root: model.disk.root); await restart.load()
        XCTAssertEqual(restart.library.videos.first?.quarterTurns, 3)
        XCTAssertEqual(try Data(contentsOf: url), original)
    }
}
