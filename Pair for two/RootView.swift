import SwiftUI

/// App entry view. Offers single-device pass-and-play (`LoopbackTransport`) and two-device play over
/// Multipeer (`MultipeerSession`) — both behind the same `GameTransport`, so the game screen is
/// identical either way.
struct RootView: View {
    private enum Screen {
        case menu, connect, game
    }

    @State private var screen: Screen = .menu
    @State private var vm: GameViewModel?
    @State private var resumeSummary: String? = GamePersistence.savedGameSummary()

    // Local player identity (also the pass-and-play "Player 1"); Player 2 is used only for loopback.
    @State private var name1 = "Player 1"
    @State private var name2 = "Player 2"
    @State private var color1 = 1   // coral
    @State private var color2 = 7   // sky

    var body: some View {
        switch screen {
        case .menu:
            StartMenu(name1: $name1, name2: $name2, color1: $color1, color2: $color2,
                      resumeSummary: resumeSummary,
                      onResume: {
                          if let saved = GamePersistence.loadState() {
                              vm = GameViewModel.resume(saved)
                              screen = .game
                          }
                      },
                      onPassAndPlay: {
                          GamePersistence.clear()
                          vm = GameViewModel.loopback(
                              names: [.one: name1, .two: name2],
                              colorIDs: [.one: color1, .two: color2])
                          screen = .game
                      },
                      onPlayNearby: { screen = .connect })

        case .connect:
            ConnectView(localName: name1, localColorID: color1,
                        onConnected: { session in
                            vm = GameViewModel.networked(transport: session,
                                                         localName: name1, localColorID: color1)
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
}

/// Start screen: name/colour for both pass-and-play players, plus the two ways to play.
private struct StartMenu: View {
    @Binding var name1: String
    @Binding var name2: String
    @Binding var color1: Int
    @Binding var color2: Int
    var resumeSummary: String?
    var onResume: () -> Void
    var onPassAndPlay: () -> Void
    var onPlayNearby: () -> Void

    var body: some View {
        ZStack {
            LinearGradient(colors: [.feltMid, .feltDark], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()

            ScrollView {
                VStack(spacing: 20) {
                    Text("Pair for Two")
                        .font(.system(size: 46, weight: .heavy, design: .serif))
                        .foregroundStyle(.white)
                    Text("Two-phone cribbage")
                        .font(.headline).foregroundStyle(Color.cribGold)

                    HStack(spacing: 40) {
                        playerSetup(name: $name1, color: $color1)
                        playerSetup(name: $name2, color: $color2)
                    }

                    HStack(spacing: 18) {
                        Button(action: onPassAndPlay) {
                            actionLabel("Play on one phone", systemImage: "iphone")
                        }
                        .buttonStyle(.borderedProminent).tint(.cribGold).foregroundStyle(.black)

                        Button(action: onPlayNearby) {
                            actionLabel("Play nearby", systemImage: "dot.radiowaves.left.and.right")
                        }
                        .buttonStyle(.bordered).tint(.white)
                    }

                    if let resumeSummary {
                        Button(action: onResume) {
                            actionLabel("Resume game  (\(resumeSummary))", systemImage: "arrow.clockwise.circle.fill")
                        }
                        .buttonStyle(.bordered).tint(Color.cribGold)
                    }

                    Text("Pass-and-play uses both names above. Play nearby uses the left player as you.")
                        .font(.caption).foregroundStyle(.white.opacity(0.6))
                        .multilineTextAlignment(.center)
                }
                .padding(28)
            }
        }
    }

    private func actionLabel(_ title: String, systemImage: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
            Text(title).fontWeight(.bold)
        }
        .font(.title3)
        .padding(.horizontal, 18).padding(.vertical, 12)
    }

    @ViewBuilder private func playerSetup(name: Binding<String>, color: Binding<Int>) -> some View {
        VStack(spacing: 10) {
            TextField("Name", text: name)
                .textFieldStyle(.roundedBorder)
                .frame(width: 180)
                .multilineTextAlignment(.center)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(playerThemes.enumerated()), id: \.offset) { index, theme in
                        Circle()
                            .fill(theme.primary)
                            .frame(width: 22, height: 22)
                            .overlay(Circle().strokeBorder(.white, lineWidth: color.wrappedValue == index ? 3 : 0))
                            .onTapGesture { color.wrappedValue = index }
                    }
                }
                .padding(.horizontal, 4)
            }
            .frame(width: 210)
        }
    }
}

#Preview {
    RootView()
}
