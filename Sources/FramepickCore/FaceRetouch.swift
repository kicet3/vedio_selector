import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins
import Vision

/// A point in normalized, EXIF-oriented image coordinates, with the origin at the top left.
public struct FacePoint: Hashable, Codable, Sendable {
    public let x: Double
    public let y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
}

public struct FaceLandmarks: Hashable, Codable, Sendable {
    public var faceContour: [FacePoint] = []
    public var leftEye: [FacePoint] = []
    public var rightEye: [FacePoint] = []
    public var leftEyebrow: [FacePoint] = []
    public var rightEyebrow: [FacePoint] = []
    public var nose: [FacePoint] = []
    public var noseCrest: [FacePoint] = []
    public var outerLips: [FacePoint] = []
    public var innerLips: [FacePoint] = []
    public init() {}
}

public struct DetectedFace: Identifiable, Hashable, Codable, Sendable {
    public let id: Int
    public let bounds: PhotoCrop
    public let landmarks: FaceLandmarks
    public init(id: Int, bounds: PhotoCrop, landmarks: FaceLandmarks = FaceLandmarks()) {
        self.id = id; self.bounds = bounds; self.landmarks = landmarks
    }
}

enum FaceRetouch {
    static func detect(in image: CIImage) throws -> [DetectedFace] {
        try Task.checkCancellation()
        let request = VNDetectFaceLandmarksRequest()
        try VNImageRequestHandler(ciImage: image, orientation: .up, options: [:]).perform([request])
        let observations = (request.results ?? []).sorted {
            if $0.boundingBox.midY != $1.boundingBox.midY { return $0.boundingBox.midY > $1.boundingBox.midY }
            return $0.boundingBox.midX < $1.boundingBox.midX
        }
        return observations.enumerated().map { index, observation in
            let box = observation.boundingBox
            func points(_ region: VNFaceLandmarkRegion2D?) -> [FacePoint] {
                guard let region else { return [] }
                return region.normalizedPoints.map { point in
                    FacePoint(x: box.minX + Double(point.x) * box.width,
                              y: 1 - box.minY - Double(point.y) * box.height)
                }
            }
            var landmarks = FaceLandmarks()
            landmarks.faceContour = points(observation.landmarks?.faceContour)
            landmarks.leftEye = points(observation.landmarks?.leftEye)
            landmarks.rightEye = points(observation.landmarks?.rightEye)
            landmarks.leftEyebrow = points(observation.landmarks?.leftEyebrow)
            landmarks.rightEyebrow = points(observation.landmarks?.rightEyebrow)
            landmarks.nose = points(observation.landmarks?.nose)
            landmarks.noseCrest = points(observation.landmarks?.noseCrest)
            landmarks.outerLips = points(observation.landmarks?.outerLips)
            landmarks.innerLips = points(observation.landmarks?.innerLips)
            return DetectedFace(id: index, bounds: PhotoCrop(x: box.minX, y: 1 - box.maxY, width: box.width, height: box.height), landmarks: landmarks)
        }
    }

    static func apply(to image: CIImage, faces: [DetectedFace], adjustments edits: PhotoAdjustments) -> CIImage {
        guard edits.hasFaceAdjustments, let mask = mask(faces: faces, extent: image.extent) else { return image }
        var treated = image
        if edits.faceSmoothing > 0 {
            let facePixels = faces.map { $0.bounds.width * image.extent.width }.max() ?? 100
            let reduced = image.applyingFilter("CINoiseReduction", parameters: [
                "inputNoiseLevel": 0.02 + edits.faceSmoothing * 0.08, "inputSharpness": 0.4
            ])
            let softened = reduced.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [
                kCIInputRadiusKey: max(0.45, facePixels * 0.0035)
            ]).cropped(to: image.extent)
            let strength = CIImage(color: CIColor(red: edits.faceSmoothing * 0.65, green: edits.faceSmoothing * 0.65,
                                                  blue: edits.faceSmoothing * 0.65)).cropped(to: image.extent)
            treated = softened.applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: image, kCIInputMaskImageKey: strength
            ])
        }
        if edits.faceBrightness != 0 {
            treated = treated.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: edits.faceBrightness * 0.7])
        }
        if edits.faceWarmth != 0 {
            treated = treated.applyingFilter("CITemperatureAndTint", parameters: [
                "inputNeutral": CIVector(x: 6_500 + edits.faceWarmth * 1_300, y: 0),
                "inputTargetNeutral": CIVector(x: 6_500, y: 0)
            ])
        }
        return treated.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: image, kCIInputMaskImageKey: mask
        ]).cropped(to: image.extent)
    }

    /// Uses conservative skin regions, preserving recognizable eyes, brows, mouth and nose detail.
    /// This is local photographic retouching, not generative reconstruction or face reshaping.
    static func mask(faces: [DetectedFace], extent: CGRect) -> CIImage? {
        guard !faces.isEmpty, extent.width > 0, extent.height > 0 else { return nil }
        var combined = CIImage(color: .black).cropped(to: extent)
        let geometries = faces.map(FaceMaskGeometry.init)
        for geometry in geometries {
            combined = ellipse(geometry.skin, extent: extent, inverted: false)
                .applyingFilter("CIMaximumCompositing", parameters: [kCIInputBackgroundImageKey: combined]).cropped(to: extent)
        }
        // Protect every person's features even where neighboring face regions overlap.
        for geometry in geometries {
            for exclusion in geometry.protectedRegions {
                combined = combined.applyingFilter("CIMultiplyCompositing", parameters: [
                    kCIInputBackgroundImageKey: ellipse(exclusion, extent: extent, inverted: true)
                ]).cropped(to: extent)
            }
        }
        return combined
    }

    private static func ellipse(_ box: PhotoCrop, extent: CGRect, inverted: Bool) -> CIImage {
        let filter = CIFilter.radialGradient()
        filter.center = .zero
        filter.radius0 = inverted ? 0.82 : 0.68
        filter.radius1 = 1
        filter.color0 = inverted ? .black : .white
        filter.color1 = inverted ? .white : .black
        let radiusX = max(0.5, box.width * extent.width / 2)
        let radiusY = max(0.5, box.height * extent.height / 2)
        return filter.outputImage!.transformed(by: CGAffineTransform(scaleX: radiusX, y: radiusY))
            .transformed(by: CGAffineTransform(translationX: extent.minX + (box.x + box.width / 2) * extent.width,
                                              y: extent.minY + (1 - box.y - box.height / 2) * extent.height)).cropped(to: extent)
    }
}

/// Geometry stays in normalized top-left coordinates so it scales equally for previews and exports.
struct FaceMaskGeometry {
    let skin: PhotoCrop
    let protectedRegions: [PhotoCrop]

    init(face: DetectedFace) {
        let box = face.bounds
        func relative(_ x: Double, _ y: Double, _ width: Double, _ height: Double) -> PhotoCrop {
            PhotoCrop(x: box.x + x * box.width, y: box.y + y * box.height,
                      width: width * box.width, height: height * box.height)
        }
        func region(_ points: [FacePoint], fallback: PhotoCrop, padding: Double = 0.04) -> PhotoCrop {
            guard let first = points.first, points.count >= 2 else { return fallback }
            let minX = points.reduce(first.x) { min($0, $1.x) }, maxX = points.reduce(first.x) { max($0, $1.x) }
            let minY = points.reduce(first.y) { min($0, $1.y) }, maxY = points.reduce(first.y) { max($0, $1.y) }
            // A bounding ellipse needs extra space to protect the corners of the landmark bounds.
            let width = max((maxX - minX) * 1.4, box.width * 0.07) + padding * box.width * 2
            let height = max((maxY - minY) * 1.4, box.height * 0.045) + padding * box.height * 2
            return PhotoCrop(x: (minX + maxX - width) / 2, y: (minY + maxY - height) / 2, width: width, height: height)
        }
        skin = relative(0.07, 0.015, 0.86, 0.97)
        let landmarks = face.landmarks
        protectedRegions = [
            region(landmarks.leftEye, fallback: relative(0.10, 0.27, 0.35, 0.20)),
            region(landmarks.rightEye, fallback: relative(0.55, 0.27, 0.35, 0.20)),
            region(landmarks.leftEyebrow, fallback: relative(0.08, 0.17, 0.39, 0.16), padding: 0.025),
            region(landmarks.rightEyebrow, fallback: relative(0.53, 0.17, 0.39, 0.16), padding: 0.025),
            region(landmarks.nose + landmarks.noseCrest, fallback: relative(0.35, 0.38, 0.30, 0.31), padding: 0.025),
            region(landmarks.outerLips + landmarks.innerLips, fallback: relative(0.25, 0.69, 0.50, 0.20))
        ]
    }
}
