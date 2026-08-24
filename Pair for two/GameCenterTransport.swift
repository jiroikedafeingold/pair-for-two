import Foundation
import GameKit

/// Online transport backed by a Game Center real-time match (`GKMatch`). GameKit relays the bytes,
/// so there's no server to run and the host-authoritative engine is unchanged. Mirrors
/// `MultipeerSession`'s shape: a nonisolated `events` stream of `TransportEvent`, with JSON-encoded
/// `GameMessage`s sent over `send`.
///
/// ## Surviving a drop
///
/// A `GKMatch` can't re-add a player that has gone, so a drop used to end the game outright. It no
/// longer does: the transport yields `.reconnecting` and tries to rebuild the match around the same
/// opponent, only falling back to `.disconnected` (which does end the game) once that has failed.
///
/// The two sides recover differently, because GameKit's invitations are one-directional and need a
/// human to accept them:
///
/// - **The host asks.** `GKMatchmaker.addPlayers(to:matchRequest:)` re-invites the dropped player
///   into the *existing* match, so if they accept, this transport's match simply fills back up and
///   the delegate reports them connected. Nothing else has to change: the host still holds the
///   authoritative `GameState`, and its `.connected` handler re-broadcasts the current snapshot.
/// - **The guest waits.** It can't invite anyone (that would race two matches), so it sits in
///   `.reconnecting` until the player accepts the invitation. Accepting produces a *new* `GKMatch`,
///   which `RootView` hands to `adopt(_:)` — the live game keeps its view model rather than being
///   restarted, and the host resyncs it.
///
/// Which means reconnecting is not silent: the dropped player taps a Game Center invitation. That's
/// GameKit's model, not a shortcut — there is no API to re-establish a real-time match without the
/// other person agreeing.
///
/// `@unchecked Sendable`: the mutable state (the current match, the remembered opponent, the recovery
/// bookkeeping) is guarded by `lock`; `GKMatch.sendData` is safe from any thread, and the delegate
/// callbacks only forward into the continuation.
final class GameCenterTransport: NSObject, GKMatchDelegate, GameTransport, @unchecked Sendable {

    let isHost: Bool
    nonisolated let events: AsyncStream<TransportEvent>
    nonisolated private let continuation: AsyncStream<TransportEvent>.Continuation

    private let lock = NSLock()
    nonisolated(unsafe) private var currentMatch: GKMatch
    /// Remembered so the host has someone to re-invite after they've vanished from `match.players`.
    nonisolated(unsafe) private var opponent: GKPlayer?
    nonisolated(unsafe) private var recovering = false
    nonisolated(unsafe) private var finished = false
    nonisolated(unsafe) private var recoveryTask: Task<Void, Never>?

    /// How many times the host re-invites before giving the game up.
    private static let rejoinAttempts = 3
    /// Between re-invitations. Long, because the other player has to notice a banner and tap it.
    private static let rejoinInterval: Duration = .seconds(20)
    /// How long a guest waits for an invitation to arrive and be accepted before giving up.
    private static let guestWait: Duration = .seconds(90)

    /// The match handed over by the matchmaker is already connected (both players are Ready). `isHost`
    /// is decided by the caller deterministically, so both devices agree on exactly one host.
    init(match: GKMatch, isHost: Bool) {
        self.currentMatch = match
        self.opponent = match.players.first
        self.isHost = isHost
        var captured: AsyncStream<TransportEvent>.Continuation!
        events = AsyncStream(bufferingPolicy: .unbounded) { captured = $0 }
        continuation = captured
        super.init()
        match.delegate = self
        continuation.yield(.connected)   // buffered until the VM starts listening
    }

    /// Which wire format the peer understands. Game Center only ever pairs iOS with iOS, so this
    /// stays `.legacy` against a build that predates protocol v1 — see `PROTOCOL.md`.
    private let negotiator = WireCodec.Negotiator()

    private var match: GKMatch {
        lock.lock(); defer { lock.unlock() }
        return currentMatch
    }

    nonisolated func send(_ message: GameMessage) async {
        guard let data = try? WireCodec.encode(message, as: negotiator.format) else { return }
        do {
            try match.sendData(toAllPlayers: data, with: .reliable)
        } catch {
            // The match has no one in it, or GameKit refused. The host's heartbeat lands here every
            // couple of seconds while the link is down, which is the earliest signal we get.
            startRecovery()
        }
    }

    // MARK: - Recovery

    /// Ask the transport to rebuild the link (called on foreground, and by the guest's silence
    /// watchdog). Idempotent while a recovery is already running.
    ///
    /// `force` skips the liveness check for the same reason Multipeer's does: after a
    /// background/foreground cycle the match can still list the other player while the link is
    /// already dead, and waiting for GameKit to notice wastes the recovery window.
    nonisolated func reconnect(force: Bool) {
        guard force || !isLive else { return }
        startRecovery()
    }

    /// Hand in a match rebuilt elsewhere — the guest accepting the host's invitation produces a new
    /// `GKMatch` for the same game, and `RootView` routes it here instead of starting a new game.
    func adopt(_ newMatch: GKMatch) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        let previous = currentMatch
        currentMatch = newMatch
        opponent = newMatch.players.first ?? opponent
        recovering = false
        recoveryTask?.cancel(); recoveryTask = nil
        lock.unlock()

        if previous !== newMatch { previous.delegate = nil }
        newMatch.delegate = self
        continuation.yield(.connected)
    }

    /// True while the match still has the other player in it.
    private var isLive: Bool {
        lock.lock(); defer { lock.unlock() }
        return !finished && !currentMatch.players.isEmpty
    }

    private var isRecovering: Bool {
        lock.lock(); defer { lock.unlock() }
        return recovering
    }

    private func startRecovery() {
        lock.lock()
        guard !finished, !recovering else { lock.unlock(); return }
        recovering = true
        let host = isHost
        lock.unlock()

        continuation.yield(.reconnecting)
        let task = Task { [weak self] in
            guard let self else { return }
            if host {
                for _ in 1...Self.rejoinAttempts {
                    if Task.isCancelled || self.isLive { return }
                    self.inviteOpponentBack()
                    try? await Task.sleep(for: Self.rejoinInterval)
                    if Task.isCancelled || self.isLive { return }
                }
            } else {
                // Nothing to send from this side; the invitation has to arrive and be accepted.
                try? await Task.sleep(for: Self.guestWait)
                if Task.isCancelled || self.isLive { return }
            }
            self.giveUp()
        }
        lock.lock(); recoveryTask = task; lock.unlock()
    }

    /// Re-invite the dropped player into the match we still hold. If they accept, GameKit fills this
    /// same match back up and the delegate reports them connected.
    private func inviteOpponentBack() {
        lock.lock()
        let target = opponent
        let m = currentMatch
        lock.unlock()
        guard let target else { return }

        let request = GKMatchRequest()
        request.minPlayers = 2
        request.maxPlayers = 2
        request.recipients = [target]
        request.inviteMessage = "Let's finish our game of Pair for Two!"
        GKMatchmaker.shared().addPlayers(to: m, matchRequest: request) { _ in
            // Success is observed through the delegate's .connected; a failure just means the next
            // attempt (or the timeout) takes over.
        }
    }

    /// Recovery is over and it didn't work — end the game for this device, which is what the app did
    /// for every drop before.
    private func giveUp() {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        recovering = false
        lock.unlock()
        continuation.yield(.disconnected)
    }

    private func markRecovered() {
        lock.lock()
        recovering = false
        recoveryTask?.cancel(); recoveryTask = nil
        opponent = currentMatch.players.first ?? opponent
        lock.unlock()
        continuation.yield(.connected)
    }

    // MARK: - GKMatchDelegate

    nonisolated func match(_ match: GKMatch, didReceive data: Data, fromRemotePlayer player: GKPlayer) {
        // Traffic is proof of life. It matters because `force`d recovery can start on a link that was
        // actually fine (a foreground, or the guest's silence watchdog firing early) — and a guest in
        // recovery otherwise just waits out its window and ends a perfectly good game.
        if isRecovering {
            lock.lock(); opponent = player; lock.unlock()
            markRecovered()
        }
        negotiator.observe(data)   // upgrade to v1 once the peer's hello announces it
        if let message = WireCodec.decode(data) {
            continuation.yield(.received(message))
        }
    }

    nonisolated func match(_ match: GKMatch, player: GKPlayer, didChange state: GKPlayerConnectionState) {
        switch state {
        case .connected:
            lock.lock(); opponent = player; lock.unlock()
            markRecovered()
        case .disconnected:
            startRecovery()
        default:
            break
        }
    }

    nonisolated func match(_ match: GKMatch, didFailWithError error: (any Error)?) {
        startRecovery()
    }
}
