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
/// - **Loopback host** (pass-and-play, `#if DEBUG` only — a shipping build is two-phone): owns the
///   state, applies intents for the rotating `viewer`, renders whoever is at the table.
/// - **Networked host**: owns the state, is a fixed player, applies its own + the guest's intents,
///   and broadcasts the guest's redacted snapshot.
/// - **Guest**: holds no state; sends intents to the host and renders the snapshots it receives.
@MainActor
@Observable
final class GameViewModel {

    private(set) var snapshot: PlayerSnapshot
    var selectedForDiscard: Set<Card> = []
    private(set) var connection: ConnectionState
    /// Flips to true when the game has been quit (locally or by the other player). The view observes
    /// this to return to the menu.
    private(set) var ended = false

    /// Flips to true when an online (Game Center) opponent drops — a real-time match can't be rejoined,
    /// so the view shows an "opponent left" state and returns to the menu.
    private(set) var opponentLeft = false

    private let transport: any GameTransport
    /// Which path is carrying this game, for the Settings footer — see `LinkKind`.
    var linkKind: LinkKind { transport.linkKind }
    let isHost: Bool
    let isLoopback: Bool
    /// Whether this game may be saved for relaunch "Rejoin". True for nearby (Multipeer) games; false
    /// for Game Center online games (a real-time match can't be rejoined after a hard exit — Phase 6).
    private let resumable: Bool
    /// Whether this is a Game Center (online) match rather than a nearby one. Explicit, because online
    /// games are resumable too now, so it can no longer be inferred from `resumable`.
    let isOnline: Bool
    /// The opponent's Game Center id, for online games: the one durable handle on them once both
    /// matches are gone, so a force-quit game can find them again. Written into the resume marker.
    private let onlineOpponentID: String?
    private let onlineOpponentName: String?

    /// Host-only authoritative state (nil on a guest, and on a networked host until the guest joins).
    private var state: GameState?

    /// The player this device controls when networked. For loopback, actions use the rotating
    /// `viewer` instead of this.
    private var fixedPlayer: PlayerID

    private var localName: String
    private var localColorID: Int
    private let seed: UInt64

    private var cutCounter = 17
    private var lastViewer: PlayerID?
    nonisolated(unsafe) private var eventsTask: Task<Void, Never>?
    nonisolated(unsafe) private var heartbeatTask: Task<Void, Never>?
    nonisolated(unsafe) private var watchdogTask: Task<Void, Never>?

    // MARK: Stats bookkeeping
    //
    // Counted here, from the phases this device actually saw, rather than read off the snapshot: a guest
    // holds no `GameState`, and `PlayerSnapshot` carries no hand number, so this is what both sides can
    // agree on without widening the wire protocol.

    /// When the first hand was dealt — the game's clock starts at the deal, not at the connect screen.
    private var firstDealAt: Date?
    /// Who dealt the opening hand (the deal alternates from there).
    private var firstDealer: PlayerID?
    /// Hands seen go by, counted on each entry into the discard phase.
    private var handsObserved = 0
    /// One record per game, however many times `.gameOver` is re-broadcast (the host heartbeats it).
    private var recordedResult = false
    /// The furthest this device fell behind during the game. Nothing persists it — a comeback is only
    /// knowable while it's being played — so it's tracked as the scores move and handed to Game Center.
    private var worstDeficit = 0

    /// When anything last arrived from the peer. Both sides send on a timer — the host its snapshot,
    /// the guest a keepalive — so this is a liveness signal either way. See `startInboundWatchdog`.
    private var lastInboundAt = Date()
    /// How long silence is tolerated before assuming the link is dead. Several missed beats.
    private static let inboundSilenceLimit: TimeInterval = 10
    /// A guest's keepalive interval. Comfortably inside `inboundSilenceLimit`, so the host has to miss
    /// two before it acts.
    private static let keepaliveInterval: TimeInterval = 4
    nonisolated(unsafe) private var keepaliveTask: Task<Void, Never>?
    /// Set once a guest's mid-game keepalive has been seen. A guest on an older build never sends one
    /// and legitimately goes quiet for minutes at a time, so the host's watchdog stays disarmed until
    /// this device knows the other end is one that reports in.
    private var sawGuestKeepalive = false

    // MARK: Init / factories

    private var scoringMode: ScoringMode

    private init(transport: any GameTransport,
                 isLoopback: Bool,
                 localName: String,
                 localColorID: Int,
                 seed: UInt64,
                 scoringMode: ScoringMode,
                 state: GameState?,
                 snapshot: PlayerSnapshot,
                 connection: ConnectionState,
                 resumable: Bool = true,
                 isOnline: Bool = false,
                 onlineOpponentID: String? = nil,
                 onlineOpponentName: String? = nil) {
        self.transport = transport
        self.isHost = transport.isHost
        self.isLoopback = isLoopback
        self.resumable = resumable
        self.isOnline = isOnline
        self.onlineOpponentID = onlineOpponentID
        self.onlineOpponentName = onlineOpponentName
        self.localName = localName
        self.localColorID = localColorID
        self.seed = seed
        self.scoringMode = scoringMode
        self.fixedPlayer = transport.isHost ? .one : .two
        self.state = state
        self.snapshot = snapshot
        self.connection = connection
        self.lastViewer = state != nil ? .one : nil
        listen()
        // Resuming host: state is pre-loaded, so start the heartbeat now (normally started once the
        // guest joins). The guest resyncs on reconnect.
        if isHost, state != nil, !isLoopback { startHeartbeat() }
        if !isLoopback {
            startInboundWatchdog()
            if !isHost { startKeepalive() }
        }
    }

#if DEBUG
    /// Single-device pass-and-play. Host owns state immediately for both players.
    ///
    /// Debug-only: this is for previews, the LAN harness, and poking at a game on one device. Shipping
    /// builds are two-phone only, so this factory — and `LoopbackTransport` with it — is compiled out of
    /// release, which is what keeps `isLoopback` false for every game a real player can start.
    static func loopback(names: [PlayerID: String],
                         colorIDs: [PlayerID: Int],
                         seed: UInt64 = UInt64.random(in: 0...UInt64.max),
                         scoringMode: ScoringMode = .feedback) -> GameViewModel {
        let transport = LoopbackTransport()
        var s = GameState.newMatch(matchID: UUID(), seed: seed, names: names, colorIDs: colorIDs, scoringMode: scoringMode)
        CribbageEngine.begin(&s)
        return GameViewModel(transport: transport, isLoopback: true,
                             localName: names[.one] ?? String(localized: "Player 1", comment: "Stand-in name for the first player"), localColorID: colorIDs[.one] ?? 1,
                             seed: seed, scoringMode: scoringMode,
                             state: s, snapshot: s.snapshot(for: .one), connection: .connected)
    }
#endif

#if DEBUG
    /// A guest showing one prepared snapshot, for App Store screenshots (see `ScreenshotFixtures`).
    ///
    /// It renders through the ordinary guest path — no authoritative state, seat fixed to `.two` — so
    /// what's captured is what a real player sees on their own device, not the pass-and-play view.
    /// The snapshot is supplied here rather than awaited from the transport because a preview snapshot
    /// is taken on the first frame, which would otherwise catch the "connecting" placeholder.
    static func previewGuest(snapshot: PlayerSnapshot) -> GameViewModel {
        GameViewModel(transport: PreviewSnapshotTransport(snapshot), isLoopback: false,
                      localName: snapshot.yourName, localColorID: snapshot.yourColorID,
                      seed: 0, scoringMode: snapshot.scoringMode,
                      state: nil, snapshot: snapshot, connection: .connected, resumable: false)
    }
#endif

    /// Two-device play over a real transport (Multipeer). The host builds state once the guest's
    /// `.hello` arrives; the guest renders incoming snapshots. The host's `scoringMode` governs.
    static func networked(transport: any GameTransport,
                          localName: String,
                          localColorID: Int,
                          scoringMode: ScoringMode = .off,
                          resumable: Bool = true,
                          isOnline: Bool = false,
                          onlineOpponentID: String? = nil,
                          onlineOpponentName: String? = nil,
                          seed: UInt64 = UInt64.random(in: 0...UInt64.max)) -> GameViewModel {
        let you: PlayerID = transport.isHost ? .one : .two
        let placeholder = GameViewModel.placeholderSnapshot(you: you, name: localName, colorID: localColorID)
        return GameViewModel(transport: transport, isLoopback: false,
                             localName: localName, localColorID: localColorID,
                             seed: seed, scoringMode: scoringMode,
                             state: nil, snapshot: placeholder, connection: .connecting,
                             resumable: resumable, isOnline: isOnline,
                             onlineOpponentID: onlineOpponentID, onlineOpponentName: onlineOpponentName)
    }

    /// Resume a saved game as the host (the authoritative state was persisted on the host device).
    /// The other player rejoins normally and gets resynced.
    static func resumeHost(transport: any GameTransport,
                           savedState: GameState,
                           isOnline: Bool = false,
                           onlineOpponentID: String? = nil,
                           onlineOpponentName: String? = nil) -> GameViewModel {
        GameViewModel(transport: transport, isLoopback: false,
                      localName: savedState.names[.one] ?? String(localized: "Player 1", comment: "Stand-in name for the first player"),
                      localColorID: savedState.colorIDs[.one] ?? 1,
                      seed: savedState.seed, scoringMode: savedState.scoringMode,
                      state: savedState,
                      snapshot: savedState.snapshot(for: .one), connection: .connecting,
                      isOnline: isOnline,
                      onlineOpponentID: onlineOpponentID, onlineOpponentName: onlineOpponentName)
    }

    /// Save the game as the app is backgrounded/closed. The host writes its full state; the guest just
    /// records a marker so it can offer to rejoin.
    func persist() {
        guard resumable else { return }   // online (Game Center) games aren't offered for Rejoin
        if isHost {
            if let state, state.phase != .gameOver {
                GamePersistence.save(state, online: isOnline,
                                     opponentGamePlayerID: onlineOpponentID,
                                     opponentName: onlineOpponentName)
            }
        } else if snapshot.phase != .connecting, snapshot.phase != .gameOver {
            GamePersistence.saveMarker(isHost: false, summary: snapshotSummary(snapshot),
                                       online: isOnline,
                                       opponentGamePlayerID: onlineOpponentID,
                                       opponentName: onlineOpponentName)
        }
    }

    private func snapshotSummary(_ s: PlayerSnapshot) -> String {
        let oneName = s.you == .one ? s.yourName : s.opponentName
        let oneScore = s.you == .one ? s.yourScore : s.opponentScore
        let twoName = s.you == .one ? s.opponentName : s.yourName
        let twoScore = s.you == .one ? s.opponentScore : s.yourScore
        return "\(oneName) \(oneScore) · \(twoName) \(twoScore)"
    }

    static func placeholderSnapshot(you: PlayerID, name: String, colorID: Int) -> PlayerSnapshot {
        PlayerSnapshot(matchID: UUID(), you: you, phase: .connecting, yourSeat: .pone, dealer: .one,
                       yourHand: [], opponentHandCount: 0, opponentHand: nil, crib: nil, cribCount: 0,
                       cribOwners: nil,
                       starter: nil, starterCutLifted: false,
                       playSequence: [], runningCount: 0, lapCardCount: 0, whoseTurn: nil, lastToPlay: nil,
                       yourScore: 0, opponentScore: 0, flags: [], scoringMode: .off,
                       cutForDeal: [:], winner: nil,
                       yourName: name,
                       opponentName: String(localized: "Opponent",
                                            comment: "Stand-in for the other player's name until it arrives"),
                       yourColorID: colorID, opponentColorID: you == .one ? 7 : 1,
                       playersWithClaims: [],
                       claimTick: 0, lastClaimPlayer: nil, lastClaimAmount: 0,
                       pegEventTick: 0, lastPegEvent: nil, scoreLog: [])
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
            lastInboundAt = Date()
            onConnected()
            // On a *re*connect the game already exists — the host just replays the current snapshot.
            if isHost, state != nil { refreshAndBroadcast() }
        case .reconnecting:
            connection = .reconnecting
        case .disconnected:
            connection = .disconnected
            // Nearby (Multipeer) games auto-rejoin after a drop; an online real-time match can't, so a
            // drop there is terminal — surface it and stop the heartbeat.
            if isOnline {
                opponentLeft = true
                heartbeatTask?.cancel()
            }
        case .received(let message):
            lastInboundAt = Date()
            receive(message)
        }
    }

    /// Watch the phases go past so a finished game can be written to this device's history. Called on
    /// every snapshot change, host and guest alike.
    private func trackProgress(from old: GamePhase, to new: GamePhase) {
        worstDeficit = max(worstDeficit, snapshot.opponentScore - snapshot.yourScore)
        guard old != new else { return }
        if new == .discardToCrib {
            handsObserved += 1
            if firstDealAt == nil { firstDealAt = Date() }
            if firstDealer == nil { firstDealer = snapshot.dealer }
        }
        if new == .gameOver { recordFinishedGame() }
        // A rematch (Play again) deals straight into a fresh game, so re-arm for the next result.
        if new == .discardToCrib, recordedResult {
            recordedResult = false
            firstDealAt = Date()
            firstDealer = snapshot.dealer
            handsObserved = 1
            worstDeficit = 0
        }
    }

    /// Write the finished game to this device's local history. Pass-and-play (debug) games aren't
    /// recorded — a history is a record of games against a real opponent.
    private func recordFinishedGame() {
        guard !isLoopback, !recordedResult else { return }
        recordedResult = true
        let s = snapshot
        // The biggest single count claimed for a hand or the crib. Pegging claims are excluded: they're
        // points, not a hand's worth.
        let showPhases: Set<GamePhase> = [.showPone, .showDealer, .showCrib]
        let best = s.scoreLog
            .filter { $0.player == s.you && showPhases.contains($0.phase) }
            .map(\.amount).max() ?? 0
        let record = GameRecord(id: UUID(),
                                finishedAt: Date(),
                                yourName: s.yourName,
                                opponentName: s.opponentName,
                                yourScore: s.yourScore,
                                opponentScore: s.opponentScore,
                                youDealtFirst: firstDealer == s.you,
                                duration: Date().timeIntervalSince(firstDealAt ?? Date()),
                                hands: max(handsObserved, 1),
                                yourBestHand: best)
        StatsStore.record(record)
        // Achievements and the wins leaderboard are derived from the same history, so they're reported
        // once it includes this game.
        GameCenterAwards.report(game: record, summary: StatsStore.summary(), worstDeficit: worstDeficit)
    }

    /// Neither side can tell a quiet link from a dead one by itself, so each listens for the other's
    /// timer: the host's snapshot every couple of seconds, the guest's keepalive every four. Silence
    /// past `inboundSilenceLimit` means the link is gone whatever the OS says — MultipeerConnectivity
    /// reports a suspended peer as connected for its whole keep-alive window (or, on the evidence,
    /// indefinitely), and a `send` into that ghost succeeds locally, so nothing here fails on its own.
    ///
    /// Forcing a re-pair also wakes the other phone: tearing down the old session hands it a
    /// disconnect, which starts its own recovery. Without this the pair could sit "connected" forever,
    /// each waiting for the other.
    ///
    /// **The host used to be exempt from this**, on the theory that its heartbeat would fail and report
    /// the drop. It doesn't: `MCSession.send` to a peer MC still lists succeeds, so the host sat there
    /// believing all was well until MC's keep-alive finally expired — up to half a minute during which
    /// the other phone was already hunting for it, and, since the inviter is elected between two
    /// *pairing* phones, quite possibly deferring to a host that wasn't looking.
    private func startInboundWatchdog() {
        watchdogTask?.cancel()
        watchdogTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self else { return }
                guard self.connection == .connected, !self.ended,
                      self.snapshot.phase != .connecting, self.snapshot.phase != .gameOver else { continue }
                // On the host, only once the guest has shown it reports in (see `sawGuestKeepalive`).
                guard !self.isHost || self.sawGuestKeepalive else { continue }
                guard Date().timeIntervalSince(self.lastInboundAt) > Self.inboundSilenceLimit else { continue }
                self.lastInboundAt = Date()   // one nudge per silent window, not one per tick
                self.transport.reconnect(force: true)
            }
        }
    }

    /// A guest sends nothing between taps, which left the host with no way to notice a dead link (see
    /// `startInboundWatchdog`). `hello` is what it repeats: the host already treats a mid-game hello as
    /// a resync request, so this needs no new message and an older host simply answers with the
    /// snapshot it was already sending.
    private func startKeepalive() {
        guard !isHost, !isLoopback else { return }
        keepaliveTask?.cancel()
        keepaliveTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.keepaliveInterval))
                guard let self, !self.ended else { return }
                guard self.connection == .connected else { continue }
                await self.transport.send(.hello(name: self.localName, colorID: self.localColorID,
                                                 playerToken: UUID()))
            }
        }
    }

    private func onConnected() {
        // A guest announces itself; the host waits for that hello before dealing. On reconnect the
        // host treats a repeat hello as a resync (see `receive`), so re-sending is safe. We re-send
        // until the host answers with a snapshot, so a first hello dropped during connection setup
        // can't leave the host stuck on "waiting for a player to join".
        guard !isHost else { return }
        Task { @MainActor [weak self] in
            for attempt in 0..<6 {
                guard let self, self.snapshot.phase == .connecting else { return }
                await self.transport.send(.hello(name: self.localName, colorID: self.localColorID, playerToken: UUID()))
                try? await Task.sleep(for: .seconds(attempt == 0 ? 1 : 2))
            }
        }
    }

    private func receive(_ message: GameMessage) {
        if case .quitGame = message { endGame(); return }   // the other player left — end for us too
        if isHost {
            switch message {
            case .hello(let name, let colorID, _):
                if state == nil {
                    startHostedGame(guestName: name, guestColorID: colorID)   // first join
                } else {
                    // Mid-game hello: a resync request, and also the guest's keepalive — so it's the
                    // proof the watchdog waits for that this guest reports in at all.
                    sawGuestKeepalive = true
                    refreshAndBroadcast()
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
                trackProgress(from: previousPhase, to: snap.phase)
                // Guest marker so this device can also offer "Rejoin game" (nearby games only).
                if snap.phase == .gameOver { GamePersistence.clear() }
                else if resumable, snap.phase != .connecting {
                    GamePersistence.saveMarker(isHost: false, summary: snapshotSummary(snap),
                                               online: isOnline,
                                               opponentGamePlayerID: onlineOpponentID,
                                               opponentName: onlineOpponentName)
                }
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
                                   colorIDs: [.one: localColorID, .two: guestColorID],
                                   scoringMode: scoringMode)
        CribbageEngine.begin(&s)
        state = s
        Task { await transport.send(.assignSeat(.two)) }
        refreshAndBroadcast()
        startHeartbeat()
    }

    /// The host re-broadcasts its authoritative snapshot every couple of seconds so a dropped update
    /// (e.g. a cut that didn't reach the other phone) self-heals — the host keeps its state and keeps
    /// resending it. Idempotent: the guest just re-renders the latest snapshot.
    private func startHeartbeat() {
        guard isHost, !isLoopback else { return }
        heartbeatTask?.cancel()
        heartbeatTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self, let state = self.state else { continue }
                let guestSnapshot = state.snapshot(for: self.fixedPlayer.opponent)
                await self.transport.send(.snapshot(guestSnapshot))
            }
        }
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
        case .cutForDeal:
            if state.cutForDeal.count == 2 { return state.dealer }   // result shown → dealer deals
            return state.cutForDeal[.one] == nil ? .one : .two
        case .discardToCrib: return state.discarded.contains(.one) ? .two : .one
        case .cutStarter: return state.starterCutLifted ? state.dealer : state.pone   // pone lifts, then dealer reveals
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
        let previousPhase = snapshot.phase
        snapshot = state.snapshot(for: renderPlayer)
        trackProgress(from: previousPhase, to: snapshot.phase)
        if isHost && !isLoopback {
            let guestSnapshot = state.snapshot(for: fixedPlayer.opponent)
            Task { await transport.send(.snapshot(guestSnapshot)) }
        }
        // Persist for resume-after-relaunch (host is the single source of truth). Clear on game over.
        // Online games save too: the state is the same, and the marker carries the Game Center id
        // needed to find the same player again after a force-quit.
        if isHost, resumable {
            if state.phase == .gameOver {
                GamePersistence.clear()
            } else {
                // Off the main thread: this runs on every intent, and a synchronous encode-and-write
                // per tap is what makes a quick run of +1s drop presses.
                GamePersistence.saveInPlay(state, online: isOnline,
                                           opponentGamePlayerID: onlineOpponentID,
                                           opponentName: onlineOpponentName)
            }
        }
    }

    // MARK: Derived UI helpers

    var runningCount: Int { snapshot.runningCount }
    var isGameOver: Bool { snapshot.phase == .gameOver }



    /// Both players have cut for deal and the dealer is decided — show the result + "Deal".
    var cutForDealDecided: Bool {
        snapshot.phase == .cutForDeal && snapshot.cutForDeal.count == 2
    }

    /// This device's player still needs to cut for deal. (In pass-and-play the rendered player is
    /// always the one due to cut, so this is true until both have cut.)
    var youNeedToCut: Bool {
        snapshot.phase == .cutForDeal && !cutForDealDecided && snapshot.cutForDeal[snapshot.you] == nil
    }

    /// You have cut but the opponent hasn't yet (networked "waiting" state).
    var waitingForOpponentCut: Bool {
        snapshot.phase == .cutForDeal && !cutForDealDecided && snapshot.cutForDeal[snapshot.you] != nil
    }

    /// After the cut is decided, the dealer deals. (Pass-and-play renders the dealer, so always true.)
    var youDeal: Bool {
        cutForDealDecided && (isLoopback || snapshot.you == snapshot.dealer)
    }

    /// At hand-complete, only the player who will deal the next hand (the current pone — the deal
    /// alternates) starts the deal. The other player just sees a "waiting" note.
    var youStartNextDeal: Bool {
        snapshot.phase == .handComplete && (isLoopback || snapshot.you == snapshot.dealer.opponent)
    }

    /// The player who deals the next hand (deal passes to the current pone).
    var nextDealer: PlayerID { snapshot.dealer.opponent }

    // MARK: Starter cut (pone lifts, dealer reveals)

    /// This device should lift the deck now (it's the pone and nobody has lifted yet).
    var youLiftCut: Bool {
        snapshot.phase == .cutStarter && !snapshot.starterCutLifted
            && (isLoopback || snapshot.you == snapshot.pone)
    }

    /// This device should reveal the starter now (it's the dealer and the pone has lifted).
    var youRevealStarter: Bool {
        snapshot.phase == .cutStarter && snapshot.starterCutLifted
            && (isLoopback || snapshot.you == snapshot.dealer)
    }

    var starterCutLifted: Bool { snapshot.starterCutLifted }

    // MARK: Pegging event alert (go / 31)

    var pegEventTick: Int { snapshot.pegEventTick }
    var lastPegEvent: PegEvent? { snapshot.lastPegEvent }

    /// The opponent is out of cards while you still hold more than one — you keep laying on your own,
    /// so we tell you (otherwise it looks like the game is stuck on your turn).
    var opponentOutKeepPlaying: Bool {
        snapshot.phase == .pegging && snapshot.isYourTurn
            && snapshot.opponentHandCount == 0 && snapshot.yourHand.count > 1
    }

    /// Every card has been played; the hand is over and it's time to count.
    var peggingComplete: Bool {
        snapshot.phase == .pegging && snapshot.whoseTurn == nil
    }

    /// Only the player who laid the last card moves the game on to the count — so they can peg their
    /// last-card / go points first. The other player waits.
    var youStartCount: Bool {
        peggingComplete && (isLoopback || snapshot.lastToPlay == nil || snapshot.you == snapshot.lastToPlay)
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

    /// The other player is reachable right now, so a networked command (e.g. Play Again) will actually
    /// be delivered. Pass-and-play is always reachable; mirrors the guard in `submit`.
    var opponentAvailable: Bool { isLoopback || connection == .connected }

    // MARK: The show (counting)

    /// Who is counting during the current show phase (pone counts first, then the dealer, then the
    /// dealer counts the crib). Nil outside the show.
    var showCountingPlayer: PlayerID? {
        switch snapshot.phase {
        case .showPone:             return snapshot.pone
        case .showDealer, .showCrib: return snapshot.dealer
        default:                    return nil
        }
    }

    /// This device is the one counting right now.
    var youAreCounting: Bool { showCountingPlayer == snapshot.you }

    /// The player the current scoring feedback belongs to (pegging → whoever just played; the show →
    /// the counter). Drives the flag color + the leading name.
    var scoringPlayer: PlayerID? {
        switch snapshot.phase {
        case .pegging:               return snapshot.lastToPlay ?? snapshot.dealer
        case .showPone:              return snapshot.pone
        case .showDealer, .showCrib: return snapshot.dealer
        default:                     return nil
        }
    }

    /// During the show only the counting player may score; the other player's panel is inert to avoid
    /// confusion.
    func scoringDisabled(for player: PlayerID) -> Bool {
        switch snapshot.phase {
        case .showPone, .showDealer, .showCrib: return player != showCountingPlayer
        default:                                return false
        }
    }

    /// The cards currently being counted, resolved from this device's snapshot (both devices see the
    /// same hand — the counter's own, the watcher's via the revealed opponent hand).
    var showCards: [Card] {
        switch snapshot.phase {
        case .showPone:
            return snapshot.pone == snapshot.you ? snapshot.yourHand : (snapshot.opponentHand ?? [])
        case .showDealer:
            return snapshot.dealer == snapshot.you ? snapshot.yourHand : (snapshot.opponentHand ?? [])
        case .showCrib:
            return snapshot.crib ?? []
        default:
            return []
        }
    }

    /// Which player discarded a given crib card, so the crib row can mark each card with its owner's
    /// color. Nil when unknown (a game resumed from a build that didn't record it).
    func cribOwner(of card: Card) -> PlayerID? { snapshot.cribOwners?[card] }

    /// Name-based label for what's being counted (never the "pone/dealer" jargon). Localized here
    /// rather than in the view because the phase-to-wording mapping is the model's business; views
    /// render it with `Text(verbatim:)`.
    var showLabel: String {
        switch snapshot.phase {
        case .showPone:
            return String(localized: "\(name(of: snapshot.pone))'s hand",
                          comment: "Whose hand is being counted; %@ is a player name")
        case .showDealer:
            return String(localized: "\(name(of: snapshot.dealer))'s hand",
                          comment: "Whose hand is being counted; %@ is a player name")
        case .showCrib:
            return String(localized: "\(name(of: snapshot.dealer))'s crib",
                          comment: "Whose crib is being counted; %@ is a player name")
        default:          return ""
        }
    }

    /// The correct count for what's on the table right now, computed on this device from the revealed
    /// cards — powers the "check my count" button so a manual counter can verify their scoring.
    var checkScoreFlags: [ScoreFlag] {
        guard let starter = snapshot.starter else { return [] }
        switch snapshot.phase {
        case .showPone, .showDealer:
            return CribbageScorer.handBreakdown(hand: showCards, starter: starter, isCrib: false)
        case .showCrib:
            return CribbageScorer.handBreakdown(hand: showCards, starter: starter, isCrib: true)
        default:
            return []
        }
    }

    var checkScoreTotal: Int { checkScoreFlags.totalPoints }

    /// The ordered scoring history for the finished game (each claim, in order) — drives the win-screen
    /// scoring replay. Empty until game over.
    var scoreLog: [Claim] { snapshot.scoreLog }

    /// The one-line prompt across the top of the table. Localized here — every `%@` is a player
    /// name, which is never translated.
    var coachBanner: String {
        let s = snapshot
        switch s.phase {
        case .connecting:
            return isHost ? String(localized: "Waiting for a player to join…",
                                   comment: "Host is waiting for the second device")
                          : String(localized: "Connecting…", comment: "Guest is joining a game")
        case .cutForDeal:
            if cutForDealDecided {
                return String(localized: "\(name(of: s.dealer)) wins the cut — deals & takes the crib",
                              comment: "Result of the cut for deal; %@ is a player name")
            }
            if waitingForOpponentCut {
                return String(localized: "Waiting for \(s.opponentName) to cut…",
                              comment: "%@ is the other player's name")
            }
            return String(localized: "\(s.yourName), cut for deal",
                          comment: "Prompt to cut for the deal; %@ is your name")
        case .dealing:
            return String(localized: "Dealing…", comment: "Cards are being dealt")
        case .discardToCrib:
            return s.yourSeat == .dealer
                ? String(localized: "\(s.yourName), discard 2 to your crib",
                         comment: "Prompt to discard; %@ is your name and the crib is yours")
                : String(localized: "\(s.yourName), discard 2 to \(name(of: s.dealer))'s crib",
                         comment: "Prompt to discard; first %@ is your name, second is the dealer's")
        case .cutStarter:
            if s.starterCutLifted {
                return youRevealStarter
                    ? String(localized: "\(name(of: s.dealer)), turn up the cut",
                             comment: "Prompt for the dealer to reveal the starter; %@ is a player name")
                    : String(localized: "Waiting for \(name(of: s.dealer)) to turn up the cut…",
                             comment: "%@ is the dealer's name")
            }
            return youLiftCut
                ? String(localized: "\(name(of: s.pone)), cut the deck",
                         comment: "Prompt for the non-dealer to cut; %@ is a player name")
                : String(localized: "Waiting for \(name(of: s.pone)) to cut the deck…",
                         comment: "%@ is the non-dealer's name")
        case .pegging:
            if peggingComplete {
                return String(localized: "All cards played — count the hands",
                              comment: "The play is over and the show begins")
            }
            if opponentOutKeepPlaying {
                return String(localized: "\(s.opponentName) is out — keep laying your cards",
                              comment: "The other player has no cards left; %@ is their name")
            }
            if s.isYourTurn {
                return canSayGo
                    ? String(localized: "\(s.yourName): no card to play — say Go",
                             comment: "You cannot play under 31; %@ is your name. 'Go' is the cribbage call")
                    : String(localized: "\(s.yourName)'s play",
                             comment: "It is your turn to lay a card; %@ is your name")
            }
            return String(localized: "Waiting for \(s.opponentName)",
                          comment: "%@ is the other player's name")
        case .showPone:
            return String(localized: "\(name(of: s.pone)) counts their hand",
                          comment: "%@ is a player name")
        case .showDealer:
            return String(localized: "\(name(of: s.dealer)) counts their hand",
                          comment: "%@ is a player name")
        case .showCrib:
            return String(localized: "\(name(of: s.dealer)) counts the crib",
                          comment: "%@ is a player name")
        case .handComplete:
            return String(localized: "Hand complete", comment: "The hand has finished scoring")
        case .gameOver:
            let w = s.winner == s.you ? s.yourName : s.opponentName
            return String(localized: "\(w) wins!", comment: "%@ is the winner's name")
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

    /// The pone lifts a portion of the deck for the starter cut (step 1 of 2).
    func liftCut() {
        cutCounter = (cutCounter &* 31 &+ 7) % 4999
        submit(.intentLiftCut(index: cutCounter))
    }

    /// The dealer turns up the starter after the pone has lifted (step 2 of 2).
    func revealStarter() { submit(.intentRevealStarter) }

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

    /// Called when the app returns to the foreground — nudge the transport to re-pair if it dropped.
    /// `force` (set after a real background) rebuilds even if the transport still thinks it's connected,
    /// so we don't wait out the OS's slow drop detection.
    func reconnect(force: Bool = false) { transport.reconnect(force: force) }

    func sayGo() { submit(.intentGo) }
    func claim(_ amount: Int, for player: PlayerID) { submit(.claimPoints(player: player, amount: amount)) }
    func undo(for player: PlayerID) { submit(.undo(player: player)) }
    func advance() { submit(.advance) }
    func playAgain() { submit(.playAgain) }

    /// A live name/color change from Settings — propagates into the running game so this device's
    /// (and the opponent's) highlight, slider, and score colors update immediately.
    func updateLocalIdentity(name: String, colorID: Int) {
        localName = name
        localColorID = colorID
        submit(.updateIdentity(name: name, colorID: colorID))
    }

    /// A live scoring-mode change from Settings — applies to the running game (either device can set
    /// it; it governs both). Auto-scoring then takes effect for subsequent scores.
    func setScoringMode(_ mode: ScoringMode) {
        // Compare against the *game's* current mode, not this device's local var: a guest's local
        // `scoringMode` was seeded from its own setting, so guarding on it would wrongly no-op when
        // the guest tries to change a game the host started in a different mode (e.g. it kept showing
        // Feedback flags after switching to Player responsibility).
        guard mode != snapshot.scoringMode else { return }
        scoringMode = mode
        submit(.setScoringMode(mode.rawValue))
    }

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
        case .intentLiftCut(let index):
            CribbageEngine.liftStarterCut(&s, player: player, index: index)
        case .intentRevealStarter:
            CribbageEngine.revealStarter(&s, player: player)
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
        case .updateIdentity(let name, let colorID):
            s.names[player] = name
            s.colorIDs[player] = colorID
        case .setScoringMode(let raw):
            s.scoringMode = ScoringMode(rawValue: raw) ?? s.scoringMode
        case .hello, .assignSeat, .snapshot, .quitGame:
            break
        }
        state = s
    }

    // MARK: Quit

    /// Leave the game for good. Tells the other player so their app ends too, then clears the saved
    /// game on this device and marks the VM finished (the view returns to the menu).
    func quit() {
        guard !ended else { return }
        if isLoopback { endGame(); return }
        Task { @MainActor in
            await transport.send(.quitGame)
            try? await Task.sleep(for: .milliseconds(400))   // let the reliable message flush before teardown
            endGame()
        }
    }

    /// Clear any saved game and mark this VM finished. Called on a local quit and when the peer quits.
    private func endGame() {
        guard !ended else { return }
        heartbeatTask?.cancel()
        watchdogTask?.cancel()
        keepaliveTask?.cancel()
        GamePersistence.clear()
        ended = true
    }

    deinit {
        eventsTask?.cancel()
        heartbeatTask?.cancel()
        watchdogTask?.cancel()
        keepaliveTask?.cancel()
    }
}
