import XCTest
@testable import FramepickCore
@testable import Framepick

final class CullingTests: XCTestCase {
    func testLegacyPhotoWithoutCullingMetadataStillDecodes() throws {
        let id = UUID()
        let json = Data("""
        {"id":"\(id.uuidString)","filename":"one.png","displayName":"one.png","addedAt":0,"isFavorite":true}
        """.utf8)
        let photo = try JSONDecoder().decode(PhotoRecord.self, from: json)
        XCTAssertEqual(photo.id, id)
        XCTAssertTrue(photo.isFavorite)
        XCTAssertNil(photo.rating)
        XCTAssertNil(photo.isRejected)
        XCTAssertNil(photo.savedAdjustments)
    }

    @MainActor
    func testRatingsAndRejectionSurviveRestartAndFolderRefreshWithoutChangingSource() async throws {
        let dir = try Fixture.directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let folder = dir.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("one.png")
        try ImageEncoder.write(Fixture.image(), to: file, format: .png)
        let original = try Data(contentsOf: file)
        let model = AppModel(root: dir.appendingPathComponent("library")); await model.load(); await model.openFolder(folder)
        let id = try XCTUnwrap(model.visiblePhotos.first?.id)
        model.setPhotoRating(99, ids: [id])
        model.setPhotosRejected(true, ids: [id])
        XCTAssertEqual(model.library.photos.first?.rating, 5)
        XCTAssertEqual(model.library.photos.first?.isRejected, true)
        await model.flush()
        let reopened = AppModel(root: model.disk.root); await reopened.load(); await reopened.openFolder(folder)
        XCTAssertEqual(reopened.visiblePhotos.first?.rating, 5)
        XCTAssertEqual(reopened.visiblePhotos.first?.isRejected, true)
        XCTAssertEqual(try Data(contentsOf: file), original)
        reopened.setPhotoRating(-1, ids: [id]); reopened.setPhotosRejected(false, ids: [id])
        XCTAssertEqual(reopened.visiblePhotos.first?.rating, 0)
        XCTAssertEqual(reopened.visiblePhotos.first?.isRejected, false)
        await reopened.flush()
    }

    @MainActor
    func testCullingFiltersCombineWithFolderFavoritesAndSearch() async throws {
        let dir = try Fixture.directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let model = AppModel(root: dir); await model.load()
        let firstFolder = UUID(), otherFolder = UUID()
        var kept = PhotoRecord(filename: "one.png", displayName: "portrait 1", isFavorite: true, folderID: firstFolder)
        kept.rating = 4
        var rejected = PhotoRecord(filename: "two.png", displayName: "portrait 2", isFavorite: true, folderID: firstFolder)
        rejected.rating = 5; rejected.isRejected = true
        var elsewhere = PhotoRecord(filename: "three.png", displayName: "portrait 3", isFavorite: true, folderID: otherFolder)
        elsewhere.rating = 5
        let unrated = PhotoRecord(filename: "four.png", displayName: "portrait 4", folderID: firstFolder)
        model.library.photos = [kept, rejected, elsewhere, unrated]
        model.selectedFolderID = firstFolder; model.favoritesOnly = true; model.search = "portrait"; model.minimumRating = 4
        model.rejectionFilter = .accepted
        XCTAssertEqual(model.visiblePhotos.map(\.id), [kept.id])
        model.rejectionFilter = .rejected
        XCTAssertEqual(model.visiblePhotos.map(\.id), [rejected.id])
        model.search = "missing"
        XCTAssertTrue(model.visiblePhotos.isEmpty)
        model.search = ""; model.favoritesOnly = false; model.resetCullingFilters()
        XCTAssertEqual(Set(model.visiblePhotos.map(\.id)), [kept.id, rejected.id, unrated.id])
        await model.flush()
    }

    @MainActor
    func testCullingNaturalNameAndRatingSort() async throws {
        let dir = try Fixture.directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let model = AppModel(root: dir); await model.load()
        var tenth = PhotoRecord(filename: "photo10.png", displayName: "photo10.png"); tenth.rating = 5
        var second = PhotoRecord(filename: "photo2.png", displayName: "photo2.png"); second.rating = 5
        var first = PhotoRecord(filename: "photo1.png", displayName: "photo1.png"); first.rating = 3
        model.library.photos = [tenth, second, first]
        model.photoSortOrder = .name
        XCTAssertEqual(model.visiblePhotos.map(\.id), [first.id, second.id, tenth.id])
        model.photoSortOrder = .rating
        XCTAssertEqual(model.visiblePhotos.map(\.id), [second.id, tenth.id, first.id])
        await model.flush()
    }

    @MainActor
    func testCompareRequiresTwoVisibleSelectionsAndKeepsRejectedCandidateAvailableForReview() async throws {
        let dir = try Fixture.directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let model = AppModel(root: dir); await model.load()
        let first = PhotoRecord(filename: "one.png", displayName: "one.png")
        let second = PhotoRecord(filename: "two.png", displayName: "two.png")
        model.library.photos = [first, second]; model.photoSortOrder = .name
        model.togglePhotoSelection(first.id); model.startPhotoComparison()
        XCTAssertTrue(model.comparisonPhotos.isEmpty)
        model.togglePhotoSelection(second.id); model.startPhotoComparison()
        XCTAssertEqual(model.comparisonPhotos.map(\.id), [first.id, second.id])
        XCTAssertNil(model.focusedPhotoID)
        model.rejectionFilter = .accepted
        model.setPhotosRejected(true, ids: [second.id])
        XCTAssertEqual(model.visiblePhotos.map(\.id), [first.id])
        XCTAssertEqual(model.comparisonPhotos.count, 2, "Marking a candidate must keep both comparison panes available")
        model.stopPhotoComparison()
        XCTAssertTrue(model.comparisonPhotos.isEmpty)
        XCTAssertEqual(model.library.photos.count, 2)
        await model.flush()
    }
}
