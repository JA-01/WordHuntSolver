import Foundation
import WordHuntCore

/// Schedules live swipes against estimated dictionary points and the round clock.
public enum WordSchedule {
    /// Exact 0/1 knapsack over conservatively rounded 10 ms gesture costs.
    public static func select(_ plans: [SwipePlan], seconds: Double) -> [SwipePlan] {
        guard seconds.isFinite, seconds > 0, !plans.isEmpty else { return [] }
        let quantum = 0.01
        let capacity = Int(min(seconds, 300) / quantum)
        guard capacity > 0 else { return [] }
        let costs = plans.map { max(1, Int(ceil($0.estimatedDuration / quantum))) }
        if costs.reduce(0, +) <= capacity { return order(plans) }
        var best = [Int](repeating: 0, count: capacity + 1)
        let stride = (capacity + 64) / 64
        var chosen = [UInt64](repeating: 0, count: stride * plans.count)
        for index in plans.indices {
            let cost = costs[index]
            guard cost <= capacity else { continue }
            for budget in Swift.stride(from: capacity, through: cost, by: -1) {
                let candidate = best[budget - cost] + plans[index].word.score
                if candidate > best[budget] {
                    best[budget] = candidate
                    chosen[index * stride + budget / 64] |= UInt64(1) << UInt64(budget % 64)
                }
            }
        }
        var budget = capacity
        var selected: [SwipePlan] = []
        for index in plans.indices.reversed() {
            if chosen[index * stride + budget / 64] & (UInt64(1) << UInt64(budget % 64)) != 0 {
                selected.append(plans[index])
                budget -= costs[index]
            }
        }
        return order(selected)
    }

    public static func selectHuman(_ words: [FoundWord], seconds: Double, timing: SwipeTiming,
                                   maxWords: Int, maxScore: Int, maxWordLength: Int) -> [FoundWord] {
        guard seconds.isFinite, seconds > 0, maxWords > 0, maxScore > 0 else { return [] }
        var candidates = words.indices.filter { words[$0].word.utf8.count <= maxWordLength }
        var selected: [FoundWord] = []
        selected.reserveCapacity(min(maxWords, candidates.count))
        var timeLeft = seconds
        var pointsLeft = maxScore
        // Draw without replacement. Keep searching if a word doesn't fit the remaining budget.
        while !candidates.isEmpty, selected.count < maxWords, pointsLeft > 0 {
            candidates.swapAt(Int.random(in: candidates.indices), candidates.count - 1)
            let word = words[candidates.removeLast()]
            guard word.score <= pointsLeft else { continue }
            let duration = timing.duration(for: word)
            guard duration <= timeLeft else { continue }
            selected.append(word)
            timeLeft -= duration
            pointsLeft -= word.score
        }
        return selected
    }

    private static func order(_ plans: [SwipePlan]) -> [SwipePlan] {
        plans.sorted {
            let left = Double($0.word.score) / max(0.001, $0.estimatedDuration)
            let right = Double($1.word.score) / max(0.001, $1.estimatedDuration)
            if left != right { return left > right }
            if $0.word.score != $1.word.score { return $0.word.score > $1.word.score }
            return $0.word.word < $1.word.word
        }
    }
}
