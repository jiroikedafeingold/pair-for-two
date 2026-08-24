import SwiftUI
import GameKit

/// Game Center achievements and the wins leaderboard.
///
/// Everything is reported from the local game history rather than from a server: the app has no
/// accounts and no backend, so what's earned is decided by the same records the Stats screen shows.
/// That has a consequence worth stating — a player who deletes the app starts these from scratch,
/// because the history they're computed from went with it. Game Center keeps whatever was already
/// earned; only progress towards the not-yet-earned ones resets.
///
/// The identifiers are the vendor identifiers configured in App Store Connect. They're a shipped
/// contract: renaming one orphans everything players have earned under it.
enum GameCenterAwards {

    enum ID {
        static let firstWin = "first_win"
        static let skunk = "skunk"
        static let doubleSkunk = "double_skunk"
        static let bigHand = "big_hand_24"
        static let perfect29 = "perfect_29"
        static let comeback = "comeback_30"
        static let streakFive = "streak_5"
        static let hundredHands = "hands_100"
    }

    static let winsLeaderboardID = "lifetime_wins"

    /// What counts as a comeback, in points behind at the worst moment.
    static let comebackDeficit = 30

    /// Report everything a finished game may have earned, plus the running wins total.
    ///
    /// `game` is the game just played; `summary` is the lifetime rollup *including* it (so "first win"
    /// and the streak read correctly); `worstDeficit` is how far behind this device fell during the
    /// game, which nothing persists — a comeback is only knowable while it's being played.
    ///
    /// Silent when Game Center isn't signed in: online play is optional in this app, and a nearby game
    /// shouldn't nag about an account it doesn't need.
    static func report(game: GameRecord, summary: StatsSummary, worstDeficit: Int) {
        guard GKLocalPlayer.local.isAuthenticated else { return }

        var earned: [String: Double] = [:]
        func complete(_ id: String) { earned[id] = 100 }

        if summary.wins >= 1 { complete(ID.firstWin) }
        if game.skunkedThem { complete(ID.skunk) }
        if game.youWon && game.isDoubleSkunk { complete(ID.doubleSkunk) }
        if game.yourBestHand >= 24 { complete(ID.bigHand) }
        if game.yourBestHand >= 29 { complete(ID.perfect29) }
        if game.youWon && worstDeficit >= comebackDeficit { complete(ID.comeback) }
        if summary.longestWinStreak >= 5 { complete(ID.streakFive) }
        // Partial progress is worth showing for the long one: 100 hands is a lot of cribbage.
        earned[ID.hundredHands] = min(100, Double(summary.hands))

        let achievements: [GKAchievement] = earned.map { id, percent in
            let a = GKAchievement(identifier: id)
            a.percentComplete = percent
            a.showsCompletionBanner = true
            return a
        }
        GKAchievement.report(achievements) { _ in }   // best-effort; GameKit retries its own queue

        GKLeaderboard.submitScore(summary.wins, context: 0, player: GKLocalPlayer.local,
                                  leaderboardIDs: [winsLeaderboardID]) { _ in }
    }
}

// MARK: - Dashboard

/// Game Center's own achievements/leaderboard UI, so what the app reports is actually visible.
/// GameKit hands over a `UIViewController`, so this thin representable is unavoidable — the same
/// arrangement as `MatchmakerView`.
struct GameCenterDashboardView: UIViewControllerRepresentable {
    var state: GKGameCenterViewControllerState = .achievements
    var onDone: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onDone: onDone) }

    func makeUIViewController(context: Context) -> GKGameCenterViewController {
        let controller = GKGameCenterViewController(state: state)
        controller.gameCenterDelegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ viewController: GKGameCenterViewController, context: Context) {}

    final class Coordinator: NSObject, GKGameCenterControllerDelegate {
        private let onDone: () -> Void
        init(onDone: @escaping () -> Void) { self.onDone = onDone }

        func gameCenterViewControllerDidFinish(_ gameCenterViewController: GKGameCenterViewController) {
            onDone()
        }
    }
}
