// Scorer differential fixtures — the iOS side of the cross-platform scoring contract.
//
// Compiled against the real `CribbageScorer.swift`, so what it emits is by construction what the
// shipping iOS app scores. The Android `:core` module asserts its own scorer reproduces every
// case exactly (`ScorerFixtureTest`). Run via tools/generate-scorer-fixtures.sh.
//
// Why this exists: the host is the sole referee, so the two platforms never score the same hand
// at the same moment — but if they disagree, a game plays differently depending on who hosts.
// Cribbage scoring has a long tail (nineteen-point hands, five-card double-double runs, his nobs
// vs his heels, the crib's flush rule) and a differential test against the known-good Swift
// implementation is far cheaper and far more thorough than hand-written cases.
//
// ---- Fixture format ----
//
// Cards are tokens: rank raw value 1…13 followed by a suit initial — "1s", "10h", "11d", "13c".
// Flags are `ScoreFlag.id`, i.e. "kind|detail|points", which pins the category, the human-readable
// wording *and* the points in one string. Both sides already compute that property.
//
//   show.json     {"version":1,"cases":[{"hand":[…],"starter":"…","isCrib":bool,
//                                        "score":[flag…],"breakdown":[flag…]}]}
//   pegging.json  {"version":1,"cases":[{"pile":[…],"played":"…","score":[flag…]}]}
//
// The corpus is deterministic: same source, same bytes, so a regeneration that changes anything
// shows up as a diff rather than as churn.

import Foundation

// MARK: - Tokens

let suitLetters: [Suit: String] = [.spades: "s", .hearts: "h", .diamonds: "d", .clubs: "c"]
let allSuits: [Suit] = [.spades, .hearts, .diamonds, .clubs]
let allRanks: [Rank] = Rank.allCases

func token(_ c: Card) -> String { "\(c.rank.rawValue)\(suitLetters[c.suit]!)" }

// MARK: - Corpus generation

/// A deterministic generator seeded per-section, so adding cases to one section doesn't reshuffle
/// another. `SeededGenerator` comes from the app's own `CribbageModels.swift`.
struct Rand {
    private var rng: SeededGenerator
    init(seed: UInt64) { rng = SeededGenerator(seed: seed) }
    mutating func int(_ bound: Int) -> Int { Int(rng.next() % UInt64(bound)) }
    mutating func pick<T>(_ xs: [T]) -> T { xs[int(xs.count)] }
}

struct ShowCase {
    let hand: [Card]
    let starter: Card
    let isCrib: Bool
}

var showCases: [ShowCase] = []

// --- Section 1: every reachable multiset of five ranks. ---
//
// Fifteens, pairs and runs depend only on the ranks, so this section is *exhaustive* over the
// rank logic: all 6,175 five-rank multisets that a real deck can produce (no rank five times).
// Suits are assigned round-robin so a rank repeat always takes a fresh suit — that keeps every
// hand legal and incidentally never produces a flush, which is section 2's job.
do {
    var chosen: [Int] = []
    func emit() {
        var used: [Rank: Int] = [:]
        var cards: [Card] = []
        for r in chosen.map({ allRanks[$0] }) {
            let n = used[r, default: 0]
            used[r] = n + 1
            cards.append(Card(rank: r, suit: allSuits[n]))
        }
        // Last card is the starter; the other four are the hand.
        showCases.append(ShowCase(hand: Array(cards.prefix(4)), starter: cards[4], isCrib: false))
    }
    func build(_ start: Int) {
        if chosen.count == 5 { emit(); return }
        for i in start..<allRanks.count {
            // A deck holds at most four of any rank, so five-of-a-kind is unreachable.
            if chosen.filter({ $0 == i }).count >= 4 { continue }
            chosen.append(i)
            build(i)
            chosen.removeLast()
        }
    }
    build(0)
}
let rankSectionCount = showCases.count

// --- Section 2: suit structure — flushes, the crib's flush rule, and his nobs. ---
//
// Exhaustive over all 715 four-card same-suit hands in one suit, each with a matching-suit
// starter (five-card flush) and an off-suit one (four-card flush, or nothing in the crib),
// under both `isCrib` values. Jacks fall out of this naturally, so nobs is covered alongside.
do {
    var rand = Rand(seed: 0xF1E5_0002)
    for a in 0..<13 {
        for b in (a + 1)..<13 {
            for c in (b + 1)..<13 {
                for d in (c + 1)..<13 {
                    let hand = [a, b, c, d].map { Card(rank: allRanks[$0], suit: .spades) }
                    let sameSuit = Card(rank: rand.pick(allRanks), suit: .spades)
                    let offSuit = Card(rank: rand.pick(allRanks), suit: .hearts)
                    for isCrib in [false, true] {
                        showCases.append(ShowCase(hand: hand, starter: sameSuit, isCrib: isCrib))
                        showCases.append(ShowCase(hand: hand, starter: offSuit, isCrib: isCrib))
                    }
                }
            }
        }
    }
}
let suitSectionCount = showCases.count - rankSectionCount

// --- Section 3: random legal deals. ---
//
// The catch-all. Sections 1 and 2 are each structured around one axis; these are ordinary
// five-card draws from a real deck, which is what the app actually sees.
do {
    var rand = Rand(seed: 0xF1E5_0003)
    let deck = Deck().cards
    for i in 0..<2000 {
        var pool = deck
        var picked: [Card] = []
        for _ in 0..<5 { picked.append(pool.remove(at: rand.int(pool.count))) }
        showCases.append(ShowCase(hand: Array(picked.prefix(4)), starter: picked[4],
                                  isCrib: i % 2 == 1))
    }
}
let randomSectionCount = showCases.count - rankSectionCount - suitSectionCount

// --- Section 4: hand-picked extremes. ---
//
// Cases worth naming, so a regression in one of them is unmistakable in the diff rather than
// buried among thousands of generated hands.
do {
    func c(_ r: Int, _ s: Suit) -> Card { Card(rank: Rank(rawValue: r)!, suit: s) }
    let picked: [ShowCase] = [
        // The 29-hand: three fives plus the jack matching the starter five.
        ShowCase(hand: [c(5, .spades), c(5, .hearts), c(5, .diamonds), c(11, .clubs)],
                 starter: c(5, .clubs), isCrib: false),
        // The 28-hand: four fives, no nobs possible.
        ShowCase(hand: [c(5, .spades), c(5, .hearts), c(5, .diamonds), c(5, .clubs)],
                 starter: c(10, .clubs), isCrib: false),
        // Double-double run: 6-6-7-7-8 — four runs of three plus two pairs.
        ShowCase(hand: [c(6, .spades), c(6, .hearts), c(7, .spades), c(7, .hearts)],
                 starter: c(8, .clubs), isCrib: false),
        // Triple run of three: 4-5-5-5-6.
        ShowCase(hand: [c(4, .spades), c(5, .spades), c(5, .hearts), c(5, .diamonds)],
                 starter: c(6, .clubs), isCrib: false),
        // Double run of five: A-2-3-4-4 — the longest run with a duplicate.
        ShowCase(hand: [c(1, .spades), c(2, .hearts), c(3, .diamonds), c(4, .clubs)],
                 starter: c(4, .spades), isCrib: false),
        // Run of five, no duplicates.
        ShowCase(hand: [c(3, .spades), c(4, .hearts), c(5, .diamonds), c(6, .clubs)],
                 starter: c(7, .spades), isCrib: false),
        // Five-card flush in the crib — the only flush the crib may score.
        ShowCase(hand: [c(2, .hearts), c(4, .hearts), c(6, .hearts), c(8, .hearts)],
                 starter: c(10, .hearts), isCrib: true),
        // The same four-card flush in the crib with an off-suit starter: scores nothing for it.
        ShowCase(hand: [c(2, .hearts), c(4, .hearts), c(6, .hearts), c(8, .hearts)],
                 starter: c(10, .spades), isCrib: true),
        // …and in the hand, where it scores four.
        ShowCase(hand: [c(2, .hearts), c(4, .hearts), c(6, .hearts), c(8, .hearts)],
                 starter: c(10, .spades), isCrib: false),
        // His nobs with a jack-starter (his heels is the engine's business, not the scorer's).
        ShowCase(hand: [c(11, .spades), c(3, .hearts), c(7, .diamonds), c(9, .clubs)],
                 starter: c(11, .hearts), isCrib: false),
        // Nobs where the jack's suit matches — one point, no flush.
        ShowCase(hand: [c(11, .spades), c(3, .hearts), c(7, .diamonds), c(9, .clubs)],
                 starter: c(2, .spades), isCrib: false),
        // Double pair royal: four of a kind, twelve.
        ShowCase(hand: [c(9, .spades), c(9, .hearts), c(9, .diamonds), c(9, .clubs)],
                 starter: c(3, .spades), isCrib: false),
        // A nineteen — the score that cannot happen; must come back empty.
        ShowCase(hand: [c(1, .spades), c(3, .hearts), c(7, .diamonds), c(11, .clubs)],
                 starter: c(13, .spades), isCrib: false),
    ]
    showCases.append(contentsOf: picked)
}
let pickedSectionCount = showCases.count - rankSectionCount - suitSectionCount - randomSectionCount

// MARK: - Pegging corpus

struct PegCase {
    let pile: [Card]
    let played: Card
}

var pegCases: [PegCase] = []

// --- Random pegging laps, scored after every card. ---
//
// Deals four cards each and plays legally until nobody can go, recording the score at each play.
// This is how pegging scores are actually produced, so the pile shapes are realistic ones.
do {
    var rand = Rand(seed: 0xF1E5_0004)
    for _ in 0..<600 {
        var pool = Deck().cards
        var hands: [[Card]] = [[], []]
        for _ in 0..<4 {
            for p in 0..<2 { hands[p].append(pool.remove(at: rand.int(pool.count))) }
        }
        var pile: [Card] = []
        var count = 0
        var turn = 0
        var consecutiveGoes = 0
        while !(hands[0].isEmpty && hands[1].isEmpty) && consecutiveGoes < 2 {
            let legal = CribbageScorer.legalPlays(hand: hands[turn], count: count)
            if legal.isEmpty {
                consecutiveGoes += 1
                if consecutiveGoes >= 2 || (hands[0].isEmpty && hands[1].isEmpty) {
                    // Lap over: reset as the engine would.
                    pile = []; count = 0; consecutiveGoes = 0
                }
                turn = 1 - turn
                continue
            }
            consecutiveGoes = 0
            let card = legal[rand.int(legal.count)]
            hands[turn].removeAll { $0 == card }
            pile.append(card)
            count += card.countingValue
            pegCases.append(PegCase(pile: pile, played: card))
            if count == 31 { pile = []; count = 0 }
            turn = 1 - turn
        }
    }
}
let pegRandomCount = pegCases.count

// --- Hand-picked pegging extremes. ---
do {
    func c(_ r: Int, _ s: Suit) -> Card { Card(rank: Rank(rawValue: r)!, suit: s) }
    func add(_ pile: [Card]) { pegCases.append(PegCase(pile: pile, played: pile.last!)) }

    add([c(5, .spades), c(10, .hearts)])                                    // fifteen 2
    add([c(10, .spades), c(10, .hearts), c(10, .diamonds), c(1, .clubs)])   // 31 for 2
    add([c(7, .spades), c(7, .hearts)])                                     // pair
    add([c(7, .spades), c(7, .hearts), c(7, .diamonds)])                    // pair royal
    add([c(7, .spades), c(7, .hearts), c(7, .diamonds), c(7, .clubs)])      // double pair royal
    add([c(3, .spades), c(5, .hearts), c(4, .diamonds)])                    // run of 3, out of order
    add([c(3, .spades), c(5, .hearts), c(4, .diamonds), c(6, .clubs)])      // extends to run of 4
    add([c(3, .spades), c(5, .hearts), c(4, .diamonds), c(6, .clubs), c(2, .spades)]) // run of 5
    add([c(3, .spades), c(4, .hearts), c(3, .diamonds), c(5, .clubs)])      // duplicate breaks the long run
    add([c(1, .spades), c(2, .hearts), c(3, .diamonds), c(9, .clubs)])      // run then a card that ends it
    add([c(4, .spades), c(5, .hearts), c(6, .diamonds), c(10, .clubs), c(6, .spades)]) // trailing pair only
    add([c(8, .spades), c(7, .hearts)])                                     // fifteen via 8+7
    add([c(6, .spades), c(4, .hearts), c(5, .diamonds)])                    // fifteen *and* a run of 3
    add([c(11, .spades), c(12, .hearts), c(13, .diamonds)])                 // J-Q-K run (faces are distinct)
    add([c(13, .spades), c(11, .hearts), c(12, .diamonds), c(1, .clubs)])   // 31 on a K-J-Q run
}

// MARK: - Emit

func flagIDs(_ flags: [ScoreFlag]) -> [String] { flags.map(\.id) }

func jsonArray(_ xs: [String]) -> String {
    "[" + xs.map { "\"\($0.replacingOccurrences(of: "\"", with: "\\\""))\"" }.joined(separator: ",") + "]"
}

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "fixtures/scorer-v1"
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

// Written by hand rather than via JSONEncoder: one case per line keeps a 10k-case fixture
// diffable, which a pretty-printer or a single long line would not.
do {
    var lines: [String] = []
    for k in showCases {
        let score = flagIDs(CribbageScorer.handScore(hand: k.hand, starter: k.starter, isCrib: k.isCrib))
        let breakdown = flagIDs(CribbageScorer.handBreakdown(hand: k.hand, starter: k.starter, isCrib: k.isCrib))
        lines.append("{\"hand\":\(jsonArray(k.hand.map(token))),\"starter\":\"\(token(k.starter))\","
                     + "\"isCrib\":\(k.isCrib),\"score\":\(jsonArray(score)),\"breakdown\":\(jsonArray(breakdown))}")
    }
    let body = "{\n  \"version\": 1,\n  \"cases\": [\n    " + lines.joined(separator: ",\n    ") + "\n  ]\n}\n"
    try body.write(toFile: "\(outDir)/show.json", atomically: true, encoding: .utf8)
    print("✓ show.json — \(showCases.count) cases "
          + "(\(rankSectionCount) rank multisets, \(suitSectionCount) suit structure, "
          + "\(randomSectionCount) random deals, \(pickedSectionCount) hand-picked)")
}

do {
    var lines: [String] = []
    for k in pegCases {
        let score = flagIDs(CribbageScorer.peggingScore(pile: k.pile, justPlayed: k.played))
        lines.append("{\"pile\":\(jsonArray(k.pile.map(token))),\"played\":\"\(token(k.played))\","
                     + "\"score\":\(jsonArray(score))}")
    }
    let body = "{\n  \"version\": 1,\n  \"cases\": [\n    " + lines.joined(separator: ",\n    ") + "\n  ]\n}\n"
    try body.write(toFile: "\(outDir)/pegging.json", atomically: true, encoding: .utf8)
    print("✓ pegging.json — \(pegCases.count) cases (\(pegRandomCount) from played laps, "
          + "\(pegCases.count - pegRandomCount) hand-picked)")
}

// A quick sanity assertion on the corpus itself: a fixture set that scored nothing anywhere would
// pass on both sides and prove nothing.
let scoredShow = showCases.filter { !CribbageScorer.handScore(hand: $0.hand, starter: $0.starter, isCrib: $0.isCrib).isEmpty }
let best = showCases.map { CribbageScorer.handScore(hand: $0.hand, starter: $0.starter, isCrib: $0.isCrib).totalPoints }.max() ?? 0
print("  \(scoredShow.count)/\(showCases.count) show cases score at least one point; best hand = \(best)")
guard best == 29 else { fatalError("corpus never produces the 29-hand — check section 4") }
