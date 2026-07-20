import SwiftUI
import GameKit

/// App entry. Two-phone play: set up your own name/colour, then Play nearby (Multipeer) or Play
/// online (Game Center). Single-device pass-and-play was removed — this is a two-phone game.
struct RootView: View {
    private enum Screen { case menu, connect, game }

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
    @Environment(\.scenePhase) private var scenePhase

    @AppStorage("localName") private var name = "Player"
    @AppStorage("localColorID") private var colorID = 1
    @AppStorage("scoringMode") private var scoringModeRaw = ScoringMode.feedback.rawValue

    /// Trimmed, non-empty player name.
    private var playerName: String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "Player" : trimmed
    }

    var body: some View {
        content
            .task { gameCenter.authenticate() }   // Game Center sign-in for online play
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
            .onChange(of: gameCenter.matchTick) { _, _ in
                if let ready = gameCenter.takePendingMatch() {
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

    /// Build the online transport from a connected match (with the host role the manager already
    /// elected) and start a networked game.
    private func startOnlineGame(_ match: GKMatch, isHost: Bool) {
        showingInvite = false
        activeMatchmaker = nil
        // Starting an online game also forgets any in-progress nearby game.
        GamePersistence.clear()
        resumeMarker = nil
        let transport = GameCenterTransport(match: match, isHost: isHost)
        resumeRole = nil
        vm = GameViewModel.networked(transport: transport,
                                     localName: playerName, localColorID: colorID,
                                     scoringMode: ScoringMode(rawValue: scoringModeRaw) ?? .feedback,
                                     resumable: false)
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
                                                             scoringMode: ScoringMode(rawValue: scoringModeRaw) ?? .feedback)
                            } else {
                                // Fresh game — isHost was already set by Host/Join. Starting a new game
                                // forgets any other in-progress game on this device (the new game writes
                                // its own resume marker as it plays).
                                GamePersistence.clear()
                                resumeMarker = nil
                                vm = GameViewModel.networked(transport: session,
                                                             localName: playerName,
                                                             localColorID: colorID,
                                                             scoringMode: ScoringMode(rawValue: scoringModeRaw) ?? .feedback)
                            }
                            screen = .game
                        },
                        onCancel: { screen = .menu })

        case .game:
            if let vm {
                GameTableView(vm: vm, onExit: {
                    self.vm = nil
                    resumeRole = nil
                    resumeMarker = nil    // the game was cleared on quit — no "Rejoin" to offer
                    screen = .menu
                })
            } else {
                Color.feltDark.ignoresSafeArea()
            }
        }
    }

    private var menu: some View {
        ZStack {
            LinearGradient(colors: [.feltMid, .feltDark], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()

            VStack(spacing: 24) {
                VStack(spacing: 6) {
                    Text("Pair for Two")
                        .font(.system(size: 46, weight: .heavy, design: .serif))
                        .foregroundStyle(.white)
                    Text("Two-phone cribbage")
                        .font(.headline).foregroundStyle(Color.cribGold)
                }

                // Your identity, tap to edit in Settings.
                Button { showingSettings = true } label: {
                    HStack(spacing: 10) {
                        Circle().fill(playerTheme(colorID: colorID).primary).frame(width: 22, height: 22)
                        Text(name.isEmpty ? "Player" : name).fontWeight(.semibold).foregroundStyle(.white)
                        Image(systemName: "pencil.circle.fill").foregroundStyle(.white.opacity(0.6))
                    }
                    .padding(.horizontal, 18).padding(.vertical, 10)
                    .background(Capsule().fill(Color.white.opacity(0.10)))
                }
                .buttonStyle(.plain)

                if let resumeMarker {
                    Button {
                        resumeRole = resumeMarker.isHost ? .host : .guest
                        screen = .connect
                    } label: {
                        VStack(spacing: 2) {
                            HStack(spacing: 8) {
                                Image(systemName: "arrow.clockwise.circle.fill")
                                Text("Rejoin game").fontWeight(.bold)
                            }
                            Text(resumeMarker.summary).font(.caption).foregroundStyle(.black.opacity(0.6))
                        }
                        .font(.title3)
                        .padding(.horizontal, 26).padding(.vertical, 12)
                    }
                    .buttonStyle(.borderedProminent).tint(.cribGold).foregroundStyle(.black)
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
                    .font(.title3)
                    .padding(.horizontal, 30).padding(.vertical, 14)
                }
                .buttonStyle(.borderedProminent)
                .tint(resumeMarker == nil ? .cribGold : Color.white.opacity(0.22))
                .foregroundStyle(resumeMarker == nil ? .black : .white)

                // Online play over Game Center. Enabled once signed in.
                VStack(spacing: 6) {
                    Button {
                        showingInvite = true
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "globe")
                            Text("Play online").fontWeight(.bold)
                        }
                        .font(.title3)
                        .padding(.horizontal, 30).padding(.vertical, 14)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.white.opacity(0.22))
                    .foregroundStyle(.white)
                    .disabled(!gameCenter.isAuthenticated)

                    if !gameCenter.isAuthenticated {
                        Text(gameCenter.unavailableReason ?? "Sign in to Game Center to play online.")
                            .font(.caption).foregroundStyle(.white.opacity(0.55))
                            .multilineTextAlignment(.center)
                    }
                }
            }
            .padding(28)
        }
        .onAppear { resumeMarker = GamePersistence.loadMarker() }
        .sheet(isPresented: $showingSettings) {
            SettingsView(onDone: { showingSettings = false })
        }
    }
}

#Preview(traits: .landscapeLeft) {
    RootView()
}
