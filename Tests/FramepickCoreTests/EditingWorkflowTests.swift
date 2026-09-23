import XCTest
import ImageIO
@testable import FramepickCore
@testable import Framepick

final class EditingWorkflowTests: XCTestCase {
    @MainActor
    func testUndoCoalescesSliderChangesButSeparatesControlsAndPresets() {
        let session = EditingSession()
        session.change("exposure") { $0.exposure = 0.3 }
        session.change("exposure") { $0.exposure = 0.6 }
        session.change("contrast") { $0.contrast = 1.2 }
        session.undo()
        XCTAssertEqual(session.adjustments.exposure, 0.6)
        XCTAssertEqual(session.adjustments.contrast, 1)
        session.undo(); XCTAssertTrue(session.adjustments.isUnchanged)
        session.redo(); XCTAssertEqual(session.adjustments.exposure, 0.6)
        session.replace(BuiltInLook.portrait.adjustments)
        XCTAssertFalse(session.canRedo)
        session.undo(); XCTAssertEqual(session.adjustments.exposure, 0.6)
    }

    func testAISuggestionReplacesColorButRetainsGeometry() {
        var before = PhotoAdjustments()
        before.quarterTurns = 1; before.straighten = 3
        before.crop = PhotoCrop(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
        before.autoEnhance = true; before.curveShadows = 0.8; before.exposure = 2
        let suggestion = AIAdjustmentSuggestion(adjustments: ["exposure": 0.3, "faceSmoothing": 0.4, "crop": 0, "sharpness": .nan], explanation: "test")
        let after = suggestion.applying(to: before)
        XCTAssertEqual(after.quarterTurns, 1); XCTAssertEqual(after.straighten, 3)
        XCTAssertEqual(after.crop, before.crop)
        XCTAssertEqual(after.exposure, 0.3); XCTAssertEqual(after.faceSmoothing, 0.4)
        XCTAssertFalse(after.autoEnhance); XCTAssertEqual(after.curveShadows, 0)
        XCTAssertEqual(after.sharpness, 0)
    }

    @MainActor
    func testSavedRecipeReopensOriginalAndPreservesSelectionMetadata() async throws {
        let dir = try Fixture.directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("one.png")
        try ImageEncoder.write(Fixture.image(width: 200, height: 100), to: file, format: .png)
        let originalBytes = try Data(contentsOf: file)
        let model = AppModel(root: dir.appendingPathComponent("library")); await model.load(); await model.importFiles([file])
        let original = try XCTUnwrap(model.library.photos.first)
        model.setPhotoRating(4, ids: [original.id]); model.setPhotosRejected(true, ids: [original.id])
        var edits = PhotoAdjustments(); edits.quarterTurns = 1; edits.exposure = 0.7
        try await model.saveEdits(for: original, adjustments: edits, format: .png)
        let first = try XCTUnwrap(model.library.photos.last)
        XCTAssertEqual(first.rating, 4); XCTAssertEqual(first.isRejected, true)
        XCTAssertEqual(first.savedAdjustments, edits)
        try await model.saveEdits(for: first, adjustments: edits, format: .png)
        let second = try XCTUnwrap(model.library.photos.last)
        XCTAssertEqual(second.editedFromID, original.id)
        XCTAssertEqual(model.editSource(for: second).id, original.id)
        let firstImage = try await PhotoRenderer.shared.image(url: model.disk.url(for: first), maxPixelSize: 0)
        let secondImage = try await PhotoRenderer.shared.image(url: model.disk.url(for: second), maxPixelSize: 0)
        XCTAssertEqual(secondImage.width, 100); XCTAssertEqual(secondImage.height, 200)
        XCTAssertEqual(Fixture.pixel(firstImage), Fixture.pixel(secondImage), "Reopening a recipe must not double exposure or rotation")
        let restart = AppModel(root: model.disk.root); await restart.load()
        XCTAssertEqual(restart.library.photos.last?.savedAdjustments, edits)
        XCTAssertEqual(try Data(contentsOf: file), originalBytes)
        await restart.flush()
    }

    @MainActor
    func testBatchCopiesColorWithoutCropAndLeavesSourceBytesUntouched() async throws {
        let dir = try Fixture.directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let files = [source.appendingPathComponent("one.png"), source.appendingPathComponent("two.png")]
        for file in files { try ImageEncoder.write(Fixture.image(width: 200, height: 100), to: file, format: .png) }
        let bytes = try files.map { try Data(contentsOf: $0) }
        let model = AppModel(root: dir.appendingPathComponent("library")); await model.load(); await model.openFolder(source)
        var edits = PhotoAdjustments(); edits.quarterTurns = 1; edits.straighten = 5; edits.exposure = 0.5
        edits.crop = PhotoCrop(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
        model.copyAdjustments(edits); model.selectAllPhotos(); model.batchApplyCopiedAdjustments()
        let deadline = Date().addingTimeInterval(15)
        while model.isBatchEditing && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertFalse(model.isBatchEditing); XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.library.photos.count, 4)
        let copies = model.library.photos.filter { $0.savedAdjustments != nil }
        XCTAssertEqual(copies.count, 2); XCTAssertEqual(model.selectedPhotos.count, 2)
        for copy in copies {
            XCTAssertEqual(copy.savedAdjustments?.crop, .full)
            XCTAssertEqual(copy.savedAdjustments?.quarterTurns, 0)
            XCTAssertEqual(copy.savedAdjustments?.straighten, 0)
            XCTAssertEqual(copy.savedAdjustments?.exposure, 0.5)
            let image = try await PhotoRenderer.shared.image(url: model.disk.url(for: copy), maxPixelSize: 0)
            XCTAssertEqual(image.width, 200); XCTAssertEqual(image.height, 100)
        }
        XCTAssertEqual(try files.map { try Data(contentsOf: $0) }, bytes)
        await model.flush()
    }

    @MainActor
    func testBatchPreservesExistingTargetCropAndRotation() async throws {
        let dir = try Fixture.directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("one.png")
        try ImageEncoder.write(Fixture.image(width: 200, height: 100), to: file, format: .png)
        let model = AppModel(root: dir.appendingPathComponent("library")); await model.load(); await model.importFiles([file])
        let original = try XCTUnwrap(model.library.photos.first)
        var geometry = PhotoAdjustments(); geometry.quarterTurns = 1
        geometry.crop = PhotoCrop(x: 0, y: 0, width: 0.5, height: 0.5)
        try await model.saveEdits(for: original, adjustments: geometry, format: .png)
        let target = try XCTUnwrap(model.library.photos.last)
        var color = PhotoAdjustments(); color.exposure = 0.25
        model.copyAdjustments(color); model.selectedPhotos = [target.id]; model.batchApplyCopiedAdjustments()
        let deadline = Date().addingTimeInterval(15)
        while model.isBatchEditing && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertFalse(model.isBatchEditing); XCTAssertNil(model.errorMessage)
        let result = try XCTUnwrap(model.library.photos.last)
        XCTAssertEqual(result.savedAdjustments?.quarterTurns, 1)
        XCTAssertEqual(result.savedAdjustments?.crop, geometry.crop)
        XCTAssertEqual(result.savedAdjustments?.exposure, 0.25)
        XCTAssertEqual(result.editedFromID, original.id)
        let image = try await PhotoRenderer.shared.image(url: model.disk.url(for: result), maxPixelSize: 0)
        XCTAssertEqual(image.width, 50); XCTAssertEqual(image.height, 100)
        await model.flush()
    }

    func testPresetRoundTripAndHistogramBins() async throws {
        let dir = try Fixture.directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let disk = LibraryDisk(root: dir)
        var adjustments = PhotoAdjustments(); adjustments.faceSmoothing = 0.3; adjustments.temperature = 20
        let preset = AdjustmentPreset(name: "인물", adjustments: adjustments)
        try await disk.savePresets([preset])
        let loaded = try await disk.loadPresets()
        XCTAssertEqual(loaded.first?.id, preset.id); XCTAssertEqual(loaded.first?.adjustments, adjustments)
        let histogram = PhotoStatistics.histogram(Fixture.image())
        XCTAssertEqual(histogram.red.count, 64); XCTAssertEqual(histogram.green.count, 64); XCTAssertEqual(histogram.blue.count, 64)
        XCTAssertEqual(max(histogram.red.max()!, histogram.green.max()!, histogram.blue.max()!), 1)
        XCTAssertEqual(histogram.clippedShadows, 0); XCTAssertEqual(histogram.clippedHighlights, 0)
    }
}
