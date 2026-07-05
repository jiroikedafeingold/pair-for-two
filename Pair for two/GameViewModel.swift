import Foundation
import Observation

/// Connection status surfaced to the UI (drives the "Reconnecting…" banner).
enum ConnectionState: Sendable {
    case connecting, connected, reconnecting, disconnected
}

/// Bridges the game engine/transport to the UI. `@MainActor @Observable`, and deliberately imports
/// no SwiftUI — views stay thin and read this model.
///
/// Three roles, all behind one type:
/// - **Loopback host** (pass-and-play): owns the state, applies intents for the rotating `viewer`,
///   renders whoever is at the table.
/// - **Networked host**: owns the state, is a fixed player, applies its own + the guest's intents,
///   and broadcasts the guest's redacted snapshot.
/// - **Guest**: holds no state; sends intents to the host and renders the snapshots it receives.
@MainActor
@Observable
final class GameViewModel {

    private(set) var snapshot: PlayerSnapshot
    var selectedForDiscard: Set<Card> = []
    private(set) var connection: ConnectionState

    // Per-player scoring-slider preferences (persisted). "Confirm after release" holds the slider
    // value until you tap the +N button to commit; "Confirm after +1" batches +1 taps before applying.
    private(set) var confirmAfterRelease: [PlayerID: Bool] = [
        .one: UserDefaults.standard.bool(forKey: "confirmRelease.one"),
        .two: UserDefaults.standard.bool(forKey: "confirmRelease.two"),
    ]
    private(set) var confirmAfterPlusOne: [PlayerID: Bool] = [
        .one: UserDefaults.standard.bool(forKey: "confirmPlus.one"),
        .two: UserDefaults.standard.bool(forKey: "confirmPlus.two"),
    ]

    func setConfirmAfterRelease(_ on: Bool, for player: PlayerID) {
        confirmAfterRelease[player] = on
        UserDefaults.standard.set(on, forKey: "confirmRelease.\(player.rawValue)")
    }
    func setConfirmAfterPlusOne(_ on: Bool, for player: PlayerID) {
        confirmAfterPlusOne[player] = on
        UserDefaults.standard.set(on, forKey: "confirmPlus.\(player.rawValue)")
    }

    private let transport: any GameTransport
    let isHost: Bool
    let isLoopback: Bool

    /// Host-only authoritative state (nil on a guest, and on a networked host until the guest joins).
    private var state: GameState?

    /// The player this device controls when networked. For loopback, actions use the rotating
    /// `viewer` instead of this.
    private var fixedPlayer: PlayerID

    private let localName: String
    private let localColorID: Int
    private let seed: UInt64

    private var cutCounter = 17
    private var lastViewer: PlayerID?
    nonisolated(unsafe) private var eventsTask: Task<Void, Never>?

    // MARK: Init / factories

    private init(transport: any GameTransport,
                 isLoopback: Bool,
                 localName: String,
                 localColorID: Int,
                 seed: UInt64,
                 state: GameState?,
                 snapshot: PlayerSnapshot,
                 connection: ConnectionState) {
        self.transport = transport
        self.isHost = transport.isHost
        self.isLoopback = isLoopback
        self.localName = localName
        self.localColorID = localColorID
        self.seed = seed
        self.fixedPlayer = transport.isHost ? .one : .two
        self.state = state
        self.snapshot = snapshot
        self.connection = connection
        self.lastViewer = state != nil ? .one : nil
        listen()
    }

    /// Single-device pass-and-play. Host owns state immediately for both players.
    static func loopback(names: [PlayerID: String],
                         colorIDs: [PlayerID: Int],
                         seed: UInt64 = UInt64.random(in: 0...UInt64.max)) -> GameViewModel {
        let transport = LoopbackTransport()
        var s = GameState.newMatch(matchID: UUID(), seed: seed, names: names, colorIDs: colorIDs)
        CribbageEngine.begin(&s)
        return GameViewModel(transport: transport, isLoopback: true,
                             localName: names[.one] ?? "Player 1", localColorID: colorIDs[.one] ?? 1,
                             seed: seed, state: s, snapshot: s.snapshot(for: .one), connection: .connected)
    }

    /// Two-device play over a real transport (Multipeer). The host builds state once the guest's
    /// `.hello` arrives; the guest renders incoming snapshots.
    static func networked(transport: any GameTransport,
                          localName: String,
                          localColorID: Int,
                          seed: UInt64 = UInt64.random(in: 0...UInt64.max)) -> GameViewModel {
        let you: PlayerID = transport.isHost ? .one : .two
        let placeholder = GameViewModel.placeholderSnapshot(you: you, name: localName, colorID: localColorID)
        return GameViewModel(transport: transport, isLoopback: false,
                             localName: localName, localColorID: localColorID,
                             seed: seed, state: nil, snapshot: placeholder, connection: .connecting)
    }

    /// Resume a previously-persisted single-device game (pass-and-play host).
    static func resume(_ savedState: GameState) -> GameViewModel {
        let render = GameViewModel.loopbackViewer(savedState)
        return GameViewModel(transport: LoopbackTransport(), isLoopback: true,
                             localName: savedState.names[.one] ?? "Player 1",
                             localColorID: savedState.colorIDs[.one] ?? 1,
                             seed: savedState.seed, state: savedState,
                             snapshot: savedState.snapshot(for: render), connection: .connected)
    }

    static func placeholderSnapshot(you: PlayerID, name: String, colorID: Int) -> PlayerSnapshot {
        PlayerSnapshot(matchID: UUID(), you: you, phase: .connecting, yourSeat: .pone, dealer: .one,
                       yourHand: [], opponentHandCount: 0, opponentHand: nil, crib: nil, cribCount: 0,
                       starter: nil, playSequence: [], runningCount: 0, whoseTurn: nil, lastToPlay: nil,
                       yourScore: 0, opponentScore: 0, flags: [], cutForDeal: [:], winner: nil,
                       yourName: name, opponentName: "Opponent",
                       yourColorID: colorID, opponentColorID: you == .one ? 7 : 1,
                       playersWithClaims: [])
    }

    // MARK: Transport event loop

    private func listen() {
        eventsTask = Task { @MainActor [weak self] in
            guard let events = self?.transport.events else { return }
            for await event in events {
                guard let self else { break }   // weak, so the VM can deallocate mid-stream
                self.handle(event)
            }
        }
    }

    private func handle(_ event: TransportEvent) {
        switch event {
        case .connected:
            connection = .connected
            onConnected()
            // On a *re*connect the game already exists — the host just replays the current snapshot.
            if isHost, state != nil { refreshAndBroadcast() }
        case .reconnecting:
            connection = .reconnecting
        case .disconnected:
            connection = .disconnected
        case .received(let message):
            receive(message)
        }
    }

    private func onConnected() {
        // A guest announces itself; the host waits for that hello before dealing. On reconnect the
        // host treats a repeat hello as a resync (see `receive`), so re-sending is safe.
        if !isHost {
            Task { await transport.send(.hello(name: localName, colorID: localColorID, playerToken: UUID())) }
        }
    }

    private func receive(_ message: GameMessage) {
        if isHost {
            switch message {
            case .hello(let name, let colorID, _):
                if state == nil {
                    startHostedGame(guestName: name, guestColorID: colorID)   // first join
                } else {
                    refreshAndBroadcast()                                     // reconnect resync
                }
            default:
                hostApply(message, from: fixedPlayer.opponent)   // the peer is the other player
                refreshAndBroadcast()
            }
        } else {
            switch message {
            case .snapshot(let snap):
                let previousPhase = snapshot.phase
                snapshot = snap
                fixedPlayer = snap.you
                if snap.phase != previousPhase { selectedForDiscard.removeAll() }
            case .assignSeat(let player):
                fixedPlayer = player
            default:
                break
            }
        }
    }

    private func startHostedGame(guestName: String, guestColorID: Int) {
        var s = GameState.newMatch(matchID: UUID(), seed: seed,
                                   names: [.one: localName, .two: guestName],
                                   colorIDs: [.one: localColorID, .two: guestColorID])
        CribbageEngine.begin(&s)
        state = s
        Task { await transport.send(.assignSeat(.two)) }
        refreshAndBroadcast()
    }

    // MARK: Viewer / rendering

    /// Whose perspective the phone currently shows. Loopback rotates to the acting player;
    /// networked is fixed to the local device's player.
    var viewer: PlayerID {
        guard isLoopback, let state else { return fixedPlayer }
        return GameViewModel.loopbackViewer(state)
    }

    /// The player whose perspective to render in pass-and-play, given the state's phase.
    static func loopbackViewer(_ state: GameState) -> PlayerID {
        switch state.phase {
        case .cutForDeal:  return state.cutForDeal[.one] == nil ? .one : .two
        case .discardToCrib: return state.discarded.contains(.one) ? .two : .one
        case .pegging: return state.whoseTurn ?? state.pone
        case .showPone: return state.pone
        case .showDealer, .showCrib: return state.dealer
        case .handComplete, .gameOver, .dealing, .connecting: return state.winner ?? .one
        }
    }

    private func refreshAndBroadcast() {
        guard let state else { return }
        let renderPlayer = isLoopback ? viewer : fixedPlayer
        if renderPlayer != lastViewer {
            selectedForDiscard.removeAll()
            lastViewer = renderPlayer
        }
        snapshot = state.snapshot(for: renderPlayer)
        if isHost && !isLoopback {
            let guestSnapshot = state.snapshot(for: fixedPlayer.opponent)
            Task { await transport.send(.snapshot(guestSnapshot)) }
        }
        // Persist for resume-after-relaunch (host is the single source of truth). Clear on game over.
        if isHost {
            if state.phase == .gameOver { GamePersistence.clear() } else { GamePersistence.save(state) }
        }
    }

    // MARK: Derived UI helpers

    var runningCount: Int { snapshot.runningCount }
    var isGameOver: Bool { snapshot.phase == .gameOver }

    /// Both players have cut for deal and the dealer is decided — show the result + "Deal".
    var cutForDealDecided: Bool {
        snapshot.phase == .cutForDeal && snapshot.cutForDeal.count == 2
    }

    /// Which pegs this device may score. Loopback shows both (pass-and-play); networked shows only
    /// the local player's panel.
    var scorablePlayers: [PlayerID] { isLoopback ? [.one, .two] : [snapshot.you] }

    func isLegalPlay(_ card: Card) -> Bool {
        snapshot.phase == .pegging && snapshot.isYourTurn
            && snapshot.runningCount + card.countingValue <= 31
    }

    var canSayGo: Bool {
        snapshot.phase == .pegging && snapshot.isYourTurn
            && CribbageScorer.legalPlays(hand: snapshot.yourHand, count: snapshot.runningCount).isEmpty
    }

    var canConfirmDiscard: Bool {
        snapshot.phase == .discardToCrib && selectedForDiscard.count == 2
    }

    /// True when this device is waiting to act and should show the cut / go / play controls.
    var canActNow: Bool { connection == .connected }

    var coachBanner: String {
        let s = snapshot
        switch s.phase {
        case .connecting:  return isHost ? "Waiting for a player to join…" : "Connecting…"
        case .cutForDeal:
            if cutForDealDecided {
                return "\(name(of: s.dealer)) wins the cut — deals & takes the crib"
            }
            return "\(s.yourName), cut for deal"
        case .dealing:     return "Dealing…"
        case .discardToCrib:
            let whose = s.yourSeat == .dealer ? "your crib" : "the crib"
            return "\(s.yourName), discard 2 to \(whose)"
        case .pegging:
            if s.isYourTurn {
                return canSayGo ? "\(s.yourName): no card to play — say Go" : "\(s.yourName)'s play"
            }
            return "Waiting for \(s.opponentName)"
        case .showPone:    return "Count the pone's hand — \(name(of: s.pone))"
        case .showDealer:  return "Count the dealer's hand — \(name(of: s.dealer))"
        case .showCrib:    return "Count the crib — \(name(of: s.dealer))'s"
        case .handComplete: return "Hand complete"
        case .gameOver:
            let w = s.winner == s.you ? s.yourName : s.opponentName
            return "\(w) wins!"
        }
    }

    func name(of player: PlayerID) -> String {
        player == snapshot.you ? snapshot.yourName : snapshot.opponentName
    }

    func theme(for player: PlayerID) -> PlayerTheme {
        let id = player == snapshot.you ? snapshot.yourColorID : snapshot.opponentColorID
        return playerTheme(colorID: id)
    }

    func score(of player: PlayerID) -> Int {
        player == snapshot.you ? snapshot.yourScore : snapshot.opponentScore
    }

    func canUndo(for player: PlayerID) -> Bool {
        snapshot.playersWithClaims.contains(player)
    }

    var winnerInfo: (winner: PlayerID, skunk: SkunkLevel)? {
        guard let winner = snapshot.winner else { return nil }
        return (winner, computeSkunk(loserScore: score(of: winner.opponent)))
    }

    // MARK: Intents (from the views)

    func cut() {
        cutCounter = (cutCounter &* 31 &+ 7) % 4999
        submit(.intentCut(index: cutCounter))
    }

    func toggleDiscard(_ card: Card) {
        if selectedForDiscard.contains(card) {
            selectedForDiscard.remove(card)
        } else if selectedForDiscard.count < 2 {
            selectedForDiscard.insert(card)
        }
    }

    func confirmDiscard() {
        guard canConfirmDiscard else { return }
        let cards = Array(selectedForDiscard)
        selectedForDiscard.removeAll()
        submit(.intentDiscard(cards))
    }

    func play(_ card: Card) {
        guard isLegalPlay(card) else { return }
        submit(.intentPlay(card))
    }

    func sayGo() { submit(.intentGo) }
    func claim(_ amount: Int, for player: PlayerID) { submit(.claimPoints(player: player, amount: amount)) }
    func undo(for player: PlayerID) { submit(.undo(player: player)) }
    func advance() { submit(.advance) }
    func playAgain() { submit(.playAgain) }

    // MARK: Intent plumbing

    /// Host applies locally + broadcasts; guest forwards to the host. Intents are ignored while a
    /// networked game is disconnected (pass-and-play is always "connected").
    private func submit(_ message: GameMessage) {
        guard isLoopback || connection == .connected else { return }
        if isHost {
            hostApply(message, from: isLoopback ? viewer : fixedPlayer)
            refreshAndBroadcast()
        } else {
            Task { await transport.send(message) }
        }
    }

    private func hostApply(_ message: GameMessage, from player: PlayerID) {
        guard var s = state else { return }
        switch message {
        case .intentCut(let index):
            if s.phase == .cutForDeal {
                CribbageEngine.cutForDeal(&s, player: player, index: index)
            }
        case .intentDiscard(let cards):
            CribbageEngine.discard(&s, player: player, cards: cards)
        case .intentPlay(let card):
            if s.whoseTurn == player { CribbageEngine.play(&s, player: player, card: card) }
        case .intentGo:
            if s.whoseTurn == player { CribbageEngine.go(&s, player: player) }
        case .claimPoints(let claimPlayer, let amount):
            // Networked: a device may only score its own peg. Loopback: either peg.
            let target = isLoopback ? claimPlayer : player
            CribbageEngine.claim(&s, player: target, amount: amount)
        case .undo(let undoPlayer):
            let target = isLoopback ? undoPlayer : player
            CribbageEngine.undo(&s, player: target)
        case .advance:
            CribbageEngine.advance(&s)
        case .playAgain:
            CribbageEngine.playAgain(&s)
        case .hello, .assignSeat, .snapshot:
            break
        }
        state = s
    }

    deinit {
        eventsTask?.cancel()
    }
}
