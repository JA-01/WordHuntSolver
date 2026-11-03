import AppKit
import ImageIO
import Testing
import WordHuntCore
@testable import WordHuntMac

struct GamePigeonRecognitionTests {
    private let liveLetters = ["T", "V", "R", "H", "T", "S", "P", "E", "W", "A", "G", "C", "O", "H", "O", "L"]
    // Measured in the privacy-cropped original, not display points. The outer
    // half-gutters give the same tile centers as the photographed board.
    private let liveBounds = CGRect(x: 33, y: 50, width: 450, height: 450)

    @Test func actualGamePigeonCaptureHasExactRowMajorLettersAndPixelGeometry() throws {
        let image = try fixtureImage("GamePigeon-Live-4x4.png")
        let detection = try BoardDetector().detect(image: image)
        #expect(detection.cells.map(\.text) == liveLetters)
        #expect(detection.cells.allSatisfy { $0.confidence >= 0.80 })
        #expect(detection.board?.tiles == liveLetters)
        assertGeometry(detection.geometry, bounds: liveBounds, tolerance: 3)
    }

    @Test func realCaptureAtMirroringScalesPreservesPixelsAndLetters() throws {
        let original = try fixtureImage("GamePigeon-Live-4x4.png")
        for scale in [0.5, 0.75, 1.5] {
            let width = Int(Double(original.width) * scale), height = Int(Double(original.height) * scale)
            let context = try #require(CGContext(data: nil, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.interpolationQuality = .high
            context.draw(original, in: CGRect(x: 0, y: 0, width: width, height: height))
            let image = try #require(context.makeImage())
            let detection = try BoardDetector().detect(image: image)
            #expect(detection.cells.map(\.text) == liveLetters, "Scale \(scale): \(detection.cells.map(\.text))")
            #expect(detection.cells.allSatisfy { $0.confidence >= 0.80 })
            assertGeometry(detection.geometry,
                           bounds: CGRect(x: liveBounds.minX * scale, y: liveBounds.minY * scale,
                                          width: liveBounds.width * scale, height: liveBounds.height * scale),
                           tolerance: 3)
        }
    }


    @Test func fiveByFiveLayoutUsingActualCapturedGlyphs() throws {
        // Layout is assembled from real captured tiles, not a claimed 5x5 phone
        // capture. This isolates size handling without changing the glyph font.
        let image = try fixtureImage("GamePigeon-Glyphs-5x5.png")
        let detection = try BoardDetector().detect(image: image, size: 5)
        let expected = (0..<25).map { liveLetters[$0 % liveLetters.count] }
        #expect(detection.cells.map(\.text) == expected)
        #expect(detection.board?.size == 5)
        assertGeometry(detection.geometry, bounds: CGRect(x: 45, y: 95, width: 500, height: 500), tolerance: 3)
    }
    @Test func actualTutorialIllustrationIsNotAPlayableBoard() throws {
        let image = try fixtureImage("GamePigeon-Tutorial.png")
        #expect(throws: WordHuntError.self) { try BoardDetector().detect(image: image) }
    }

    @Test func heldOutRealReferenceGlyphsIncludeEveryLetterAndRejectConfusions() throws {
        let manifest = try fixtureURL("ReferenceGlyphs.json")
        let examples = try JSONDecoder().decode([ReferenceGlyph].self, from: Data(contentsOf: manifest))
        for example in examples {
            let image = try fixtureImage(example.file)
            let result = try GameGlyphRecognizer.recognize(image)
            if case .recognized(let reading) = result {
                #expect(example.accepted, "Ambiguous source \(example.file) must not silently choose a letter")
                #expect(reading.text == example.letter, "Original source \(example.file)")
                #expect(reading.confidence >= 0.80)
            } else {
                #expect(!example.accepted, "Readable source \(example.file) should be recognized")
            }
        }
    }

    @Test func realQGlyphIsLiteralQNotAnImplicitQU() throws {
        let examples = try JSONDecoder().decode([ReferenceGlyph].self,
            from: Data(contentsOf: fixtureURL("ReferenceGlyphs.json")))
        let example = try #require(examples.first { $0.letter == "Q" && $0.accepted })
        let result = try GameGlyphRecognizer.recognize(fixtureImage(example.file))
        guard case .recognized(let reading) = result else {
            Issue.record("Expected a complete real Q glyph")
            return
        }
        #expect(reading.text == "Q")
    }

    private struct ReferenceGlyph: Decodable {
        let file: String
        let letter: String
        let accepted: Bool
    }

    private func fixtureURL(_ name: String) throws -> URL {
        try #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"))
    }

    private func fixtureImage(_ name: String) throws -> CGImage {
        let url = try fixtureURL(name)
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        return try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }

    private func assertGeometry(_ geometry: GridGeometry, bounds: CGRect, tolerance: Double) {
        #expect(abs(geometry.x - Double(bounds.minX)) <= tolerance)
        #expect(abs(geometry.y - Double(bounds.minY)) <= tolerance)
        #expect(abs(geometry.width - Double(bounds.width)) <= tolerance)
        #expect(abs(geometry.height - Double(bounds.height)) <= tolerance)
    }
}
