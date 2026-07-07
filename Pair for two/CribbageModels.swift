import Foundation

// MARK: - Deck

/// A standard 52-card deck. Pure and `nonisolated` so shuffles can run off the main actor and be
/// reproduced deterministically by the host referee via a seed.
nonisolated struct Deck: Codable, Sendable {
    private(set) var cards: [Card]

    /// A fresh, ordered 52-card deck (suit-major, Ace → King).
    init() {
        cards = Suit.allCases.flatMap { suit in
            Rank.allCases.map { Card(rank: $0, suit: suit) }
        }
    }

    /// Returns a shuffled deck. When `seed` is supplied the shuffle is deterministic, so the host
    /// can reproduce (and a guest can later verify) the exact deal.
    static func shuffled(seed: UInt64? = nil) -> Deck {
        var deck = Deck()
        if let seed {
            var rng = SeededGenerator(seed: seed)
            deck.cards.shuffle(using: &rng)
        } else {
            deck.cards.shuffle()
        }
        return deck
    }

    /// Removes and returns the top `count` cards.
    mutating func deal(_ count: Int) -> [Card] {
        let dealt = Array(cards.prefix(count))
        cards.removeFirst(min(count, cards.count))
        return dealt
    }

    /// The card at a cut index (wraps around the deck length).
    func card(atCut index: Int) -> Card {
        cards[((index % cards.count) + cards.count) % cards.count]
    }
}

/// A small, deterministic SplitMix64 generator so seeded shuffles are reproducible across devices
/// without depending on the platform's system RNG.
nonisolated struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

// MARK: - Players & seats

/// Which of the two devices/players this is. Stable for the whole match.
nonisolated enum PlayerID: String, Codable, Hashable, Sendable, CaseIterable {
    case one
    case two

    var opponent: PlayerID { self == .one ? .two : .one }
}

/// The role a player holds for a single hand. The dealer owns the crib; the pone leads the pegging.
/// Dealer alternates each hand.
nonisolated enum Seat: String, Codable, Hashable, Sendable {
    case dealer
    case pone

    var other: Seat { self == .dealer ? .pone : .dealer }
}

// MARK: - Scoring mode

/// How the app handles scoring. Chosen by the host; governs the whole game.
nonisolated enum ScoringMode: Int, Codable, Sendable, CaseIterable {
    case auto = 0       // automatically score all play + show feedback
    case feedback = 1   // show scoring feedback (flags), but the players enter points manually
    case off = 2        // no feedback, no auto-scoring — fully manual

    var showsFlags: Bool { self != .off }
    var isAuto: Bool { self == .auto }

    var title: String {
        switch self {
        case .auto:     return "Automatic"
        case .feedback: return "Feedback"
        case .off:      return "Player responsibility"
        }
    }

    var detail: String {
        switch self {
        case .auto:     return "The app counts and adds every score for you."
        case .feedback: return "The app shows each score and the total; you add them on your slider."
        case .off:      return "No hints — you count and add every score yourself."
        }
    }
}

// MARK: - Phases

/// The full lifecycle of a hand/game, driven by the host-authoritative engine.
nonisolated enum GamePhase: String, Codable, Hashable, Sendable {
    case connecting
    case cutForDeal
    case dealing
    case discardToCrib
    case cutStarter       // manual two-step cut: the pone lifts the deck, the dealer reveals the starter
    case pegging
    case showPone
    case showDealer
    case showCrib
    case handComplete
    case gameOver
}
