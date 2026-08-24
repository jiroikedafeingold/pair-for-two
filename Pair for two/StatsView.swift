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
                        LabeledContent("Games") { Text("\(summary.games)") }
                        LabeledContent("Won") { Text("\(summary.wins) of \(summary.games)  ·  \(percent(summary.winRate))") }
                        LabeledContent("Skunks") { Text(skunkLine) }
                        LabeledContent("Best hand") { Text(summary.bestHand > 0 ? "\(summary.bestHand) points" : "—") }
                        LabeledContent("Win streak") { Text(streakLine) }
                        LabeledContent("Hands played") { Text("\(summary.hands)") }
                        LabeledContent("Time at the table") { Text(durationText(summary.totalPlayTime)) }
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
                    Text(GKLocalPlayer.local.isAuthenticated
                         ? "Earned from the games above and reported to Game Center."
                         : "Sign in to Game Center in the Settings app to collect achievements.")
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
                Text("\(game.yourScore) – \(game.opponentScore)")
                    .font(.body.weight(.semibold)).monospacedDigit()
                Text("vs \(game.opponentName)").font(.subheadline).foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if let badge = skunkBadge(game) {
                    Text(badge)
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Capsule().fill(game.youWon ? Color.cribGold.opacity(0.85) : Color.secondary.opacity(0.25)))
                        .foregroundStyle(game.youWon ? .black : .primary)
                }
            }
            Text(detailLine(game))
                .font(.caption2).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibleSummary(game))
    }

    private func skunkBadge(_ game: GameRecord) -> String? {
        guard game.isSkunk else { return nil }
        let kind = game.isDoubleSkunk ? "DOUBLE SKUNK" : "SKUNK"
        return game.youWon ? kind : "\(kind)ED"
    }

    private func detailLine(_ game: GameRecord) -> String {
        var parts = [game.finishedAt.formatted(date: .abbreviated, time: .shortened)]
        parts.append("\(game.hands) hand\(game.hands == 1 ? "" : "s")")
        parts.append(durationText(game.duration))
        parts.append(game.youDealtFirst ? "you dealt first" : "\(game.opponentName) dealt first")
        if game.yourBestHand > 0 { parts.append("best hand \(game.yourBestHand)") }
        return parts.joined(separator: "  ·  ")
    }

    private func accessibleSummary(_ game: GameRecord) -> String {
        let outcome = game.youWon ? "Won" : "Lost"
        let skunk = game.isSkunk ? (game.isDoubleSkunk ? ", double skunk" : ", skunk") : ""
        return "\(outcome) \(game.yourScore) to \(game.opponentScore) against \(game.opponentName)\(skunk). "
            + "\(game.hands) hands, \(durationText(game.duration))."
    }

    // MARK: Formatting

    private var skunkLine: String {
        guard summary.skunksInflicted > 0 || summary.skunksSuffered > 0 else { return "none yet" }
        var text = "\(summary.skunksInflicted) for"
        if summary.doubleSkunksInflicted > 0 { text += " (\(summary.doubleSkunksInflicted) double)" }
        text += ", \(summary.skunksSuffered) against"
        return text
    }

    private var streakLine: String {
        if summary.currentWinStreak > 1 { return "\(summary.currentWinStreak) now  ·  best \(summary.longestWinStreak)" }
        return summary.longestWinStreak > 0 ? "best \(summary.longestWinStreak)" : "—"
    }

    private func percent(_ rate: Double) -> String {
        rate.formatted(.percent.precision(.fractionLength(0)))
    }

    /// Hours and minutes, or minutes alone under an hour — a cribbage game is tens of minutes, so
    /// seconds are noise.
    private func durationText(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let hours = total / 3600, minutes = (total % 3600) / 60
        if hours > 0 { return "\(hours)h \(minutes)m" }
        if minutes > 0 { return "\(minutes)m" }
        return "under a minute"
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
