import Foundation

// MARK: - Suit

/// The four French-deck suits. Pure value type, safe to use off the main actor.
nonisolated enum Suit: String, CaseIterable, Codable, Hashable, Sendable, Identifiable {
    case spades
    case hearts
    case diamonds
    case clubs

    var id: String { rawValue }

    /// The glyph drawn on a card face.
    var symbol: String {
        switch self {
        case .spades:   return "♠"
        case .hearts:   return "♥"
        case .diamonds: return "♦"
        case .clubs:    return "♣"
        }
    }

    /// Hearts and diamonds are drawn in red; spades and clubs in near-black.
    var isRed: Bool {
        self == .hearts || self == .diamonds
    }
}

// MARK: - Rank

/// Card ranks Ace through King.
nonisolated enum Rank: Int, CaseIterable, Codable, Hashable, Sendable, Comparable, Identifiable {
    case ace = 1
    case two
    case three
    case four
    case five
    case six
    case seven
    case eight
    case nine
    case ten
    case jack
    case queen
    case king

    var id: Int { rawValue }

    /// Value used for pegging and fifteens: Ace = 1, face cards = 10, others = pip value.
    var countingValue: Int {
        min(rawValue, 10)
    }

    /// Value used for detecting runs: Ace = 1 … King = 13 (faces are distinct, unlike counting value).
    var orderValue: Int {
        rawValue
    }

    /// Short label shown on a card corner ("A", "2" … "10", "J", "Q", "K").
    var label: String {
        switch self {
        case .ace:   return "A"
        case .jack:  return "J"
        case .queen: return "Q"
        case .king:  return "K"
        default:     return String(rawValue)
        }
    }

    static func < (lhs: Rank, rhs: Rank) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

// MARK: - Card

/// A single playing card. `Identifiable` by its rank+suit, which are unique within a standard deck.
nonisolated struct Card: Codable, Hashable, Sendable, Identifiable {
    let rank: Rank
    let suit: Suit

    var id: String { "\(rank.rawValue)\(suit.rawValue)" }

    /// Convenience for pegging / fifteen arithmetic.
    var countingValue: Int { rank.countingValue }

    /// Convenience for run detection.
    var orderValue: Int { rank.orderValue }

    /// e.g. "A♠", "10♥", "K♣" — compact debug/label form.
    var shortName: String { "\(rank.label)\(suit.symbol)" }

    /// Spoken form for VoiceOver, e.g. "Seven of Hearts".
    var accessibleName: String {
        let rankName: String
        switch rank {
        case .ace:   rankName = "Ace"
        case .two:   rankName = "Two"
        case .three: rankName = "Three"
        case .four:  rankName = "Four"
        case .five:  rankName = "Five"
        case .six:   rankName = "Six"
        case .seven: rankName = "Seven"
        case .eight: rankName = "Eight"
        case .nine:  rankName = "Nine"
        case .ten:   rankName = "Ten"
        case .jack:  rankName = "Jack"
        case .queen: rankName = "Queen"
        case .king:  rankName = "King"
        }
        let suitName: String
        switch suit {
        case .spades:   suitName = "Spades"
        case .hearts:   suitName = "Hearts"
        case .diamonds: suitName = "Diamonds"
        case .clubs:    suitName = "Clubs"
        }
        return "\(rankName) of \(suitName)"
    }
}

// MARK: - Display sorting

extension Suit {
    /// Order suits appear in a sorted hand (spades, hearts, diamonds, clubs).
    var displayOrder: Int {
        switch self {
        case .spades:   return 0
        case .hearts:   return 1
        case .diamonds: return 2
        case .clubs:    return 3
        }
    }
}

extension Card {
    /// Stable key for laying a hand out: by rank (Ace → King), then by suit.
    var displaySortKey: Int { rank.orderValue * 4 + suit.displayOrder }
}

extension Array where Element == Card {
    /// A copy sorted for display — by rank, then suit.
    func sortedForDisplay() -> [Card] { sorted { $0.displaySortKey < $1.displaySortKey } }
}
