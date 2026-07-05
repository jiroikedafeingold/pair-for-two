import Foundation

/// Persists the host's authoritative `GameState` to Application Support so a single-device
/// (pass-and-play) game can be resumed after the app is killed. The host is the single source of
/// truth, so recovery is just reloading that one object.
///
/// Scope: relaunch-resume covers the single-device / host game. Networked *live* drop-and-return is
/// handled at the transport layer (`MultipeerSession` keeps trying to rejoin); cross-launch re-pairing
/// of two devices is out of scope for v1.
enum GamePersistence {
    private static let filename = "pairfortwo-game.json"

    private static var url: URL? {
        let fm = FileManager.default
        guard let dir = try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                    appropriateFor: nil, create: true) else { return nil }
        return dir.appendingPathComponent(filename)
    }

    static func save(_ state: GameState) {
        guard let url else { return }
        do {
            let data = try JSONEncoder().encode(state)
            try data.write(to: url, options: .atomic)
        } catch {
            // Best-effort; a failed write just means no resume is offered.
        }
    }

    static func loadState() -> GameState? {
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(GameState.self, from: data)
    }

    static func clear() {
        guard let url else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// A short description for the resume button, e.g. "Ann 42 · Ben 51".
    static func savedGameSummary() -> String? {
        guard let s = loadState(), s.phase != .gameOver else { return nil }
        let one = s.names[.one] ?? "Player 1"
        let two = s.names[.two] ?? "Player 2"
        return "\(one) \(s.scores[.one] ?? 0) · \(two) \(s.scores[.two] ?? 0)"
    }
}
