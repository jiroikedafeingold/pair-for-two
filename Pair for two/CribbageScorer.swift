import Foundation

// MARK: - ScoreFlag

/// A single detected scoring opportunity. The app is flag-only for v1: these drive the coach's
/// flag chips and can optionally pre-fill the manual slider, but never auto-apply points.
nonisolated struct ScoreFlag: Codable, Hashable, Sendable, Identifiable {

    /// The category of the score. Used for grouping, icons, and (later) automatic scoring.
    enum Kind: String, Codable, Hashable, Sendable {
        case fifteen
        case pair          // covers pairs (2), pairs royal / trips (6), double pair royal / quads (12)
        case run
        case flush
        case nobs          // Jack in hand matching the starter's suit
        case hisHeels      // starter is a Jack — 2 for the dealer, scored at the cut
        case thirtyOne
        case go
        case lastCard
    }

    let kind: Kind
    let points: Int
    /// Human-readable detail, e.g. "Fifteen 2", "Run of 3", "Pair", "His Nobs". Kept English here;
    /// the view layer localizes for display.
    let detail: String

    var id: String { "\(kind.rawValue)|\(detail)|\(points)" }

    init(_ kind: Kind, points: Int, detail: String) {
        self.kind = kind
        self.points = points
        self.detail = detail
    }
}

extension Array where Element == ScoreFlag {
    /// Total points represented by this collection of flags.
    var totalPoints: Int {
        reduce(0) { $0 + $1.points }
    }
}

// MARK: - CribbageScorer

/// Pure, `nonisolated`, fully unit-testable cribbage scoring. Detects every count; it never decides
/// whether points are *taken* — that stays manual in v1.
nonisolated enum CribbageScorer {

    // MARK: Hand / crib scoring (the show)

    /// Scores a 4-card hand (or the 4-card crib) together with the cut `starter`.
    /// - Parameter isCrib: the crib may only score a 5-card flush (all five same suit), never a 4-card flush.
    static func handScore(hand: [Card], starter: Card, isCrib: Bool) -> [ScoreFlag] {
        let all = hand + [starter]
        var flags: [ScoreFlag] = []
        flags += fifteens(in: all)
        flags += pairs(in: all)
        flags += runs(in: all)
        flags += flush(hand: hand, starter: starter, isCrib: isCrib)
        flags += nobs(hand: hand, starter: starter)
        return flags
    }

    /// A human-readable breakdown of a hand/crib show score using proper cribbage terminology —
    /// "double run", "pair royal", "run of five", etc. — one line per scoring element. The point
    /// totals match `handScore`; this is a presentation of the same count for the "check my count" view.
    static func handBreakdown(hand: [Card], starter: Card, isCrib: Bool) -> [ScoreFlag] {
        let all = hand + [starter]
        var flags: [ScoreFlag] = []

        // Fifteens (each distinct subset summing to 15 is 2 points).
        let n15 = fifteens(in: all).count
        if n15 > 0 {
            flags.append(ScoreFlag(.fifteen, points: n15 * 2,
                                   detail: n15 == 1 ? "Fifteen" : "\(numberWord(n15).capitalized) fifteens"))
        }

        // Runs, folding any in-run duplicates into the run's name (double/triple/double-double run).
        var counts: [Int: Int] = [:]
        for c in all { counts[c.orderValue, default: 0] += 1 }
        let distinct = counts.keys.sorted()
        var consumedByRun = Set<Int>()
        var i = 0
        while i < distinct.count {
            var end = i
            while end + 1 < distinct.count, distinct[end + 1] == distinct[end] + 1 { end += 1 }
            let length = end - i + 1
            if length >= 3 {
                let blockRanks = Array(distinct[i...end])
                let multiplicity = blockRanks.reduce(1) { $0 * (counts[$1] ?? 1) }
                let inRunPairPts = blockRanks.reduce(0) { $0 + pairPoints(counts[$1] ?? 1) }
                flags.append(ScoreFlag(.run, points: multiplicity * length + inRunPairPts,
                                       detail: runName(multiplicity: multiplicity, length: length)))
                blockRanks.forEach { consumedByRun.insert($0) }
            }
            i = end + 1
        }

        // Pairs / trips / quads for ranks not already folded into a run.
        for rank in distinct where !consumedByRun.contains(rank) {
            let c = counts[rank] ?? 0
            if c >= 2 { flags.append(ScoreFlag(.pair, points: pairPoints(c), detail: pairName(c))) }
        }

        flags += flush(hand: hand, starter: starter, isCrib: isCrib)
        flags += nobs(hand: hand, starter: starter)
        return flags
    }

    private static func pairPoints(_ count: Int) -> Int {
        switch count {
        case 2: return 2
        case 3: return 6
        case 4: return 12
        default: return 0
        }
    }

    private static func pairName(_ count: Int) -> String {
        switch count {
        case 2: return "Pair"
        case 3: return "Pair royal"
        case 4: return "Double pair royal"
        default: return "Pair"
        }
    }

    private static func runName(multiplicity: Int, length: Int) -> String {
        let base: String
        switch multiplicity {
        case 1:  base = "Run of \(numberWord(length))"
        case 2:  base = length == 3 ? "Double run" : "Double run of \(numberWord(length))"
        case 3:  base = length == 3 ? "Triple run" : "Triple run of \(numberWord(length))"
        default: base = length == 3 ? "Double double run" : "Double double run of \(numberWord(length))"
        }
        return base
    }

    private static func numberWord(_ n: Int) -> String {
        let words = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine"]
        return (n >= 0 && n < words.count) ? words[n] : "\(n)"
    }

    // MARK: Pegging scoring (the play)

    /// Scores the card just laid onto the pegging pile. `pile` is the current run of play since the
    /// last reset (a go or a 31) and **includes** `justPlayed` as its final element.
    ///
    /// Detects fifteens, thirty-ones, pairs/trips/quads, and runs. `go` and `lastCard` depend on
    /// turn/hand context and are emitted by the engine, not here.
    static func peggingScore(pile: [Card], justPlayed: Card) -> [ScoreFlag] {
        var flags: [ScoreFlag] = []
        let count = pile.reduce(0) { $0 + $1.countingValue }

        if count == 15 {
            flags.append(ScoreFlag(.fifteen, points: 2, detail: "Fifteen 2"))
        }
        if count == 31 {
            flags.append(ScoreFlag(.thirtyOne, points: 2, detail: "31 for 2"))
        }

        // Pairs: how many trailing cards share the rank of the card just played.
        var sameRank = 0
        for card in pile.reversed() {
            if card.rank == justPlayed.rank { sameRank += 1 } else { break }
        }
        switch sameRank {
        case 4: flags.append(ScoreFlag(.pair, points: 12, detail: "Double pair royal"))
        case 3: flags.append(ScoreFlag(.pair, points: 6, detail: "Pair royal"))
        case 2: flags.append(ScoreFlag(.pair, points: 2, detail: "Pair"))
        default: break
        }

        // Runs: the longest trailing window (length ≥ 3) that forms consecutive distinct ranks.
        // Order within the window does not matter in cribbage pegging.
        var runLength = 0
        var window = pile.count
        while window >= 3 {
            let tail = Array(pile.suffix(window))
            let values = Set(tail.map(\.orderValue))
            if values.count == tail.count,
               let lo = values.min(), let hi = values.max(),
               hi - lo == tail.count - 1 {
                runLength = window
                break
            }
            window -= 1
        }
        if runLength >= 3 {
            flags.append(ScoreFlag(.run, points: runLength, detail: "Run of \(runLength)"))
        }

        return flags
    }

    // MARK: Legality helpers

    /// Cards from `hand` that may legally be played on a pile at the given running `count`
    /// (i.e. would not push the count past 31).
    static func legalPlays(hand: [Card], count: Int) -> [Card] {
        hand.filter { count + $0.countingValue <= 31 }
    }

    /// A player must say "go" when they hold cards but none can be played without exceeding 31.
    static func mustSayGo(hand: [Card], count: Int) -> Bool {
        !hand.isEmpty && legalPlays(hand: hand, count: count).isEmpty
    }

    /// "His heels" / "his nibs": if the cut starter is a Jack, the dealer pegs 2 immediately.
    static func isHisHeels(starter: Card) -> Bool {
        starter.rank == .jack
    }

    // MARK: - Private scoring primitives

    /// One flag per distinct subset of cards summing to 15 (2 points each).
    private static func fifteens(in cards: [Card]) -> [ScoreFlag] {
        var flags: [ScoreFlag] = []
        let values = cards.map(\.countingValue)
        let n = values.count
        // Enumerate every non-empty subset via a bitmask.
        for mask in 1..<(1 << n) {
            var sum = 0
            for i in 0..<n where mask & (1 << i) != 0 {
                sum += values[i]
            }
            if sum == 15 {
                flags.append(ScoreFlag(.fifteen, points: 2, detail: "Fifteen 2"))
            }
        }
        return flags
    }

    /// One flag per unordered pair of same-rank cards (2 points each). Naturally yields 2/6/12 for
    /// pairs / trips / quads.
    private static func pairs(in cards: [Card]) -> [ScoreFlag] {
        var flags: [ScoreFlag] = []
        for i in 0..<cards.count {
            for j in (i + 1)..<cards.count where cards[i].rank == cards[j].rank {
                flags.append(ScoreFlag(.pair, points: 2, detail: "Pair"))
            }
        }
        return flags
    }

    /// Runs in the show: find each maximal block of consecutive ranks (length ≥ 3) and emit one
    /// `run` flag per distinct run instance (accounting for duplicate ranks — double/triple runs).
    private static func runs(in cards: [Card]) -> [ScoreFlag] {
        // Count cards per orderValue.
        var counts: [Int: Int] = [:]
        for card in cards { counts[card.orderValue, default: 0] += 1 }
        let distinct = counts.keys.sorted()

        var flags: [ScoreFlag] = []
        var index = 0
        while index < distinct.count {
            // Extend a consecutive block.
            var end = index
            while end + 1 < distinct.count, distinct[end + 1] == distinct[end] + 1 {
                end += 1
            }
            let blockLength = end - index + 1
            if blockLength >= 3 {
                // Multiplicity = product of the per-rank counts in the block.
                let multiplicity = (index...end).reduce(1) { $0 * (counts[distinct[$1]] ?? 1) }
                for _ in 0..<multiplicity {
                    flags.append(ScoreFlag(.run, points: blockLength, detail: "Run of \(blockLength)"))
                }
            }
            index = end + 1
        }
        return flags
    }

    /// Flush: 4 matching hand cards score 4 (5 if the starter matches too). The crib scores only a
    /// full 5-card flush.
    private static func flush(hand: [Card], starter: Card, isCrib: Bool) -> [ScoreFlag] {
        guard let suit = hand.first?.suit, hand.allSatisfy({ $0.suit == suit }) else {
            return []
        }
        if starter.suit == suit {
            return [ScoreFlag(.flush, points: 5, detail: "Flush of 5")]
        }
        if isCrib {
            return []   // no 4-card flush in the crib
        }
        return [ScoreFlag(.flush, points: 4, detail: "Flush of 4")]
    }

    /// His Nobs: a Jack held in hand whose suit matches the starter scores 1.
    private static func nobs(hand: [Card], starter: Card) -> [ScoreFlag] {
        let hasNobs = hand.contains { $0.rank == .jack && $0.suit == starter.suit }
        return hasNobs ? [ScoreFlag(.nobs, points: 1, detail: "His Nobs")] : []
    }
}
