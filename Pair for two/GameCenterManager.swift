import GameKit
import Observation
import UIKit

/// Owns the device's Game Center sign-in and matchmaking entry points for online (remote) play.
/// SwiftUI reads `isAuthenticated` to enable the online entry point and builds a matchmaker UI via
/// `makeMatchmakerViewController`.
///
/// Game Center identity is device-global, so `RootView` creates one instance and calls
/// `authenticate()` once at launch. Nearby (Multipeer) play does not depend on this.
@MainActor
@Observable
final class GameCenterManager: NSObject {

    /// True once the local player has signed in to Game Center on this device.
    private(set) var isAuthenticated = false

    /// Why online play is unavailable (not signed in, restricted, …), or nil when it's available.
    private(set) var unavailableReason: String?

    /// A match that became ready when this device accepted an invitation. `matchTick` bumps so
    /// `RootView` starts the game.
    private(set) var pendingMatch: GKMatch?
    private(set) var matchTick = 0
    private var didRegisterListener = false

    /// A friendly error to surface in an alert (e.g. Game Center not set up, or a network failure).
    var presentedError: String?

    /// Turn a raw Game Center error into a clear, human message — or nil if it was just a cancel
    /// (nothing to show). Notably maps `.gameUnrecognized` (the "not recognized by Game Center" error
    /// you hit before the app is registered for Game Center).
    static func friendlyMessage(for error: Error) -> String? {
        guard let gkError = error as? GKError else { return error.localizedDescription }
        switch gkError.code {
        case .cancelled:
            return nil
        case .gameUnrecognized:
            return "Online play isn't set up for this app yet. Game Center doesn't recognize this build — this clears once the app is enabled for Game Center in App Store Connect (and can take a little while to take effect)."
        case .notAuthenticated:
            return "Sign in to Game Center in the Settings app to play online."
        case .communicationsFailure, .unknown:
            return "Couldn't reach Game Center. Check your internet connection and try again."
        default:
            return "Couldn't start the online game. Please try again. (Game Center error \(gkError.code.rawValue).)"
        }
    }

    /// Surface an error in the alert, unless it was a cancel.
    func report(_ error: Error) {
        if let message = Self.friendlyMessage(for: error) { presentedError = message }
    }

    /// The signed-in player's Game Center name (empty until authenticated).
    var localDisplayName: String {
        GKLocalPlayer.local.isAuthenticated ? GKLocalPlayer.local.displayName : ""
    }

    // MARK: Custom friend invite (avoids the flaky automatch path)

    /// Friends + recent players, deduped and sorted by name, for the in-app invite list. Game Center
    /// gates friend access, so this can be empty (friend hasn't run the game / authorized) — the UI
    /// then offers Apple's own picker as a fallback.
    func loadInvitablePlayers() async -> [GKPlayer] {
        let recents = await players { GKLocalPlayer.local.loadRecentPlayers(completionHandler: $0) }
        let challengeable = await players { GKLocalPlayer.local.loadChallengableFriends(completionHandler: $0) }
        var byID: [String: GKPlayer] = [:]
        for player in recents + challengeable { byID[player.gamePlayerID] = player }
        return byID.values.sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    private func players(_ load: (@escaping @Sendable ([GKPlayer]?, (any Error)?) -> Void) -> Void) async -> [GKPlayer] {
        await withCheckedContinuation { continuation in
            load { fetched, _ in continuation.resume(returning: fetched ?? []) }
        }
    }

    /// Hand off (and clear) a ready match so it's only started once.
    func takePendingMatch() -> GKMatch? {
        defer { pendingMatch = nil }
        return pendingMatch
    }

    private func deliver(_ match: GKMatch) {
        pendingMatch = match
        matchTick += 1
    }

    /// Build Apple's own matchmaking UI. Pass a `recipient` to target a specific friend directly
    /// (Apple's UI reliably delivers the invite — the programmatic `findMatch` path did not); pass nil
    /// for the generic picker (Invite Players / Quick Match). Returns nil if matchmaking is unavailable.
    func makeMatchmakerViewController(recipient: GKPlayer? = nil) -> GKMatchmakerViewController? {
        let request = GKMatchRequest()
        request.minPlayers = 2
        request.maxPlayers = 2
        if let recipient {
            request.recipients = [recipient]
            request.inviteMessage = "Let's play Pair for Two!"
        }
        return GKMatchmakerViewController(matchRequest: request)
    }

    /// Begin Game Center sign-in. GameKit may call the handler several times — once handing back a
    /// sign-in view controller to present, and again with the final result. Safe to call once at launch.
    func authenticate() {
        GKLocalPlayer.local.authenticateHandler = { [weak self] viewController, error in
            // GameKit may invoke this off the main actor; hop on, matching the app's transport code.
            Task { @MainActor in
                self?.handle(viewController: viewController, error: error)
            }
        }
    }

    private func handle(viewController: UIViewController?, error: Error?) {
        if let viewController {
            present(viewController)   // the player needs to sign in / create an account
            return
        }
        isAuthenticated = GKLocalPlayer.local.isAuthenticated
        if isAuthenticated {
            unavailableReason = nil
            if !didRegisterListener {
                GKLocalPlayer.local.register(self)   // receive game invitations from friends
                didRegisterListener = true
            }
        } else if let error {
            unavailableReason = Self.friendlyMessage(for: error) ?? "Sign in to Game Center to play online."
        } else {
            unavailableReason = "Sign in to Game Center to play online."
        }
    }

    /// Present a GameKit-supplied view controller (the sign-in flow). GameKit hands us a
    /// `UIViewController`, so a little presentation interop is unavoidable — put it atop the key window.
    private func present(_ viewController: UIViewController) {
        guard let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState == .foregroundActive }),
              let root = scene.keyWindow?.rootViewController else { return }
        var top = root
        while let presented = top.presentedViewController { top = presented }
        top.present(viewController, animated: true)
    }
}

// MARK: - Invitations

extension GameCenterManager: GKLocalPlayerListener {
    /// The local player accepted an invitation (from a Game Center notification / their friend's
    /// invite). Resolve it to a match programmatically and start the game — no matchmaker UI needed.
    nonisolated func player(_ player: GKPlayer, didAccept invite: GKInvite) {
        GKMatchmaker.shared().match(for: invite) { [weak self] match, error in
            Task { @MainActor in
                guard let self else { return }
                if let match { self.deliver(match) }
                else if let error { self.report(error) }
            }
        }
    }
}
