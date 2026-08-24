import Foundation

/// Which edge of the phone a player is sitting at. The phone lies flat between them, so one player's
/// half of the screen is upside down from the other's — the side is what decides which way up a half
/// is drawn, not who is "first".
nonisolated enum BoardSide: String, Codable, Sendable, CaseIterable {
    case bottom, top
    var other: BoardSide { self == .bottom ? .top : .bottom }
}

/// A game played with real cards where the app is only the board: two pegging sliders and the race to
/// 121. Nothing here knows about hands, the crib or the cut, because the app never sees them — which is
/// exactly the point. Deliberately not built on `GameState`/`CribbageEngine`: those exist to referee a
/// two-phone game through its phases over a wire protocol, none of which applies to a scoreboard.
nonisolated struct BoardGame: Codable, Sendable, Equatable {

    /// One peg forward, kept so it can be taken back. `amount` is what was actually *applied* after the
    /// cap at 121, so undoing it always lands back exactly where the score was.
    struct Peg: Codable, Sendable, Equatable, Identifiable {
        var id = UUID()
        let side: BoardSide
        let amount: Int
    }

    /// Game point. Points beyond it are void — you stop the moment you get there.
    static let gamePoint = 121

    private(set) var bottom = 0
    private(set) var top = 0
    private(set) var pegs: [Peg] = []
    var startedAt = Date()

    func score(_ side: BoardSide) -> Int { side == .bottom ? bottom : top }

    /// Whoever has reached 121. Only one can: pegging stops there.
    var winner: BoardSide? {
        if bottom >= Self.gamePoint { return .bottom }
        if top >= Self.gamePoint { return .top }
        return nil
    }

    var isFinished: Bool { winner != nil }
    /// True once anything has been pegged — what decides whether there's a game worth resuming.
    var hasProgress: Bool { !pegs.isEmpty }

    /// The loser's score, for the skunk lines. Zero-ish games included: this is only meaningful once
    /// somebody has won.
    var loserScore: Int { min(bottom, top) }

    /// Peg `amount` forward for `side`, capped at game point. Ignored once the game is over, and
    /// ignored for a non-positive amount so a stray zero can't clutter the undo history.
    mutating func add(_ amount: Int, to side: BoardSide) {
        guard !isFinished, amount > 0 else { return }
        let current = score(side)
        let applied = min(amount, Self.gamePoint - current)
        guard applied > 0 else { return }
        switch side {
        case .bottom: bottom += applied
        case .top:    top += applied
        }
        pegs.append(Peg(side: side, amount: applied))
    }

    /// Take back this side's most recent peg. Works after the game has been won, so a mis-tapped
    /// winning peg can be corrected — the same latitude the in-game undo has.
    mutating func undo(_ side: BoardSide) {
        guard let index = pegs.lastIndex(where: { $0.side == side }) else { return }
        let peg = pegs.remove(at: index)
        switch side {
        case .bottom: bottom = max(0, bottom - peg.amount)
        case .top:    top = max(0, top - peg.amount)
        }
    }

    func canUndo(_ side: BoardSide) -> Bool { pegs.contains { $0.side == side } }
}

// MARK: - Store

/// The board's own saved game, so a game interrupted mid-way can be picked back up.
///
/// Its own file on purpose: the two-phone game's resume marker decides whether the menu offers to
/// rejoin a *networked* game, and a scoreboard has no business touching that.
nonisolated enum BoardGameStore {
    private static let filename = "pairfortwo-board.json"

    private static var url: URL? {
        let fm = FileManager.default
        guard let dir = try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                    appropriateFor: nil, create: true) else { return nil }
        return dir.appendingPathComponent(filename)
    }

    /// Saves a game in progress; a finished or untouched one is cleared instead, so there's never a
    /// stale "resume" offering a game that's over.
    static func save(_ game: BoardGame) {
        guard game.hasProgress, !game.isFinished else { clear(); return }
        guard let url, let data = try? JSONEncoder().encode(game) else { return }
        try? data.write(to: url, options: .atomic)
    }

    static func load() -> BoardGame? {
        guard let url, let data = try? Data(contentsOf: url),
              let game = try? JSONDecoder().decode(BoardGame.self, from: data),
              game.hasProgress, !game.isFinished else { return nil }
        return game
    }

    static func clear() {
        guard let url else { return }
        try? FileManager.default.removeItem(at: url)
    }
}
