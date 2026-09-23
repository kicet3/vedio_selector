import XCTest
import CoreImage
import ImageIO
import UniformTypeIdentifiers
@testable import FramepickCore

final class AdvancedEditingTests: XCTestCase {
    private let context = CIContext(options: [.cacheIntermediates: false])

    func testRecipesRoundTripAndOldRecipesUseNeutralDefaults() throws {
        let old = try JSONDecoder().decode(PhotoAdjustments.self, from: Data(#"{"exposure":0.8,"quarterTurns":1}"#.utf8))
        XCTAssertEqual(old.exposure, 0.8)
        XCTAssertEqual(old.contrast, 1)
        XCTAssertEqual(old.saturation, 1)
        XCTAssertEqual(old.faceSmoothing, 0)
        XCTAssertEqual(old.crop, .full)
        var edits = old
        edits.crop = PhotoCrop(x: 0.2, y: 0.1, width: 0.6, height: 0.7)
        edits.faceSmoothing = 0.4
        edits.faceWarmth = -0.2
        edits.curveMidtones = 0.3
        edits.autoEnhance = true
        XCTAssertEqual(try JSONDecoder().decode(PhotoAdjustments.self, from: JSONEncoder().encode(edits)), edits)
    }

    func testUntrustedNumericControlsAreFiniteAndClamped() {
        var edits = PhotoAdjustments()
        edits.exposure = .infinity
        edits.contrast = .nan
        edits.saturation = -.infinity
        edits.temperature = 10_000
        edits.tint = -10_000
        edits.faceSmoothing = 10
        edits.faceBrightness = -10
        edits.sharpness = -5
        edits.straighten = 90
        edits.quarterTurns = Int.min
        let safe = edits.normalized()
        XCTAssertEqual(safe.exposure, 0)
        XCTAssertEqual(safe.contrast, 1)
        XCTAssertEqual(safe.saturation, 1)
        XCTAssertEqual(safe.temperature, 100)
        XCTAssertEqual(safe.tint, -100)
        XCTAssertEqual(safe.faceSmoothing, 1)
        XCTAssertEqual(safe.faceBrightness, -1)
        XCTAssertEqual(safe.sharpness, 0)
        XCTAssertEqual(safe.straighten, 15)
        XCTAssertTrue((0...3).contains(safe.quarterTurns))
        var turns = PhotoAdjustments(); turns.quarterTurns = -4
        XCTAssertTrue(turns.isUnchanged)
    }

    func testColorAndToneControlsChangeRenderedPixels() async throws {
        let directory = try Fixture.directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("gradient.png")
        try ImageEncoder.write(patternImage(), to: url, format: .png)
        let editor = ImageEditor()
        let neutral = try await editor.render(url: url, adjustments: PhotoAdjustments())
        let baseline = pixels(neutral)
        let controls: [(String, WritableKeyPath<PhotoAdjustments, Double>, Double)] = [
            ("exposure", \.exposure, 1), ("contrast", \.contrast, 1.3), ("saturation", \.saturation, 0),
            ("vibrance", \.vibrance, 1), ("temperature", \.temperature, 80), ("tint", \.tint, 70),
            ("highlights", \.highlights, -0.8), ("shadows", \.shadows, 0.8), ("blackPoint", \.blackPoint, 0.1),
            ("curveShadows", \.curveShadows, -0.7), ("curveMidtones", \.curveMidtones, 0.7),
            ("curveHighlights", \.curveHighlights, -0.7), ("noiseReduction", \.noiseReduction, 1),
            ("sharpness", \.sharpness, 1.5), ("vignette", \.vignette, 1)
        ]
        for (name, path, amount) in controls {
            var edits = PhotoAdjustments(); edits[keyPath: path] = amount
            let rendered = try await editor.render(url: url, adjustments: edits)
            let changed = zip(pixels(rendered), baseline).filter { abs(Int($0) - Int($1)) > 1 }.count
            XCTAssertGreaterThan(changed, 100, "\(name) must affect real pixels")
            XCTAssertEqual(rendered.width, neutral.width)
            XCTAssertEqual(rendered.height, neutral.height)
        }
        var monochrome = PhotoAdjustments(); monochrome.saturation = 0
        let gray = pixels(try await editor.render(url: url, adjustments: monochrome))
        for offset in stride(from: 0, to: gray.count, by: 4) {
            XCTAssertLessThanOrEqual(abs(Int(gray[offset]) - Int(gray[offset + 1])), 1)
            XCTAssertLessThanOrEqual(abs(Int(gray[offset + 1]) - Int(gray[offset + 2])), 1)
        }
    }

    func testExposureRangeReallyExtendsBeyondTwoStops() async throws {
        let directory = try Fixture.directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("dark.png")
        let image = try XCTUnwrap(context.createCGImage(CIImage(color: CIColor(red: 0.03, green: 0.03, blue: 0.03))
            .cropped(to: CGRect(x: 0, y: 0, width: 80, height: 80)), from: CGRect(x: 0, y: 0, width: 80, height: 80)))
        try ImageEncoder.write(image, to: url, format: .png)
        let editor = ImageEditor()
        var edits = PhotoAdjustments(); edits.exposure = 2
        let twoStops = try await editor.render(url: url, adjustments: edits)
        edits.exposure = 4
        let fourStops = try await editor.render(url: url, adjustments: edits)
        XCTAssertGreaterThan(Fixture.pixel(fourStops)[0], Fixture.pixel(twoStops)[0] + 15)
    }

    func testNoFaceAdjustmentsLeavePhotoExactlyUnchanged() async throws {
        let directory = try Fixture.directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("no-face.png")
        try ImageEncoder.write(Fixture.image(width: 400, height: 300), to: url, format: .png)
        let editor = ImageEditor()
        let faces = try await editor.faces(url: url)
        XCTAssertTrue(faces.isEmpty)
        let original = try await editor.render(url: url, adjustments: PhotoAdjustments())
        var edits = PhotoAdjustments(); edits.faceSmoothing = 1; edits.faceBrightness = 1; edits.faceWarmth = 1
        let result = try await editor.render(url: url, adjustments: edits)
        XCTAssertTrue(pixels(original) == pixels(result), "No detected face means no face-only pixel changes")
    }

    func testFaceMaskProtectsFeaturesAndUsesTopLeftCoordinatesAtAnyResolution() throws {
        let face = DetectedFace(id: 0, bounds: PhotoCrop(x: 0.1, y: 0.05, width: 0.5, height: 0.6))
        func facePoint(_ x: Double, _ y: Double) -> FacePoint {
            FacePoint(x: face.bounds.x + x * face.bounds.width, y: face.bounds.y + y * face.bounds.height)
        }
        for size in [CGSize(width: 500, height: 400), CGSize(width: 1_000, height: 800)] {
            let mask = try XCTUnwrap(FaceRetouch.mask(faces: [face], extent: CGRect(origin: .zero, size: size)))
            XCTAssertGreaterThan(sample(mask, at: facePoint(0.25, 0.56))[0], 220, "Cheek should be treated")
            for point in [facePoint(0.275, 0.37), facePoint(0.725, 0.37), facePoint(0.275, 0.25),
                          facePoint(0.725, 0.25), facePoint(0.5, 0.53), facePoint(0.5, 0.79),
                          FacePoint(x: 0.9, y: 0.9), FacePoint(x: 0.02, y: 0.02)] {
                XCTAssertLessThan(sample(mask, at: point)[0], 3, "Feature or background must stay protected at \(point)")
            }
            let feather = sample(mask, at: facePoint(0.09, 0.5))[0]
            XCTAssertGreaterThan(feather, 2)
            XCTAssertLessThan(feather, 230)
        }
        XCTAssertNil(FaceRetouch.mask(faces: [], extent: CGRect(x: 0, y: 0, width: 100, height: 100)))
    }

    func testVisionLandmarkLocationsOverrideFallbackFeaturePositions() throws {
        var landmarks = FaceLandmarks()
        landmarks.leftEye = [FacePoint(x: 0.25, y: 0.45), FacePoint(x: 0.31, y: 0.47)]
        let face = DetectedFace(id: 0, bounds: PhotoCrop(x: 0.1, y: 0.1, width: 0.7, height: 0.8), landmarks: landmarks)
        let geometry = FaceMaskGeometry(face: face)
        XCTAssertEqual(geometry.protectedRegions.count, 6)
        XCTAssertEqual(geometry.protectedRegions[0].x + geometry.protectedRegions[0].width / 2, 0.28, accuracy: 0.0001)
        XCTAssertEqual(geometry.protectedRegions[0].y + geometry.protectedRegions[0].height / 2, 0.46, accuracy: 0.0001)
        let mask = try XCTUnwrap(FaceRetouch.mask(faces: [face], extent: CGRect(x: 0, y: 0, width: 800, height: 800)))
        XCTAssertLessThan(sample(mask, at: FacePoint(x: 0.28, y: 0.46))[0], 3)
    }

    func testOverlappingFaceRegionsNeverRetouchAnotherPersonsEyes() throws {
        let first = DetectedFace(id: 0, bounds: PhotoCrop(x: 0.1, y: 0.1, width: 0.6, height: 0.6))
        let second = DetectedFace(id: 1, bounds: PhotoCrop(x: 0.05, y: 0.02, width: 0.9, height: 0.7))
        let eye = FacePoint(x: first.bounds.x + 0.275 * first.bounds.width,
                            y: first.bounds.y + 0.37 * first.bounds.height)
        let mask = try XCTUnwrap(FaceRetouch.mask(faces: [first, second], extent: CGRect(x: 0, y: 0, width: 600, height: 600)))
        XCTAssertLessThan(sample(mask, at: eye)[0], 3)
    }

    func testPositiveWarmthWarmsBothImageAndFaceSkin() async throws {
        let directory = try Fixture.directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let extent = CGRect(x: 0, y: 0, width: 200, height: 200)
        let base = CIImage(color: CIColor(red: 0.4, green: 0.4, blue: 0.4)).cropped(to: extent)
        let image = try XCTUnwrap(context.createCGImage(base, from: extent))
        let url = directory.appendingPathComponent("gray.png")
        try ImageEncoder.write(image, to: url, format: .png)
        var edits = PhotoAdjustments(); edits.temperature = 80
        let result = try await ImageEditor().render(url: url, adjustments: edits)
        let pixel = Fixture.pixel(result)
        XCTAssertGreaterThan(pixel[0], pixel[2], "Positive temperature must add warmth")
        edits = PhotoAdjustments(); edits.faceWarmth = 1
        let face = DetectedFace(id: 0, bounds: PhotoCrop(x: 0.1, y: 0.1, width: 0.8, height: 0.8))
        let treated = FaceRetouch.apply(to: base, faces: [face], adjustments: edits)
        let cheek = sample(treated, at: FacePoint(x: 0.3, y: 0.548))
        XCTAssertGreaterThan(cheek[0], cheek[2], "Positive face warmth must add warmth")
    }

    func testRetouchChangesCheeksButPreservesBackgroundAndEyes() throws {
        let input = CIImage(cgImage: patternImage(width: 500, height: 500))
        let face = DetectedFace(id: 0, bounds: PhotoCrop(x: 0.1, y: 0.1, width: 0.8, height: 0.8))
        var edits = PhotoAdjustments(); edits.faceSmoothing = 0.8; edits.faceBrightness = 0.8; edits.faceWarmth = 0.5
        let result = FaceRetouch.apply(to: input, faces: [face], adjustments: edits)
        let cheek = FacePoint(x: 0.3, y: 0.548)
        XCTAssertNotEqual(sample(input, at: cheek), sample(result, at: cheek))
        for point in [FacePoint(x: 0.04, y: 0.5), FacePoint(x: 0.32, y: 0.396), FacePoint(x: 0.5, y: 0.732)] {
            XCTAssertEqual(sample(input, at: point), sample(result, at: point), "Retouch must not change protected pixels")
        }
        let withoutFaces = FaceRetouch.apply(to: input, faces: [], adjustments: edits)
        XCTAssertEqual(sample(input, at: cheek), sample(withoutFaces, at: cheek))
    }

    func testStraighteningTrimsTransparentCornersAndKeepsAspectRatio() async throws {
        let directory = try Fixture.directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("landscape.png")
        try ImageEncoder.write(Fixture.image(width: 400, height: 240), to: url, format: .png)
        let editor = ImageEditor()
        var edits = PhotoAdjustments(); edits.straighten = 15
        let image = try await editor.render(url: url, adjustments: edits)
        XCTAssertLessThan(image.width, 400)
        XCTAssertLessThan(image.height, 240)
        XCTAssertEqual(Double(image.width) / Double(image.height), 400.0 / 240, accuracy: 0.02)
        let bytes = pixels(image)
        let minimumAlpha = stride(from: 3, to: bytes.count, by: 4).map { bytes[$0] }.min()
        XCTAssertEqual(minimumAlpha, 255, "No transparent rotation corners")
    }

    func testTopLeftCropAndEXIFOrientationAgreeBetweenPreviewAndExport() async throws {
        let directory = try Fixture.directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("oriented.jpg")
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, patternImage(width: 320, height: 160), [kCGImagePropertyOrientation: 6] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let editor = ImageEditor()
        var edits = PhotoAdjustments(); edits.crop = PhotoCrop(x: 0.1, y: 0.2, width: 0.5, height: 0.5)
        edits.exposure = 0.4; edits.curveMidtones = 0.2; edits.temperature = 30
        let full = try await editor.render(url: url, adjustments: edits)
        let preview = try await editor.render(url: url, adjustments: edits, maxPixelSize: 1_000)
        XCTAssertEqual(full.width, 80); XCTAssertEqual(full.height, 160)
        XCTAssertEqual(preview.width, full.width); XCTAssertEqual(preview.height, full.height)
        let errors = zip(pixels(full), pixels(preview)).map { abs(Int($0) - Int($1)) }
        XCTAssertLessThan(Double(errors.reduce(0, +)) / Double(errors.count), 1)
    }

    func testSourceCacheInvalidatesWhenFileChanges() async throws {
        let directory = try Fixture.directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("replace.png")
        try ImageEncoder.write(Fixture.image(), to: url, format: .png)
        let editor = ImageEditor()
        let first = try await editor.render(url: url, adjustments: PhotoAdjustments())
        try ImageEncoder.write(patternImage(width: 180, height: 120), to: url, format: .png)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(10)], ofItemAtPath: url.path)
        let second = try await editor.render(url: url, adjustments: PhotoAdjustments())
        XCTAssertFalse(pixels(first) == pixels(second), "Replacing a source must invalidate the decoded image cache")
    }

    private func patternImage(width: Int = 200, height: Int = 160) -> CGImage {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                let noise = (x * 29 + y * 13) % 19 - 9
                bytes[offset] = UInt8(clamping: 40 + x * 165 / width + noise)
                bytes[offset + 1] = UInt8(clamping: 45 + y * 130 / height + noise)
                bytes[offset + 2] = UInt8(clamping: 75 + x * 85 / width - noise)
            }
        }
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }

    private func pixels(_ image: CGImage) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        bytes.withUnsafeMutableBytes { buffer in
            let cg = CGContext(data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                               bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                               bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            cg.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return bytes
    }

    private func sample(_ image: CIImage, at point: FacePoint) -> [UInt8] {
        let rectangle = CGRect(x: floor(image.extent.minX + point.x * image.extent.width),
                               y: floor(image.extent.minY + (1 - point.y) * image.extent.height), width: 1, height: 1)
        return pixels(context.createCGImage(image, from: rectangle, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))!)
    }
}
