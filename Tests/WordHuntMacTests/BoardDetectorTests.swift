import AppKit
import CoreText
import Testing
import WordHuntCore
@testable import WordHuntMac

struct BoardDetectorTests {
    @Test func automaticFourByFourGeometryAndOCR() throws {
        let letters = ["A", "B", "C", "D", "E", "F", "G", "H", "K", "L", "M", "N", "P", "R", "S", "T"]
        let fixture = try makeFixture(size: 4, letters: letters)
        let detection = try BoardDetector().detect(image: fixture.image)
        assertGeometry(detection.geometry, equals: fixture.bounds, accuracy: 2)
        // Exercises the native shape recognizer and unfamiliar-font Vision path,
        // without injected OCR observations.
        let correct = zip(detection.cells, letters).filter { $0.0.text == $0.1 }.count
        #expect(correct >= 14, "OCR readings: \(detection.cells.map(\.text))")
        #expect(detection.cells[0].text == "A")
        #expect(detection.cells[10].text == "M")
    }

    @Test func automaticFiveByFiveAtDifferentScale() throws {
        let fixture = try makeFixture(size: 5, letters: Array(repeating: "A", count: 25), pitch: 54)
        let detection = try BoardDetector().detect(image: fixture.image, size: 5)
        assertGeometry(detection.geometry, equals: fixture.bounds, accuracy: 2)
        #expect(detection.cells.map(\.text) == Array(repeating: "A", count: 25))
        #expect(detection.board != nil)
    }

    @Test func isolatedNarrowRoundAndMultiletterGlyphs() throws {
        let letters = ["I", "O", "Q", "QU", "J", "K", "L", "T", "U", "V", "W", "X", "Y", "Z", "C", "P"]
        let fixture = try makeFixture(size: 4, letters: letters)
        let detection = try BoardDetector().detect(image: fixture.image)
        #expect(detection.cells.map(\.text) == letters)
        #expect(detection.board?.tiles == letters)
    }

    @Test func nativeMacFontEvidenceHandlesRoundAndHeavyGlyphsWithoutVision() throws {
        for fontName in ["Helvetica-Bold", NSFont.systemFont(ofSize: 44, weight: .heavy).fontName] {
            let letters = ["M", "O", "C"] + Array(repeating: "A", count: 13)
            let fixture = try makeFixture(size: 4, letters: letters, fontName: fontName)
            for index in 0..<3 {
                let rect = CGRect(x: fixture.bounds.minX + CGFloat(index) * 76,
                                  y: fixture.bounds.minY, width: 76, height: 76)
                let crop = try #require(fixture.image.cropping(to: rect))
                let result = try GameGlyphRecognizer.recognize(crop)
                guard case .recognized(let reading) = result else {
                    Issue.record("Missing native shape evidence for \(fontName) \(letters[index])")
                    continue
                }
                #expect(reading.text == letters[index])
                #expect(reading.confidence >= 0.80)
            }
        }
    }

    @Test func manualPixelBoundsAndQUTile() throws {
        var letters = Array(repeating: "A", count: 16)
        letters[0] = "QU"
        // Neutral background intentionally precludes automatic green-gutter detection.
        let fixture = try makeFixture(size: 4, letters: letters, pitch: 94, green: false)
        #expect(throws: WordHuntError.self) { try BoardDetector().detect(image: fixture.image) }
        let detection = try BoardDetector().detect(image: fixture.image, bounds: fixture.bounds)
        assertGeometry(detection.geometry, equals: fixture.bounds, accuracy: 0.01)
        #expect(detection.cells[0].text == "QU")
        #expect(detection.board?.tiles[0] == "QU")
    }

    @Test func blankTileIsUnknownAndBoardIsUnavailable() throws {
        var letters = Array(repeating: "A", count: 16)
        letters[7] = ""
        let fixture = try makeFixture(size: 4, letters: letters)
        let detection = try BoardDetector().detect(image: fixture.image)
        #expect(detection.cells[7].text == "?")
        #expect(detection.cells[7].confidence == 0)
        #expect(detection.board == nil)
    }

    @Test func noBoardDoesNotFallBackToImageCenter() throws {
        let image = try makeSolidImage(width: 720, height: 1000, color: NSColor(calibratedRed: 0.13, green: 0.42, blue: 0.20, alpha: 1))
        #expect(throws: WordHuntError.self) { try BoardDetector().detect(image: image) }
    }

    @Test func irregularTileArrangementIsRejected() throws {
        let fixture = try makeFixture(size: 4, letters: Array(repeating: "A", count: 16), displacedTile: 6)
        #expect(throws: WordHuntError.self) { try BoardDetector().detect(image: fixture.image) }
    }

    @Test func ambiguousTwoBoardsAreRejected() throws {
        let fixture = try makeFixture(size: 4, letters: Array(repeating: "A", count: 16), pitch: 54)
        let width = fixture.image.width * 2 + 40
        let context = try makeContext(width: width, height: fixture.image.height)
        context.setFillColor(CGColor(red: 0.13, green: 0.42, blue: 0.20, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: fixture.image.height))
        context.draw(fixture.image, in: CGRect(x: 0, y: 0, width: fixture.image.width, height: fixture.image.height))
        context.draw(fixture.image, in: CGRect(x: fixture.image.width + 40, y: 0,
                                              width: fixture.image.width, height: fixture.image.height))
        let image = try #require(context.makeImage())
        #expect(throws: WordHuntError.self) { try BoardDetector().detect(image: image) }
        let selected = try BoardDetector().detect(image: image, bounds: fixture.bounds)
        #expect(selected.cells.map(\.text) == Array(repeating: "A", count: 16))
    }

    @Test func invalidSizeAndManualBoundsAreRejected() throws {
        let fixture = try makeFixture(size: 4, letters: Array(repeating: "A", count: 16))
        let detector = BoardDetector()
        #expect(throws: WordHuntError.self) { try detector.detect(image: fixture.image, size: 3) }
        for bounds in [CGRect(x: -1, y: 0, width: 300, height: 300),
                       CGRect(x: 0, y: 0, width: 10000, height: 300),
                       CGRect(x: 0, y: 0, width: 1, height: 1),
                       CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 300)] {
            #expect(throws: WordHuntError.self) { try detector.detect(image: fixture.image, bounds: bounds) }
        }
    }

    private func assertGeometry(_ geometry: GridGeometry, equals rect: CGRect, accuracy: Double) {
        #expect(abs(geometry.x - Double(rect.minX)) <= accuracy)
        #expect(abs(geometry.y - Double(rect.minY)) <= accuracy)
        #expect(abs(geometry.width - Double(rect.width)) <= accuracy)
        #expect(abs(geometry.height - Double(rect.height)) <= accuracy)
    }

    private struct Fixture {
        let image: CGImage
        let bounds: CGRect
    }

    private func makeFixture(size: Int, letters: [String], pitch: CGFloat = 76,
                             green: Bool = true, displacedTile: Int? = nil,
                             fontName: String = "Helvetica-Bold") throws -> Fixture {
        let bounds = CGRect(x: 57, y: 139, width: CGFloat(size) * pitch, height: CGFloat(size) * pitch)
        let width = Int(bounds.maxX + 83), height = Int(bounds.maxY + 117)
        let context = try makeContext(width: width, height: height)
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        context.setFillColor(green
            ? CGColor(red: 0.13, green: 0.42, blue: 0.20, alpha: 1)
            : CGColor(gray: 0.4, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        for index in 0..<(size * size) {
            let row = index / size, column = index % size
            var tile = CGRect(x: bounds.minX + CGFloat(column) * pitch + 4,
                              y: bounds.minY + CGFloat(row) * pitch + 4,
                              width: pitch - 8, height: pitch - 8)
            if index == displacedTile { tile.origin.x += pitch * 0.3 }
            context.setFillColor(CGColor(red: 0.91, green: 0.77, blue: 0.54, alpha: 1))
            context.addPath(CGPath(roundedRect: tile, cornerWidth: 6, cornerHeight: 6, transform: nil))
            context.fillPath()
            let text = letters[index]
            guard !text.isEmpty else { continue }
            let fontSize = pitch * (text == "QU" ? 0.43 : 0.57)
            let font = CTFontCreateWithName(fontName as CFString, fontSize, nil)
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0.02, alpha: 1)
            ]))
            let textBounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
            // The context uses top-left fixture coordinates; compensate the
            // CoreText text matrix so the glyphs remain upright.
            context.saveGState()
            context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
            context.textPosition = CGPoint(x: tile.midX - textBounds.midX,
                                           y: tile.midY + textBounds.midY)
            CTLineDraw(line, context)
            context.restoreGState()
        }
        return Fixture(image: try #require(context.makeImage()), bounds: bounds)
    }

    private func makeSolidImage(width: Int, height: Int, color: NSColor) throws -> CGImage {
        let context = try makeContext(width: width, height: height)
        context.setFillColor(color.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try #require(context.makeImage())
    }

    private func makeContext(width: Int, height: Int) throws -> CGContext {
        try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                              bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
    }
}
