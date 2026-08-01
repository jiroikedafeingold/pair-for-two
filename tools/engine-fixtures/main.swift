// Engine differential fixtures — the iOS side of the referee contract.
//
// Compiled against the real `CribbageEngine.swift` and `GameState.swift`, so what it emits is by
// construction how the shipping iOS host referees a game. The Android `:core` engine replays every
// script and must reach an identical state after every single step (`EngineFixtureTest`).
//
// Why the whole state after *every* step, rather than just the outcome: the engine's job is turn
// order, phase transitions and rejection of illegal intents. A divergence in "whose turn is it now"
// wouldn't change the final score, it would deadlock a real game — one device waiting for the other
// to play. So each step records the full digest, and each handler's boolean return, since
// "silently ignored" versus "applied" is exactly that class of bug.
//
// ---- What this deliberately does not cover ----
//
// Anything that reshuffles: `dealNewHand`, the cut-for-deal tie recut, and `playAgain`. Swift's
// `shuffle(using:)` consumes a `SeededGenerator` in a way that is a stdlib implementation detail,
// and PLAN.md §0.3 accepts that: the host is the sole referee and ships the resulting deal in its
// snapshots, so the two platforms never re-derive a shuffle from a shared seed. Scripts therefore
// carry an **explicit deck** in their setup and stop before any step that would deal. Those paths
// get structural (not differential) tests on the Kotlin side — see `EngineTest`.
//
// ---- Fixture format ----
//
// Cards are tokens: rank raw value 1…13 plus a suit initial — "1s", "10h", "11d", "13c".
// Flags are `ScoreFlag.id`, i.e. "kind|detail|points".
//
//   engine.json  {"version":1,"scripts":[{"name":…,"setup":{…},"steps":[…],"trace":[digest…]}]}
//
// `trace[i]` is the state after `steps[i]` was applied, and `trace[i].ok` is what the handler
// returned. Deterministic: same source, same bytes.

import Foundation

// MARK: - Tokens

let suitLetters: [Suit: String] = [.spades: "s", .hearts: "h", .diamonds: "d", .clubs: "c"]
func tok(_ c: Card) -> String { "\(c.rank.rawValue)\(suitLetters[c.suit]!)" }
func toks(_ cs: [Card]) -> String { "[" + cs.map { "\"\(tok($0))\"" }.joined(separator: ",") + "]" }
func strs(_ xs: [String]) -> String { "[" + xs.map { "\"\($0)\"" }.joined(separator: ",") + "]" }
func optTok(_ c: Card?) -> String { c.map { "\"\(tok($0))\"" } ?? "null" }
func optStr(_ s: String?) -> String { s.map { "\"\($0)\"" } ?? "null" }
func optInt(_ i: Int?) -> String { i.map(String.init) ?? "null" }

// MARK: - Deterministic RNG (the app's own SplitMix64)

struct Rand {
    private var rng: SeededGenerator
    init(seed: UInt64) { rng = SeededGenerator(seed: seed) }
    mutating func raw() -> UInt64 { rng.next() }
    mutating func int(_ bound: Int) -> Int { bound <= 0 ? 0 : Int(rng.next() % UInt64(bound)) }
    mutating func bool(_ oneIn: Int) -> Bool { int(oneIn) == 0 }
}

// MARK: - Script model

enum Step {
    case begin
    case cut(PlayerID, Int)
    case discard(PlayerID, [Card])
    case lift(PlayerID, Int)
    case reveal(PlayerID)
    case play(PlayerID, Card)
    case go(PlayerID)
    case claim(PlayerID, Int)
    case undo(PlayerID)
    case advance

    var json: String {
        switch self {
        case .begin:                return #"{"do":"begin"}"#
        case .cut(let p, let i):    return #"{"do":"cut","p":"\#(p.rawValue)","i":\#(i)}"#
        case .discard(let p, let c):return #"{"do":"discard","p":"\#(p.rawValue)","cards":\#(toks(c))}"#
        case .lift(let p, let i):   return #"{"do":"lift","p":"\#(p.rawValue)","i":\#(i)}"#
        case .reveal(let p):        return #"{"do":"reveal","p":"\#(p.rawValue)"}"#
        case .play(let p, let c):   return #"{"do":"play","p":"\#(p.rawValue)","card":"\#(tok(c))"}"#
        case .go(let p):            return #"{"do":"go","p":"\#(p.rawValue)"}"#
        case .claim(let p, let n):  return #"{"do":"claim","p":"\#(p.rawValue)","n":\#(n)}"#
        case .undo(let p):          return #"{"do":"undo","p":"\#(p.rawValue)"}"#
        case .advance:              return #"{"do":"advance"}"#
        }
    }
}

/// Applies a step and returns the handler's answer. `begin` returns Void in the Swift API, so it
/// reports `true` — the Kotlin side does the same, keeping the traces comparable.
func apply(_ step: Step, _ s: inout GameState) -> Bool {
    switch step {
    case .begin:                 CribbageEngine.begin(&s); return true
    case .cut(let p, let i):     return CribbageEngine.cutForDeal(&s, player: p, index: i)
    case .discard(let p, let c): return CribbageEngine.discard(&s, player: p, cards: c)
    case .lift(let p, let i):    return CribbageEngine.liftStarterCut(&s, player: p, index: i)
    case .reveal(let p):         return CribbageEngine.revealStarter(&s, player: p)
    case .play(let p, let c):    return CribbageEngine.play(&s, player: p, card: c)
    case .go(let p):             return CribbageEngine.go(&s, player: p)
    case .claim(let p, let n):   return CribbageEngine.claim(&s, player: p, amount: n)
    case .undo(let p):           return CribbageEngine.undo(&s, player: p)
    case .advance:               return CribbageEngine.advance(&s)
    }
}

// MARK: - Digest

/// Everything the two engines must agree on after a step. Written by hand rather than via
/// JSONEncoder so key order is fixed and the fixture stays diffable.
func digest(_ s: GameState, ok: Bool) -> String {
    let seq = s.playSequence.map { "\(tok($0.card)):\($0.player.rawValue)" }
    let claims = s.claimHistory.map { "\($0.player.rawValue):\($0.amount):\($0.phase.rawValue)" }
    let peg = s.lastPegEvent.map { "\($0.kind.rawValue):\($0.scorer.rawValue):\($0.points)" }
    let goes = s.goPlayers.map(\.rawValue).sorted()
    let disc = s.discarded.map(\.rawValue).sorted()

    // Redaction is part of the referee's job — a snapshot that leaked the opponent's hand before
    // the show would be a real bug, and it is cheap to pin here alongside everything else.
    // Quote-free so it can live inside a JSON string: cards joined with "+", absent lists as "-".
    func plain(_ cs: [Card]) -> String { cs.isEmpty ? "" : cs.map(tok).joined(separator: "+") }
    func snap(_ you: PlayerID) -> String {
        let v = s.snapshot(for: you)
        return "\(plain(v.yourHand)):\(v.opponentHandCount):"
            + "\(v.opponentHand.map { plain($0) } ?? "-"):\(v.crib.map { plain($0) } ?? "-"):"
            + "\(v.flags.count):\(v.scoreLog.count):\(v.lapCardCount)"
    }

    return "{"
        + #""ok":\#(ok),"#
        + #""phase":"\#(s.phase.rawValue)","hand":\#(s.handNumber),"dealer":"\#(s.dealer.rawValue)","#
        + #""turn":\#(optStr(s.whoseTurn?.rawValue)),"last":\#(optStr(s.lastToPlay?.rawValue)),"#
        + #""s1":\#(s.scores[.one] ?? 0),"s2":\#(s.scores[.two] ?? 0),"#
        + #""h1":\#(toks(s.hands[.one] ?? [])),"h2":\#(toks(s.hands[.two] ?? [])),"#
        + #""u1":\#(toks(s.unplayed(of: .one))),"u2":\#(toks(s.unplayed(of: .two))),"#
        + #""lap":\#(toks(s.lapCards)),"count":\#(s.runningCount),"seq":\#(strs(seq)),"#
        + #""go":\#(strs(goes)),"flags":\#(strs(s.activeFlags.map(\.id))),"#
        + #""crib":\#(toks(s.crib)),"starter":\#(optTok(s.starter)),"#
        + #""lifted":\#(s.starterCutLifted),"cutIdx":\#(optInt(s.starterCutIndex)),"#
        + #""disc":\#(strs(disc)),"#
        + #""cut1":\#(optTok(s.cutForDeal[.one])),"cut2":\#(optTok(s.cutForDeal[.two])),"#
        + #""ct":\#(s.claimTick),"claims":\#(strs(claims)),"#
        + #""pt":\#(s.pegEventTick),"pe":\#(optStr(peg)),"#
        + #""win":\#(optStr(s.winner?.rawValue)),"allPlayed":\#(s.allCardsPlayed),"#
        + #""snap1":"\#(snap(.one))","snap2":"\#(snap(.two))""#
        + "}"
}

// MARK: - Setup

struct Setup {
    var dealer: PlayerID = .one
    var phase: GamePhase = .discardToCrib
    var scoringMode: ScoringMode = .off
    var handNumber: Int = 1
    var scores: [PlayerID: Int] = [.one: 0, .two: 0]
    var hands: [PlayerID: [Card]] = [.one: [], .two: []]
    var crib: [Card] = []
    var starter: Card?
    var deck: [Card] = []
    var whoseTurn: PlayerID?

    var json: String {
        #"{"dealer":"\#(dealer.rawValue)","phase":"\#(phase.rawValue)","mode":\#(scoringMode.rawValue),"#
        + #""hand":\#(handNumber),"s1":\#(scores[.one] ?? 0),"s2":\#(scores[.two] ?? 0),"#
        + #""h1":\#(toks(hands[.one] ?? [])),"h2":\#(toks(hands[.two] ?? [])),"#
        + #""crib":\#(toks(crib)),"starter":\#(optTok(starter)),"#
        + #""turn":\#(optStr(whoseTurn?.rawValue)),"deck":\#(toks(deck))}"#
    }
}

/// Rebuilds the state a setup describes. The engine's own dealing is bypassed on purpose — see the
/// header — so the deck is installed by dealing the whole explicit list out of a fresh Deck.
func makeState(_ setup: Setup) -> GameState {
    var s = GameState(matchID: UUID(uuidString: "6BA7B810-9DAD-11D1-80B4-00C04FD430C8")!,
                      names: [.one: "Jiro", .two: "Sam"],
                      colorIDs: [.one: 2, .two: 7],
                      dealer: setup.dealer,
                      seed: 0x5EED,
                      deck: Deck())
    s.phase = setup.phase
    s.scoringMode = setup.scoringMode
    s.handNumber = setup.handNumber
    s.scores = setup.scores
    s.hands = setup.hands
    s.crib = setup.crib
    s.starter = setup.starter
    s.whoseTurn = setup.whoseTurn
    s.deck = deckFrom(setup.deck)
    return s
}

/// `Deck.cards` is `private(set)`, so an arbitrary order can't be assigned directly. Searching the
/// seed space for a given order is obviously hopeless — instead every generated deck *comes from*
/// `Deck.shuffled(seed:)`, and this maps a recorded order back by finding that seed's deck. For
/// scripts the emitter builds, the order and the seed are produced together, so this is a lookup.
var deckCache: [String: Deck] = [:]
func deckFrom(_ cards: [Card]) -> Deck {
    let key = cards.map(tok).joined(separator: ",")
    if let d = deckCache[key] { return d }
    fatalError("no deck registered for \(key) — decks must come from registerDeck()")
}

func registerDeck(_ deck: Deck, dropping dealt: Int) -> (Deck, [Card]) {
    var d = deck
    let taken = d.deal(dealt)
    deckCache[d.cards.map(tok).joined(separator: ",")] = d
    return (d, taken)
}

// MARK: - Script assembly

struct Script {
    let name: String
    let setup: Setup
    let steps: [Step]
}

var scripts: [Script] = []

/// Deals a hand from a seeded shuffle and returns the two 6-card hands plus the 40-card remainder,
/// registering that remainder so `makeState` can reconstruct it.
func dealHand(seed: UInt64) -> (one: [Card], two: [Card], rest: Deck) {
    var deck = Deck.shuffled(seed: seed)
    let one = deck.deal(6)
    let two = deck.deal(6)
    deckCache[deck.cards.map(tok).joined(separator: ",")] = deck
    return (one, two, deck)
}

// MARK: Randomised full hands
//
// The bulk of the corpus: a complete hand from discard through the three shows, driven by random
// legal choices, with deliberate illegal intents mixed in so rejection is exercised as heavily as
// acceptance. Starting scores are random, so a good share of scripts run into a win at 121 and
// then keep issuing intents that must all be refused.
do {
    var rand = Rand(seed: 0xE7_1000)
    for n in 0..<140 {
        let (h1, h2, rest) = dealHand(seed: 0xDEA1_0000 &+ UInt64(n))
        let dealer: PlayerID = n % 2 == 0 ? .one : .two
        let mode: ScoringMode = [ScoringMode.off, .feedback, .auto][n % 3]
        // A quarter of scripts start near the finish so the win path gets real coverage.
        let hot = n % 4 == 0
        var setup = Setup()
        setup.dealer = dealer
        setup.scoringMode = mode
        setup.hands = [.one: h1, .two: h2]
        setup.deck = rest.cards
        setup.scores = hot
            ? [.one: 100 + rand.int(18), .two: 100 + rand.int(18)]
            : [.one: rand.int(60), .two: rand.int(60)]

        var s = makeState(setup)
        var steps: [Step] = []
        func run(_ step: Step) { steps.append(step); _ = apply(step, &s) }

        let pone = dealer.opponent

        // Discards. One script in six sends a malformed discard first — wrong count, or a card
        // the player doesn't hold — which must be refused without disturbing the hand.
        if rand.bool(6) {
            run(.discard(pone, [s.hands[pone]![0]]))
            run(.discard(pone, [s.hands[dealer]![0], s.hands[dealer]![1]]))
        }
        for p in [pone, dealer] {
            let hand = s.hands[p]!
            var idx = [Int](0..<hand.count)
            let a = idx.remove(at: rand.int(idx.count))
            let b = idx.remove(at: rand.int(idx.count))
            run(.discard(p, [hand[a], hand[b]]))
        }
        // Discarding twice must be refused.
        if rand.bool(4) { run(.discard(pone, [s.crib[0], s.crib[1]])) }

        // Starter cut. The dealer trying to lift, and the pone trying to reveal, are both illegal.
        if rand.bool(3) { run(.lift(dealer, 5)) }
        run(.lift(pone, rand.int(40)))
        if rand.bool(3) { run(.lift(pone, 11)) }        // already lifted
        if rand.bool(3) { run(.reveal(pone)) }
        run(.reveal(dealer))

        // Pegging.
        var guard_ = 0
        while s.phase == .pegging, let turn = s.whoseTurn, guard_ < 60 {
            guard_ += 1
            let legal = CribbageScorer.legalPlays(hand: s.unplayed(of: turn), count: s.runningCount)
            // Out-of-turn play, and a "go" with a legal play in hand, must both be refused.
            if rand.bool(5), let card = s.unplayed(of: turn.opponent).first {
                run(.play(turn.opponent, card))
            }
            if legal.isEmpty {
                run(.go(turn))
            } else {
                if rand.bool(6) { run(.go(turn)) }
                run(.play(turn, legal[rand.int(legal.count)]))
            }
            // In manual modes, take the flags that were just surfaced — the whole point of the
            // flag-only design is that the *player* does this, so the scripts do it too.
            if mode != .auto, s.activeFlags.totalPoints > 0, rand.bool(2) {
                run(.claim(s.lastToPlay ?? turn, s.activeFlags.totalPoints))
            }
        }

        // The three shows.
        for _ in 0..<4 {
            run(.advance)
            if mode != .auto, s.activeFlags.totalPoints > 0 {
                let scorer: PlayerID
                switch s.phase {
                case .showPone: scorer = s.pone
                default:        scorer = s.dealer
                }
                run(.claim(scorer, s.activeFlags.totalPoints))
                if rand.bool(5) { run(.undo(scorer)) }
                if rand.bool(8) { run(.undo(scorer.opponent)) }
            }
        }
        // A trailing advance from handComplete would deal — deliberately not scripted.
        scripts.append(Script(name: "hand-\(n)", setup: setup, steps: steps))
    }
}
let randomScriptCount = scripts.count

// MARK: Hand-written scripts
//
// Named cases for the transitions that random play reaches rarely or never, so a regression in one
// of them is unmistakable in the diff.
do {
    func c(_ r: Int, _ s: Suit) -> Card { Card(rank: Rank(rawValue: r)!, suit: s) }

    /// Builds a pegging-phase setup with chosen hands and starter, using a registered deck.
    func pegSetup(one: [Card], two: [Card], starter: Card, dealer: PlayerID,
                  mode: ScoringMode = .off, scores: [PlayerID: Int] = [.one: 0, .two: 0]) -> Setup {
        let (rest, _) = registerDeck(Deck.shuffled(seed: 0xB0A2), dropping: 12)
        var setup = Setup()
        setup.phase = .pegging
        setup.dealer = dealer
        setup.scoringMode = mode
        setup.hands = [.one: one, .two: two]
        setup.starter = starter
        setup.deck = rest.cards
        setup.scores = scores
        setup.whoseTurn = dealer.opponent
        return setup
    }

    /// `build` gets a *getter* for the running state rather than an `inout` binding: `run` already
    /// captures it, and handing out a second simultaneous access would trip Swift's exclusivity
    /// checking at runtime.
    func add(_ name: String, _ setup: Setup, _ build: (() -> GameState, (Step) -> Void) -> Void) {
        var s = makeState(setup)
        var steps: [Step] = []
        let run: (Step) -> Void = { step in steps.append(step); _ = apply(step, &s) }
        build({ s }, run)
        scripts.append(Script(name: name, setup: setup, steps: steps))
    }

    // Exactly 31, mid-hand: the lap resets and the lead passes to the other player.
    add("peg-thirty-one", pegSetup(
        one: [c(10, .spades), c(6, .hearts), c(2, .diamonds), c(9, .clubs)],
        two: [c(10, .hearts), c(5, .spades), c(3, .clubs), c(4, .diamonds)],
        starter: c(7, .spades), dealer: .one)) { _, run in
        run(.play(.two, c(10, .hearts)))
        run(.play(.one, c(10, .spades)))
        run(.play(.two, c(5, .spades)))
        run(.play(.one, c(6, .hearts)))     // 31 for 2
        run(.play(.two, c(3, .clubs)))      // new lap, two leads
        run(.play(.one, c(2, .diamonds)))
        run(.play(.two, c(4, .diamonds)))
        run(.play(.one, c(9, .clubs)))      // last card
        run(.advance)
    }

    // A go where the opponent keeps laying, then the lap ends and the go point is flagged.
    add("peg-go-then-continue", pegSetup(
        one: [c(13, .spades), c(12, .hearts), c(1, .diamonds), c(2, .clubs)],
        two: [c(13, .hearts), c(12, .spades), c(11, .clubs), c(10, .diamonds)],
        starter: c(3, .spades), dealer: .one)) { _, run in
        run(.play(.two, c(13, .hearts)))
        run(.play(.one, c(13, .spades)))    // pair, 20
        run(.play(.two, c(12, .spades)))    // 30
        run(.go(.one))                      // one holds only a queen and an ace… ace fits
        run(.play(.one, c(1, .diamonds)))   // 31
        run(.play(.two, c(11, .clubs)))
        run(.play(.one, c(12, .hearts)))
        run(.play(.two, c(10, .diamonds)))
        run(.go(.one))
        run(.play(.one, c(2, .clubs)))
        run(.advance)
    }

    // His heels: a Jack starter must flag 2 for the dealer at the reveal, and in AUTO mode be
    // taken immediately.
    do {
        let (rest, taken) = registerDeck(Deck.shuffled(seed: 0x11AC_C5), dropping: 12)
        // Find a jack in the remaining deck and cut to it.
        let jackIndex = rest.cards.firstIndex { $0.rank == .jack }!
        var setup = Setup()
        setup.phase = .cutStarter
        setup.dealer = .two
        setup.scoringMode = .auto
        setup.hands = [.one: Array(taken.prefix(4)), .two: Array(taken.dropFirst(6).prefix(4))]
        setup.crib = Array(taken[4..<6]) + Array(taken.dropFirst(10).prefix(2))
        setup.deck = rest.cards
        add("starter-his-heels-auto", setup) { _, run in
            run(.reveal(.two))              // refused: nobody has lifted
            run(.lift(.two, jackIndex))     // refused: the dealer may not lift
            run(.lift(.one, jackIndex))
            run(.reveal(.one))              // refused: the pone may not reveal
            run(.reveal(.two))              // his heels, auto-claimed
        }
    }

    // Cut for deal: lower card deals; then a collision where both devices pick the same index.
    do {
        let deck = Deck.shuffled(seed: 0xC0_1DE)
        deckCache[deck.cards.map(tok).joined(separator: ",")] = deck
        var setup = Setup()
        setup.phase = .connecting
        setup.handNumber = 0
        setup.hands = [.one: [], .two: []]
        setup.deck = deck.cards
        add("cut-for-deal-collision", setup) { _, run in
            run(.begin)
            run(.cut(.one, 4))
            run(.cut(.one, 9))     // refused: already cut
            run(.cut(.two, 4))     // same index — must resolve to a different card
        }
        add("cut-for-deal-normal", setup) { _, run in
            run(.begin)
            run(.cut(.two, 17))
            run(.cut(.one, 33))
        }
    }

    // Claim, win, and undo the win — the score must come back down and the phase must be restored
    // to the one the claim was made in, not to whatever came next.
    add("claim-win-undo", pegSetup(
        one: [c(10, .spades), c(6, .hearts), c(2, .diamonds), c(9, .clubs)],
        two: [c(10, .hearts), c(5, .spades), c(3, .clubs), c(4, .diamonds)],
        starter: c(7, .spades), dealer: .one, scores: [.one: 118, .two: 90])) { _, run in
        run(.claim(.one, 0))       // refused: zero is not a claim
        run(.claim(.two, 5))
        run(.claim(.one, 3))       // 121 — game over
        run(.play(.two, c(10, .hearts)))   // refused: the game is over
        run(.claim(.two, 4))       // refused: the game is over
        run(.undo(.one))           // back to 118, phase restored, winner cleared
        run(.play(.two, c(10, .hearts)))   // now legal again
        run(.undo(.one))           // no earlier claim by one… there is none left
        run(.undo(.two))
        run(.undo(.two))           // refused: nothing left to undo
    }

    // The full show sequence with manual claiming, including a claim of the wrong amount (which
    // the engine accepts — scoring is the player's responsibility in this mode).
    do {
        var setup = pegSetup(
            one: [c(5, .spades), c(5, .hearts), c(5, .diamonds), c(11, .clubs)],
            two: [c(1, .spades), c(2, .hearts), c(3, .diamonds), c(4, .clubs)],
            starter: c(5, .clubs), dealer: .one, mode: .feedback)
        setup.crib = [c(6, .spades), c(7, .hearts), c(8, .diamonds), c(9, .clubs)]
        add("show-sequence-manual", setup) { state, run in
            // Play the hand out so pegging finishes, then walk the shows.
            var guard_ = 0
            while state().phase == .pegging, let turn = state().whoseTurn, guard_ < 40 {
                guard_ += 1
                let s = state()
                let legal = CribbageScorer.legalPlays(hand: s.unplayed(of: turn), count: s.runningCount)
                if legal.isEmpty { run(.go(turn)) } else { run(.play(turn, legal[0])) }
            }
            run(.advance)          // showPone — two's hand: a run of four plus fifteens
            run(.claim(.two, 1))   // under-claiming is allowed; the app is a scorekeeper here
            run(.advance)          // showDealer — the 29 hand
            run(.claim(.one, 29))
            run(.advance)          // showCrib
            run(.claim(.one, 4))
            run(.advance)          // handComplete — stop here; a further advance would deal
        }
    }

    // AUTO mode across a whole show: every flag is claimed by the engine itself.
    do {
        var setup = pegSetup(
            one: [c(5, .spades), c(5, .hearts), c(5, .diamonds), c(11, .clubs)],
            two: [c(1, .spades), c(2, .hearts), c(3, .diamonds), c(4, .clubs)],
            starter: c(5, .clubs), dealer: .one, mode: .auto)
        setup.crib = [c(6, .spades), c(7, .hearts), c(8, .diamonds), c(9, .clubs)]
        add("show-sequence-auto", setup) { state, run in
            var guard_ = 0
            while state().phase == .pegging, let turn = state().whoseTurn, guard_ < 40 {
                guard_ += 1
                let s = state()
                let legal = CribbageScorer.legalPlays(hand: s.unplayed(of: turn), count: s.runningCount)
                if legal.isEmpty { run(.go(turn)) } else { run(.play(turn, legal[0])) }
            }
            run(.advance); run(.advance); run(.advance); run(.advance)
        }
    }

    // Out-of-turn and out-of-hand plays, and a play that would break 31.
    add("illegal-plays", pegSetup(
        one: [c(10, .spades), c(10, .hearts), c(10, .diamonds), c(10, .clubs)],
        two: [c(9, .spades), c(9, .hearts), c(9, .diamonds), c(9, .clubs)],
        starter: c(7, .spades), dealer: .one)) { _, run in
        run(.play(.one, c(10, .spades)))    // refused: not one's turn (pone leads)
        run(.play(.two, c(1, .spades)))     // refused: not in hand
        run(.play(.two, c(9, .spades)))
        run(.play(.one, c(10, .spades)))
        run(.play(.two, c(9, .hearts)))     // 28
        run(.play(.one, c(10, .hearts)))    // refused: would reach 38
        run(.go(.one))
        run(.go(.two))                      // refused: not two's turn after the go resolved
        run(.play(.two, c(9, .diamonds)))
        run(.play(.one, c(10, .hearts)))
        run(.play(.two, c(9, .clubs)))
        run(.play(.one, c(10, .diamonds)))
        run(.go(.two))
        run(.play(.one, c(10, .clubs)))
        run(.advance)
    }

    // Malformed discards arriving off the wire. Our own UI can't produce any of these — they exist
    // because the host must referee a peer it doesn't control, and `[X, X]` in particular used to
    // get through, taking one card out of the hand and putting two of it in the crib.
    do {
        let (rest, taken) = registerDeck(Deck.shuffled(seed: 0xD15_CA2D), dropping: 12)
        var setup = Setup()
        setup.phase = .discardToCrib
        setup.dealer = .one
        setup.hands = [.one: Array(taken.prefix(6)), .two: Array(taken.dropFirst(6))]
        setup.deck = rest.cards
        add("discard-malformed", setup) { state, run in
            let pone = state().pone
            let dealer = state().dealer
            let poneHand = state().hands[pone]!
            let dealerHand = state().hands[dealer]!

            run(.discard(pone, [poneHand[0], poneHand[0]]))   // refused: the same card twice
            run(.discard(pone, [poneHand[0]]))                // refused: only one card
            run(.discard(pone, [poneHand[0], poneHand[1], poneHand[2]]))  // refused: three
            run(.discard(pone, []))                           // refused: none
            run(.discard(pone, [poneHand[0], dealerHand[0]])) // refused: not the pone's card
            run(.discard(pone, [poneHand[0], poneHand[1]]))   // accepted
            run(.discard(pone, [poneHand[2], poneHand[3]]))   // refused: already discarded
            run(.discard(dealer, [dealerHand[0], dealerHand[0]]))  // refused: duplicate again
            run(.discard(dealer, [dealerHand[0], dealerHand[1]]))  // accepted — on to the cut
        }
    }

    // Advance from a phase that has nothing to advance to.
    add("advance-noop", pegSetup(
        one: [c(10, .spades), c(6, .hearts), c(2, .diamonds), c(9, .clubs)],
        two: [c(10, .hearts), c(5, .spades), c(3, .clubs), c(4, .diamonds)],
        starter: c(7, .spades), dealer: .one)) { _, run in
        run(.advance)   // refused: pegging is still in progress
        run(.play(.two, c(10, .hearts)))
        run(.advance)   // refused again
    }
}
let pickedScriptCount = scripts.count - randomScriptCount

// MARK: - Emit

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "fixtures/engine-v1"
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

var blocks: [String] = []
var totalSteps = 0
var rejected = 0
var wins = 0

for script in scripts {
    var s = makeState(script.setup)
    var trace: [String] = []
    for step in script.steps {
        let ok = apply(step, &s)
        if !ok { rejected += 1 }
        trace.append(digest(s, ok: ok))
    }
    totalSteps += script.steps.count
    if s.winner != nil { wins += 1 }
    blocks.append("""
        {
          "name": "\(script.name)",
          "setup": \(script.setup.json),
          "steps": [
            \(script.steps.map(\.json).joined(separator: ",\n        "))
          ],
          "trace": [
            \(trace.joined(separator: ",\n        "))
          ]
        }
        """)
}

let body = "{\n  \"version\": 1,\n  \"scripts\": [\n" + blocks.joined(separator: ",\n") + "\n  ]\n}\n"
try body.write(toFile: "\(outDir)/engine.json", atomically: true, encoding: .utf8)

print("✓ engine.json — \(scripts.count) scripts, \(totalSteps) steps "
      + "(\(randomScriptCount) randomised hands, \(pickedScriptCount) hand-written)")
print("  \(rejected) steps were refused as illegal; \(wins) scripts ended in a win")

// The corpus has to actually exercise rejection and the win path, or it would pass on both sides
// while testing only the happy path.
guard rejected > totalSteps / 20 else { fatalError("too few illegal intents in the corpus") }
guard wins > 5 else { fatalError("too few scripts reach a win") }
