import Foundation

// MARK: - CribbageEngine

/// The host-authoritative referee. Pure and `nonisolated`: it validates *intents* and mutates the
/// canonical `GameState`, advancing phases. It never auto-applies points — scoring stays manual
/// (flag-only) — but it *surfaces* every scoring opportunity in `state.activeFlags`.
///
/// Every handler returns `false` for an illegal/out-of-turn intent (the host simply ignores it) and
/// `true` when the intent was applied.
nonisolated enum CribbageEngine {

    // MARK: Lifecycle

    /// Move from `.connecting` into the opening cut-for-deal.
    static func begin(_ s: inout GameState) {
        s.phase = .cutForDeal
        s.cutForDeal = [:]
        s.activeFlags = []
    }

    // MARK: Cut for deal

    /// Each player cuts once; the **lower** card wins the deal (and therefore the first crib). A tie
    /// triggers a reshuffle and recut. Both cut cards stay on the table so each player sees the other's
    /// — dealing then happens on the next `advance` (the "Deal" tap), not automatically.
    @discardableResult
    static func cutForDeal(_ s: inout GameState, player: PlayerID, index: Int) -> Bool {
        guard s.phase == .cutForDeal, s.cutForDeal[player] == nil else { return false }

        // Two players can never cut the same physical card. Each device generates its cut index
        // independently and they can collide, so if this draw matches the opponent's, take a
        // different position of the deck (a genuine same-rank tie with *different* cards still recuts).
        var card = s.deck.card(atCut: index)
        if let other = s.cutForDeal[player.opponent], card == other {
            card = s.deck.card(atCut: index + 26)
        }
        s.cutForDeal[player] = card

        guard let a = s.cutForDeal[.one], let b = s.cutForDeal[.two] else { return true }
        if a.orderValue == b.orderValue {
            // Genuine tie (two different cards, same rank) — reshuffle and recut.
            s.cutForDeal = [:]
            s.seed = s.seed &+ 0x1111_1111
            s.deck = Deck.shuffled(seed: s.seed)
        } else {
            // Lower card deals and takes the crib. Hold here so the result is visible; `advance` deals.
            s.dealer = a.orderValue < b.orderValue ? .one : .two
        }
        return true
    }

    /// True once both players have cut for deal and the dealer is decided (result is on show).
    static func cutForDealDecided(_ s: GameState) -> Bool {
        s.phase == .cutForDeal && s.cutForDeal.count == 2
    }

    // MARK: Deal

    /// Shuffle a fresh deck for the hand and deal 6 to each player. Leaves the remaining 40 in the
    /// deck for the starter cut. Advances to `.discardToCrib`.
    static func dealNewHand(_ s: inout GameState) {
        s.handNumber += 1
        var deck = Deck.shuffled(seed: s.seed &+ (UInt64(s.handNumber) &* 0x9E37_79B9))
        s.hands[.one] = deck.deal(6)
        s.hands[.two] = deck.deal(6)
        s.deck = deck
        s.crib = []
        s.discarded = []
        s.starter = nil
        s.playSequence = []
        s.lapCards = []
        s.goPlayers = []
        s.lastToPlay = nil
        s.whoseTurn = nil
        s.activeFlags = []
        s.phase = .discardToCrib
    }

    // MARK: Discard to crib

    /// A player lays 2 cards into the crib. When both have discarded, the starter is cut automatically
    /// and pegging begins (there is no separate manual starter-cut step).
    @discardableResult
    static func discard(_ s: inout GameState, player: PlayerID, cards: [Card]) -> Bool {
        guard s.phase == .discardToCrib, !s.discarded.contains(player), cards.count == 2 else { return false }
        guard let hand = s.hands[player], cards.allSatisfy(hand.contains) else { return false }

        s.hands[player]?.removeAll { cards.contains($0) }
        s.crib.append(contentsOf: cards)
        s.discarded.insert(player)

        if s.discarded.count == 2 {
            beginPegging(&s)
        }
        return true
    }

    /// Auto-cuts the starter and begins pegging (pone leads). A Jack starter flags "His Heels" (2 for
    /// the dealer). The starter is not shown during the play — only at the show — but the his-heels
    /// flag is surfaced now so the dealer can peg it.
    private static func beginPegging(_ s: inout GameState) {
        let index = Int(s.seed % 47) &+ s.handNumber &* 13 &+ 7
        let starter = s.deck.card(atCut: index)
        s.starter = starter
        s.activeFlags = CribbageScorer.isHisHeels(starter: starter)
            ? [ScoreFlag(.hisHeels, points: 2, detail: "His Heels — 2 for dealer")]
            : []

        s.phase = .pegging
        s.lapCards = []
        s.playSequence = []
        s.goPlayers = []
        s.lastToPlay = nil
        s.whoseTurn = s.pone       // pone leads the play
    }

    // MARK: Pegging — play a card

    @discardableResult
    static func play(_ s: inout GameState, player: PlayerID, card: Card) -> Bool {
        guard s.phase == .pegging, s.whoseTurn == player else { return false }
        guard s.unplayed(of: player).contains(card) else { return false }
        guard s.runningCount + card.countingValue <= 31 else { return false }

        s.playSequence.append(PlayedCard(card: card, player: player))
        s.lapCards.append(card)
        s.lastToPlay = player

        var flags = CribbageScorer.peggingScore(pile: s.lapCards, justPlayed: card)
        let count = s.runningCount
        let done = s.allCardsPlayed

        if count == 31 {
            s.activeFlags = flags                      // "31 for 2" already included
            if done { finishPegging(&s) } else { resetLap(&s, nextLeadPreferring: player.opponent) }
            return true
        }

        if done {
            flags.append(ScoreFlag(.lastCard, points: 1, detail: "Last card"))
            s.activeFlags = flags
            finishPegging(&s)
            return true
        }

        s.activeFlags = flags
        // Turn passes to the opponent unless they've gone or are out of cards, in which case you
        // continue laying.
        let opp = player.opponent
        let oppInPlay = !s.goPlayers.contains(opp) && !s.unplayed(of: opp).isEmpty
        s.whoseTurn = oppInPlay ? opp : player
        return true
    }

    // MARK: Pegging — say "go"

    @discardableResult
    static func go(_ s: inout GameState, player: PlayerID) -> Bool {
        guard s.phase == .pegging, s.whoseTurn == player else { return false }
        // A player may only say "go" with no legal play available.
        guard CribbageScorer.legalPlays(hand: s.unplayed(of: player), count: s.runningCount).isEmpty else { return false }

        s.goPlayers.insert(player)
        let opp = player.opponent
        let oppCanPlay = !s.goPlayers.contains(opp)
            && !CribbageScorer.legalPlays(hand: s.unplayed(of: opp), count: s.runningCount).isEmpty

        if oppCanPlay {
            s.whoseTurn = opp                          // opponent keeps laying until they also can't
            return true
        }

        // Neither can add — the lap ends. Last player to lay a card pegs 1 for the go.
        s.activeFlags = [ScoreFlag(.go, points: 1, detail: "Go")]
        if s.allCardsPlayed {
            finishPegging(&s)
        } else {
            resetLap(&s, nextLeadPreferring: (s.lastToPlay ?? player).opponent)
        }
        return true
    }

    /// Clears the current lap and hands the lead to `preferred` (or the other player if `preferred`
    /// is out of cards). If both are out, pegging is finished.
    private static func resetLap(_ s: inout GameState, nextLeadPreferring preferred: PlayerID) {
        s.lapCards = []
        s.goPlayers = []
        if !s.unplayed(of: preferred).isEmpty {
            s.whoseTurn = preferred
        } else if !s.unplayed(of: preferred.opponent).isEmpty {
            s.whoseTurn = preferred.opponent
        } else {
            finishPegging(&s)
        }
    }

    /// Pegging is over. Keep the final flags visible for claiming; the show starts on `advance`.
    private static func finishPegging(_ s: inout GameState) {
        s.whoseTurn = nil
        s.lapCards = []
        s.goPlayers = []
    }

    // MARK: The show

    private static func beginShow(_ s: inout GameState, phase: GamePhase) {
        s.phase = phase
        guard let starter = s.starter else { s.activeFlags = []; return }
        switch phase {
        case .showPone:
            s.activeFlags = CribbageScorer.handScore(hand: s.hands[s.pone] ?? [], starter: starter, isCrib: false)
        case .showDealer:
            s.activeFlags = CribbageScorer.handScore(hand: s.hands[s.dealer] ?? [], starter: starter, isCrib: false)
        case .showCrib:
            s.activeFlags = CribbageScorer.handScore(hand: s.crib, starter: starter, isCrib: true)
        default:
            s.activeFlags = []
        }
    }

    // MARK: Manual scoring

    /// Apply a manual claim from the slider. Reaching 121 wins the game immediately.
    @discardableResult
    static func claim(_ s: inout GameState, player: PlayerID, amount: Int) -> Bool {
        guard s.phase != .gameOver, amount > 0 else { return false }
        s.scores[player, default: 0] += amount
        s.claimHistory.append(Claim(player: player, amount: amount, phase: s.phase))
        s.claimTick += 1
        if (s.scores[player] ?? 0) >= 121 {
            s.winner = player
            s.whoseTurn = nil
            s.phase = .gameOver
        }
        return true
    }

    /// Undo a player's most recent claim (restores the pre-win phase if it had ended the game).
    @discardableResult
    static func undo(_ s: inout GameState, player: PlayerID) -> Bool {
        guard let idx = s.claimHistory.lastIndex(where: { $0.player == player }) else { return false }
        let claim = s.claimHistory.remove(at: idx)
        s.scores[player, default: 0] -= claim.amount
        if s.winner == player, (s.scores[player] ?? 0) < 121 {
            s.winner = nil
            if s.phase == .gameOver { s.phase = claim.phase }
        }
        return true
    }

    // MARK: Advancing steps ("Continue")

    /// Advance the show sub-phases, finish pegging into the show, and start the next hand.
    @discardableResult
    static func advance(_ s: inout GameState) -> Bool {
        switch s.phase {
        case .cutForDeal where cutForDealDecided(s):
            dealNewHand(&s); return true
        case .pegging where s.whoseTurn == nil:
            beginShow(&s, phase: .showPone); return true
        case .showPone:
            beginShow(&s, phase: .showDealer); return true
        case .showDealer:
            beginShow(&s, phase: .showCrib); return true
        case .showCrib:
            s.phase = .handComplete
            s.activeFlags = []
            return true
        case .handComplete:
            s.dealer = s.dealer.opponent   // deal passes to the former pone
            s.cutForDeal = [:]
            dealNewHand(&s)
            return true
        default:
            return false
        }
    }

    // MARK: Play again

    /// Reset scores and start a fresh game (keeps names/colors, opens with a new cut for deal).
    static func playAgain(_ s: inout GameState) {
        var fresh = GameState.newMatch(matchID: s.matchID,
                                       seed: s.seed &+ 0x7777_7777,
                                       names: s.names,
                                       colorIDs: s.colorIDs)
        fresh.phase = .cutForDeal
        s = fresh
    }
}
