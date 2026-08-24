import SwiftUI
import GameKit

/// App entry. Two-phone play: set up your own name/colour, then Play nearby (Multipeer) or Play
/// online (Game Center). Single-device pass-and-play was removed — this is a two-phone game.
struct RootView: View {
    private enum Screen { case menu, connect, rejoiningOnline, game }

    @State private var screen: Screen = .menu
    @State private var vm: GameViewModel?
    @State private var showingSettings = false
    @State private var resumeMarker: GamePersistence.ResumeMarker? = GamePersistence.loadMarker()
    @State private var resumeRole: ResumeRole? = nil
    @State private var gameCenter = GameCenterManager()
    @State private var showingInvite = false                  // custom "invite a friend" sheet
    @State private var pendingFallbackPicker = false          // present Apple's picker after the sheet closes
    @State private var activeMatchmaker: MatchmakerContext?   // Apple's matchmaking UI (fallback)
    @State private var wasBackgrounded = false                // distinguish a real background from a transient inactive
    @State private var showingHelp = false
    @State private var showingStats = false
    /// The live online transport, if the current game is an online one. Held so a Game Center match
    /// that arrives *during* a game (the other player re-inviting us after a drop) can be handed to it
    /// rather than starting a new game over the top of the one in progress.
    @State private var onlineTransport: GameCenterTransport?
    /// Online rejoin-after-force-quit bookkeeping: who we're waiting for, whether this device holds the
    /// saved position (and so does the inviting), and anything that went wrong worth telling them.
    @State private var rejoinOpponentName: String?
    @State private var rejoinIsHost = false
    @State private var rejoinFailure: String?
    @State private var showOnboarding = false
    @AppStorage("hasOnboarded") private var hasOnboarded = false
    @Environment(\.scenePhase) private var scenePhase

    @AppStorage("localName") private var name = "Player"
    @AppStorage("localColorID") private var colorID = 1
    @AppStorage("scoringMode") private var scoringModeRaw = ScoringMode.off.rawValue

    /// Trimmed, non-empty player name.
    private var playerName: String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "Player" : trimmed
    }

    var body: some View {
        content
            .task { gameCenter.authenticate() }   // Game Center sign-in for online play
            .task { if !hasOnboarded { showOnboarding = true } }   // first-run welcome
            .fullScreenCover(isPresented: $showOnboarding) {
                OnboardingView(onFinish: { hasOnboarded = true; showOnboarding = false })
            }
            .sheet(isPresented: $showingHelp) {
                HelpView(onDone: { showingHelp = false },
                         onReplayOnboarding: { showingHelp = false; showOnboarding = true })
            }
            .onChange(of: scenePhase) { _, phase in
                switch phase {
                case .active:
                    // After a real background the link is almost certainly dead but the OS may still
                    // report it connected — force a rebuild so we re-pair in seconds, not ~30s. A mere
                    // transient inactive (control centre, a banner) does a plain, non-destructive nudge.
                    vm?.reconnect(force: wasBackgrounded)
                    wasBackgrounded = false
                case .background:
                    wasBackgrounded = true
                    vm?.persist()      // save the game if we're being closed
                case .inactive:
                    vm?.persist()
                @unknown default:
                    break
                }
            }
            // A match connected (a friend accepted our invite, or we accepted theirs) — start it with
            // the host role the manager elected once both players were actually connected.
            //
            // Unless a game is already running on this device: then the match is a *rejoin* of it (the
            // other phone dropped and re-invited us), so it's handed to the live transport instead.
            // Starting a new game here would throw away the position we're mid-way through.
            .onChange(of: gameCenter.matchTick) { _, _ in
                guard let ready = gameCenter.takePendingMatch() else { return }
                if screen == .game, let transport = onlineTransport {
                    transport.adopt(ready.match)
                } else if let marker = GamePersistence.loadMarker(), marker.isOnline {
                    // An online game was interrupted and still has a saved position, so a match
                    // arriving now *is* that game being picked back up — whatever screen we're on.
                    // Keying this off the marker rather than the rejoin screen matters: accepting the
                    // invitation can cold-launch the app, and starting a fresh game there would throw
                    // the saved position away. Explicitly starting a new online game clears the marker
                    // first (see the Play online button), so that case still lands below.
                    resumeOnlineGame(ready.match, marker: marker)
                } else {
                    startOnlineGame(ready.match, isHost: ready.isHost)
                }
            }
            // Custom "invite a friend" list. Tapping a friend sends a one-tap invite in place; the
            // "Invite with Game Center" button closes this sheet and opens Apple's picker (presented
            // only after dismissal completes, since SwiftUI can't present while dismissing).
            .sheet(isPresented: $showingInvite, onDismiss: {
                if pendingFallbackPicker { pendingFallbackPicker = false; presentApplePicker() }
            }) {
                InvitePlayersView(gameCenter: gameCenter,
                                  onUseGameCenterPicker: { pendingFallbackPicker = true; showingInvite = false },
                                  onCancel: { gameCenter.cancelInvite(); showingInvite = false })
            }
            .fullScreenCover(item: $activeMatchmaker) { context in
                MatchmakerView(controller: context.controller,
                               onMatch: { activeMatchmaker = nil; gameCenter.beginMatch($0) },
                               onCancel: { activeMatchmaker = nil },
                               onError: { error in activeMatchmaker = nil; gameCenter.report(error) })
                    .ignoresSafeArea()
            }
            .alert("Online play unavailable",
                   isPresented: Binding(get: { gameCenter.presentedError != nil },
                                        set: { if !$0 { gameCenter.presentedError = nil } })) {
                Button("OK", role: .cancel) { gameCenter.presentedError = nil }
            } message: {
                Text(gameCenter.presentedError ?? "")
            }
    }

    // MARK: Online (Game Center) matchmaking

    private func presentApplePicker() {
        guard let controller = gameCenter.makeMatchmakerViewController() else { return }
        activeMatchmaker = MatchmakerContext(controller: controller)
    }

    // MARK: Rejoining an online game after a force-quit

    /// Pick an online game back up after the app was killed. Both matches are gone, so this is about
    /// finding the same Game Center player again and rebuilding around the saved state.
    ///
    /// Exactly one device holds the authoritative `GameState` (only a host ever writes it), and that's
    /// the device that invites: it has the position, so it decides who hosts, regardless of the
    /// gamePlayerID election a fresh match would use. The other device waits for the invitation —
    /// deterministic, and it can't produce two matches the way both sides inviting would.
    private func rejoinOnlineGame(_ marker: GamePersistence.ResumeMarker) {
        rejoinOpponentName = marker.opponentName
        rejoinIsHost = GamePersistence.hasSavedState
        rejoinFailure = nil
        screen = .rejoiningOnline

        guard rejoinIsHost else { return }   // guest: just wait for their invitation to arrive
        guard let id = marker.opponentGamePlayerID else {
            // Nothing to invite (a marker from before this existed). Let them pick from the list.
            rejoinFailure = "Choose who to rejoin from your Game Center friends and recent players."
            return
        }
        Task { @MainActor in
            if let player = await gameCenter.recentPlayer(withGamePlayerID: id) {
                gameCenter.invite(player)
            } else {
                rejoinFailure = "Couldn't find \(marker.opponentName ?? "your opponent") in Game Center. They may need to invite you instead — or pick them from your friends and recent players."
            }
        }
    }

    /// Pick the interrupted online game back up over a freshly rebuilt match. Whoever holds the saved
    /// `GameState` re-hosts it; the other device joins as a guest and gets resynced from it, exactly as
    /// a nearby resume does. Only one device can hold it — a guest's marker deletes any stale state
    /// file — so the roles can't collide.
    private func resumeOnlineGame(_ match: GKMatch, marker: GamePersistence.ResumeMarker) {
        showingInvite = false
        activeMatchmaker = nil
        resumeRole = nil
        let saved = GamePersistence.loadState()
        let transport = GameCenterTransport(match: match, isHost: saved != nil)
        onlineTransport = transport
        if let saved {
            vm = GameViewModel.resumeHost(transport: transport, savedState: saved,
                                          isOnline: true,
                                          onlineOpponentID: marker.opponentGamePlayerID,
                                          onlineOpponentName: marker.opponentName)
        } else {
            vm = GameViewModel.networked(transport: transport,
                                         localName: playerName, localColorID: colorID,
                                         scoringMode: ScoringMode(rawValue: scoringModeRaw) ?? .off,
                                         isOnline: true,
                                         onlineOpponentID: marker.opponentGamePlayerID,
                                         onlineOpponentName: marker.opponentName)
        }
        rejoinFailure = nil
        screen = .game
    }

    /// Build the online transport from a connected match (with the host role the manager already
    /// elected) and start a networked game.
    private func startOnlineGame(_ match: GKMatch, isHost: Bool) {
        showingInvite = false
        activeMatchmaker = nil
        // Starting an online game also forgets any in-progress nearby game.
        GamePersistence.clear()
        resumeMarker = nil
        let transport = GameCenterTransport(match: match, isHost: isHost)
        onlineTransport = transport   // kept so a rejoin can be handed to the running game
        resumeRole = nil
        let opponent = match.players.first
        vm = GameViewModel.networked(transport: transport,
                                     localName: playerName, localColorID: colorID,
                                     scoringMode: ScoringMode(rawValue: scoringModeRaw) ?? .off,
                                     isOnline: true,
                                     onlineOpponentID: opponent?.gamePlayerID,
                                     onlineOpponentName: opponent?.displayName)
        screen = .game
    }

    @ViewBuilder private var content: some View {
        switch screen {
        case .menu:
            menu

        case .connect:
            ConnectView(localName: playerName, localColorID: colorID, resumeRole: resumeRole,
                        onConnected: { session in
                            // For a resume, the host is whichever phone actually holds the saved
                            // state — not the (possibly stale) role marker. This keeps the two phones
                            // from both trying to host after a rendezvous reconnect.
                            if resumeRole != nil, let saved = GamePersistence.loadState() {
                                session.isHost = true
                                vm = GameViewModel.resumeHost(transport: session, savedState: saved)
                            } else if resumeRole != nil {
                                session.isHost = false   // guest rejoining; the host resyncs it
                                vm = GameViewModel.networked(transport: session,
                                                             localName: playerName,
                                                             localColorID: colorID,
                                                             scoringMode: ScoringMode(rawValue: scoringModeRaw) ?? .off)
                            } else {
                                // Fresh game — isHost was already set by Host/Join. Starting a new game
                                // forgets any other in-progress game on this device (the new game writes
                                // its own resume marker as it plays).
                                GamePersistence.clear()
                                resumeMarker = nil
                                vm = GameViewModel.networked(transport: session,
                                                             localName: playerName,
                                                             localColorID: colorID,
                                                             scoringMode: ScoringMode(rawValue: scoringModeRaw) ?? .off)
                            }
                            screen = .game
                        },
                        onCancel: { screen = .menu })

        case .rejoiningOnline:
            onlineRejoinWaiting

        case .game:
            if let vm {
                GameTableView(vm: vm, onExit: {
                    self.vm = nil
                    onlineTransport = nil
                    resumeRole = nil
                    resumeMarker = nil    // the game was cleared on quit — no "Rejoin" to offer
                    screen = .menu
                })
            } else {
                Color.feltDark.ignoresSafeArea()
            }
        }
    }

    /// Waiting to pick a force-quit online game back up. Which side you're on decides what happens:
    /// the device holding the saved position invites, the other waits to be invited — so this screen
    /// mostly exists to say which of those is going on, since GameKit needs a human to accept.
    private var onlineRejoinWaiting: some View {
        ZStack {
            LinearGradient(colors: [.feltMid, .feltDark], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()

            VStack(spacing: 16) {
                Text("Rejoining your game")
                    .font(.system(size: 30, weight: .heavy, design: .serif))
                    .foregroundStyle(.white)

                if rejoinFailure == nil {
                    ProgressView().tint(.white).controlSize(.large)
                    Text(rejoinIsHost
                         ? "Inviting \(rejoinOpponentName ?? "your opponent") back…"
                         : "Waiting for \(rejoinOpponentName ?? "your opponent") to invite you back…")
                        .font(.headline).foregroundStyle(.white)
                    Text(rejoinIsHost
                         ? "They'll get a Game Center invitation — they need to accept it to pick the game up where you left off."
                         : "This phone has the invitation coming to it. Ask them to open Pair for Two and tap Rejoin online game.")
                        .font(.caption).foregroundStyle(.white.opacity(0.7))
                        .multilineTextAlignment(.center).frame(maxWidth: 420)
                } else {
                    Text(rejoinFailure ?? "")
                        .font(.callout).foregroundStyle(Color.cribGold)
                        .multilineTextAlignment(.center).frame(maxWidth: 420)
                    Button("Choose from Game Center") {
                        rejoinFailure = nil
                        showingInvite = true
                    }
                    .buttonStyle(.borderedProminent).tint(.cribGold).foregroundStyle(.black)
                }

                Text("The position is safe on \(rejoinIsHost ? "this phone" : "their phone") — it's kept until the game is finished or you start a new one.")
                    .font(.caption2).foregroundStyle(.white.opacity(0.5))
                    .multilineTextAlignment(.center).frame(maxWidth: 420)

                Button("Back to menu") {
                    gameCenter.cancelInvite()
                    rejoinFailure = nil
                    screen = .menu
                }
                .buttonStyle(.bordered).tint(.white)
                .padding(.top, 4)
            }
            .padding(28)
        }
    }

    private var menu: some View {
        ZStack {
            LinearGradient(colors: [.feltMid, .feltDark], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()

            VStack(spacing: 14) {
                    VStack(spacing: 4) {
                        Text("Pair for Two")
                            .font(.system(size: 32, weight: .heavy, design: .serif))
                            .foregroundStyle(.white)
                        Text("Two-phone cribbage")
                            .font(.subheadline).foregroundStyle(Color.cribGold)
                    }

                    // Your identity, tap to edit in Settings.
                    Button { showingSettings = true } label: {
                        HStack(spacing: 10) {
                            Circle().fill(playerTheme(colorID: colorID).primary).frame(width: 20, height: 20)
                            Text(name.isEmpty ? "Player" : name).fontWeight(.semibold).foregroundStyle(.white)
                            Image(systemName: "pencil.circle.fill").foregroundStyle(.white.opacity(0.6))
                        }
                        .padding(.horizontal, 16).padding(.vertical, 8)
                        .background(Capsule().fill(Color.white.opacity(0.10)))
                    }
                    .buttonStyle(.plain)

                    if let resumeMarker {
                        Button {
                            // An online game can't be re-paired over Bluetooth — it has to find the
                            // same Game Center player again, which is its own route.
                            if resumeMarker.isOnline {
                                rejoinOnlineGame(resumeMarker)
                            } else {
                                resumeRole = resumeMarker.isHost ? .host : .guest
                                screen = .connect
                            }
                        } label: {
                            VStack(spacing: 2) {
                                HStack(spacing: 8) {
                                    Image(systemName: resumeMarker.isOnline ? "globe" : "arrow.clockwise.circle.fill")
                                    Text(resumeMarker.isOnline ? "Rejoin online game" : "Rejoin game").fontWeight(.bold)
                                }
                                Text(resumeMarker.summary).font(.caption2).foregroundStyle(.black.opacity(0.6))
                            }
                            .font(.headline)
                            .padding(.horizontal, 22).padding(.vertical, 9)
                        }
                        .buttonStyle(.borderedProminent).tint(.cribGold).foregroundStyle(.black)
                        .disabled(resumeMarker.isOnline && !gameCenter.isAuthenticated)
                    }

                    Button {
                        resumeRole = nil
                        GamePersistence.clear()   // fresh game supersedes any saved one
                        resumeMarker = nil
                        screen = .connect
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "dot.radiowaves.left.and.right")
                            Text(resumeMarker == nil ? "Play nearby" : "New nearby game").fontWeight(.bold)
                        }
                        .font(.headline)
                        .padding(.horizontal, 26).padding(.vertical, 11)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(resumeMarker == nil ? .cribGold : Color.white.opacity(0.22))
                    .foregroundStyle(resumeMarker == nil ? .black : .white)

                    // Online play over Game Center. Enabled once signed in.
                    VStack(spacing: 5) {
                        Button {
                            // Asking for a new online game supersedes any saved one, exactly like the
                            // nearby button. It also has to clear the marker *before* a match arrives:
                            // an online marker is what tells the match handler "this is a rejoin", so
                            // leaving it would resume the old game instead of starting this one.
                            GamePersistence.clear()
                            resumeMarker = nil
                            showingInvite = true
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "globe")
                                Text(resumeMarker?.isOnline == true ? "New online game" : "Play online").fontWeight(.bold)
                            }
                            .font(.headline)
                            .padding(.horizontal, 26).padding(.vertical, 11)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Color.white.opacity(0.22))
                        .foregroundStyle(.white)
                        .disabled(!gameCenter.isAuthenticated)

                        if !gameCenter.isAuthenticated {
                            Text(gameCenter.unavailableReason ?? "Sign in to Game Center to play online.")
                                .font(.caption2).foregroundStyle(.white.opacity(0.55))
                                .multilineTextAlignment(.center)
                        }
                    }

            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 28)
        }
        .overlay(alignment: .topTrailing) {
            HStack(spacing: 14) {
                Button { showingStats = true } label: {
                    Image(systemName: "chart.bar.fill")
                        .font(.system(size: 21, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.85))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Stats and game history")

                Button { showingHelp = true } label: {
                    Image(systemName: "questionmark.circle.fill")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.85))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("How to play")
            }
            .padding(.top, 8).padding(.trailing, 14)
        }
        .onAppear { resumeMarker = GamePersistence.loadMarker() }
        .sheet(isPresented: $showingStats) {
            StatsView(onDone: { showingStats = false })
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView(onDone: { showingSettings = false })
        }
    }
}

#Preview(traits: .landscapeLeft) {
    RootView()
}
