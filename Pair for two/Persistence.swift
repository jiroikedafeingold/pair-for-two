import Foundation

/// Persists an interrupted game so it can be rejoined after the app is closed.
///
/// - The **host** writes its full authoritative `GameState` (to Application Support) — resuming means
///   reloading that one object and re-hosting.
/// - Both devices also write a small **marker** (in `UserDefaults`) recording that a game is in
///   progress, this device's role, and a score summary — so *either* phone can show "Rejoin game".
///   The guest holds no state; it just reconnects and the host resyncs it.
nonisolated enum GamePersistence {
    private static let filename = "pairfortwo-game.json"
    private static let kActive = "resume.active"
    private static let kIsHost = "resume.isHost"
    private static let kSummary = "resume.summary"
    private static let kOnline = "resume.online"
    private static let kOpponentID = "resume.opponentGamePlayerID"
    private static let kOpponentName = "resume.opponentName"

    /// What a device knows about the game it was in the middle of when it last closed.
    ///
    /// `isOnline` decides which rejoin route the menu offers: a nearby game re-pairs over
    /// Bluetooth/Wi-Fi, while an online one has to find the same Game Center player again — which is
    /// what `opponentGamePlayerID` is for. Both are absent for markers written before online games
    /// were resumable, so an old marker simply reads as a nearby game.
    struct ResumeMarker {
        let isHost: Bool
        let summary: String
        var isOnline = false
        var opponentGamePlayerID: String?
        var opponentName: String?
    }

    private static var url: URL? {
        let fm = FileManager.default
        guard let dir = try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                    appropriateFor: nil, create: true) else { return nil }
        return dir.appendingPathComponent(filename)
    }

    // MARK: Host — full state

    /// Writes made *during play* run here rather than inline. Encoding the state and writing the file
    /// was happening on the main thread on every intent — including every +1 — which is exactly the work
    /// that swallows a quick run of taps. Serial, so writes can't interleave.
    private static let writeQueue = DispatchQueue(label: "com.jirofeingold.pairfortwo.persistence",
                                                 qos: .utility)

    /// Save while the game is being played, off the main thread. Use `save` directly when the write has
    /// to have completed before returning — going to the background, for instance.
    static func saveInPlay(_ state: GameState,
                           online: Bool = false,
                           opponentGamePlayerID: String? = nil,
                           opponentName: String? = nil) {
        writeQueue.async {
            save(state, online: online,
                 opponentGamePlayerID: opponentGamePlayerID, opponentName: opponentName)
        }
    }

    static func save(_ state: GameState,
                     online: Bool = false,
                     opponentGamePlayerID: String? = nil,
                     opponentName: String? = nil) {
        guard let url else { return }
        do {
            try JSONEncoder().encode(state).write(to: url, options: .atomic)
            saveMarker(isHost: true, summary: summary(of: state),
                       online: online,
                       opponentGamePlayerID: opponentGamePlayerID,
                       opponentName: opponentName)
        } catch {
            // Best-effort; a failed write just means no rejoin is offered.
        }
    }

    static func loadState() -> GameState? {
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(GameState.self, from: data)
    }

    /// True only on the device that holds the authoritative full state — i.e. the host. Used at
    /// resume time to pick who re-hosts, independent of the (possibly stale) role marker.
    static var hasSavedState: Bool {
        guard let url else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    // MARK: Marker — both roles

    /// `online` + `opponentGamePlayerID` are what let an online game be picked up after the app has
    /// been force-quit: the id is the only durable handle on the other player once both matches are
    /// gone, and it's matched against Game Center's recent-players list at rejoin time.
    static func saveMarker(isHost: Bool,
                           summary: String,
                           online: Bool = false,
                           opponentGamePlayerID: String? = nil,
                           opponentName: String? = nil) {
        let d = UserDefaults.standard
        d.set(true, forKey: kActive)
        d.set(isHost, forKey: kIsHost)
        d.set(summary, forKey: kSummary)
        d.set(online, forKey: kOnline)
        if let opponentGamePlayerID { d.set(opponentGamePlayerID, forKey: kOpponentID) }
        if let opponentName { d.set(opponentName, forKey: kOpponentName) }
        // A guest never holds full state — drop any stale file left over from a game it once hosted,
        // so `hasSavedState` reliably identifies the one true host when resuming.
        if !isHost, let url { try? FileManager.default.removeItem(at: url) }
    }

    static func loadMarker() -> ResumeMarker? {
        let d = UserDefaults.standard
        guard d.bool(forKey: kActive) else { return nil }
        return ResumeMarker(isHost: d.bool(forKey: kIsHost),
                            summary: d.string(forKey: kSummary) ?? "",
                            isOnline: d.bool(forKey: kOnline),
                            opponentGamePlayerID: d.string(forKey: kOpponentID),
                            opponentName: d.string(forKey: kOpponentName))
    }

    // MARK: Clear

    static func clear() {
        if let url { try? FileManager.default.removeItem(at: url) }
        let d = UserDefaults.standard
        for key in [kActive, kIsHost, kSummary, kOnline, kOpponentID, kOpponentName] {
            d.removeObject(forKey: key)
        }
    }

    /// One line for the menu's "Rejoin" caption: both names and scores. Only the stand-in names need
    /// translating — everything else is a name or a number.
    private static func summary(of s: GameState) -> String {
        let one = s.names[.one] ?? String(localized: "Player 1", comment: "Stand-in name for the first player")
        let two = s.names[.two] ?? String(localized: "Player 2", comment: "Stand-in name for the second player")
        return "\(one) \(s.scores[.one] ?? 0) · \(two) \(s.scores[.two] ?? 0)"
    }
}
