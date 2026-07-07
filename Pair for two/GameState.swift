import Foundation

// MARK: - Played card

/// A card laid on the shared pegging pile, tagged with who played it. Visible to both players.
nonisolated struct PlayedCard: Codable, Hashable, Sendable, Identifiable {
    let card: Card
    let player: PlayerID
    var id: String { "\(card.id)-\(player.rawValue)" }
}

// MARK: - Claim (manual scoring)

/// A manual score entry (from the slider). Recorded so it can be undone. Scoring is flag-only in v1,
/// so *every* point on the board arrives through one of these.
nonisolated struct Claim: Codable, Hashable, Sendable {
    let player: PlayerID
    let amount: Int
    let phase: GamePhase
}

// MARK: - Pegging event (go / 31 notification)

/// A notable pegging moment the *other* device should be nudged about, so the player who earns the
/// point knows to take it. Carried on the snapshot with a monotonically-increasing tick so a repeat
/// (heartbeat) broadcast never re-fires the alert.
nonisolated struct PegEvent: Codable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable { case go, thirtyOne }
    let kind: Kind
    let scorer: PlayerID   // who earns the point(s)
    let points: Int
}

// MARK: - GameState (authoritative, host-only)

/// The single source of truth for a match. Lives only on the host referee. Guests never see this;
/// they receive redacted `PlayerSnapshot`s. Persisted by the host for resume.
nonisolated struct GameState: Codable, Sendable {

    var matchID: UUID
    var phase: GamePhase = .connecting
    var handNumber: Int = 0
    var scoringMode: ScoringMode = .feedback

    // Players
    var names: [PlayerID: String]
    var colorIDs: [PlayerID: Int]
    var scores: [PlayerID: Int] = [.one: 0, .two: 0]

    // Deal
    var dealer: PlayerID
    var seed: UInt64
    var deck: Deck
    var hands: [PlayerID: [Card]] = [.one: [], .two: []]
    var crib: [Card] = []
    var starter: Card?
    var discarded: Set<PlayerID> = []

    // Starter cut (manual two-step: the pone lifts the deck, then the dealer reveals the starter)
    var starterCutIndex: Int?          // set when the pone lifts; the reveal derives the starter from it
    var starterCutLifted: Bool = false

    // Cut for deal
    var cutForDeal: [PlayerID: Card] = [:]

    // Pegging
    var playSequence: [PlayedCard] = []   // full play history for the current hand (both players see)
    var lapCards: [Card] = []             // cards played since the last reset (a go or a 31)
    var whoseTurn: PlayerID?
    var goPlayers: Set<PlayerID> = []     // who has said "go" in the current lap
    var lastToPlay: PlayerID?             // who laid the most recent card (for last-card & next lead)

    // Scoring assist (surfaced to the coach UI, never auto-applied)
    var activeFlags: [ScoreFlag] = []
    var claimHistory: [Claim] = []
    var claimTick: Int = 0            // increments on each claim, so devices can preview "+X"

    // Pegging event alert (go / 31) — bumps on each event so the other device can prompt "take the score".
    var pegEventTick: Int = 0
    var lastPegEvent: PegEvent?

    var winner: PlayerID?

    /// The pone is always the dealer's opponent.
    var pone: PlayerID { dealer.opponent }

    /// Running pegging count for the current lap.
    var runningCount: Int { lapCards.reduce(0) { $0 + $1.countingValue } }

    /// The seat a given player holds this hand.
    func seat(of player: PlayerID) -> Seat {
        player == dealer ? .dealer : .pone
    }

    /// A player's cards not yet laid on the pegging pile. The 4-card `hands` stay intact through the
    /// whole hand (they're needed for the show); pegging progress is tracked via `playSequence`.
    func unplayed(of player: PlayerID) -> [Card] {
        let played = Set(playSequence.filter { $0.player == player }.map(\.card))
        return (hands[player] ?? []).filter { !played.contains($0) }
    }

    /// True once every card has been laid during pegging.
    var allCardsPlayed: Bool {
        unplayed(of: .one).isEmpty && unplayed(of: .two).isEmpty
    }

    /// A fresh state for a brand-new match. `dealer` here is provisional; the real dealer is decided
    /// by the cut-for-deal phase.
    static func newMatch(matchID: UUID,
                         seed: UInt64,
                         names: [PlayerID: String],
                         colorIDs: [PlayerID: Int],
                         scoringMode: ScoringMode = .feedback) -> GameState {
        GameState(matchID: matchID,
                  scoringMode: scoringMode,
                  names: names,
                  colorIDs: colorIDs,
                  dealer: .one,
                  seed: seed,
                  deck: Deck.shuffled(seed: seed))
    }
}

// MARK: - Snapshot redaction

extension GamePhase {
    /// Ordinal used to decide when hidden information becomes visible.
    private var revealRank: Int {
        switch self {
        case .connecting:    return 0
        case .cutForDeal:    return 1
        case .dealing:       return 2
        case .discardToCrib: return 3
        case .cutStarter:    return 4
        case .pegging:       return 5
        case .showPone:      return 6
        case .showDealer:    return 7
        case .showCrib:      return 8
        case .handComplete:  return 9
        case .gameOver:      return 10
        }
    }

    /// At the show, both hands and the starter become visible to both devices.
    var revealsHands: Bool { revealRank >= GamePhase.showPone.revealRank }

    /// The crib is only exposed once counting reaches it.
    var revealsCrib: Bool { revealRank >= GamePhase.showCrib.revealRank }
}

extension GameState {
    /// Builds the redacted view for one device. The opponent's hole cards are only ever included once
    /// the phase reveals hands — before that the wire literally never carries them.
    func snapshot(for you: PlayerID) -> PlayerSnapshot {
        let opponent = you.opponent
        let reveal = phase.revealsHands
        // During pegging a player sees only their still-unplayed cards; at the show, the full 4.
        let yourVisibleHand = phase == .pegging ? unplayed(of: you) : (hands[you] ?? [])
        return PlayerSnapshot(
            matchID: matchID,
            you: you,
            phase: phase,
            yourSeat: seat(of: you),
            dealer: dealer,
            yourHand: yourVisibleHand,
            opponentHandCount: phase == .pegging ? unplayed(of: opponent).count : (hands[opponent]?.count ?? 0),
            opponentHand: reveal ? hands[opponent] : nil,
            crib: phase.revealsCrib ? crib : nil,
            cribCount: crib.count,
            starter: starter,
            starterCutLifted: starterCutLifted,
            playSequence: playSequence,
            runningCount: runningCount,
            lapCardCount: lapCards.count,
            whoseTurn: whoseTurn,
            lastToPlay: lastToPlay,
            yourScore: scores[you] ?? 0,
            opponentScore: scores[opponent] ?? 0,
            flags: scoringMode.showsFlags ? activeFlags : [],
            scoringMode: scoringMode,
            cutForDeal: cutForDeal,
            winner: winner,
            yourName: names[you] ?? "You",
            opponentName: names[opponent] ?? "Opponent",
            yourColorID: colorIDs[you] ?? 0,
            opponentColorID: colorIDs[opponent] ?? 1,
            playersWithClaims: Set(claimHistory.map(\.player)),
            claimTick: claimTick,
            lastClaimPlayer: claimHistory.last?.player,
            lastClaimAmount: claimHistory.last?.amount ?? 0,
            pegEventTick: pegEventTick,
            lastPegEvent: lastPegEvent
        )
    }
}

// MARK: - PlayerSnapshot (redacted, sent over the wire)

/// The per-device view of the game. Your hand is full; the opponent's is hidden (count only) until a
/// reveal phase. Everything here is safe to send to `you` — it never contains the opponent's hole cards
/// before the show.
nonisolated struct PlayerSnapshot: Codable, Hashable, Sendable {
    let matchID: UUID
    let you: PlayerID
    let phase: GamePhase
    let yourSeat: Seat
    let dealer: PlayerID

    let yourHand: [Card]
    let opponentHandCount: Int
    let opponentHand: [Card]?      // non-nil only at the show
    let crib: [Card]?              // non-nil only once counting reaches the crib
    let cribCount: Int
    let starter: Card?
    /// During the manual starter cut, true once the pone has lifted the deck (so both devices can show
    /// the lifted portion set aside, awaiting the dealer's reveal).
    let starterCutLifted: Bool

    let playSequence: [PlayedCard]
    let runningCount: Int
    /// How many trailing `playSequence` cards belong to the current count (lap). Earlier cards were
    /// played in a prior lap (count already reset via a go or 31) and are shown greyed/out of play.
    let lapCardCount: Int
    let whoseTurn: PlayerID?
    let lastToPlay: PlayerID?

    let yourScore: Int
    let opponentScore: Int

    let flags: [ScoreFlag]
    let scoringMode: ScoringMode
    let cutForDeal: [PlayerID: Card]
    let winner: PlayerID?

    let yourName: String
    let opponentName: String
    let yourColorID: Int
    let opponentColorID: Int

    /// Players that currently have at least one undoable claim (so the guest, which holds no
    /// authoritative state, can still enable/disable its undo button).
    let playersWithClaims: Set<PlayerID>

    /// Increments on each claim; the most recent claim's player + amount, so the *other* device can
    /// preview "+X" next to that player's score before it lands.
    let claimTick: Int
    let lastClaimPlayer: PlayerID?
    let lastClaimAmount: Int

    /// A go/31 alert for the other device (see `PegEvent`). `pegEventTick` de-dupes heartbeat repeats.
    let pegEventTick: Int
    let lastPegEvent: PegEvent?

    /// True when it is this device's turn to act during pegging.
    var isYourTurn: Bool { whoseTurn == you }

    /// Whether the pone (non-dealer) leads — used by coach banners.
    var pone: PlayerID { dealer.opponent }
}
