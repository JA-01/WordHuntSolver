import Foundation

/// An immutable dictionary trie. Solves are independent and never perform network I/O.
public final class WordSolver {
    private struct BuildingNode {
        var firstChild = -1
        var nextSibling = -1
        var letter: UInt8 = 0
        var terminal = -1
    }

    // Packed edges avoid a separate allocation, or 26 mostly empty pointers, per node.
    private struct Node {
        let letters: UInt32
        let firstEdge: Int
        let terminal: Int
    }

    private struct Entry {
        let word: String
        let length: Int
    }

    private struct Neighbor {
        let index: Int
        let diagonal: Bool
    }

    private struct Match {
        let entry: Int
        let path: [Int]
        let travel: Double
    }

    private let nodes: [Node]
    private let edges: [Int]
    private let entries: [Entry]
    public var wordCount: Int { entries.count }

    /// Accepts case-insensitive ASCII words, trimming surrounding whitespace.
    /// Empty, nonalphabetic and duplicate entries are ignored. Short words are
    /// retained in wordCount but cannot be returned by solve (minimum 3 letters).
    public init(words: [String]) {
        var building = [BuildingNode()]
        var entries: [Entry] = []
        entries.reserveCapacity(words.count)
        for input in words {
            let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let bytes = trimmed.utf8.map { byte -> UInt8 in
                (97...122).contains(byte) ? byte - 32 : byte
            }
            guard bytes.allSatisfy({ (65...90).contains($0) }) else { continue }
            var node = 0
            for byte in bytes {
                let letter = byte - 65
                var child = building[node].firstChild
                while child != -1 && building[child].letter != letter {
                    child = building[child].nextSibling
                }
                if child == -1 {
                    child = building.count
                    var added = BuildingNode()
                    added.letter = letter
                    added.nextSibling = building[node].firstChild
                    building.append(added)
                    building[node].firstChild = child
                }
                node = child
            }
            if building[node].terminal == -1 {
                building[node].terminal = entries.count
                entries.append(Entry(word: String(decoding: bytes, as: UTF8.self), length: bytes.count))
            }
        }

        var nodes: [Node] = []
        var edges: [Int] = []
        nodes.reserveCapacity(building.count)
        edges.reserveCapacity(building.count - 1)
        var children = [Int](repeating: -1, count: 26)
        for node in building {
            var mask: UInt32 = 0
            var child = node.firstChild
            while child != -1 {
                let letter = Int(building[child].letter)
                children[letter] = child
                mask |= UInt32(1) << letter
                child = building[child].nextSibling
            }
            nodes.append(Node(letters: mask, firstEdge: edges.count, terminal: node.terminal))
            for letter in 0..<26 where children[letter] != -1 {
                edges.append(children[letter])
                children[letter] = -1
            }
        }
        self.nodes = nodes
        self.edges = edges
        self.entries = entries
    }

    public static func bundled() throws -> WordSolver {
        guard let url = ResourceBundle.packaged("WordHuntSolver_WordHuntCore", fallback: { .module })
            .url(forResource: "enable1", withExtension: "txt") else {
            throw WordHuntError.dictionary("The bundled ENABLE dictionary is missing. Reinstall the complete application bundle.")
        }
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            let solver = WordSolver(words: text.components(separatedBy: .newlines))
            guard solver.wordCount > 0 else {
                throw WordHuntError.dictionary("The bundled ENABLE dictionary is empty.")
            }
            return solver
        } catch let error as WordHuntError {
            throw error
        } catch {
            throw WordHuntError.dictionary("Unable to read the bundled ENABLE dictionary: \(error.localizedDescription)")
        }
    }

    /// Estimated length scores from secondary references; see THIRD_PARTY_NOTICES.md.
    public static func score(length: Int) -> Int {
        switch length {
        case ..<3: return 0
        case 3: return 100
        case 4: return 400
        case 5: return 800
        case 6: return 1400
        case 7: return 1800
        default: return 2200
        }
    }

    @inline(__always)
    private func child(of node: Int, letter: UInt8) -> Int {
        let record = nodes[node]
        let bit = UInt32(1) << letter
        guard record.letters & bit != 0 else { return -1 }
        let rank = (record.letters & (bit - 1)).nonzeroBitCount
        return edges[record.firstEdge + rank]
    }

    /// Exhausts all legal 8-neighbor paths. QU consumes both trie letters but
    /// just one tile; Q alone never implicitly supplies a U.
    /// For each spelling, prefers minimum center-to-center travel, then fewer
    /// tiles, then lexicographic row-major indices. Results sort by score,
    /// travel, tile count, and finally spelling for a stable priority order.
    public func solve(_ board: Board) -> [FoundWord] {
        guard !entries.isEmpty else { return [] }
        let neighbors = board.size == 4 ? Self.neighbors4 : Self.neighbors5
        let letters = board.tiles.map { $0.utf8.first! - 65 }
        let isQU = board.tiles.map { $0 == "QU" }
        var matches: [Int: Match] = [:]
        var path = [Int](repeating: 0, count: board.tiles.count)
        let diagonalDistance = Double(2).squareRoot()

        path.withUnsafeMutableBufferPointer { buffer in
            func visit(_ tile: Int, _ parent: Int, _ used: UInt32, _ depth: Int, _ diagonals: Int) {
                var node = child(of: parent, letter: letters[tile])
                guard node != -1 else { return }
                if isQU[tile] {
                    node = child(of: node, letter: 20) // U
                    guard node != -1 else { return }
                }
                buffer[depth] = tile
                let count = depth + 1
                let terminal = nodes[node].terminal
                if terminal != -1 && entries[terminal].length >= 3 {
                    let travel = Double(depth - diagonals) + Double(diagonals) * diagonalDistance
                    let old = matches[terminal]
                    var replace = old == nil
                    if let old = old {
                        if travel != old.travel {
                            replace = travel < old.travel
                        } else if count != old.path.count {
                            replace = count < old.path.count
                        } else {
                            replace = buffer.prefix(count).lexicographicallyPrecedes(old.path)
                        }
                    }
                    if replace {
                        matches[terminal] = Match(entry: terminal, path: Array(buffer.prefix(count)), travel: travel)
                    }
                }
                guard nodes[node].letters != 0 else { return }
                let visited = used | (UInt32(1) << tile)
                for neighbor in neighbors[tile] where visited & (UInt32(1) << neighbor.index) == 0 {
                    visit(neighbor.index, node, visited, count, diagonals + (neighbor.diagonal ? 1 : 0))
                }
            }
            for tile in board.tiles.indices {
                visit(tile, 0, 0, 0, 0)
            }
        }

        return matches.values.sorted { left, right in
            let leftScore = Self.score(length: entries[left.entry].length)
            let rightScore = Self.score(length: entries[right.entry].length)
            if leftScore != rightScore { return leftScore > rightScore }
            if left.travel != right.travel { return left.travel < right.travel }
            if left.path.count != right.path.count { return left.path.count < right.path.count }
            return entries[left.entry].word < entries[right.entry].word
        }.map { match in
            let entry = entries[match.entry]
            return FoundWord(word: entry.word, path: match.path, score: Self.score(length: entry.length))
        }
    }

    private static let neighbors4 = makeNeighbors(size: 4)
    private static let neighbors5 = makeNeighbors(size: 5)

    private static func makeNeighbors(size: Int) -> [[Neighbor]] {
        (0..<(size * size)).map { tile in
            let row = tile / size
            let column = tile % size
            var result: [Neighbor] = []
            result.reserveCapacity(8)
            for nextRow in max(0, row - 1)...min(size - 1, row + 1) {
                for nextColumn in max(0, column - 1)...min(size - 1, column + 1) {
                    if nextRow != row || nextColumn != column {
                        result.append(Neighbor(index: nextRow * size + nextColumn,
                                               diagonal: nextRow != row && nextColumn != column))
                    }
                }
            }
            return result
        }
    }
}
