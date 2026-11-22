import AppKit
import WordHuntCore

/// A real local game surface for recognition and mouse-gesture verification.
/// It does not claim to emulate GamePigeon's private dictionary or touch transport.
enum BoardArtwork {
    static let sample = try! Board(text: "S T A R\nE N O T\nL I N E\nC A R E", size: 4)
    static let canvas = CGSize(width: 520, height: 720)

    static func geometry(size: Int, canvas: CGSize = canvas) -> GridGeometry {
        let side = min(canvas.width - 64, canvas.height - 210)
        return GridGeometry(size: size, x: (canvas.width - side) / 2, y: 150, width: side, height: side)
    }

    static func draw(board: Board, rect: CGRect, selected: [Int] = [], score: Int = 0, lastWord: String = "Drag across neighboring letters") {
        NSColor(calibratedRed: 0.10, green: 0.28, blue: 0.21, alpha: 1).setFill()
        rect.fill()
        let title: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 27, weight: .bold), .foregroundColor: NSColor.white]
        ("Word Hunt" as NSString).draw(at: CGPoint(x: 32, y: 25), withAttributes: title)
        ("\(score.formatted()) points" as NSString).draw(at: CGPoint(x: 32, y: 70), withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 23, weight: .medium), .foregroundColor: NSColor.white])
        let grid = geometry(size: board.size, canvas: rect.size)
        let cell = grid.width / Double(board.size)
        for index in board.tiles.indices {
            let center = grid.center(of: index)
            let tile = CGRect(x: center.x - cell * 0.43, y: center.y - cell * 0.43, width: cell * 0.86, height: cell * 0.86)
            let active = selected.contains(index)
            (active ? NSColor(calibratedRed: 0.96, green: 0.75, blue: 0.29, alpha: 1) : NSColor(calibratedRed: 0.94, green: 0.83, blue: 0.63, alpha: 1)).setFill()
            NSBezierPath(roundedRect: tile, xRadius: 10, yRadius: 10).fill()
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: cell * (board.tiles[index] == "QU" ? 0.38 : 0.51), weight: .heavy), .foregroundColor: NSColor(calibratedWhite: 0.10, alpha: 1)]
            let text = board.tiles[index] as NSString
            let size = text.size(withAttributes: attributes)
            text.draw(at: CGPoint(x: center.x - size.width / 2, y: center.y - size.height / 2), withAttributes: attributes)
        }
        if selected.count > 1 {
            let line = NSBezierPath()
            line.move(to: grid.center(of: selected[0]))
            selected.dropFirst().forEach { line.line(to: grid.center(of: $0)) }
            line.lineWidth = 6
            NSColor.white.withAlphaComponent(0.45).setStroke()
            line.stroke()
        }
        (lastWord as NSString).draw(in: CGRect(x: 32, y: grid.y + grid.height + 23, width: rect.width - 64, height: 50), withAttributes: [.font: NSFont.systemFont(ofSize: 16, weight: .medium), .foregroundColor: NSColor.white])
    }

    static func image(board: Board = sample, canvas: CGSize = canvas) throws -> CGImage {
        let image = NSImage(size: canvas, flipped: true) { rect in
            draw(board: board, rect: rect)
            return true
        }
        guard let result = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw WordHuntError.detection("Could not render the practice board.")
        }
        return result
    }

    static func savePNG(_ image: CGImage, to url: URL) throws {
        let bitmap = NSBitmapImageRep(cgImage: image)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw WordHuntError.detection("Could not encode PNG.")
        }
        try data.write(to: url)
    }
}

final class PracticeBoardView: NSView {
    let board: Board
    private let valid: [String: Int]
    private(set) var accepted: Set<String> = []
    private(set) var score = 0
    private var path: [Int] = []
    private var lastWord = "Drag across neighboring letters"
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    init(board: Board, solver: WordSolver) {
        self.board = board
        valid = Dictionary(uniqueKeysWithValues: solver.solve(board).map { ($0.word, $0.score) })
        super.init(frame: CGRect(origin: .zero, size: BoardArtwork.canvas))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func draw(_ dirtyRect: NSRect) {
        BoardArtwork.draw(board: board, rect: bounds, selected: path, score: score, lastWord: lastWord)
    }

    override func mouseDown(with event: NSEvent) {
        path = []
        visit(event)
    }
    override func mouseDragged(with event: NSEvent) { visit(event) }
    override func mouseUp(with event: NSEvent) {
        let word = path.map { board.tiles[$0] }.joined()
        if let points = valid[word], accepted.insert(word).inserted {
            score += points
            lastWord = "\(word)  +\(points)"
        } else {
            lastWord = word.isEmpty ? "Drag across neighboring letters" : "\(word) — duplicate or not in ENABLE"
        }
        path = []
        needsDisplay = true
    }

    private func visit(_ event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let geometry = BoardArtwork.geometry(size: board.size, canvas: bounds.size)
        guard geometry.rect.contains(point) else { return }
        let column = Int((point.x - geometry.x) / geometry.width * Double(board.size))
        let row = Int((point.y - geometry.y) / geometry.height * Double(board.size))
        let index = row * board.size + column
        guard !path.contains(index) else { return }
        if let previous = path.last {
            guard abs(previous % board.size - column) <= 1, abs(previous / board.size - row) <= 1 else { return }
        }
        path.append(index)
        needsDisplay = true
    }

    /// Delivers native NSEvents through this surface's production mouse handlers.
    /// Used when Accessibility is unavailable; does not pretend to test system injection.
    func replayLocally(_ words: [FoundWord]) throws {
        guard let window else { throw WordHuntError.automation("Practice view must be attached to a window.") }
        let geometry = BoardArtwork.geometry(size: board.size, canvas: bounds.size)
        for word in words {
            for (offset, index) in word.path.enumerated() {
                let point = convert(geometry.center(of: index), to: nil)
                let type: NSEvent.EventType = offset == 0 ? .leftMouseDown : .leftMouseDragged
                guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else { throw WordHuntError.automation("Could not create practice mouse event.") }
                if offset == 0 { mouseDown(with: event) } else { mouseDragged(with: event) }
            }
            let point = convert(geometry.center(of: word.path.last!), to: nil)
            let event = NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 0)!
            mouseUp(with: event)
        }
    }
}

final class PracticeController {
    let window: NSWindow
    let view: PracticeBoardView

    init(solver: WordSolver, board: Board = BoardArtwork.sample) {
        view = PracticeBoardView(board: board, solver: solver)
        window = NSWindow(contentRect: CGRect(origin: .zero, size: BoardArtwork.canvas), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Word Hunt Practice"
        window.contentView = view
        window.isReleasedWhenClosed = false
        window.center()
    }

    func show() { window.makeKeyAndOrderFront(nil) }
}
