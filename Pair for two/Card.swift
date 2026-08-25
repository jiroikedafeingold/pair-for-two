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

    /// Spoken form for VoiceOver, localized, e.g. "Seven of Hearts".
    var accessibleName: String {
        String(localized: "\(rank.spokenName) of \(suit.spokenName)",
               comment: "VoiceOver name of a card: rank, then suit")
    }
}

// MARK: - Localized names

extension Rank {
    /// The letter or number printed on the card face. Localizable because other decks use other
    /// letters for the face cards (German B/D/K, French V/D/R); a translation may equally leave
    /// them as they are.
    var faceLabel: String {
        switch self {
        case .ace:   return String(localized: "A", comment: "Ace, on the card face — one or two letters")
        case .jack:  return String(localized: "J", comment: "Jack, on the card face — one or two letters")
        case .queen: return String(localized: "Q", comment: "Queen, on the card face — one or two letters")
        case .king:  return String(localized: "K", comment: "King, on the card face — one or two letters")
        // Digits read the same in every language, so they need no lookup.
        default:     return String(rawValue)
        }
    }

    /// Spoken rank for VoiceOver.
    var spokenName: String {
        switch self {
        case .ace:   return String(localized: "Ace", comment: "Card rank, spoken")
        case .two:   return String(localized: "Two", comment: "Card rank, spoken")
        case .three: return String(localized: "Three", comment: "Card rank, spoken")
        case .four:  return String(localized: "Four", comment: "Card rank, spoken")
        case .five:  return String(localized: "Five", comment: "Card rank, spoken")
        case .six:   return String(localized: "Six", comment: "Card rank, spoken")
        case .seven: return String(localized: "Seven", comment: "Card rank, spoken")
        case .eight: return String(localized: "Eight", comment: "Card rank, spoken")
        case .nine:  return String(localized: "Nine", comment: "Card rank, spoken")
        case .ten:   return String(localized: "Ten", comment: "Card rank, spoken")
        case .jack:  return String(localized: "Jack", comment: "Card rank, spoken")
        case .queen: return String(localized: "Queen", comment: "Card rank, spoken")
        case .king:  return String(localized: "King", comment: "Card rank, spoken")
        }
    }
}

extension Suit {
    /// Spoken suit for VoiceOver.
    var spokenName: String {
        switch self {
        case .spades:   return String(localized: "Spades", comment: "Card suit, spoken")
        case .hearts:   return String(localized: "Hearts", comment: "Card suit, spoken")
        case .diamonds: return String(localized: "Diamonds", comment: "Card suit, spoken")
        case .clubs:    return String(localized: "Clubs", comment: "Card suit, spoken")
        }
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
