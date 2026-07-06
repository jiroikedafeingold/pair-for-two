import Foundation
import GameKit

/// Online transport backed by a Game Center real-time match (`GKMatch`). GameKit relays the bytes,
/// so there's no server to run and the host-authoritative engine is unchanged. Mirrors
/// `MultipeerSession`'s shape: a nonisolated `events` stream of `TransportEvent`, with JSON-encoded
/// `GameMessage`s sent over `send`.
///
/// `@unchecked Sendable`: the only stored state is immutable (`isHost`, the match reference, and the
/// thread-safe stream continuation); `GKMatch.sendData` is safe to call from any thread and delegate
/// callbacks only forward into the continuation.
final class GameCenterTransport: NSObject, GKMatchDelegate, GameTransport, @unchecked Sendable {

    let isHost: Bool
    nonisolated let events: AsyncStream<TransportEvent>
    nonisolated private let continuation: AsyncStream<TransportEvent>.Continuation
    private let match: GKMatch

    /// The match handed over by the matchmaker is already connected (both players are Ready). `isHost`
    /// is decided by the caller deterministically, so both devices agree on exactly one host.
    init(match: GKMatch, isHost: Bool) {
        self.match = match
        self.isHost = isHost
        var captured: AsyncStream<TransportEvent>.Continuation!
        events = AsyncStream(bufferingPolicy: .unbounded) { captured = $0 }
        continuation = captured
        super.init()
        match.delegate = self
        continuation.yield(.connected)   // buffered until the VM starts listening
    }

    nonisolated func send(_ message: GameMessage) async {
        guard let data = try? JSONEncoder().encode(message) else { return }
        try? match.sendData(toAllPlayers: data, with: .reliable)
    }

    // A real-time GKMatch can't re-add a dropped peer; a disconnect ends the online game (Phase 6 UI).
    nonisolated func reconnect() {}

    // MARK: - GKMatchDelegate

    nonisolated func match(_ match: GKMatch, didReceive data: Data, fromRemotePlayer player: GKPlayer) {
        if let message = try? JSONDecoder().decode(GameMessage.self, from: data) {
            continuation.yield(.received(message))
        }
    }

    nonisolated func match(_ match: GKMatch, player: GKPlayer, didChange state: GKPlayerConnectionState) {
        switch state {
        case .connected:    continuation.yield(.connected)
        case .disconnected: continuation.yield(.disconnected)
        default:            break
        }
    }

    nonisolated func match(_ match: GKMatch, didFailWithError error: (any Error)?) {
        continuation.yield(.disconnected)
    }
}
