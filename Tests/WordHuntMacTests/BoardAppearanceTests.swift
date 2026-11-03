import CoreGraphics
import Testing
import WordHuntCore
@testable import WordHuntMac

struct BoardAppearanceTests {
    private let geometry = GridGeometry(size: 4, x: 20, y: 60, width: 240, height: 240)

    @Test func ignoresTimerAndTileColorButRejectsChangedGlyph() throws {
        let original = try image(changed: false, highlight: false)
        let timerAndHighlight = try image(changed: false, highlight: true)
        let otherBoard = try image(changed: true, highlight: false)
        #expect(try BoardAppearance.matches(original, timerAndHighlight, geometry: geometry))
        #expect(try !BoardAppearance.matches(original, otherBoard, geometry: geometry))
    }

    private func image(changed: Bool, highlight: Bool) throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: 280, height: 360, bitsPerComponent: 8,
                                            bytesPerRow: 280 * 4, space: CGColorSpaceCreateDeviceRGB(),
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.translateBy(x: 0, y: 360)
        context.scaleBy(x: 1, y: -1)
        context.setFillColor(CGColor(red: 0.12, green: 0.35, blue: 0.22, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 280, height: 360))
        for index in 0..<16 {
            let center = geometry.center(of: index)
            context.setFillColor(highlight ? CGColor(red: 1, green: 0.75, blue: 0.4, alpha: 1) : CGColor(red: 0.9, green: 0.8, blue: 0.6, alpha: 1))
            context.fill(CGRect(x: center.x - 26, y: center.y - 26, width: 52, height: 52))
            context.setFillColor(CGColor(gray: 0.05, alpha: 1))
            let width: CGFloat = changed && index == 0 ? 25 : 9
            context.fill(CGRect(x: center.x - width / 2, y: center.y - 16, width: width, height: 32))
        }
        if highlight {
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 10, y: 8, width: 120, height: 20))
        }
        return try #require(context.makeImage())
    }
}
