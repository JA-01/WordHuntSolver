import CoreGraphics
import Foundation
import WordHuntCore

/// Compares dark glyph silhouettes, ignoring wood color and score/timer changes.
/// This protects manually corrected OCR without requiring the OCR to agree again.
public enum BoardAppearance {
    public static func matches(_ original: CGImage, _ current: CGImage, geometry: GridGeometry) throws -> Bool {
        guard original.width == current.width, original.height == current.height,
              (4...5).contains(geometry.size), geometry.width > 0, geometry.height > 0,
              CGRect(x: 0, y: 0, width: original.width, height: original.height).contains(geometry.rect) else { return false }
        let cellWidth = geometry.width / Double(geometry.size)
        let cellHeight = geometry.height / Double(geometry.size)
        for index in 0..<(geometry.size * geometry.size) {
            let center = geometry.center(of: index)
            let rect = CGRect(x: center.x - cellWidth * 0.34, y: center.y - cellHeight * 0.34,
                              width: cellWidth * 0.68, height: cellHeight * 0.68).integral
            guard let left = original.cropping(to: rect), let right = current.cropping(to: rect) else { return false }
            let a = try mask(left), b = try mask(right)
            var intersection = 0, union = 0
            for pixel in a.indices {
                let darkA = a[pixel] < 110, darkB = b[pixel] < 110
                if darkA || darkB { union += 1 }
                if darkA && darkB { intersection += 1 }
            }
            guard union > 4, Double(intersection) / Double(union) >= 0.86 else { return false }
        }
        return true
    }

    private static func mask(_ image: CGImage) throws -> [UInt8] {
        var pixels = [UInt8](repeating: 255, count: 32 * 32)
        let success = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: 32, height: 32, bitsPerComponent: 8,
                                          bytesPerRow: 32, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0) else { return false }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: 32, height: 32))
            return true
        }
        guard success else { throw WordHuntError.automation("Could not compare the live board to its captured letters.") }
        return pixels
    }
}
