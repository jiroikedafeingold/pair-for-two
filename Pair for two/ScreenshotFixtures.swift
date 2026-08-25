import SwiftUI

#if DEBUG

// MARK: - App Store screenshot fixtures
//
// The source of the App Store screenshots. Rules these previews exist to keep (Marketing/README.md):
//
//   * **Player responsibility scoring** (`ScoringMode.off`) in every shot — it's the app's default,
//     so it's what a new player sees. `.feedback` puts coach chips on the rail that most people
//     never see.
//   * **Never capture through the debug pass-and-play path.** The ordinary previews in
//     `GameTableView.swift` drive `GameViewModel.loopback`, where one phone rotates to whoever is
//     acting — a mode compiled out of release, so shots taken there aren't the shipping experience.
//     These build a `GameState` with the engine instead, redact it into the snapshot the guest would
//     really receive, and push it through the normal guest path with the seat fixed to `.two`.
//
// Render each preview below at the required device and scale it to Apple's exact pixels:
// iPhone 6.9" → 2868 × 1320, iPad 13" → 2752 × 2064.

/// Set while the screenshot previews render, so `DealtCardsRow` starts fully dealt rather than
/// animating cards in — a preview snapshot is taken on the first frame, where the animation has
/// revealed nothing and the table photographs empty.
nonisolated(unsafe) var dealsCardsInstantly = false

/// Stands in for a host: delivers one prepared snapshot, then holds the line open.
nonisolated final class PreviewSnapshotTransport: GameTransport, Sendable {

    let isHost = false
    let events: AsyncStream<TransportEvent>

    init(_ snapshot: PlayerSnapshot) {
        var captured: AsyncStream<TransportEvent>.Continuation!
        events = AsyncStream(bufferingPolicy: .unbounded) { captured = $0 }
        captured.yield(.connected)
        captured.yield(.received(.assignSeat(snapshot.you)))
        captured.yield(.received(.snapshot(snapshot)))
        // Deliberately not finished: an ended stream would read as the host hanging up.
    }

    /// A screenshot never acts, and there's no peer to act on.
    func send(_ message: GameMessage) async {}
}

/// Builds the game positions the shots are taken from. Every one is a legal state reached by driving
/// the real engine, so nothing in the frame can be a state the game couldn't actually be in.
enum ScreenshotFixture {

    private static let names: [PlayerID: String] = [.one: "Ann", .two: "Ben"]
    private static let colorIDs: [PlayerID: Int] = [.one: 1, .two: 7]

    /// A dealt hand with the guest (`.two`) as pone — the seat every shot is taken from, because the
    /// pone lifts the starter cut, leads the play, and counts first.
    private static func dealt(seed: UInt64) -> GameState {
        var s = GameState.newMatch(matchID: UUID(), seed: seed, names: names,
                                   colorIDs: colorIDs, scoringMode: .off)
        CribbageEngine.begin(&s)
        s.dealer = .one
        CribbageEngine.dealNewHand(&s)
        for player in [PlayerID.one, .two] {
            let hand = s.hands[player] ?? []
            CribbageEngine.discard(&s, player: player, cards: Array(hand.suffix(2)))
        }
        return s
    }

    /// Lay the next card (or say go) for whoever is on turn.
    private static func playOne(_ s: inout GameState) {
        guard let turn = s.whoseTurn else { return }
        let legal = CribbageScorer.legalPlays(hand: s.unplayed(of: turn), count: s.runningCount)
        if let card = legal.first {
            CribbageEngine.play(&s, player: turn, card: card)
        } else {
            CribbageEngine.go(&s, player: turn)
        }
    }

    private static func cutStarter(_ s: inout GameState) {
        CribbageEngine.liftStarterCut(&s, player: s.pone, index: 17)
        CribbageEngine.revealStarter(&s, player: s.dealer)
    }

    private static func score(_ s: inout GameState, ann: Int, ben: Int) {
        CribbageEngine.claim(&s, player: .one, amount: ann)
        CribbageEngine.claim(&s, player: .two, amount: ben)
    }

    /// Shot 1 — mid-play: cards on the pile, a running count worth reading, and the guest holding
    /// cards they can actually play. Seeds are searched because the first position to hand is often
    /// "no card to play — say Go", which shows a greyed-out hand and explains nothing.
    static func pegging() -> PlayerSnapshot {
        for bump in 0..<400 {
            var s = dealt(seed: 2000 &+ UInt64(bump))
            cutStarter(&s)
            score(&s, ann: 62, ben: 71)
            var steps = 0
            while s.whoseTurn != nil, steps < 12 {
                if s.whoseTurn == .two, s.playSequence.count >= 2, (10...24).contains(s.runningCount),
                   s.unplayed(of: .two).count >= 3,
                   !CribbageScorer.legalPlays(hand: s.unplayed(of: .two), count: s.runningCount).isEmpty {
                    return s.snapshot(for: .two)
                }
                playOne(&s)
                steps += 1
            }
        }
        var s = dealt(seed: 2000)
        cutStarter(&s)
        score(&s, ann: 62, ben: 71)
        return s.snapshot(for: .two)
    }

    /// Shot 2 — the show: the guest counting their own hand against the starter. Seeds are searched
    /// for a hand worth photographing; a screenshot of "four points" undersells the moment.
    static func show() -> PlayerSnapshot {
        var fallback: GameState?
        for bump in 0..<400 {
            var s = dealt(seed: 4000 &+ UInt64(bump))
            cutStarter(&s)
            var steps = 0
            while s.phase == .pegging, s.whoseTurn != nil, steps < 20 { playOne(&s); steps += 1 }
            CribbageEngine.advance(&s)          // pegging → showPone, which is the guest's hand
            guard s.phase == .showPone else { continue }
            score(&s, ann: 44, ben: 51)
            if s.activeFlags.totalPoints >= 12 { return s.snapshot(for: .two) }
            if fallback == nil { fallback = s }
        }
        return (fallback ?? dealt(seed: 4000)).snapshot(for: .two)
    }

    /// Shot 3 — the in-person cut: the guest is the pone, so the deck is theirs to cut.
    static func starterCut() -> PlayerSnapshot {
        var s = dealt(seed: 21)
        score(&s, ann: 38, ben: 46)
        return s.snapshot(for: .two)
    }

    /// Shot 4 — the win, with the loser under 91 so it's the skunk celebration.
    static func winner() -> PlayerSnapshot {
        var s = dealt(seed: 9)
        cutStarter(&s)
        var steps = 0
        while s.phase == .pegging, s.whoseTurn != nil, steps < 20 { playOne(&s); steps += 1 }
        CribbageEngine.advance(&s)
        // A believable path to 121 rather than one giant claim, so the win screen's scoring replay
        // has something to replay.
        // Ann finishes on 77 — under 91, so the win screen is the skunk celebration.
        for amount in [12, 9, 16, 8, 14, 11, 7] {
            CribbageEngine.claim(&s, player: .one, amount: amount)
        }
        for amount in [16, 21, 14, 19, 12, 17, 22] {
            CribbageEngine.claim(&s, player: .two, amount: amount)
        }
        let toGo = 121 - (s.scores[.two] ?? 0)
        if toGo > 0 { CribbageEngine.claim(&s, player: .two, amount: toGo) }
        return s.snapshot(for: .two)
    }

    /// Shot 5 — the scoreboard: a real-cards game most of the way to 121.
    static func board() -> BoardGame {
        var game = BoardGame()
        for amount in [8, 12, 6, 15, 9, 14, 7, 13] { game.add(amount, to: .bottom) }
        for amount in [6, 11, 8, 16, 12, 9, 14] { game.add(amount, to: .top) }
        return game
    }
}

/// One screenshot: the guest's own device, showing a prepared position.
private struct GuestShot: View {
    @State private var vm: GameViewModel

    init(_ snapshot: PlayerSnapshot) {
        dealsCardsInstantly = true
        // A finished game otherwise opens on the pre-win scoring replay, which is what would get
        // photographed instead of the win itself.
        UserDefaults.standard.set(false, forKey: "replayBeforeWin")
        _vm = State(initialValue: GameViewModel.previewGuest(snapshot: snapshot))
    }

    var body: some View { GameTableView(vm: vm) }
}

#Preview("Shot 1 — pegging", traits: .landscapeLeft) {
    GuestShot(ScreenshotFixture.pegging())
}

#Preview("Shot 2 — the show", traits: .landscapeLeft) {
    GuestShot(ScreenshotFixture.show())
}

#Preview("Shot 3 — the cut", traits: .landscapeLeft) {
    GuestShot(ScreenshotFixture.starterCut())
}

#Preview("Shot 4 — the win", traits: .landscapeLeft) {
    GuestShot(ScreenshotFixture.winner())
}

/// The scoreboard shot, with both seats named and colored to match the play shots — the stored
/// defaults are otherwise the unnamed "Player"/"Opponent" a fresh install starts with.
private struct BoardShot: View {
    init() {
        let defaults = UserDefaults.standard
        defaults.set("Ben", forKey: "localName")
        defaults.set(7, forKey: "localColorID")
        defaults.set("Ann", forKey: "boardFarName")
        defaults.set(1, forKey: "boardFarColorID")
    }

    var body: some View { BoardView(onExit: {}, startGame: ScreenshotFixture.board()) }
}

#Preview("Shot 5 — scoreboard", traits: .landscapeLeft) {
    BoardShot()
}

#endif
