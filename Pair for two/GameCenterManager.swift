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

    /// A fully-connected match ready to play, with the elected host role. `matchTick` bumps so
    /// `RootView` starts the game.
    private(set) var pendingMatch: GKMatch?
    private(set) var pendingIsHost = false
    private(set) var matchTick = 0
    private var didRegisterListener = false

    /// A match we're holding until its opponent actually connects (so host election is reliable).
    private var awaitingMatch: GKMatch?

    /// Progress of a one-tap friend invite, for the invite UI.
    enum InviteState: Equatable { case idle, inviting(String), failed(String) }
    private(set) var inviteState: InviteState = .idle

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

    /// One-tap invite: ask Game Center to invite this specific friend to a new 2-player match. When
    /// they accept and the match connects, `beginMatch` elects the host and starts the game. The UI
    /// shows "Inviting…", and `recipientResponseHandler` surfaces a decline / no-answer so it never
    /// hangs. Apple's own picker remains available as a fallback.
    func invite(_ player: GKPlayer) {
        let request = GKMatchRequest()
        request.minPlayers = 2
        request.maxPlayers = 2
        request.recipients = [player]
        request.inviteMessage = "Let's play Pair for Two!"
        inviteState = .inviting(player.displayName)
        request.recipientResponseHandler = { [weak self] responder, response in
            Task { @MainActor in
                guard let self, case .inviting = self.inviteState else { return }
                switch response {
                case .accepted:
                    break   // they'll connect; beginMatch takes over
                case .declined:
                    self.cancelInvite()
                    self.inviteState = .failed("\(responder.displayName) declined.")
                default:
                    self.cancelInvite()
                    self.inviteState = .failed("No response from \(responder.displayName). Make sure they're signed into Game Center, or use the Game Center inviter below.")
                }
            }
        }
        GKMatchmaker.shared().findMatch(for: request) { [weak self] match, error in
            Task { @MainActor in
                guard let self, case .inviting = self.inviteState else { return }
                if let match {
                    self.beginMatch(match)
                } else if let error, let message = Self.friendlyMessage(for: error) {
                    self.inviteState = .failed(message)
                } else {
                    self.inviteState = .idle
                }
            }
        }
    }

    /// Cancel a pending one-tap invite.
    func cancelInvite() {
        GKMatchmaker.shared().cancel()
        awaitingMatch = nil
        inviteState = .idle
    }

    /// Take a ready match once, from either path (an accepted invite, or the matchmaker's `didFind`).
    /// Waits until the opponent has actually connected before electing a host, so the two devices can't
    /// both default to host when `match.players` is momentarily empty at start.
    func beginMatch(_ match: GKMatch) {
        if match.players.isEmpty {
            awaitingMatch = match
            match.delegate = self          // wait for the opponent's .connected
        } else {
            finalize(match)
        }
    }

    private func finalize(_ match: GKMatch) {
        awaitingMatch = nil
        inviteState = .idle
        // Deterministic host election: the lower Game Center id hosts. gamePlayerID is stable per
        // player for this game across both devices, so both compute the same single host.
        let localID = GKLocalPlayer.local.gamePlayerID
        pendingIsHost = match.players.first.map { localID < $0.gamePlayerID } ?? true
        pendingMatch = match
        matchTick += 1
    }

    /// Hand off (and clear) the ready match + its elected host role so it's only started once.
    func takePendingMatch() -> (match: GKMatch, isHost: Bool)? {
        guard let match = pendingMatch else { return nil }
        pendingMatch = nil
        return (match, pendingIsHost)
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

// MARK: - Awaiting the opponent's connection

extension GameCenterManager: GKMatchDelegate {
    /// While holding a match in `beginMatch`, start it once the opponent connects. The transport takes
    /// over as the match's delegate when the game starts.
    nonisolated func match(_ match: GKMatch, player: GKPlayer, didChange state: GKPlayerConnectionState) {
        Task { @MainActor in
            guard self.awaitingMatch === match else { return }
            if state == .connected, !match.players.isEmpty { self.finalize(match) }
        }
    }
}

// MARK: - Invitations

extension GameCenterManager: GKLocalPlayerListener {
    /// The local player accepted an invitation (from a Game Center notification / their friend's
    /// invite). Resolve it to a match and start once connected — no matchmaker UI needed.
    nonisolated func player(_ player: GKPlayer, didAccept invite: GKInvite) {
        GKMatchmaker.shared().match(for: invite) { [weak self] match, error in
            Task { @MainActor in
                guard let self else { return }
                if let match { self.beginMatch(match) }
                else if let error { self.report(error) }
            }
        }
    }
}
