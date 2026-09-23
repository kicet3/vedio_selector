import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO

/// Coordinates are normalized to the oriented image, with the origin at top left.
public struct PhotoCrop: Equatable, Hashable, Codable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public static let full = PhotoCrop(x: 0, y: 0, width: 1, height: 1)
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
}

public struct PhotoAdjustments: Equatable, Hashable, Codable, Sendable {
    public var quarterTurns = 0
    public var exposure = 0.0
    public var crop = PhotoCrop.full
    public var contrast = 1.0
    public var saturation = 1.0
    public var vibrance = 0.0
    public var temperature = 0.0
    public var tint = 0.0
    public var highlights = 0.0
    public var shadows = 0.0
    public var blackPoint = 0.0
    public var sharpness = 0.0
    public var noiseReduction = 0.0
    public var vignette = 0.0
    public var straighten = 0.0
    public var curveShadows = 0.0
    public var curveMidtones = 0.0
    public var curveHighlights = 0.0
    public var faceSmoothing = 0.0
    public var faceBrightness = 0.0
    public var faceWarmth = 0.0
    public var autoEnhance = false

    public init() {}
    public var isUnchanged: Bool { normalized() == PhotoAdjustments() }
    public var hasFaceAdjustments: Bool { faceSmoothing != 0 || faceBrightness != 0 || faceWarmth != 0 }

    /// Sanitizes numeric controls. Invalid crop rectangles remain invalid and are rejected by render.
    public func normalized() -> PhotoAdjustments {
        var result = self
        result.quarterTurns = ((quarterTurns % 4) + 4) % 4
        result.exposure = Self.value(exposure, in: -4...4)
        result.contrast = Self.value(contrast, in: 0.5...1.5, fallback: 1)
        result.saturation = Self.value(saturation, in: 0...2, fallback: 1)
        result.vibrance = Self.value(vibrance, in: -1...1)
        result.temperature = Self.value(temperature, in: -100...100)
        result.tint = Self.value(tint, in: -100...100)
        result.highlights = Self.value(highlights, in: -1...1)
        result.shadows = Self.value(shadows, in: -1...1)
        result.blackPoint = Self.value(blackPoint, in: -0.2...0.2)
        result.sharpness = Self.value(sharpness, in: 0...2)
        result.noiseReduction = Self.value(noiseReduction, in: 0...1)
        result.vignette = Self.value(vignette, in: 0...1)
        result.straighten = Self.value(straighten, in: -15...15)
        result.curveShadows = Self.value(curveShadows, in: -1...1)
        result.curveMidtones = Self.value(curveMidtones, in: -1...1)
        result.curveHighlights = Self.value(curveHighlights, in: -1...1)
        result.faceSmoothing = Self.value(faceSmoothing, in: 0...1)
        result.faceBrightness = Self.value(faceBrightness, in: -1...1)
        result.faceWarmth = Self.value(faceWarmth, in: -1...1)
        return result
    }

    private static func value(_ value: Double, in range: ClosedRange<Double>, fallback: Double = 0) -> Double {
        value.isFinite ? min(range.upperBound, max(range.lowerBound, value)) : fallback
    }

    private enum CodingKeys: String, CodingKey {
        case quarterTurns, exposure, crop, contrast, saturation, vibrance, temperature, tint
        case highlights, shadows, blackPoint, sharpness, noiseReduction, vignette, straighten
        case curveShadows, curveMidtones, curveHighlights, faceSmoothing, faceBrightness, faceWarmth, autoEnhance
    }

    /// Missing controls in older saved recipes use their neutral values.
    public init(from decoder: Decoder) throws {
        self.init()
        let values = try decoder.container(keyedBy: CodingKeys.self)
        quarterTurns = try values.decodeIfPresent(Int.self, forKey: .quarterTurns) ?? 0
        crop = try values.decodeIfPresent(PhotoCrop.self, forKey: .crop) ?? .full
        autoEnhance = try values.decodeIfPresent(Bool.self, forKey: .autoEnhance) ?? false
        let controls: [(CodingKeys, WritableKeyPath<PhotoAdjustments, Double>)] = [
            (.exposure, \.exposure), (.contrast, \.contrast), (.saturation, \.saturation),
            (.vibrance, \.vibrance), (.temperature, \.temperature), (.tint, \.tint),
            (.highlights, \.highlights), (.shadows, \.shadows), (.blackPoint, \.blackPoint),
            (.sharpness, \.sharpness), (.noiseReduction, \.noiseReduction), (.vignette, \.vignette),
            (.straighten, \.straighten), (.curveShadows, \.curveShadows), (.curveMidtones, \.curveMidtones),
            (.curveHighlights, \.curveHighlights), (.faceSmoothing, \.faceSmoothing),
            (.faceBrightness, \.faceBrightness), (.faceWarmth, \.faceWarmth)
        ]
        for (key, path) in controls {
            if let value = try values.decodeIfPresent(Double.self, forKey: key) { self[keyPath: path] = value }
        }
        self = normalized()
    }
}

public actor ImageEditor {
    public static let shared = ImageEditor()
    private let context = CIContext(options: [.cacheIntermediates: false])
    private var sourceCache: [SourceCacheEntry] = []
    private var faceCache: [(key: FileVersion, faces: [DetectedFace])] = []
    private let sourceCacheLimit = 192 * 1_024 * 1_024
    public init() {}

    /// Vision runs entirely on this Mac; face data is never uploaded.
    public func faces(url: URL) async throws -> [DetectedFace] {
        try Task.checkCancellation()
        return try detectedFaces(url: url, version: fileVersion(url))
    }

    public func render(url: URL, adjustments: PhotoAdjustments, maxPixelSize: Int = 0) throws -> CGImage {
        try Task.checkCancellation()
        let version = try fileVersion(url)
        let base = try source(url: url, version: version, maxPixelSize: max(0, maxPixelSize))
        let edits = adjustments.normalized()
        let faces = edits.hasFaceAdjustments ? try detectedFaces(url: url, version: version) : []
        return try render(base: base, adjustments: edits, faces: faces)
    }

    private struct FileVersion: Hashable {
        let url: URL
        let modified: Date?
        let size: Int?
    }

    private struct SourceCacheEntry {
        let version: FileVersion
        let size: Int
        let image: CIImage
        let cost: Int
    }

    private func fileVersion(_ url: URL) throws -> FileVersion {
        // URL resource values may themselves be cached after an external editor replaces the file.
        let values = try FileManager.default.attributesOfItem(atPath: url.path)
        return FileVersion(url: url.standardizedFileURL, modified: values[.modificationDate] as? Date,
                           size: (values[.size] as? NSNumber)?.intValue)
    }

    private func source(url: URL, version: FileVersion, maxPixelSize: Int) throws -> CIImage {
        if let index = sourceCache.firstIndex(where: { $0.version == version && $0.size == maxPixelSize }) {
            let entry = sourceCache.remove(at: index)
            sourceCache.append(entry)
            return entry.image
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw MediaError.message("원본 사진을 읽을 수 없습니다. 원본이 있는 폴더를 다시 열어 주세요.")
        }
        let base: CIImage
        let cost: Int
        if maxPixelSize > 0 {
            guard let decoded = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
                kCGImageSourceShouldCacheImmediately: true
            ] as CFDictionary) else { throw MediaError.message("편집할 사진을 읽을 수 없습니다.") }
            base = CIImage(cgImage: decoded)
            cost = decoded.bytesPerRow * decoded.height
        } else {
            guard let decoded = CGImageSourceCreateImageAtIndex(source, 0,
                    [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else {
                throw MediaError.message("원본 사진을 읽을 수 없습니다.")
            }
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
            let orientation = (properties?[kCGImagePropertyOrientation] as? NSNumber)?.uint32Value ?? 1
            base = CIImage(cgImage: decoded).oriented(CGImagePropertyOrientation(rawValue: orientation) ?? .up)
            cost = decoded.bytesPerRow * decoded.height
        }
        let image = Self.atOrigin(base)
        sourceCache.removeAll { $0.version.url == version.url && $0.version != version }
        if cost <= sourceCacheLimit {
            while !sourceCache.isEmpty && (sourceCache.count >= 5 || sourceCache.reduce(cost, { $0 + $1.cost }) > sourceCacheLimit) {
                sourceCache.removeFirst()
            }
            sourceCache.append(SourceCacheEntry(version: version, size: maxPixelSize, image: image, cost: cost))
        }
        return image
    }

    private func detectedFaces(url: URL, version: FileVersion) throws -> [DetectedFace] {
        if let index = faceCache.firstIndex(where: { $0.key == version }) {
            let entry = faceCache.remove(at: index)
            faceCache.append(entry)
            return entry.faces
        }
        let input = try source(url: url, version: version, maxPixelSize: 1_600)
        let result = try FaceRetouch.detect(in: input)
        try Task.checkCancellation()
        faceCache.removeAll { $0.key.url == version.url }
        if faceCache.count >= 24 { faceCache.removeFirst() }
        faceCache.append((version, result))
        return result
    }

    private func render(base: CIImage, adjustments edits: PhotoAdjustments, faces: [DetectedFace]) throws -> CGImage {
        let crop = edits.crop
        guard [crop.x, crop.y, crop.width, crop.height].allSatisfy(\.isFinite),
              crop.x >= 0, crop.y >= 0, crop.width > 0, crop.height > 0,
              crop.x + crop.width <= 1.000001, crop.y + crop.height <= 1.000001 else {
            throw MediaError.message("자를 영역을 사진 안에서 선택해 주세요.")
        }
        var image = base
        if edits.autoEnhance {
            // Geometry and red-eye changes remain explicit, user-controlled operations.
            for filter in image.autoAdjustmentFilters(options: [.enhance: true, .redEye: false]) {
                filter.setValue(image, forKey: kCIInputImageKey)
                if let result = filter.outputImage { image = result.cropped(to: base.extent) }
            }
        }
        image = Self.applyTone(to: image, edits: edits)
        if edits.noiseReduction > 0 {
            image = image.applyingFilter("CINoiseReduction", parameters: [
                "inputNoiseLevel": edits.noiseReduction * 0.08, "inputSharpness": 0.4
            ])
        }
        if edits.hasFaceAdjustments && !faces.isEmpty {
            image = FaceRetouch.apply(to: image, faces: faces, adjustments: edits)
        }
        if edits.sharpness > 0 {
            image = image.applyingFilter("CISharpenLuminance", parameters: [kCIInputSharpnessKey: edits.sharpness])
        }
        for _ in 0..<edits.quarterTurns { image = image.oriented(.right) }
        image = Self.atOrigin(image)
        if edits.straighten != 0 { image = Self.straightened(image, degrees: edits.straighten) }
        let bounds = image.extent
        let rectangle = CGRect(x: crop.x * bounds.width, y: (1 - crop.y - crop.height) * bounds.height,
                               width: crop.width * bounds.width, height: crop.height * bounds.height).integral.intersection(bounds)
        guard rectangle.width >= 1, rectangle.height >= 1 else { throw MediaError.message("자를 영역이 너무 작습니다.") }
        image = Self.atOrigin(image.cropped(to: rectangle))
        if edits.vignette > 0 {
            image = image.applyingFilter("CIVignette", parameters: [
                kCIInputIntensityKey: edits.vignette * 1.5,
                kCIInputRadiusKey: min(image.extent.width, image.extent.height) * 0.5
            ])
        }
        try Task.checkCancellation()
        guard let result = context.createCGImage(image, from: image.extent, format: .RGBA8,
                                               colorSpace: CGColorSpace(name: CGColorSpace.sRGB)) else {
            throw MediaError.message("편집한 사진을 생성하지 못했습니다.")
        }
        return result
    }

    private static func atOrigin(_ image: CIImage) -> CIImage {
        image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
    }

    private static func applyTone(to input: CIImage, edits: PhotoAdjustments) -> CIImage {
        var image = input
        if edits.exposure != 0 { image = image.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: edits.exposure]) }
        if edits.temperature != 0 || edits.tint != 0 {
            image = image.applyingFilter("CITemperatureAndTint", parameters: [
                "inputNeutral": CIVector(x: 6_500 + edits.temperature * 28, y: edits.tint),
                "inputTargetNeutral": CIVector(x: 6_500, y: 0)
            ])
        }
        if edits.contrast != 1 || edits.saturation != 1 {
            image = image.applyingFilter("CIColorControls", parameters: [
                kCIInputContrastKey: edits.contrast, kCIInputSaturationKey: edits.saturation
            ])
        }
        if edits.vibrance != 0 { image = image.applyingFilter("CIVibrance", parameters: [kCIInputAmountKey: edits.vibrance]) }
        if edits.highlights != 0 || edits.shadows != 0 || edits.blackPoint != 0 ||
            edits.curveShadows != 0 || edits.curveMidtones != 0 || edits.curveHighlights != 0 {
            // A monotone five-point curve avoids inverted tones even at slider extremes.
            let low = max(0, -edits.blackPoint)
            let p1 = min(0.48, max(low + 0.015, 0.25 + edits.shadows * 0.14 + edits.curveShadows * 0.15 - edits.blackPoint * 0.6))
            let p2 = min(0.79, max(p1 + 0.015, 0.5 + edits.curveMidtones * 0.2 - edits.blackPoint * 0.3))
            let p3 = min(0.985, max(p2 + 0.015, 0.75 + edits.highlights * 0.14 + edits.curveHighlights * 0.15 - edits.blackPoint * 0.1))
            image = image.applyingFilter("CIToneCurve", parameters: [
                "inputPoint0": CIVector(x: 0, y: low), "inputPoint1": CIVector(x: 0.25, y: p1),
                "inputPoint2": CIVector(x: 0.5, y: p2), "inputPoint3": CIVector(x: 0.75, y: p3),
                "inputPoint4": CIVector(x: 1, y: 1)
            ])
        }
        return image
    }

    /// Rotates about the center, then trims to an inscribed rectangle with the original aspect ratio.
    private static func straightened(_ image: CIImage, degrees: Double) -> CIImage {
        let bounds = image.extent
        let radians = degrees * .pi / 180
        let rotated = image.transformed(by: CGAffineTransform(translationX: -bounds.midX, y: -bounds.midY))
            .transformed(by: CGAffineTransform(rotationAngle: -radians))
        let sine = abs(sin(radians)), cosine = abs(cos(radians))
        let scale = 1 / max(cosine + bounds.height / bounds.width * sine, cosine + bounds.width / bounds.height * sine)
        let halfWidth = floor(bounds.width * scale / 2), halfHeight = floor(bounds.height * scale / 2)
        guard halfWidth >= 1, halfHeight >= 1 else { return image }
        // Integral crop edges avoid half-transparent edge pixels when Core Image resamples the crop.
        return atOrigin(rotated.cropped(to: CGRect(x: -halfWidth, y: -halfHeight, width: halfWidth * 2, height: halfHeight * 2)))
    }
}
