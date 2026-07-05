import SwiftUI

/// App entry. Two-phone play over Multipeer: set up your own name/colour, then Play → find or host a
/// nearby game. (Single-device pass-and-play was removed — this is a two-phone game.)
struct RootView: View {
    private enum Screen { case menu, connect, game }

    @State private var screen: Screen = .menu
    @State private var vm: GameViewModel?
    @State private var showingSettings = false
    @State private var resumeSummary: String? = GamePersistence.savedGameSummary()
    @State private var resuming = false
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
            ConnectView(localName: playerName, localColorID: colorID, resuming: resuming,
                        onConnected: { session in
                            if resuming, let saved = GamePersistence.loadState() {
                                vm = GameViewModel.resumeHost(transport: session, savedState: saved)
                            } else {
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
                GameTableView(vm: vm)
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

                if let resumeSummary {
                    Button {
                        resuming = true
                        screen = .connect
                    } label: {
                        VStack(spacing: 2) {
                            HStack(spacing: 8) {
                                Image(systemName: "arrow.clockwise.circle.fill")
                                Text("Continue game").fontWeight(.bold)
                            }
                            Text(resumeSummary).font(.caption).foregroundStyle(.black.opacity(0.6))
                        }
                        .font(.title3)
                        .padding(.horizontal, 26).padding(.vertical, 12)
                    }
                    .buttonStyle(.borderedProminent).tint(.cribGold).foregroundStyle(.black)
                }

                Button {
                    resuming = false
                    GamePersistence.clear()   // fresh game supersedes any saved one
                    resumeSummary = nil
                    screen = .connect
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "dot.radiowaves.left.and.right")
                        Text(resumeSummary == nil ? "Play" : "New game").fontWeight(.bold)
                    }
                    .font(.title3)
                    .padding(.horizontal, 30).padding(.vertical, 14)
                }
                .buttonStyle(.borderedProminent)
                .tint(resumeSummary == nil ? .cribGold : Color.white.opacity(0.22))
                .foregroundStyle(resumeSummary == nil ? .black : .white)

                Button("Settings") { showingSettings = true }
                    .buttonStyle(.bordered).tint(.white)
            }
            .padding(28)
        }
        .onAppear { resumeSummary = GamePersistence.savedGameSummary() }
        .sheet(isPresented: $showingSettings) {
            SettingsView(onDone: { showingSettings = false })
        }
    }
}

#Preview {
    RootView()
}
