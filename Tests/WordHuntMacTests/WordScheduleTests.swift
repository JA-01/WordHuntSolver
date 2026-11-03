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
}
