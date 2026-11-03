import Testing
@testable import WordHuntCore

struct ExhaustiveSolverTests {
    @Test
    func testTrieMatchesIndependentUnprunedEnumeration() throws {
        let board = try Board(text: "A B C X B C A X C A B X X X X X", size: 4)
        var dictionary: [String] = []
        func generate(_ prefix: String, _ remaining: Int) {
            if prefix.count >= 3 { dictionary.append(prefix) }
            if remaining > 0 {
                for letter in ["A", "B", "C"] { generate(prefix + letter, remaining - 1) }
            }
        }
        generate("", 5)
        let accepted = Set(dictionary)
        var expected: [String: [Int]] = [:]
        var path: [Int] = []

        func travel(_ path: [Int]) -> Double {
            let diagonals = zip(path, path.dropFirst()).filter { left, right in
                left / 4 != right / 4 && left % 4 != right % 4
            }.count
            return Double(path.count - 1 - diagonals) + Double(diagonals) * Double(2).squareRoot()
        }

        // Deliberately no prefix pruning or trie: enumerate every legal path
        // through length five, then look up the complete spelling in a set.
        func visit(_ index: Int, _ spelling: String) {
            path.append(index)
            let word = spelling + board.tiles[index]
            if accepted.contains(word) {
                if let previous = expected[word] {
                    let oldTravel = travel(previous)
                    let newTravel = travel(path)
                    if newTravel < oldTravel || (newTravel == oldTravel && path.lexicographicallyPrecedes(previous)) {
                        expected[word] = path
                    }
                } else {
                    expected[word] = path
                }
            }
            if path.count < 5 {
                for next in board.tiles.indices where !path.contains(next) {
                    if abs(index / 4 - next / 4) <= 1 && abs(index % 4 - next % 4) <= 1 {
                        visit(next, word)
                    }
                }
            }
            path.removeLast()
        }
        for index in board.tiles.indices { visit(index, "") }

        let results = WordSolver(words: dictionary).solve(board)
        #expect(!expected.isEmpty)
        #expect(Set(results.map(\.word)) == Set(expected.keys))
        #expect(results.count == expected.count)
        for found in results {
            #expect(found.path == expected[found.word], "Wrong minimum path for \(found.word)")
            #expect(found.score == WordSolver.score(length: found.word.count))
        }
    }
}
