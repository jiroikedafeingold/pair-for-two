import Foundation

/// Persists an interrupted game so it can be rejoined after the app is closed.
///
/// - The **host** writes its full authoritative `GameState` (to Application Support) — resuming means
///   reloading that one object and re-hosting.
/// - Both devices also write a small **marker** (in `UserDefaults`) recording that a game is in
///   progress, this device's role, and a score summary — so *either* phone can show "Rejoin game".
///   The guest holds no state; it just reconnects and the host resyncs it.
enum GamePersistence {
    private static let filename = "pairfortwo-game.json"
    private static let kActive = "resume.active"
    private static let kIsHost = "resume.isHost"
    private static let kSummary = "resume.summary"

    struct ResumeMarker { let isHost: Bool; let summary: String }

    private static var url: URL? {
        let fm = FileManager.default
        guard let dir = try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                    appropriateFor: nil, create: true) else { return nil }
        return dir.appendingPathComponent(filename)
    }

    // MARK: Host — full state

    static func save(_ state: GameState) {
        guard let url else { return }
        do {
            try JSONEncoder().encode(state).write(to: url, options: .atomic)
            saveMarker(isHost: true, summary: summary(of: state))
        } catch {
            // Best-effort; a failed write just means no rejoin is offered.
        }
    }

    static func loadState() -> GameState? {
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(GameState.self, from: data)
    }

    // MARK: Marker — both roles

    static func saveMarker(isHost: Bool, summary: String) {
        let d = UserDefaults.standard
        d.set(true, forKey: kActive)
        d.set(isHost, forKey: kIsHost)
        d.set(summary, forKey: kSummary)
    }

    static func loadMarker() -> ResumeMarker? {
        let d = UserDefaults.standard
        guard d.bool(forKey: kActive) else { return nil }
        return ResumeMarker(isHost: d.bool(forKey: kIsHost), summary: d.string(forKey: kSummary) ?? "")
    }

    // MARK: Clear

    static func clear() {
        if let url { try? FileManager.default.removeItem(at: url) }
        let d = UserDefaults.standard
        d.removeObject(forKey: kActive)
        d.removeObject(forKey: kIsHost)
        d.removeObject(forKey: kSummary)
    }

    private static func summary(of s: GameState) -> String {
        let one = s.names[.one] ?? "Player 1"
        let two = s.names[.two] ?? "Player 2"
        return "\(one) \(s.scores[.one] ?? 0) · \(two) \(s.scores[.two] ?? 0)"
    }
}
