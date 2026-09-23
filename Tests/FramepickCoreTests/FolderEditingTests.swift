import XCTest
import ImageIO
import UniformTypeIdentifiers
@testable import FramepickCore
@testable import Framepick

final class FolderEditingTests: XCTestCase {
    func testFolderScannerRecursiveNaturalOrderAndIgnoresNonMedia() throws {
        let dir = try Fixture.directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let child = dir.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        for name in ["photo10.png", "photo2.png", ".hidden.png"] {
            try ImageEncoder.write(Fixture.image(), to: dir.appendingPathComponent(name), format: .png)
        }
        try ImageEncoder.write(Fixture.image(), to: child.appendingPathComponent("child.png"), format: .png)
        try Data("ignore me".utf8).write(to: dir.appendingPathComponent("notes.txt"))
        try FileManager.default.createSymbolicLink(at: dir.appendingPathComponent("link.png"), withDestinationURL: dir.appendingPathComponent("photo2.png"))
        let flat = try FolderScanner.scan(dir, includesSubfolders: false)
        XCTAssertEqual(flat.entries.map(\.relativePath), ["photo2.png", "photo10.png"])
        let recursive = try FolderScanner.scan(dir, includesSubfolders: true)
        XCTAssertEqual(recursive.entries.map(\.relativePath), ["nested/child.png", "photo2.png", "photo10.png"])
        XCTAssertTrue(recursive.warnings.isEmpty)
    }

    @MainActor
    func testOpenFolderDeduplicatesPreservesLikesAndReferencesOriginal() async throws {
        let dir = try Fixture.directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("photos")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let file = source.appendingPathComponent("one.png")
        try ImageEncoder.write(Fixture.image(), to: file, format: .png)
        let originalBytes = try Data(contentsOf: file)
        let model = AppModel(root: dir.appendingPathComponent("library")); await model.load()
        await model.openFolder(source)
        XCTAssertNil(model.errorMessage); XCTAssertEqual(model.visiblePhotos.count, 1)
        let photo = try XCTUnwrap(model.visiblePhotos.first)
        XCTAssertEqual(model.disk.url(for: photo).standardizedFileURL, file.standardizedFileURL)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: model.disk.photosDirectory.path).count, 0)
        model.toggleFavorite(photo.id)
        await model.openFolder(source)
        XCTAssertEqual(model.visiblePhotos.count, 1); XCTAssertEqual(model.favorites.first?.id, photo.id)
        XCTAssertEqual(model.library.folders.count, 1)
        model.favoritesOnly = true; XCTAssertEqual(model.visiblePhotos.count, 1)
        await model.flush()
        let restart = AppModel(root: model.disk.root); await restart.load(); await restart.openFolder(source)
        XCTAssertEqual(restart.visiblePhotos.first?.id, photo.id)
        XCTAssertEqual(restart.favorites.first?.id, photo.id)
        XCTAssertEqual(try Data(contentsOf: file), originalBytes)
        await restart.flush()
    }

    @MainActor
    func testFolderDropEmptyFolderRefreshAndFolderScopedAirDrop() async throws {
        let dir = try Fixture.directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let first = dir.appendingPathComponent("first"), second = dir.appendingPathComponent("second")
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        let file = first.appendingPathComponent("one.png")
        try ImageEncoder.write(Fixture.image(), to: file, format: .png)
        let model = AppModel(root: dir.appendingPathComponent("library")); await model.load()
        await model.importFiles([first])
        let photo = try XCTUnwrap(model.visiblePhotos.first); model.toggleFavorite(photo.id)
        await model.openFolder(second)
        XCTAssertTrue(model.visiblePhotos.isEmpty); XCTAssertTrue(model.airDropPhotos.isEmpty)
        XCTAssertEqual(model.favorites.count, 1)
        await model.openFolder(first)
        XCTAssertEqual(model.airDropPhotos.map(\.id), [photo.id])
        try FileManager.default.removeItem(at: file)
        await model.openFolder(first)
        XCTAssertTrue(model.visiblePhotos.isEmpty)
        try ImageEncoder.write(Fixture.image(), to: file, format: .png)
        await model.openFolder(first)
        XCTAssertEqual(model.favorites.map(\.id), [photo.id], "Restoring a missing source must preserve its like")
        await model.flush()
    }

    func testRotationCropAndExposureRenderExpectedPixelsAndDimensions() async throws {
        let dir = try Fixture.directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("source.png")
        try ImageEncoder.write(Fixture.image(width: 200, height: 100), to: source, format: .png)
        let editor = ImageEditor()
        var edits = PhotoAdjustments(); edits.quarterTurns = 1
        let rotated = try await editor.render(url: source, adjustments: edits)
        XCTAssertEqual(rotated.width, 100); XCTAssertEqual(rotated.height, 200)
        edits.crop = PhotoCrop(x: 0.1, y: 0.25, width: 0.8, height: 0.5)
        let cropped = try await editor.render(url: source, adjustments: edits)
        XCTAssertEqual(cropped.width, 80); XCTAssertEqual(cropped.height, 100)
        edits.exposure = 1
        let brighter = try await editor.render(url: source, adjustments: edits)
        XCTAssertGreaterThan(Fixture.pixel(brighter)[0], Fixture.pixel(cropped)[0])
        edits.crop = PhotoCrop(x: -0.1, y: 0, width: 1, height: 1)
        do { _ = try await editor.render(url: source, adjustments: edits); XCTFail("Out-of-bounds crop accepted") } catch {}
    }

    func testEXIFOrientationAppliedToPreviewAndExport() async throws {
        let dir = try Fixture.directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("oriented.jpg")
        let destination = CGImageDestinationCreateWithURL(source as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, Fixture.image(width: 200, height: 100), [kCGImagePropertyOrientation: 6] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let editor = ImageEditor()
        let full = try await editor.render(url: source, adjustments: PhotoAdjustments())
        let preview = try await editor.render(url: source, adjustments: PhotoAdjustments(), maxPixelSize: 1000)
        XCTAssertEqual(full.width, 100); XCTAssertEqual(full.height, 200)
        XCTAssertEqual(preview.width, full.width); XCTAssertEqual(preview.height, full.height)
    }

    @MainActor
    func testEditedCopyPreservesOriginalAndRemainsInFolderAfterRefresh() async throws {
        let dir = try Fixture.directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("photos")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let file = source.appendingPathComponent("one.png")
        try ImageEncoder.write(Fixture.image(), to: file, format: .png)
        let originalData = try Data(contentsOf: file)
        let model = AppModel(root: dir.appendingPathComponent("library")); await model.load(); await model.openFolder(source)
        let photo = try XCTUnwrap(model.visiblePhotos.first); model.toggleFavorite(photo.id)
        var edits = PhotoAdjustments(); edits.quarterTurns = 1; edits.exposure = 0.5
        try await model.saveEdits(for: photo, adjustments: edits, format: .png)
        let copy = try XCTUnwrap(model.library.photos.first { $0.editedFromID == photo.id })
        XCTAssertNil(copy.sourcePath); XCTAssertEqual(copy.folderID, photo.folderID); XCTAssertTrue(copy.isFavorite)
        XCTAssertEqual(try Data(contentsOf: file), originalData)
        XCTAssertTrue(FileManager.default.fileExists(atPath: model.disk.url(for: copy).path))
        await model.openFolder(source)
        XCTAssertEqual(model.visiblePhotos.count, 2)
        let exported = try await model.disk.export([copy], to: dir.appendingPathComponent("export"))
        let image = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(exported[0] as CFURL, nil)!, 0, nil)!
        XCTAssertEqual(image.width, 120); XCTAssertEqual(image.height, 180)
        await model.flush()
    }

    func testPreviousLibrarySchemaStillLoads() throws {
        let json = Data(#"{"version":1,"photos":[],"videos":[]}"#.utf8)
        let library = try JSONDecoder().decode(LibrarySnapshot.self, from: json)
        XCTAssertTrue(library.folders.isEmpty)
    }

    @MainActor
    func testInlinePhotoSelectionNavigationAndFavoriteFilter() async throws {
        let dir = try Fixture.directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("photos")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        for name in ["one.png", "two.png"] { try ImageEncoder.write(Fixture.image(), to: source.appendingPathComponent(name), format: .png) }
        let model = AppModel(root: dir.appendingPathComponent("library")); await model.load(); await model.openFolder(source)
        let photos = model.visiblePhotos
        XCTAssertNil(model.focusedPhoto)
        model.selectPhoto(photos[0].id, extending: false)
        XCTAssertEqual(model.focusedPhoto?.id, photos[0].id); XCTAssertTrue(model.isShowingViewer)
        XCTAssertNil(model.editingPhoto, "Viewing a photo must not open a sheet")
        model.stepPhoto(1); XCTAssertEqual(model.focusedPhoto?.id, photos[1].id)
        model.stepPhoto(99); XCTAssertEqual(model.focusedPhoto?.id, photos[1].id)
        model.toggleFavorite(photos[0].id); model.toggleFavorite(photos[1].id)
        model.favoritesOnly = true
        model.toggleFavorite(photos[1].id)
        XCTAssertEqual(model.focusedPhoto?.id, photos[0].id, "Unliking the viewed photo should show the next visible photo")
        model.showPhotoGrid(); XCTAssertNil(model.focusedPhoto); XCTAssertFalse(model.isShowingViewer)
        await model.flush()
    }
}
