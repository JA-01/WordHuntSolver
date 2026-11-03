import Foundation

/// Exact 0/1 knapsack over conservatively rounded 10 ms gesture costs.
/// Optimizes estimated dictionary points, not confirmed GamePigeon acceptance.
public enum WordSchedule {
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
