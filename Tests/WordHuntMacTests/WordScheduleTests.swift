import Foundation
import Testing
@testable import WordHuntMac
import WordHuntCore

struct WordScheduleTests {
    private func plan(_ spelling: String, score: Int, seconds: Double) -> SwipePlan {
        SwipePlan(word: FoundWord(word: spelling, path: [0, 1, 2], score: score),
                  points: [CGPoint(x: 10, y: 10), CGPoint(x: 20, y: 10), CGPoint(x: 30, y: 10)],
                  estimatedDuration: seconds)
    }

    @Test func choosesHigherTotalInsteadOfGreedyLongestWord() {
        let plans = [plan("LONGEST", score: 1800, seconds: 1.0),
                     plan("SMALL", score: 1000, seconds: 0.6),
                     plan("OTHER", score: 1000, seconds: 0.6)]
        let selected = WordSchedule.select(plans, seconds: 1.2)
        #expect(Set(selected.map { $0.word.word }) == ["SMALL", "OTHER"])
        #expect(selected.reduce(0) { $0 + $1.word.score } == 2000)
    }

    @Test func roundedCostsNeverExceedActualBudgetOrDuplicateWords() {
        let plans = [plan("ONE", score: 100, seconds: 0.101),
                     plan("TWO", score: 100, seconds: 0.101),
                     plan("THREE", score: 800, seconds: 0.21)]
        let selected = WordSchedule.select(plans, seconds: 0.21)
        #expect(selected.map { $0.word.word } == ["THREE"])
        #expect(selected.reduce(0) { $0 + $1.estimatedDuration } <= 0.21)
        #expect(WordSchedule.select(plans, seconds: 0.10).isEmpty)
    }

    @Test func humanModeCapsAttemptsAndTotalEstimatedScore() {
        let words = ["CATS", "DOGS", "BARS"].map { FoundWord(word: $0, path: [0, 1, 2, 3], score: 400) }
        let timing = SwipeTiming(thinkingPause: 2)
        let byCount = WordSchedule.selectHuman(words, seconds: 30, timing: timing,
                                               maxWords: 2, maxScore: 2_000, maxWordLength: 6)
        #expect(byCount.count == 2)
        #expect(Set(byCount.map(\.word)).count == 2)
        let byScore = WordSchedule.selectHuman(words, seconds: 30, timing: timing,
                                               maxWords: 3, maxScore: 850, maxWordLength: 6)
        #expect(byScore.reduce(0) { $0 + $1.score } == 800)
    }

    @Test func humanModeCountsLettersAndReservesThinkingTime() throws {
        let words = [FoundWord(word: "QUIT", path: [0, 1, 2], score: 400),
                     FoundWord(word: "CAT", path: [0, 1, 2], score: 100),
                     FoundWord(word: "DOG", path: [4, 5, 6], score: 100)]
        let timing = SwipeTiming(thinkingPause: 2)
        let shortWords = WordSchedule.selectHuman(words, seconds: 30, timing: timing,
                                                  maxWords: 3, maxScore: 1_000, maxWordLength: 3)
        #expect(Set(shortWords.map(\.word)) == ["CAT", "DOG"])

        let timed = WordSchedule.selectHuman(words, seconds: 2, timing: timing,
                                             maxWords: 3, maxScore: 1_000, maxWordLength: 6)
        let plans = try SwipePlanner.plan(words: timed, geometry: GridGeometry(size: 4, x: 0, y: 0, width: 400, height: 400),
                                          imageSize: CGSize(width: 400, height: 400),
                                          windowFrame: CGRect(x: 0, y: 0, width: 400, height: 400), timing: timing)
        let duration = plans.reduce(0) { $0 + $1.estimatedDuration }
        #expect(plans.count == 1)
        #expect((1.75...2).contains(duration))
    }
}
