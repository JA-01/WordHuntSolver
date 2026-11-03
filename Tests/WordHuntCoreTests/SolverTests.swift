import Testing
@testable import WordHuntCore

struct SolverTests {
    private func board(_ tiles: [String], size: Int = 4) throws -> Board {
        try Board(size: size, tiles: tiles)
    }

    @Test
    func testDictionaryNormalizationAndInvalidEntries() throws {
        let solver = WordSolver(words: [" cat ", "CAT", "CaT", "dog", "a", "at", "", "can't", "two words", "café", "123"])
        #expect(solver.wordCount == 4)
        let grid = try Board(text: "C A T X D O G X X X X X X X X X", size: 4)
        #expect(Set(solver.solve(grid).map(\.word)) == Set(["CAT", "DOG"]))
        #expect(WordSolver(words: []).solve(grid).isEmpty)
    }

    @Test
    func testEveryNeighborDirectionIsSearchable() throws {
        let solver = WordSolver(words: ["CAT"])
        let center = 5
        for adjacent in [0, 1, 2, 4, 6, 8, 9, 10] {
            let row = adjacent / 4
            let column = adjacent % 4
            let end = (0..<16).first { index in
                index != center && index != adjacent &&
                abs(index / 4 - row) <= 1 && abs(index % 4 - column) <= 1
            }!
            var tiles = [String](repeating: "X", count: 16)
            tiles[center] = "C"
            tiles[adjacent] = "A"
            tiles[end] = "T"
            let results = solver.solve(try board(tiles))
            #expect(results.map(\.word) == ["CAT"], "Missing direction toward \(adjacent)")
            #expect(results.first?.path == [center, adjacent, end])
        }
    }

    @Test
    func testNoTileReuseOrRowWrappingOrJumping() throws {
        var tiles = [String](repeating: "X", count: 16)
        tiles[0] = "A"
        tiles[1] = "B"
        tiles[3] = "C"
        tiles[4] = "D"
        tiles[15] = "E"
        let solver = WordSolver(words: ["ABA", "BAB", "CDA", "ABE", "ABC"])
        #expect(solver.solve(try board(tiles)).isEmpty)
    }

    @Test
    func testExplicitQUConsumesOneTileButTwoLetters() throws {
        var tiles = [String](repeating: "X", count: 16)
        tiles[0] = "QU"
        tiles[1] = "A"
        tiles[2] = "D"
        let solver = WordSolver(words: ["QUA", "QUAD", "QAD", "QU", "QUQU"])
        let results = solver.solve(try board(tiles))
        try #require(results.count == 2)
        #expect(results.map(\.word) == ["QUAD", "QUA"])
        #expect(results[0].path == [0, 1, 2])
        #expect(results[0].score == 400)
        #expect(results[1].path == [0, 1])
        #expect(results[1].score == 100)
    }

    @Test
    func testBareQRemainsLiteralAndMayUseSeparateU() throws {
        var tiles = [String](repeating: "X", count: 16)
        tiles[0] = "Q"
        tiles[1] = "A"
        tiles[2] = "D"
        let solver = WordSolver(words: ["QAD", "QUAD"])
        #expect(solver.solve(try board(tiles)).map(\.word) == ["QAD"])
        tiles[1] = "U"
        tiles[2] = "A"
        tiles[3] = "D"
        let results = solver.solve(try board(tiles))
        try #require(results.count == 1)
        #expect(results.map(\.word) == ["QUAD"])
        #expect(results[0].path == [0, 1, 2, 3])
    }

    @Test
    func testShortestTravelWinsBeforeLexicographicPath() throws {
        // [0, 5, 2] is lexically earlier but has two diagonals.
        var tiles = [String](repeating: "X", count: 16)
        for index in [0, 8] { tiles[index] = "C" }
        for index in [5, 9] { tiles[index] = "A" }
        for index in [2, 10] { tiles[index] = "T" }
        let result = WordSolver(words: ["CAT", "cat"]).solve(try board(tiles))
        try #require(result.count == 1)
        #expect(result[0].path == [8, 9, 10])
    }

    @Test
    func testEqualTravelPathTieIsLexicographic() throws {
        var tiles = [String](repeating: "X", count: 16)
        for index in [0, 4] { tiles[index] = "C" }
        for index in [1, 5] { tiles[index] = "A" }
        for index in [2, 6] { tiles[index] = "T" }
        #expect(WordSolver(words: ["CAT"]).solve(try board(tiles)).first?.path == [0, 1, 2])
    }

    @Test
    func testScoreThenTravelThenSpellingPriority() throws {
        let grid = try Board(text: "C A T S D O G X X X X X X X X X", size: 4)
        let words = ["DOG", "CATS", "CAT", "COG", "ACT"]
        let forward = WordSolver(words: words).solve(grid)
        let reverse = WordSolver(words: Array(words.reversed())).solve(grid)
        #expect(forward == reverse)
        #expect(forward.map(\.word) == ["CATS", "CAT", "DOG", "COG"])
        // A -> C -> T jumps two columns; letter presence alone is insufficient.
        #expect(!forward.contains { $0.word == "ACT" })
    }

    @Test
    func testFiveByFiveAndLongWordScoreCap() throws {
        let grid = try Board(text: "A B C D E J I H G F K L M N O T S R Q P U V W X Y", size: 5)
        let result = WordSolver(words: ["ABCDEFGHI", "ABCDEFGHIJKLMNOPQRSTUVWXY"]).solve(grid)
        try #require(result.count == 2)
        #expect(result[0].word == "ABCDEFGHI")
        #expect(result[1].path.count == 25)
        #expect(result.map(\.score) == [2200, 2200])
        for found in result {
            #expect(Set(found.path).count == found.path.count)
            #expect(found.path.map { grid.tiles[$0] }.joined() == found.word)
            for (left, right) in zip(found.path, found.path.dropFirst()) {
                #expect(abs(left / 5 - right / 5) <= 1)
                #expect(abs(left % 5 - right % 5) <= 1)
            }
        }
    }

    @Test
    func testScoringBoundaries() {
        #expect((-1...10).map { WordSolver.score(length: $0) } ==
                [0, 0, 0, 0, 100, 400, 800, 1400, 1800, 2200, 2200, 2200])
        #expect(WordSolver.score(length: Int.max) == 2200)
        #expect(WordSolver.score(length: Int.min) == 0)
    }

    @Test
    func testBundledFullENABLEDictionaryIsAvailableOffline() throws {
        let solver = try WordSolver.bundled()
        let grid = try Board(text: "C A T S X X X X X X X X X X X X", size: 4)
        let words = Set(solver.solve(grid).map(\.word))
        #expect(words.contains("CAT"))
        #expect(words.contains("CATS"))
    }
}
