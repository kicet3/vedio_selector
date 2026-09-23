import Foundation
import AVFoundation
import ImageIO
import UniformTypeIdentifiers
import CoreImage

public enum VideoIndexer {
    public static func read(url: URL, progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> VideoIndex {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw MediaError.message("이 파일에는 읽을 수 있는 동영상 트랙이 없습니다.")
        }
        let duration = try await asset.load(.duration).seconds
        let size = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let fps = try await track.load(.nominalFrameRate)
        let displaySize = size.applying(transform)
        let reader = try AVAssetReader(asset: asset)
        // Compressed samples avoid decoding a whole movie merely to count its frames.
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw MediaError.message("이 동영상의 프레임 정보를 읽을 수 없습니다.") }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? MediaError.message("동영상 읽기를 시작할 수 없습니다.") }
        var times: [FrameStamp] = []
        do {
            while true {
                try Task.checkCancellation()
                let hasSample: Bool = try autoreleasepool {
                    guard let sample = output.copyNextSampleBuffer() else { return false }
                    let count = CMSampleBufferGetNumSamples(sample)
                    if count == 0 { return true } // Edit-list marker buffers contain no frames.
                    let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
                    var outputTiming = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: count)
                    var timingCount = 0
                    if count > 1 {
                        guard CMSampleBufferGetOutputSampleTimingInfoArray(sample, entryCount: count, arrayToFill: &outputTiming, entriesNeededOut: &timingCount) == noErr else {
                            throw MediaError.message("프레임의 출력 시간 정보를 읽을 수 없습니다.")
                        }
                    }
                    for offset in 0..<count {
                        if let attachments, offset < attachments.count,
                           attachments[offset][kCMSampleAttachmentKey_DoNotDisplay] as? Bool == true { continue }
                        let time: CMTime
                        // Output PTS applies MP4 edit lists and speed mappings. Raw PTS may
                        // include decoder preroll, shifting every requested frame by 1–2 frames.
                        if count == 1 { time = CMSampleBufferGetOutputPresentationTimeStamp(sample) }
                        else if timingCount == 1 {
                            time = CMTimeAdd(outputTiming[0].presentationTimeStamp, CMTimeMultiply(outputTiming[0].duration, multiplier: Int32(offset)))
                        } else if offset < timingCount { time = outputTiming[offset].presentationTimeStamp }
                        else { throw MediaError.message("일부 프레임의 출력 시간 정보를 읽을 수 없습니다.") }
                        if time.isNumeric && time.seconds >= 0 && time.seconds < duration {
                            times.append(FrameStamp(time))
                        }
                    }
                    if times.count % 500 == 0, let last = times.last, duration > 0 {
                        progress(min(0.99, last.seconds / duration))
                    }
                    return true
                }
                if !hasSample { break }
            }
        } catch { reader.cancelReading(); throw error }
        guard reader.status == .completed else { throw reader.error ?? MediaError.message("동영상 읽기가 중단되었습니다.") }
        // B-frames arrive in decode order, which is different from display order.
        times.sort { CMTimeCompare($0.time, $1.time) < 0 }
        guard !times.isEmpty else { throw MediaError.message("이 동영상에서 표시할 프레임을 찾지 못했습니다.") }
        progress(1)
        return VideoIndex(frames: times, duration: duration, width: Int(abs(displaySize.width)),
                          height: Int(abs(displaySize.height)), nominalFPS: fps)
    }
}

/// Separate renderer instances keep preview work independent of queued thumbnails.
/// Synchronous generation is deliberately isolated to this actor, never the UI actor.
public actor FrameRenderer {
    private let generator: AVAssetImageGenerator
    private let cache = NSCache<NSString, CGImage>()
    private let imageContext = CIContext(options: [.cacheIntermediates: false])
    public init(url: URL, maxPixelSize: Int) {
        generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        if maxPixelSize > 0 { generator.maximumSize = CGSize(width: maxPixelSize, height: maxPixelSize) }
        cache.totalCostLimit = maxPixelSize > 0 && maxPixelSize <= 400 ? 48 * 1024 * 1024 : 64 * 1024 * 1024
        cache.countLimit = maxPixelSize > 0 && maxPixelSize <= 400 ? 240 : 6
    }
    public func image(at stamp: FrameStamp, quarterTurns: Int = 0) throws -> CGImage {
        try Task.checkCancellation()
        let turns = ((quarterTurns % 4) + 4) % 4
        let key = "\(stamp.value)/\(stamp.timescale)/\(turns)" as NSString
        if let image = cache.object(forKey: key) { return image }
        var actualTime = CMTime.invalid
        var image = try generator.copyCGImage(at: stamp.time, actualTime: &actualTime)
        try Task.checkCancellation()
        guard CMTimeCompare(actualTime, stamp.time) == 0 else {
            throw MediaError.message("요청한 프레임과 디코딩한 프레임이 다릅니다. 다른 동영상을 시도해 주세요.")
        }
        if turns != 0 {
            let orientation: CGImagePropertyOrientation = turns == 1 ? .right : turns == 2 ? .down : .left
            let rotated = CIImage(cgImage: image).oriented(orientation)
            guard let output = imageContext.createCGImage(rotated, from: rotated.extent) else {
                throw MediaError.message("프레임을 회전하지 못했습니다.")
            }
            image = output
        }
        cache.setObject(image, forKey: key, cost: image.bytesPerRow * image.height)
        return image
    }
}

public actor PhotoRenderer {
    public static let shared = PhotoRenderer()
    private let cache = NSCache<NSString, CGImage>()
    public init() { cache.totalCostLimit = 80 * 1024 * 1024; cache.countLimit = 180 }
    public func image(url: URL, maxPixelSize: Int) throws -> CGImage {
        try Task.checkCancellation()
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate?.timeIntervalSince1970 ?? 0
        let key = "\(url.path):\(modified):\(maxPixelSize)" as NSString
        if let image = cache.object(forKey: key) { return image }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw MediaError.message("사진을 읽을 수 없습니다: \(url.lastPathComponent)")
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let width = (properties?[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
        let height = (properties?[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
        let limit = maxPixelSize > 0 ? maxPixelSize : max(width, height)
        guard limit > 0, let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: limit,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { throw MediaError.message("사진을 읽을 수 없습니다: \(url.lastPathComponent)") }
        try Task.checkCancellation()
        cache.setObject(image, forKey: key, cost: image.bytesPerRow * image.height)
        return image
    }
}

public enum ImageEncoder {
    public static func write(_ image: CGImage, to url: URL, format: CaptureFormat) throws {
        let type = format == .png ? UTType.png.identifier : UTType.jpeg.identifier
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type as CFString, 1, nil) else {
            throw MediaError.message("사진 파일을 만들 수 없습니다.")
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.96] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw MediaError.message("사진 저장을 완료하지 못했습니다.") }
    }
}
