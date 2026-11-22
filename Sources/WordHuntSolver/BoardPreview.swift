import AppKit
import SwiftUI
import WordHuntCore

struct BoardPreview: NSViewRepresentable {
    let image: CGImage?
    let geometry: GridGeometry?
    let path: [Int]

    func makeNSView(context: Context) -> PreviewCanvas { PreviewCanvas() }
    func updateNSView(_ view: PreviewCanvas, context: Context) {
        view.image = image
        view.geometry = geometry
        view.path = path
        view.needsDisplay = true
    }
}

final class PreviewCanvas: NSView {
    var image: CGImage?
    var geometry: GridGeometry?
    var path: [Int] = []
    override var isFlipped: Bool { true }

    private var imageRect: CGRect {
        guard let image else { return .zero }
        let scale = min(bounds.width / Double(image.width), bounds.height / Double(image.height))
        let size = CGSize(width: Double(image.width) * scale, height: Double(image.height) * scale)
        return CGRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2, width: size.width, height: size.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let image else { return }
        let frame = imageRect
        NSImage(cgImage: image, size: CGSize(width: image.width, height: image.height)).draw(in: frame, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        let scale = frame.width / Double(image.width)
        func point(_ p: CGPoint) -> CGPoint { CGPoint(x: frame.minX + p.x * scale, y: frame.minY + p.y * scale) }
        if let geometry {
            NSColor.systemMint.setStroke()
            let outline = NSBezierPath(rect: CGRect(x: frame.minX + geometry.x * scale, y: frame.minY + geometry.y * scale, width: geometry.width * scale, height: geometry.height * scale))
            outline.lineWidth = 2
            outline.stroke()
            for index in 0..<(geometry.size * geometry.size) {
                let p = point(geometry.center(of: index))
                NSColor.systemMint.withAlphaComponent(0.8).setFill()
                NSBezierPath(ovalIn: CGRect(x: p.x - 3, y: p.y - 3, width: 6, height: 6)).fill()
            }
            if let first = path.first {
                let line = NSBezierPath()
                line.move(to: point(geometry.center(of: first)))
                path.dropFirst().forEach { line.line(to: point(geometry.center(of: $0))) }
                line.lineWidth = 5
                NSColor.systemOrange.setStroke()
                line.stroke()
            }
        }
    }
}
