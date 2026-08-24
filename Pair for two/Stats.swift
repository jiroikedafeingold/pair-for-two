import Foundation

// MARK: - One finished game

/// A finished game as this device saw it. Deliberately written from the local player's point of view
/// ("your" score, "your" best hand) rather than as neutral player-one/player-two data: each phone keeps
/// its own history, there are no accounts, and nothing is ever compared across devices.
///
/// Skunk lines aren't stored — they're a pure function of the loser's score, so deriving them can't
/// drift from the score the game actually ended on.
nonisolated struct GameRecord: Codable, Hashable, Sendable, Identifiable {
    let id: UUID
    let finishedAt: Date
    let yourName: String
    let opponentName: String
    let yourScore: Int
    let opponentScore: Int
    /// Whether the local player dealt the first hand (the deal alternates from there).
    let youDealtFirst: Bool
    /// Seconds from the first deal to the winning peg.
    let duration: TimeInterval
    /// Hands played, counted locally as the game passed through each deal.
    let hands: Int
    /// The biggest single count the local player claimed for a hand or the crib in this game. It's the
    /// largest *claim*, not a re-scored hand: someone who pegs a 12-hand as 8 then 4 shows as 8.
    let yourBestHand: Int

    /// The winner is whoever reached 121, so they always hold the higher score.
    var youWon: Bool { yourScore > opponentScore }
    var loserScore: Int { min(yourScore, opponentScore) }

    /// Standard cribbage lines: the loser short of 91 is skunked, short of 61 double-skunked.
    var isSkunk: Bool { loserScore < 91 }
    var isDoubleSkunk: Bool { loserScore < 61 }
    var skunkedThem: Bool { youWon && isSkunk }
    var skunkedByThem: Bool { !youWon && isSkunk }
}

// MARK: - Lifetime rollup

/// Everything the stats screen shows, derived from the stored records rather than kept as separate
/// counters — one source of truth, so a total can never disagree with the list underneath it.
nonisolated struct StatsSummary: Sendable, Equatable {
    var games = 0
    var wins = 0
    var skunksInflicted = 0
    var skunksSuffered = 0
    var doubleSkunksInflicted = 0
    var bestHand = 0
    var hands = 0
    var totalPlayTime: TimeInterval = 0
    var longestWinStreak = 0
    var currentWinStreak = 0

    var losses: Int { games - wins }
    /// 0…1; zero when nothing has been played (rather than undefined).
    var winRate: Double { games == 0 ? 0 : Double(wins) / Double(games) }

    /// `records` must be in the order they were played (oldest first), which is how the store keeps them.
    init(records: [GameRecord]) {
        games = records.count
        var streak = 0
        for r in records {
            if r.youWon {
                wins += 1
                streak += 1
                longestWinStreak = max(longestWinStreak, streak)
            } else {
                streak = 0
            }
            if r.skunkedThem { skunksInflicted += 1 }
            if r.skunkedByThem { skunksSuffered += 1 }
            if r.youWon && r.isDoubleSkunk { doubleSkunksInflicted += 1 }
            bestHand = max(bestHand, r.yourBestHand)
            hands += r.hands
            totalPlayTime += r.duration
        }
        currentWinStreak = streak
    }

    init() {}
}

// MARK: - Store

/// Local game history, in Application Support next to the resume file. Local-only by design: no
/// accounts, no sync, nothing leaves the device — which also means it goes when the app does.
///
/// Reads and writes the whole file. The history is capped, the records are tiny, and it's touched once
/// per finished game and once per visit to the stats screen, so there's nothing to optimise here.
nonisolated enum StatsStore {
    private static let filename = "pairfortwo-stats.json"
    /// Plenty of history to browse without letting the file grow forever.
    static let historyLimit = 300

    private static var url: URL? {
        let fm = FileManager.default
        guard let dir = try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                    appropriateFor: nil, create: true) else { return nil }
        return dir.appendingPathComponent(filename)
    }

    /// Oldest first — the order games were played, which is what streak maths needs.
    static func load() -> [GameRecord] {
        guard let url, let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([GameRecord].self, from: data)) ?? []
    }

    /// Append a finished game, trimming the oldest beyond `historyLimit`. Best-effort: a failed write
    /// costs a line of history, never a game.
    static func record(_ record: GameRecord) {
        var all = load()
        all.append(record)
        if all.count > historyLimit { all.removeFirst(all.count - historyLimit) }
        save(all)
    }

    static func summary() -> StatsSummary { StatsSummary(records: load()) }

    /// Most recent first, for display.
    static func recentFirst() -> [GameRecord] { load().reversed() }

    static func clear() {
        guard let url else { return }
        try? FileManager.default.removeItem(at: url)
    }

    private static func save(_ records: [GameRecord]) {
        guard let url, let data = try? JSONEncoder().encode(records) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
