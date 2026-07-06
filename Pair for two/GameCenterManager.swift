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

    /// An invitation the local player accepted from Game Center (via Messages/notification).
    /// `inviteTick` bumps whenever one arrives so the UI can react and present the matchmaker for it.
    private(set) var pendingInvite: GKInvite?
    private(set) var inviteTick = 0
    private var didRegisterListener = false

    /// The signed-in player's Game Center name (empty until authenticated).
    var localDisplayName: String {
        GKLocalPlayer.local.isAuthenticated ? GKLocalPlayer.local.displayName : ""
    }

    /// Build Game Center's matchmaking UI — a fresh 2-player match, or the accept flow for an
    /// incoming `invite`. Returns nil if matchmaking isn't available (e.g. not signed in).
    func makeMatchmakerViewController(invite: GKInvite? = nil) -> GKMatchmakerViewController? {
        if let invite { return GKMatchmakerViewController(invite: invite) }
        let request = GKMatchRequest()
        request.minPlayers = 2
        request.maxPlayers = 2
        return GKMatchmakerViewController(matchRequest: request)
    }

    /// Hand off (and clear) a pending accepted invitation so it's only acted on once.
    func takePendingInvite() -> GKInvite? {
        defer { pendingInvite = nil }
        return pendingInvite
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
        } else {
            unavailableReason = error?.localizedDescription ?? "Sign in to Game Center to play online."
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
    /// The local player accepted an invitation (from Messages / a Game Center notification). Surface it
    /// so `RootView` can present the matchmaker in its accept state and start the match.
    nonisolated func player(_ player: GKPlayer, didAccept invite: GKInvite) {
        Task { @MainActor in
            self.pendingInvite = invite
            self.inviteTick += 1
        }
    }
}
