import AppKit
import Vision
import WordHuntCore

public struct CellReading {
    public let text: String
    public let confidence: Float

    public init(text: String, confidence: Float) {
        self.text = text
        self.confidence = confidence
    }
}

public struct BoardDetection {
    public let size: Int
    public let cells: [CellReading]
    public let geometry: GridGeometry
    public var board: Board? { try? Board(size: size, tiles: cells.map(\.text)) }
}

/// Recognizes an axis-aligned, regular wooden-tile board. All geometry is in
/// source-image pixels measured from its top-left, never display points.
public final class BoardDetector {
    public init() {}

    public func detect(image: CGImage, size: Int = 4, bounds: CGRect? = nil) throws -> BoardDetection {
        guard size == 4 || size == 5 else {
            throw WordHuntError.detection("Board size must be 4 or 5.")
        }
        let rect: CGRect
        if let bounds {
            let values = [bounds.origin.x, bounds.origin.y, bounds.width, bounds.height]
            guard values.allSatisfy(\.isFinite), bounds.width >= CGFloat(size * 12),
                  bounds.height >= CGFloat(size * 12), bounds.minX >= 0, bounds.minY >= 0,
                  bounds.maxX <= CGFloat(image.width), bounds.maxY <= CGFloat(image.height) else {
                throw WordHuntError.detection("Calibrated bounds must lie inside the captured image and contain readable tiles.")
            }
            rect = bounds
        } else {
            rect = try locateGrid(image: image, size: size)
        }
        let geometry = GridGeometry(size: size, x: rect.minX, y: rect.minY,
                                    width: rect.width, height: rect.height)
        var cells: [CellReading] = []
        cells.reserveCapacity(size * size)
        for row in 0..<size {
            for column in 0..<size {
                let cell = CGRect(x: rect.minX + CGFloat(column) * rect.width / CGFloat(size),
                                  y: rect.minY + CGFloat(row) * rect.height / CGFloat(size),
                                  width: rect.width / CGFloat(size), height: rect.height / CGFloat(size))
                // The native segmenter removes the gutter itself. Cropping too
                // tightly here clips wide W/M glyphs on real GamePigeon tiles.
                guard let crop = image.cropping(to: cell.integral) else {
                    cells.append(CellReading(text: "?", confidence: 0))
                    continue
                }
                cells.append(try recognize(crop))
            }
        }
        return BoardDetection(size: size, cells: cells, geometry: geometry)
    }

    private struct Tile {
        let rect: CGRect
        var center: CGPoint { CGPoint(x: rect.midX, y: rect.midY) }
    }

    private func locateGrid(image: CGImage, size: Int) throws -> CGRect {
        // A whole-desktop Retina capture can contain a phone only a few hundred
        // pixels wide. Keep enough resolution to retain its separate tile bodies.
        let raster = try PixelRaster(image: image, maximumDimension: 1600)
        let width = raster.width, height = raster.height
        var mask = [UInt8](repeating: 0, count: width * height)
        for index in mask.indices {
            let p = index * 4
            let r = Int(raster.bytes[p]), g = Int(raster.bytes[p + 1]), b = Int(raster.bytes[p + 2])
            // Warm light wood, including highlights and medium tan shadows.
            if r > 105 && g > 75 && b > 30 && r * 100 > b * 116 && g * 100 > b * 106
                && r * 100 >= g * 96 && r - g < 100 {
                mask[index] = 1
            }
        }
        var tiles: [Tile] = []
        var queue: [Int] = []
        for start in mask.indices where mask[start] == 1 {
            queue.removeAll(keepingCapacity: true)
            queue.append(start)
            mask[start] = 0
            var cursor = 0
            var minX = start % width, maxX = minX, minY = start / width, maxY = minY
            while cursor < queue.count {
                let index = queue[cursor]
                cursor += 1
                let x = index % width, y = index / width
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
                if x > 0, mask[index - 1] == 1 { mask[index - 1] = 0; queue.append(index - 1) }
                if x + 1 < width, mask[index + 1] == 1 { mask[index + 1] = 0; queue.append(index + 1) }
                if y > 0, mask[index - width] == 1 { mask[index - width] = 0; queue.append(index - width) }
                if y + 1 < height, mask[index + width] == 1 { mask[index + width] = 0; queue.append(index + width) }
            }
            let w = maxX - minX + 1, h = maxY - minY + 1
            guard w >= 12, h >= 12, Double(w) / Double(h) > 0.75,
                  Double(w) / Double(h) < 1.33, queue.count * 100 > w * h * 48 else { continue }
            tiles.append(Tile(rect: CGRect(x: minX, y: minY, width: w, height: h)))
        }
        guard tiles.count >= size * size else {
            throw WordHuntError.detection("No regular tan-tile board found. Show the entire game board and check the selected grid size.")
        }
        var candidates: [CGRect] = []
        var sawInstructions = false
        for first in tiles {
            for next in tiles {
                let pitchX = next.center.x - first.center.x
                guard pitchX > first.rect.width * 1.02, pitchX < first.rect.width * 1.65,
                      abs(next.center.y - first.center.y) < first.rect.height * 0.12 else { continue }
                // Infer vertical pitch independently to tolerate capture scaling.
                for below in tiles {
                    let pitchY = below.center.y - first.center.y
                    guard pitchY > first.rect.height * 1.02, pitchY < first.rect.height * 1.65,
                          abs(below.center.x - first.center.x) < first.rect.width * 0.12 else { continue }
                    var matched = Set<Int>()
                    for row in 0..<size {
                        for column in 0..<size {
                            let x = first.center.x + CGFloat(column) * pitchX
                            let y = first.center.y + CGFloat(row) * pitchY
                            if let index = tiles.indices.first(where: {
                                let tile = tiles[$0]
                                return abs(tile.center.x - x) < pitchX * 0.10
                                    && abs(tile.center.y - y) < pitchY * 0.10
                                    && abs(tile.rect.width - first.rect.width) < first.rect.width * 0.18
                                    && abs(tile.rect.height - first.rect.height) < first.rect.height * 0.18
                            }) { matched.insert(index) }
                        }
                    }
                    guard matched.count == size * size else { continue }
                    let rect = CGRect(x: first.center.x - pitchX / 2, y: first.center.y - pitchY / 2,
                                      width: CGFloat(size) * pitchX, height: CGFloat(size) * pitchY)
                    guard rect.minX >= 0, rect.minY >= 0, rect.maxX <= CGFloat(width), rect.maxY <= CGFloat(height),
                          greenGutters(rect: rect, size: size, raster: raster) else { continue }
                    if onInstructionCard(rect: rect, raster: raster) { sawInstructions = true; continue }
                    if !candidates.contains(where: { abs($0.midX - rect.midX) < pitchX * 0.2 && abs($0.midY - rect.midY) < pitchY * 0.2 }) {
                        candidates.append(rect)
                    }
                }
            }
        }
        guard candidates.count == 1, let candidate = candidates.first else {
            if candidates.isEmpty && sawInstructions {
                throw WordHuntError.detection("The How to play screen is showing, not a round. Press Start on the phone.")
            }
            throw WordHuntError.detection(candidates.isEmpty
                ? "No regular board with green gutters found. Show the entire game board without overlays."
                : "Multiple boards found. Capture an image containing only the intended board.")
        }
        return CGRect(x: candidate.minX * raster.scaleX, y: candidate.minY * raster.scaleY,
                      width: candidate.width * raster.scaleX, height: candidate.height * raster.scaleY)
    }

    private func greenGutters(rect: CGRect, size: Int, raster: PixelRaster) -> Bool {
        var green = 0, count = 0
        for boundary in 1..<size {
            for cell in 0..<size {
                let points = [CGPoint(x: rect.minX + CGFloat(boundary) * rect.width / CGFloat(size),
                                      y: rect.minY + (CGFloat(cell) + 0.5) * rect.height / CGFloat(size)),
                              CGPoint(x: rect.minX + (CGFloat(cell) + 0.5) * rect.width / CGFloat(size),
                                      y: rect.minY + CGFloat(boundary) * rect.height / CGFloat(size))]
                for point in points {
                    let x = min(raster.width - 1, max(0, Int(point.x)))
                    let y = min(raster.height - 1, max(0, Int(point.y)))
                    let p = (y * raster.width + x) * 4
                    let r = Int(raster.bytes[p]), g = Int(raster.bytes[p + 1]), b = Int(raster.bytes[p + 2])
                    if g * 100 > r * 112 && g * 100 > b * 110 { green += 1 }
                    count += 1
                }
            }
        }
        return green * 100 >= count * 65
    }

    /// GamePigeon's "How to play" modal shows an illustrative board on a white
    /// panel. Its tile colors reject it only while the tutorial path is
    /// highlighted. A live round's board sits on the green game background.
    private func onInstructionCard(rect: CGRect, raster: PixelRaster) -> Bool {
        var white = 0, count = 0
        for x in [rect.minX - rect.width * 0.18, rect.maxX + rect.width * 0.18] {
            let column = Int(x)
            guard column >= 0, column < raster.width else { continue }
            for step in 0..<9 {
                let row = Int(rect.minY + rect.height * (CGFloat(step) + 0.5) / 9)
                guard row >= 0, row < raster.height else { continue }
                let p = (row * raster.width + column) * 4
                let r = Int(raster.bytes[p]), g = Int(raster.bytes[p + 1]), b = Int(raster.bytes[p + 2])
                if min(r, g, b) > 215 && max(r, g, b) - min(r, g, b) < 30 { white += 1 }
                count += 1
            }
        }
        return count >= 9 && white * 100 >= count * 70
    }

    private func recognize(_ image: CGImage) throws -> CellReading {
        switch try GameGlyphRecognizer.recognize(image) {
        case .recognized(let reading): return reading
        case .ambiguous, .blank: return CellReading(text: "?", confidence: 0)
        case .unfamiliar: break
        }
        // Only unfamiliar fonts or genuine multi-letter tiles need Vision.
        // Do not let its language-biased alternatives override a close native
        // shape match: ambiguity must remain visible to the caller.
        let inner = image.cropping(to: CGRect(x: 0, y: 0, width: image.width, height: image.height)
            .insetBy(dx: CGFloat(image.width) * 0.12, dy: CGFloat(image.height) * 0.12).integral) ?? image
        var best = CellReading(text: "?", confidence: 0)
        var preparedImages = [CGImage?](repeating: nil, count: 4)
        for attempt in 0..<8 {
            let variant = attempt / 2
            let repeated = variant >= 2
            let prepared: CGImage
            if let cached = preparedImages[variant] {
                prepared = cached
            } else {
                if repeated {
                    prepared = try repeatedGlyph(preparedImages[variant - 2]!)
                } else {
                    prepared = try preparedGlyph(inner, threshold: variant == 1)
                }
                preparedImages[variant] = prepared
            }
            let request = VNRecognizeTextRequest()
            // Retain both Vision character/text-line models for unfamiliar
            // fonts; familiar GamePigeon glyphs never reach this fallback.
            request.recognitionLevel = attempt % 2 == 0 ? .accurate : .fast
            request.usesLanguageCorrection = false
            request.recognitionLanguages = ["en-US"]
            request.minimumTextHeight = 0.08
            request.customWords = ["QU"]
            try VNImageRequestHandler(cgImage: prepared, options: [:]).perform([request])
            for observation in request.results ?? [] {
                for candidate in observation.topCandidates(5) {
                    let recognized = candidate.string.uppercased().filter { !$0.isWhitespace }
                    let text: String
                    if repeated {
                        if observation.boundingBox.width <= 0.38 && (recognized.count == 1 || recognized == "QU") {
                            text = recognized
                        } else if recognized == "QUQUQU" {
                            text = "QU"
                        } else if recognized.count == 3, let first = recognized.first,
                                  recognized.allSatisfy({ $0 == first }) {
                            text = String(first)
                        } else { continue }
                    } else {
                        text = recognized
                    }
                    guard text == "QU" || (text.utf8.count == 1 && text.utf8.first! >= 65 && text.utf8.first! <= 90),
                          candidate.confidence >= 0.80 else { continue }
                    if candidate.confidence > best.confidence {
                        best = CellReading(text: text, confidence: candidate.confidence)
                    }
                }
            }
            if best.confidence >= 0.9 { break }
        }
        return best
    }

    /// A short line of identical glyphs gives Vision the text-line context its
    /// recognizer needs for otherwise ambiguous isolated capitals. Accept a
    /// localized glyph observation or unanimous repeated text, not a completion.
    private func repeatedGlyph(_ glyph: CGImage) throws -> CGImage {
        guard let context = CGContext(data: nil, width: glyph.width * 3, height: glyph.height,
                                      bitsPerComponent: 8, bytesPerRow: glyph.width * 3,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0) else {
            throw WordHuntError.detection("Could not allocate an OCR text line.")
        }
        for column in 0..<3 {
            context.draw(glyph, in: CGRect(x: column * glyph.width, y: 0, width: glyph.width, height: glyph.height))
        }
        guard let image = context.makeImage() else { throw WordHuntError.detection("Could not prepare an OCR text line.") }
        return image
    }

    private func preparedGlyph(_ image: CGImage, threshold: Bool) throws -> CGImage {
        // Upscale tiny screen glyphs and add a neutral margin. Binarization removes
        // wood grain without changing a literal Q into a QU tile.
        let side = 320
        guard let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8,
                                      bytesPerRow: side, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0) else {
            throw WordHuntError.detection("Could not allocate an OCR image.")
        }
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        context.interpolationQuality = .high
        let scale = 256 / CGFloat(max(image.width, image.height))
        let w = CGFloat(image.width) * scale, h = CGFloat(image.height) * scale
        context.draw(image, in: CGRect(x: (320 - w) / 2, y: (320 - h) / 2, width: w, height: h))
        if threshold, let data = context.data?.assumingMemoryBound(to: UInt8.self) {
            for index in 0..<(side * side) { data[index] = data[index] < 125 ? 0 : 255 }
        }
        guard let result = context.makeImage() else { throw WordHuntError.detection("Could not prepare an OCR image.") }
        return result
    }
}

struct PixelRaster {
    let width: Int
    let height: Int
    let scaleX: CGFloat
    let scaleY: CGFloat
    let bytes: [UInt8]

    init(image: CGImage, maximumDimension: Int) throws {
        let factor = min(1, Double(maximumDimension) / Double(max(image.width, image.height)))
        width = max(1, Int(Double(image.width) * factor))
        height = max(1, Int(Double(image.height) * factor))
        scaleX = CGFloat(image.width) / CGFloat(width)
        scaleY = CGFloat(image.height) / CGFloat(height)
        var storage = [UInt8](repeating: 0, count: width * height * 4)
        let w = width, h = height
        let success = storage.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: w, height: h,
                                          bitsPerComponent: 8, bytesPerRow: w * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard success else { throw WordHuntError.detection("Could not read captured image pixels.") }
        bytes = storage
    }
}
