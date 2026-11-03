import Foundation
import CoreGraphics

public enum WordHuntError: Error, LocalizedError {
    case invalidBoard(String)
    case dictionary(String)
    case detection(String)
    case automation(String)

    public var errorDescription: String? {
        switch self {
        case .invalidBoard(let message), .dictionary(let message), .detection(let message), .automation(let message):
            return message
        }
    }
}

/// Row-major tiles. A tile is A–Z or QU; a bare Q remains a single letter.
public struct Board: Equatable, Codable, Sendable {
    public let size: Int
    public let tiles: [String]

    public init(size: Int, tiles: [String]) throws {
        guard (4...5).contains(size), tiles.count == size * size else {
            throw WordHuntError.invalidBoard("Provide exactly \(size * size) tiles on a 4×4 or 5×5 board.")
        }
        let normalized = tiles.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() }
        guard normalized.allSatisfy({ $0 == "QU" || ($0.utf8.count == 1 && $0.utf8.first! >= 65 && $0.utf8.first! <= 90) }) else {
            throw WordHuntError.invalidBoard("Each tile must be A–Z or QU. Correct unreadable tiles before solving.")
        }
        self.size = size
        self.tiles = normalized
    }

    public init(text: String, size: Int) throws {
        let separated = text.uppercased().split { $0.isWhitespace || $0 == "," || $0 == ";" || $0 == "/" }
        let tiles: [String]
        if separated.count == size * size {
            tiles = separated.map(String.init)
        } else {
            tiles = text.uppercased().filter { !$0.isWhitespace && $0 != "," && $0 != ";" && $0 != "/" }.map(String.init)
        }
        try self.init(size: size, tiles: tiles)
    }

    public var text: String {
        (0..<size).map { row in tiles[(row * size)..<((row + 1) * size)].joined(separator: " ") }.joined(separator: "\n")
    }
}

public struct FoundWord: Equatable, Codable, Sendable, Identifiable {
    public let word: String
    public let path: [Int]
    public let score: Int
    public var id: String { word }

    public init(word: String, path: [Int], score: Int) {
        self.word = word
        self.path = path
        self.score = score
    }
}

/// Bounds are image pixels, with origin at the image's top-left corner.
/// Bounds include the whole board; centers are halfway across equal-sized cells.
public struct GridGeometry: Equatable, Codable, Sendable {
    public let size: Int
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(size: Int, x: Double, y: Double, width: Double, height: Double) {
        self.size = size
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var rect: CGRect { CGRect(x: x, y: y, width: width, height: height) }

    public func center(of index: Int) -> CGPoint {
        CGPoint(x: x + (Double(index % size) + 0.5) * width / Double(size),
                y: y + (Double(index / size) + 0.5) * height / Double(size))
    }
}
