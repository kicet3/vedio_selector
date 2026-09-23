import Foundation
import CoreGraphics

public struct AdjustmentPreset: Identifiable, Codable, Sendable {
    public let id: UUID
    public var name: String
    public var adjustments: PhotoAdjustments
    public init(name: String, adjustments: PhotoAdjustments) {
        id = UUID(); self.name = name; self.adjustments = adjustments
    }
}

public struct PhotoHistogram: Sendable {
    public let red: [Double]
    public let green: [Double]
    public let blue: [Double]
    public let clippedShadows: Double
    public let clippedHighlights: Double
}

public enum PhotoStatistics {
    public static func histogram(_ image: CGImage) -> PhotoHistogram {
        let width = 256, height = 128
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        bytes.withUnsafeMutableBytes { data in
            guard let context = CGContext(data: data.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        var red = [Double](repeating: 0, count: 64), green = red, blue = red
        var dark = 0.0, light = 0.0
        for offset in stride(from: 0, to: bytes.count, by: 4) {
            let r = Int(bytes[offset]), g = Int(bytes[offset + 1]), b = Int(bytes[offset + 2])
            red[r / 4] += 1; green[g / 4] += 1; blue[b / 4] += 1
            if max(r, g, b) < 4 { dark += 1 }
            if min(r, g, b) > 251 { light += 1 }
        }
        let maximum = max(1, max(red.max() ?? 1, max(green.max() ?? 1, blue.max() ?? 1)))
        return PhotoHistogram(red: red.map { $0 / maximum }, green: green.map { $0 / maximum }, blue: blue.map { $0 / maximum },
                              clippedShadows: dark / Double(width * height), clippedHighlights: light / Double(width * height))
    }
}

extension LibraryDisk {
    public func loadPresets() throws -> [AdjustmentPreset] {
        let path = root.appendingPathComponent("presets.json")
        guard FileManager.default.fileExists(atPath: path.path) else { return [] }
        return try JSONDecoder().decode([AdjustmentPreset].self, from: Data(contentsOf: path))
    }
    public func savePresets(_ presets: [AdjustmentPreset]) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONEncoder().encode(presets).write(to: root.appendingPathComponent("presets.json"), options: .atomic)
    }
}
