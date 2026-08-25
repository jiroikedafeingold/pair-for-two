import SwiftUI
import GameKit

/// This device's game history: lifetime totals over a list of finished games. Presented as a sheet from
/// the menu, in the same `Form` idiom as Settings and Help, so it scrolls, scales with Dynamic Type and
/// reads correctly under VoiceOver on both iPhone and iPad without a bespoke layout.
///
/// Everything here comes from `StatsStore` on this phone. There are no accounts and nothing syncs, so
/// each device keeps its own record — a fact the footer states plainly rather than leaving to be
/// discovered when a reinstall empties it.
struct StatsView: View {
    var onDone: () -> Void

    @State private var summary = StatsSummary()
    @State private var games: [GameRecord] = []
    @State private var confirmingClear = false
    @State private var showingGameCenter = false

    var body: some View {
        NavigationStack {
            Form {
                if summary.games == 0 {
                    Section {
                        VStack(spacing: 8) {
                            Image(systemName: "chart.bar.doc.horizontal")
                                .font(.system(size: 34, weight: .semibold))
                                .foregroundStyle(Color.cribGold)
                            Text("No finished games yet").font(.headline)
                            Text("Play a game to 121 and it lands here — with your skunks, your best hand, and the running tally.")
                                .font(.caption).foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                    }
                } else {
                    Section("Lifetime") {
                        LabeledContent("Games") { Text(verbatim: "\(summary.games)") }
                        LabeledContent("Won") {
                            Text("\(summary.wins) of \(summary.games)  ·  \(percent(summary.winRate))",
                                 comment: "Games won: count, total, then a percentage")
                        }
                        LabeledContent("Skunks") { Text(verbatim: skunkLine) }
                        LabeledContent("Best hand") {
                            if summary.bestHand > 0 {
                                Text("\(summary.bestHand) points", comment: "Best hand ever counted; %lld is the score")
                            } else {
                                Text(verbatim: "—")
                            }
                        }
                        LabeledContent("Win streak") { Text(verbatim: streakLine) }
                        LabeledContent("Hands played") { Text(verbatim: "\(summary.hands)") }
                        LabeledContent("Time at the table") { Text(verbatim: durationText(summary.totalPlayTime)) }
                    }

                    Section {
                        ForEach(games) { game in row(game) }
                    } header: {
                        Text("Recent games")
                    } footer: {
                        Text("Kept on this device only — nothing is synced or shared, so a reinstall clears it. The last \(StatsStore.historyLimit) games are stored.")
                    }

                    Section {
                        Button("Clear history", role: .destructive) { confirmingClear = true }
                    }
                }

                // Achievements and the wins leaderboard live in Game Center, reported from the same
                // history above. Shown whether or not anything has been played yet — it's also where
                // you find out what there is to earn.
                Section {
                    Button {
                        showingGameCenter = true
                    } label: {
                        Label("Achievements & leaderboard", systemImage: "trophy.fill")
                    }
                    .disabled(!GKLocalPlayer.local.isAuthenticated)
                } footer: {
                    if GKLocalPlayer.local.isAuthenticated {
                        Text("Earned from the games above and reported to Game Center.",
                             comment: "Footer under the achievements row")
                    } else {
                        Text("Sign in to Game Center in the Settings app to collect achievements.",
                             comment: "Footer under the achievements row when not signed in")
                    }
                }
            }
            .navigationTitle("Stats")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: onDone).fontWeight(.semibold)
                }
            }
            .confirmationDialog("Clear your game history?", isPresented: $confirmingClear, titleVisibility: .visible) {
                Button("Clear history", role: .destructive) {
                    StatsStore.clear()
                    reload()
                }
                Button("Keep it", role: .cancel) {}
            } message: {
                Text("This erases every recorded game on this phone. It can't be undone.")
            }
        }
        .fullScreenCover(isPresented: $showingGameCenter) {
            GameCenterDashboardView(state: .achievements) { showingGameCenter = false }
                .ignoresSafeArea()
        }
        .onAppear(perform: reload)
    }

    private func reload() {
        games = StatsStore.recentFirst()
        summary = StatsSummary(records: StatsStore.load())
    }

    // MARK: One game

    @ViewBuilder private func row(_ game: GameRecord) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Image(systemName: game.youWon ? "crown.fill" : "circle")
                    .font(.caption)
                    .foregroundStyle(game.youWon ? Color.cribGold : .secondary)
                Text(verbatim: "\(game.yourScore) – \(game.opponentScore)")
                    .font(.body.weight(.semibold)).monospacedDigit()
                Text("vs \(game.opponentName)", comment: "Opponent in a past game; %@ is their name")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if let badge = skunkBadge(game) {
                    Text(verbatim: badge)
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Capsule().fill(game.youWon ? Color.cribGold.opacity(0.85) : Color.secondary.opacity(0.25)))
                        .foregroundStyle(game.youWon ? .black : .primary)
                }
            }
            Text(verbatim: detailLine(game))
                .font(.caption2).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(verbatim: accessibleSummary(game)))
    }

    /// The badge on a past game. Built as four whole strings rather than by appending "ED" to a
    /// stem — suffixing a word is an English-only trick.
    private func skunkBadge(_ game: GameRecord) -> String? {
        guard game.isSkunk else { return nil }
        switch (game.isDoubleSkunk, game.youWon) {
        case (true, true):   return String(localized: "DOUBLE SKUNK", comment: "Badge: you won with the loser under 61; shown in capitals")
        case (true, false):  return String(localized: "DOUBLE SKUNKED", comment: "Badge: you lost with under 61; shown in capitals")
        case (false, true):  return String(localized: "SKUNK", comment: "Badge: you won with the loser under 91; shown in capitals")
        case (false, false): return String(localized: "SKUNKED", comment: "Badge: you lost with under 91; shown in capitals")
        }
    }

    private func detailLine(_ game: GameRecord) -> String {
        var parts = [game.finishedAt.formatted(date: .abbreviated, time: .shortened)]
        parts.append(String(localized: "^[\(game.hands) hand](inflect: true)",
                            comment: "How many hands a game lasted; %lld is the count"))
        parts.append(durationText(game.duration))
        parts.append(game.youDealtFirst
                     ? String(localized: "you dealt first", comment: "Who dealt the first hand")
                     : String(localized: "\(game.opponentName) dealt first", comment: "%@ is the other player's name"))
        if game.yourBestHand > 0 {
            parts.append(String(localized: "best hand \(game.yourBestHand)",
                                comment: "Your best count in that game; %lld is the score"))
        }
        return parts.joined(separator: "  ·  ")
    }

    private func accessibleSummary(_ game: GameRecord) -> String {
        let outcome = game.youWon
            ? String(localized: "Won", comment: "VoiceOver: you won this game")
            : String(localized: "Lost", comment: "VoiceOver: you lost this game")
        let skunk: String
        switch (game.isSkunk, game.isDoubleSkunk) {
        case (true, true):  skunk = String(localized: ", double skunk", comment: "VoiceOver, appended to a result")
        case (true, false): skunk = String(localized: ", skunk", comment: "VoiceOver, appended to a result")
        default:            skunk = ""
        }
        return String(localized: "\(outcome) \(game.yourScore) to \(game.opponentScore) against \(game.opponentName)\(skunk). \(game.hands) hands, \(durationText(game.duration)).",
                      comment: "VoiceOver summary of one past game")
    }

    // MARK: Formatting

    private var skunkLine: String {
        guard summary.skunksInflicted > 0 || summary.skunksSuffered > 0 else {
            return String(localized: "none yet", comment: "No skunks recorded yet")
        }
        let forCount = summary.doubleSkunksInflicted > 0
            ? String(localized: "\(summary.skunksInflicted) for (\(summary.doubleSkunksInflicted) double)",
                     comment: "Skunks you inflicted; first %lld is the total, second how many were doubles")
            : String(localized: "\(summary.skunksInflicted) for", comment: "Skunks you inflicted; %lld is the count")
        return String(localized: "\(forCount), \(summary.skunksSuffered) against",
                      comment: "Skunks for and against; %@ is the 'for' half, %lld the count against")
    }

    private var streakLine: String {
        if summary.currentWinStreak > 1 {
            return String(localized: "\(summary.currentWinStreak) now  ·  best \(summary.longestWinStreak)",
                          comment: "Current win streak and the best ever; both %lld are counts")
        }
        guard summary.longestWinStreak > 0 else { return "—" }
        return String(localized: "best \(summary.longestWinStreak)", comment: "Best win streak; %lld is the count")
    }

    private func percent(_ rate: Double) -> String {
        rate.formatted(.percent.precision(.fractionLength(0)))
    }

    /// Hours and minutes, or minutes alone under an hour — a cribbage game is tens of minutes, so
    /// seconds are noise.
    private func durationText(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let hours = total / 3600, minutes = (total % 3600) / 60
        if hours > 0 {
            return String(localized: "\(hours)h \(minutes)m", comment: "A duration in hours and minutes")
        }
        if minutes > 0 {
            return String(localized: "\(minutes)m", comment: "A duration in minutes")
        }
        return String(localized: "under a minute", comment: "A duration shorter than a minute")
    }
}

#if DEBUG
/// Fixture-backed preview: writes a handful of games to the real store so the screen renders with
/// content, then shows it. Debug-only, like every other preview here.
private struct StatsPreviewHarness: View {
    init() {
        StatsStore.clear()
        let now = Date()
        let games: [(Int, Int, Int, Int, Double, Bool)] = [
            (121, 95, 12, 9, 1500, true), (121, 88, 20, 8, 1320, false), (55, 121, 8, 10, 1680, true),
            (121, 60, 24, 7, 1140, false), (121, 119, 16, 12, 2100, true), (121, 40, 29, 6, 980, false)
        ]
        for (i, g) in games.enumerated() {
            StatsStore.record(GameRecord(id: UUID(),
                                         finishedAt: now.addingTimeInterval(Double(i - games.count) * 86_400),
                                         yourName: "Ann", opponentName: "Ben",
                                         yourScore: g.0, opponentScore: g.1, youDealtFirst: g.5,
                                         duration: g.4, hands: g.3, yourBestHand: g.2))
        }
    }
    var body: some View { StatsView(onDone: {}) }
}

#Preview("Stats") { StatsPreviewHarness() }

#Preview("Stats — empty") {
    StatsStore.clear()
    return StatsView(onDone: {})
}
#endif
