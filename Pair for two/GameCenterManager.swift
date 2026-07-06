import GameKit
import Observation
import UIKit

/// Owns the device's Game Center sign-in, used by online (remote) play. It deliberately does no
/// matchmaking — that's Phase 2. SwiftUI reads `isAuthenticated` to enable the online entry point.
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

    /// The signed-in player's Game Center name (empty until authenticated).
    var localDisplayName: String {
        GKLocalPlayer.local.isAuthenticated ? GKLocalPlayer.local.displayName : ""
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
            // Phase 2 will `GKLocalPlayer.local.register(self)` here to receive game invitations.
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
