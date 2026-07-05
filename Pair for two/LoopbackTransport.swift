import Foundation

/// Single-process transport for development, tests, and "pass-and-play on one phone."
///
/// There is no real peer: the local device is the host and both players act on it. The host
/// `GameViewModel` applies intents straight to the engine and renders snapshots locally, so `send`
/// has nothing to transmit. `deliver(_:)` is provided so tests can inject simulated peer messages
/// through the same `events` path used by real transports.
///
/// This is the primary dev/test harness because Multipeer is unreliable between two simulators.
nonisolated final class LoopbackTransport: GameTransport, Sendable {

    let isHost = true
    let events: AsyncStream<TransportEvent>
    private let continuation: AsyncStream<TransportEvent>.Continuation

    init() {
        var captured: AsyncStream<TransportEvent>.Continuation!
        events = AsyncStream(bufferingPolicy: .unbounded) { captured = $0 }
        continuation = captured
        continuation.yield(.connected)
    }

    /// No peer to transmit to in single-process play; intents are applied locally by the host VM.
    func send(_ message: GameMessage) async {}

    /// Inject a message as though it arrived from a peer (used by tests / simulated second player).
    func deliver(_ message: GameMessage) {
        continuation.yield(.received(message))
    }

    /// End the event stream (e.g. when leaving the game).
    func finish() {
        continuation.finish()
    }
}
