import SwiftUI

/// App entry. Two-phone play over Multipeer: set up your own name/colour, then Play → find or host a
/// nearby game. (Single-device pass-and-play was removed — this is a two-phone game.)
struct RootView: View {
    private enum Screen { case menu, connect, game }

    @State private var screen: Screen = .menu
    @State private var vm: GameViewModel?
    @State private var showingSettings = false
    @State private var resumeMarker: GamePersistence.ResumeMarker? = GamePersistence.loadMarker()
    @State private var resumeRole: ResumeRole? = nil
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
            .onChange(of: scenePhase) { _, phase in
                switch phase {
                case .active:                 vm?.reconnect()   // re-pair after returning from background
                case .background, .inactive:  vm?.persist()      // save the game if we're being closed
                @unknown default:             break
                }
            }
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
                                // Fresh game — isHost was already set by Host/Join.
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
                        Text(resumeMarker == nil ? "Play" : "New game").fontWeight(.bold)
                    }
                    .font(.title3)
                    .padding(.horizontal, 30).padding(.vertical, 14)
                }
                .buttonStyle(.borderedProminent)
                .tint(resumeMarker == nil ? .cribGold : Color.white.opacity(0.22))
                .foregroundStyle(resumeMarker == nil ? .black : .white)
            }
            .padding(28)
        }
        .onAppear { resumeMarker = GamePersistence.loadMarker() }
        .sheet(isPresented: $showingSettings) {
            SettingsView(onDone: { showingSettings = false })
        }
    }
}

#Preview {
    RootView()
}
