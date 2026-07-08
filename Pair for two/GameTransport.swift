import Foundation

// MARK: - Wire messages

/// Everything that crosses the wire between the two devices. The host is the referee: guests send
/// *intents*; the host validates, mutates the canonical `GameState`, and broadcasts `.snapshot`.
nonisolated enum GameMessage: Codable, Sendable {
    // Handshake / lifecycle
    case hello(name: String, colorID: Int, playerToken: UUID)
    case assignSeat(PlayerID)              // host → guest: which player you are
    case snapshot(PlayerSnapshot)          // host → guests: current redacted view

    // Guest → host intents
    case intentCut(index: Int)
    case intentDiscard([Card])
    case intentPlay(Card)
    case intentGo
    case intentLiftCut(index: Int)          // pone lifts the deck for the starter cut
    case intentRevealStarter                // dealer turns up the starter
    case claimPoints(player: PlayerID, amount: Int)
    case undo(player: PlayerID)
    case advance                            // "continue" through cut-for-deal recut / show steps / next deal
    case playAgain
    case updateIdentity(name: String, colorID: Int)   // live name/colour change from Settings
    case setScoringMode(Int)                          // live scoring-mode change from Settings
    case quitGame                                     // either side ends the game for both players
}

// MARK: - Transport events

/// Connection lifecycle plus inbound messages, surfaced as a single async stream.
nonisolated enum TransportEvent: Sendable {
    case connected
    case reconnecting
    case disconnected
    case received(GameMessage)
}

// MARK: - Transport protocol

/// Abstraction over how the two devices talk. v1 ships `MultipeerTransport` (in-person) and
/// `LoopbackTransport` (single-device dev/test & pass-and-play). Game Center can slot in later
/// behind this same protocol.
protocol GameTransport: Sendable {
    /// Whether this device owns the authoritative `GameState` (runs the engine).
    var isHost: Bool { get }

    /// Connection events and inbound messages.
    var events: AsyncStream<TransportEvent> { get }

    /// Sends a message to the peer. On the host this typically means a snapshot; on a guest, an intent.
    func send(_ message: GameMessage) async

    /// Ask the transport to re-establish the connection (e.g. after returning from the background).
    /// `force` rebuilds the session even if it still *believes* it is connected — needed after a
    /// background/foreground cycle, where the OS often hasn't yet detected that the link dropped.
    func reconnect(force: Bool)
}

extension GameTransport {
    func reconnect(force: Bool) {}   // no-op by default (e.g. loopback)
    func reconnect() { reconnect(force: false) }
}
