import XCTest
import AVFoundation
import ImageIO
@testable import FramepickCore
@testable import Framepick

enum Fixture {
    static func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("FramepickTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    static func movie(in directory: URL, times: [Int64], rotated: Bool = false) async throws -> URL {
        let url = directory.appendingPathComponent("test-\(UUID().uuidString).mov")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 96, AVVideoHeightKey: 64,
            AVVideoCompressionPropertiesKey: [AVVideoAllowFrameReorderingKey: true, AVVideoMaxKeyFrameIntervalKey: 30]
        ])
        input.mediaTimeScale = 1000
        if rotated { input.transform = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 64, ty: 0) }
        let adapter = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
            kCVPixelBufferWidthKey as String: 96, kCVPixelBufferHeightKey as String: 64
        ])
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        for (index, value) in times.enumerated() {
            while !input.isReadyForMoreMediaData {
                if writer.status == .failed { throw writer.error! }
                try await Task.sleep(for: .milliseconds(2))
            }
            var pixel: CVPixelBuffer?
            XCTAssertEqual(CVPixelBufferPoolCreatePixelBuffer(nil, adapter.pixelBufferPool!, &pixel), kCVReturnSuccess)
            let buffer = pixel!
            CVPixelBufferLockBaseAddress(buffer, [])
            let bytes = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
            let row = CVPixelBufferGetBytesPerRow(buffer)
            for y in 0..<64 {
                for x in 0..<96 {
                    let base = y * row + x * 4
                    bytes[base] = 255
                    bytes[base + 1] = index % 3 == 0 ? 240 : 10
                    bytes[base + 2] = index % 3 == 1 ? 240 : 10
                    bytes[base + 3] = index % 3 == 2 ? 240 : 10
                }
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            XCTAssertTrue(adapter.append(buffer, withPresentationTime: CMTime(value: value, timescale: 1000)))
        }
        writer.endSession(atSourceTime: CMTime(value: (times.last ?? 0) + 40, timescale: 1000))
        input.markAsFinished()
        await writer.finishWriting()
        if let error = writer.error { throw error }
        return url
    }
    static func image(width: Int = 180, height: Int = 120) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.3, green: 0.5, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }
    static func pixel(_ image: CGImage) -> [UInt8] {
        var result = [UInt8](repeating: 0, count: 4)
        result.withUnsafeMutableBytes { bytes in
            let context = CGContext(data: bytes.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return result
    }
}

final class VideoTests: XCTestCase {
    func testMP4EditListUsesOutputTimestampAndIncludesFirstAndLastFrames() async throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "bframes", withExtension: "mp4", subdirectory: "Fixtures"))
        let index = try await VideoIndexer.read(url: url)
        XCTAssertEqual(index.frames.count, 15)
        XCTAssertEqual(index.frames.first!.seconds, 0, accuracy: 0.00001)
        XCTAssertEqual(index.frames.last!.seconds, 14.0 / 30, accuracy: 0.00001)
        let renderer = FrameRenderer(url: url, maxPixelSize: 0)
        for (offset, stamp) in index.frames.enumerated() {
            XCTAssertEqual(stamp.seconds, Double(offset) / 30, accuracy: 0.00001)
            let image = try await renderer.image(at: stamp)
            XCTAssertEqual(image.width, 96); XCTAssertEqual(image.height, 64)
        }
    }
    func testEveryConstantRateFrameAndExactImage() async throws {
        let dir = try Fixture.directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let times = (0..<61).map { Int64($0 * 40) }
        let url = try await Fixture.movie(in: dir, times: times)
        let index = try await VideoIndexer.read(url: url)
        XCTAssertEqual(index.frames.count, times.count)
        XCTAssertEqual(index.width, 96); XCTAssertEqual(index.height, 64)
        let renderer = FrameRenderer(url: url, maxPixelSize: 0)
        for (offset, stamp) in index.frames.enumerated() {
            XCTAssertEqual(stamp.seconds, Double(times[offset]) / 1000, accuracy: 0.00001)
            let image = try await renderer.image(at: stamp)
            XCTAssertEqual(image.width, 96); XCTAssertEqual(image.height, 64)
            let pixel = Fixture.pixel(image)
            XCTAssertGreaterThan(pixel[offset % 3], 180, "Wrong color for frame \(offset)")
            XCTAssertLessThan(pixel[(offset + 1) % 3], 70)
        }
    }
    func testVariableFrameRateAndRotation() async throws {
        let dir = try Fixture.directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let times: [Int64] = [0, 33, 91, 130, 245, 278, 500, 541, 600]
        let url = try await Fixture.movie(in: dir, times: times, rotated: true)
        let index = try await VideoIndexer.read(url: url)
        XCTAssertEqual(index.frames.count, times.count)
        XCTAssertEqual(index.width, 64); XCTAssertEqual(index.height, 96)
        let renderer = FrameRenderer(url: url, maxPixelSize: 0)
        for (offset, stamp) in index.frames.enumerated() {
            XCTAssertEqual(stamp.seconds, Double(times[offset]) / 1000, accuracy: 0.00001)
            let image = try await renderer.image(at: stamp)
            XCTAssertEqual(image.width, 64); XCTAssertEqual(image.height, 96)
            XCTAssertGreaterThan(Fixture.pixel(image)[offset % 3], 180)
        }
        XCTAssertEqual(index.frame(at: 0.244), 3)
        XCTAssertEqual(index.frame(at: 0.245), 4)
        XCTAssertEqual(index.frame(at: -1), 0)
        XCTAssertEqual(index.frame(at: 200), 8)
    }
    func testSingleFrameAndInvalidVideo() async throws {
        let dir = try Fixture.directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = try await Fixture.movie(in: dir, times: [0])
        let index = try await VideoIndexer.read(url: url)
        XCTAssertEqual(index.frames.count, 1)
        let invalid = dir.appendingPathComponent("broken.mov")
        try Data("not a movie".utf8).write(to: invalid)
        do { _ = try await VideoIndexer.read(url: invalid); XCTFail("Corrupt movie accepted") } catch {}
    }
    func testCancelledIndexingStops() async throws {
        let dir = try Fixture.directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = try await Fixture.movie(in: dir, times: (0..<20).map { Int64($0 * 40) })
        let task = Task { try await VideoIndexer.read(url: url) }
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled indexing succeeded") } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
    }
}

final class LibraryTests: XCTestCase {
    func testImportFavoritesRelaunchAndCollisionSafeExport() async throws {
        let dir = try Fixture.directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("holiday.png")
        try ImageEncoder.write(Fixture.image(), to: source, format: .png)
        let disk = LibraryDisk(root: dir.appendingPathComponent("library"))
        var snapshot = try await disk.load()
        var photo = try await disk.importPhoto(from: source); photo.isFavorite = true
        snapshot.photos.append(photo)
        try await disk.save(snapshot)
        let reopened = try await LibraryDisk(root: disk.root).load()
        XCTAssertEqual(reopened.photos, snapshot.photos)
        XCTAssertTrue(reopened.photos[0].isFavorite)
        XCTAssertEqual(try Data(contentsOf: source), try Data(contentsOf: disk.url(for: photo)))
        let exported = try await disk.export([photo, photo], to: dir)
        XCTAssertEqual(exported.map(\.lastPathComponent), ["holiday (2).png", "holiday (3).png"])
        XCTAssertEqual(try Data(contentsOf: source), try Data(contentsOf: exported[1]))
    }
    func testCapturePNGAndJPEGKeepFullDimensionsAndProvenance() async throws {
        let dir = try Fixture.directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let disk = LibraryDisk(root: dir)
        let video = VideoRecord(url: dir.appendingPathComponent("clip.mov"))
        for format in CaptureFormat.allCases {
            let photo = try await disk.capture(image: Fixture.image(width: 1920, height: 1080), video: video, frame: 99,
                                               stamp: FrameStamp(CMTime(value: 99, timescale: 30)), format: format, favorite: true)
            XCTAssertTrue(photo.isFavorite); XCTAssertEqual(photo.frameNumber, 99); XCTAssertEqual(photo.videoID, video.id)
            XCTAssertTrue(photo.displayName.contains("000100"))
            let source = CGImageSourceCreateWithURL(disk.url(for: photo) as CFURL, nil)!
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)!
            XCTAssertEqual(image.width, 1920); XCTAssertEqual(image.height, 1080)
        }
    }
    func testCorruptLibraryAndInvalidPhotoAreRejected() async throws {
        let dir = try Fixture.directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let data = Data("broken".utf8)
        try data.write(to: dir.appendingPathComponent("library.json"))
        let disk = LibraryDisk(root: dir)
        do { _ = try await disk.load(); XCTFail("Corruption ignored") } catch {}
        let invalid = dir.appendingPathComponent("invalid.jpg"); try data.write(to: invalid)
        do { _ = try await disk.importPhoto(from: invalid); XCTFail("Corrupt photo accepted") } catch {}
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent("library.json")), data)
    }
}

final class WorkflowTests: XCTestCase {
    @MainActor
    func testPhotoSelectionFavoritesAndPersistence() async throws {
        let dir = try Fixture.directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let one = dir.appendingPathComponent("one.png"), two = dir.appendingPathComponent("two.png")
        try ImageEncoder.write(Fixture.image(), to: one, format: .png)
        try ImageEncoder.write(Fixture.image(), to: two, format: .png)
        let model = AppModel(root: dir.appendingPathComponent("library"))
        await model.load(); await model.importFiles([one, two])
        XCTAssertNil(model.errorMessage); XCTAssertEqual(model.library.photos.count, 2)
        XCTAssertEqual(model.page, .photos)
        let id = model.library.photos[0].id
        model.toggleFavorite(id)
        XCTAssertEqual(model.airDropPhotos.map(\.id), [id])
        model.selectPhoto(model.library.photos[1].id, extending: false)
        XCTAssertTrue(model.airDropPhotos.isEmpty, "Unliked selected photos must never be shared by this action")
        model.navigate(to: .favorites)
        XCTAssertEqual(model.visiblePhotos.map(\.id), [id])
        model.selectAllPhotos(); model.toggleSelectedFavorites()
        XCTAssertTrue(model.visiblePhotos.isEmpty); XCTAssertTrue(model.selectedPhotos.isEmpty)
        model.toggleFavorite(id); await model.flush()
        let restarted = AppModel(root: model.disk.root); await restarted.load()
        XCTAssertEqual(restarted.favorites.map(\.id), [id])
        XCTAssertEqual(restarted.library.photos.count, 2)
    }
    @MainActor
    func testVideoCaptureIsDeduplicatedAndFrameNavigationClamps() async throws {
        let dir = try Fixture.directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = try await Fixture.movie(in: dir, times: [0, 40, 80, 160])
        let model = AppModel(root: dir.appendingPathComponent("library"))
        await model.load(); await model.importFiles([url])
        for _ in 0..<500 where model.isIndexing { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNil(model.errorMessage); XCTAssertEqual(model.videoIndex?.frames.count, 4)
        model.selectFrame(999); XCTAssertEqual(model.frameNumber, 3)
        model.step(-999); XCTAssertEqual(model.frameNumber, 0)
        model.selectFrame(2); model.capture(favorite: true)
        for _ in 0..<500 where model.isCapturing { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNil(model.errorMessage); XCTAssertEqual(model.library.photos.count, 1)
        XCTAssertEqual(model.favorites.count, 1)
        XCTAssertEqual(model.library.photos.first?.frameNumber, 2)
        model.capture(); XCTAssertEqual(model.library.photos.count, 1)
        model.capture(favorite: true); XCTAssertEqual(model.favorites.count, 0)
        await model.flush()
    }
    @MainActor
    func testCorruptLibraryIsNotOverwrittenByApp() async throws {
        let dir = try Fixture.directory(); defer { try? FileManager.default.removeItem(at: dir) }
        let data = Data("broken".utf8), file = dir.appendingPathComponent("library.json")
        try data.write(to: file)
        let model = AppModel(root: dir); await model.load()
        XCTAssertFalse(model.libraryReady); XCTAssertNotNil(model.errorMessage)
        model.persist(); await model.flush()
        XCTAssertEqual(try Data(contentsOf: file), data)
    }
}
