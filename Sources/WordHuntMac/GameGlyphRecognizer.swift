import Accelerate
import AppKit
import CoreGraphics
import CoreText
import Foundation
import WordHuntCore

/// Shape matching against real, labeled GamePigeon captures. No dictionary or
/// language model participates: a Q remains Q, and two-letter tiles go to OCR.
/// The bundled bank and held-out corpus provenance are in GlyphProvenance.json.
struct GameGlyphRecognizer {
    enum Result {
        case recognized(CellReading)
        case ambiguous
        case unfamiliar
        case blank
    }

    private struct Prototype {
        let letterIndex: Int
        let pixels: [Float]
    }

    private static let side = 32
    private static let prototypes: [Prototype] = {
        guard let url = Bundle.module.url(forResource: "GamePigeonGlyphs", withExtension: "bin"),
              let data = try? Data(contentsOf: url), data.count >= 8,
              Array(data.prefix(4)) == Array("WHG1".utf8) else { return [] }
        let bytes = [UInt8](data)
        let count = Int(bytes[4]) | Int(bytes[5]) << 8 | Int(bytes[6]) << 16 | Int(bytes[7]) << 24
        guard count > 0, count <= 4096, bytes.count == 8 + count * 1025 else { return [] }
        return (0..<count).compactMap { index in
            let start = 8 + index * 1025
            guard (65...90).contains(bytes[start]) else { return nil }
            return Prototype(letterIndex: Int(bytes[start]) - 65,
                             pixels: bytes[(start + 1)..<(start + 1025)].map { Float($0) / 255 })
        }
    }()

    /// Independently rendered support for the app's practice font and common
    /// screenshot typography. This bank never replaces accepted GamePigeon
    /// evidence, and must beat a rejected reference match by at least 2×.
    private static let nativeFontPrototypes: [Prototype] = {
        let canvas = 112
        guard let context = CGContext(data: nil, width: canvas, height: canvas,
                                      bitsPerComponent: 8, bytesPerRow: canvas * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                                        | CGBitmapInfo.byteOrder32Big.rawValue) else { return [] }
        context.translateBy(x: 0, y: CGFloat(canvas))
        context.scaleBy(x: 1, y: -1)
        var result: [Prototype] = []
        result.reserveCapacity(572)
        for pointValue in stride(from: 32, through: 72, by: 4) {
            let pointSize = CGFloat(pointValue)
            let fonts = [
                CTFontCreateWithName("Helvetica-Bold" as CFString, pointSize, nil),
                CTFontCreateWithName(NSFont.systemFont(ofSize: pointSize, weight: .heavy).fontName as CFString, pointSize, nil)
            ]
            for font in fonts {
                for letterIndex in 0..<26 {
                    context.setFillColor(gray: 1, alpha: 1)
                    context.fill(CGRect(x: 0, y: 0, width: canvas, height: canvas))
                    let text = String(UnicodeScalar(65 + letterIndex)!)
                    let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
                        NSAttributedString.Key(kCTFontAttributeName as String): font,
                        NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)
                    ]))
                    let bounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
                    context.saveGState()
                    context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
                    context.textPosition = CGPoint(x: CGFloat(canvas) / 2 - bounds.midX,
                                                   y: CGFloat(canvas) / 2 + bounds.midY)
                    CTLineDraw(line, context)
                    context.restoreGState()
                    guard let image = context.makeImage(),
                          let raster = try? PixelRaster(image: image, maximumDimension: 128),
                          let glyph = segment(raster), !glyph.multiletter else { continue }
                    result.append(Prototype(letterIndex: letterIndex, pixels: glyph.pixels))
                }
            }
        }
        return result
    }()

    private struct Match {
        let letterIndex: Int
        let distance: Float
        let margin: Float

        func reading(maximumDistance: Float) -> CellReading {
            let quality = min(1, min((maximumDistance - distance) / maximumDistance, margin / 0.05))
            return CellReading(text: String(UnicodeScalar(65 + letterIndex)!),
                               confidence: 0.80 + 0.19 * max(0, quality))
        }
    }

    private static func match(_ pixels: [Float], against bank: [Prototype]) -> Match {
        var scores = [Float](repeating: .greatestFiniteMagnitude, count: 26)
        for prototype in bank {
            var sum: Float = 0
            vDSP_distancesq(pixels, 1, prototype.pixels, 1, &sum, vDSP_Length(side * side))
            scores[prototype.letterIndex] = min(scores[prototype.letterIndex], sum / Float(side * side))
        }
        let ranked = scores.indices.sorted { scores[$0] < scores[$1] }
        return Match(letterIndex: ranked[0], distance: scores[ranked[0]],
                     margin: scores[ranked[1]] - scores[ranked[0]])
    }

    static func recognize(_ image: CGImage) throws -> Result {
        guard !prototypes.isEmpty else {
            throw WordHuntError.detection("The bundled GamePigeon glyph bank is missing or damaged. Reinstall the app.")
        }
        let raster = try PixelRaster(image: image, maximumDimension: 128)
        guard let glyph = segment(raster) else { return .blank }
        // QU and other clearly separated multi-letter shapes must not be reduced
        // to their largest component (in particular QU must never become Q).
        guard !glyph.multiletter else { return .unfamiliar }
        let reference = match(glyph.pixels, against: prototypes)
        // These limits reject every observed cross-label confusion in the pinned
        // held-out reference split. They are shape distances, not softmax claims.
        if reference.distance <= 0.07, reference.margin >= 0.018 {
            return .recognized(reference.reading(maximumDistance: 0.07))
        }
        // An unfamiliar native font must independently fit a much stricter
        // shape limit, have a clear distinct-letter margin, and materially
        // outperform the reference bank. Merely being ambiguous is not enough.
        let native = match(glyph.pixels, against: nativeFontPrototypes)
        if native.distance <= 0.025, native.margin >= 0.03,
           native.distance <= reference.distance * 0.5 {
            return .recognized(native.reading(maximumDistance: 0.025))
        }
        return reference.distance <= 0.07 ? .ambiguous : .unfamiliar
    }

    private struct Glyph {
        let pixels: [Float]
        let multiletter: Bool
    }

    private struct Component {
        let points: [Int]
        let minX: Int
        let minY: Int
        let maxX: Int
        let maxY: Int
    }

    private static func segment(_ raster: PixelRaster) -> Glyph? {
        let pad = max(1, Int((Double(min(raster.width, raster.height)) * 0.10).rounded()))
        let width = raster.width - pad * 2, height = raster.height - pad * 2
        guard width >= 8, height >= 8 else { return nil }
        var gray = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                let p = ((y + pad) * raster.width + x + pad) * 4
                gray[y * width + x] = UInt8((Int(raster.bytes[p]) * 299
                    + Int(raster.bytes[p + 1]) * 587 + Int(raster.bytes[p + 2]) * 114) / 1000)
            }
        }
        var ordered = gray.sorted()
        if ordered[ordered.count / 2] < 90 {
            for index in gray.indices { gray[index] = 255 - gray[index] }
            ordered = gray.sorted()
        }
        let low = Int(ordered[Int(Double(ordered.count - 1) * 0.02)])
        let high = Int(ordered[Int(Double(ordered.count - 1) * 0.80)])
        guard high - low >= 45 else { return nil }
        let threshold = Double(low) + Double(high - low) * 0.48
        var mask = gray.map { Double($0) < threshold }
        var components: [Component] = []
        var queue: [Int] = []
        for start in mask.indices where mask[start] {
            queue.removeAll(keepingCapacity: true)
            queue.append(start)
            mask[start] = false
            var cursor = 0
            var minX = start % width, maxX = minX, minY = start / width, maxY = minY
            while cursor < queue.count {
                let index = queue[cursor]
                cursor += 1
                let x = index % width, y = index / width
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
                for dy in -1...1 {
                    for dx in -1...1 {
                        let nx = x + dx, ny = y + dy
                        guard nx >= 0, nx < width, ny >= 0, ny < height else { continue }
                        let next = ny * width + nx
                        if mask[next] { mask[next] = false; queue.append(next) }
                    }
                }
            }
            // Tile borders, bevels and the outside green surround touch the ROI
            // edge. Only a complete interior glyph is eligible for matching.
            guard minX > 0, minY > 0, maxX < width - 1, maxY < height - 1,
                  Double(maxY - minY + 1) >= Double(height) * 0.23,
                  queue.count >= 4 else { continue }
            components.append(Component(points: queue, minX: minX, minY: minY, maxX: maxX, maxY: maxY))
        }
        guard let largest = components.indices.max(by: { components[$0].points.count < components[$1].points.count }) else { return nil }
        let component = components[largest]
        let minX = component.minX, minY = component.minY
        let glyphWidth = component.maxX - minX + 1, glyphHeight = component.maxY - minY + 1
        let multiletter = components.indices.contains { index in
            let other = components[index]
            return index != largest && other.points.count >= component.points.count / 3
                && (other.maxX < minX || other.minX > component.maxX)
                && other.maxY >= minY && other.minY <= component.maxY
                && other.maxY - other.minY + 1 >= glyphHeight / 2
        }
        var source = [Float](repeating: 0, count: glyphWidth * glyphHeight)
        for point in component.points { source[(point / width - minY) * glyphWidth + point % width - minX] = 1 }
        let scale = 28.0 / Double(max(glyphWidth, glyphHeight))
        let targetWidth = max(1, Int((Double(glyphWidth) * scale).rounded()))
        let targetHeight = max(1, Int((Double(glyphHeight) * scale).rounded()))
        var pixels = [Float](repeating: 0, count: side * side)
        // Deterministic bilinear sampling, shared with the resource generator.
        for y in 0..<targetHeight {
            let sy = max(0, min(Double(glyphHeight - 1), (Double(y) + 0.5) * Double(glyphHeight) / Double(targetHeight) - 0.5))
            let y0 = Int(sy), y1 = min(glyphHeight - 1, y0 + 1), fy = Float(sy - Double(y0))
            for x in 0..<targetWidth {
                let sx = max(0, min(Double(glyphWidth - 1), (Double(x) + 0.5) * Double(glyphWidth) / Double(targetWidth) - 0.5))
                let x0 = Int(sx), x1 = min(glyphWidth - 1, x0 + 1), fx = Float(sx - Double(x0))
                let a = source[y0 * glyphWidth + x0] * (1 - fx) + source[y0 * glyphWidth + x1] * fx
                let b = source[y1 * glyphWidth + x0] * (1 - fx) + source[y1 * glyphWidth + x1] * fx
                pixels[(y + (side - targetHeight) / 2) * side + x + (side - targetWidth) / 2] = a * (1 - fy) + b * fy
            }
        }
        return Glyph(pixels: pixels, multiletter: multiletter)
    }
}
