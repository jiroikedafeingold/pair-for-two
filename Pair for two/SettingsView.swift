import SwiftUI

/// Your player settings: name, color, the scoring mode, and the two scoring-slider confirm options.
/// Backed by `@AppStorage`, so the same screen works from the start menu and from inside a game, and
/// changes persist. Only the current player is configured (this is a two-phone game — the other
/// player sets their own on their device). The scoring mode is set by whoever hosts the game.
struct SettingsView: View {
    var onDone: () -> Void

    @AppStorage("localName") private var name = "Player"
    @AppStorage("localColorID") private var colorID = 1
    @AppStorage("confirmRelease") private var confirmRelease = true
    @AppStorage("scoringMode") private var scoringModeRaw = ScoringMode.off.rawValue
    @AppStorage("cardBackID") private var cardBackID = 0
    @AppStorage("hapticsEnabled") private var hapticsEnabled = true
    @AppStorage("soundEnabled") private var soundEnabled = true
    @AppStorage("celebrationEffects") private var celebrationEffects = true
    @AppStorage("replayBeforeWin") private var replayBeforeWin = true
    @AppStorage("scoreTrackEnabled") private var scoreTrackEnabled = true

    private var scoringMode: ScoringMode { ScoringMode(rawValue: scoringModeRaw) ?? .off }

    @State private var showOnboarding = false

    /// App marketing version + build number, shown at the bottom of Settings.
    private var appVersionBuild: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "Pair for Two \(version) (build \(build))"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button {
                        showOnboarding = true
                    } label: {
                        Label("Replay welcome tour", systemImage: "sparkles")
                    }
                } footer: {
                    Text("See the intro again — how to connect, keep score, and where to change settings.")
                }

                Section("You") {
                    LabeledContent("Name") {
                        TextField("Name", text: $name)
                            .multilineTextAlignment(.trailing)
                            .textInputAutocapitalization(.words)
                            .submitLabel(.done)
                    }
                    colorRow
                }

                Section {
                    cardBackRow
                } header: {
                    Text("Card back")
                } footer: {
                    Text("How the backs of the cards look on your device.")
                }

                Section {
                    ForEach(ScoringMode.allCases, id: \.rawValue) { mode in
                        Button {
                            scoringModeRaw = mode.rawValue
                        } label: {
                            HStack(alignment: .top, spacing: 12) {
                                Image(systemName: scoringModeRaw == mode.rawValue ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(scoringModeRaw == mode.rawValue ? Color.accentColor : .secondary)
                                    .font(.title3)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(mode.title).font(.body).foregroundStyle(.primary)
                                    Text(mode.detail).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    Text("Scoring")
                } footer: {
                    Text("Applies to the whole game — either player can change it.")
                }

                if scoringMode != .auto {
                    Section {
                        Toggle("Confirm after release", isOn: $confirmRelease)
                    } header: {
                        Text("Scoring slider")
                    } footer: {
                        Text("Holds the slider value until you tap the +N button, instead of adding it "
                             + "the moment you let go.")
                    }
                }

                Section {
                    Toggle("Haptics", isOn: $hapticsEnabled)
                    Toggle("Sound effects", isOn: $soundEnabled)
                    Toggle("Celebration effects", isOn: $celebrationEffects)
                    Toggle("Score progress rings", isOn: $scoreTrackEnabled)
                } header: {
                    Text("Feel & effects")
                } footer: {
                    Text("Haptics are the vibrations during play and on a win. Sound effects are the "
                         + "in-game sounds. Celebration effects are the fireworks and flash on the win "
                         + "screen (the win screen itself still shows). Score progress rings trace each "
                         + "player's color around the scores, closing the loop at 121.")
                }

                Section {
                    Toggle("Scoring replay before win", isOn: $replayBeforeWin)
                } header: {
                    Text("Win screen")
                } footer: {
                    Text("When someone wins, replay the whole game's scoring — score by score — before "
                         + "showing the win screen. You can also replay it any time from the win screen.")
                }

                Section {
                } footer: {
                    Text(appVersionBuild)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: onDone).fontWeight(.semibold)
                }
            }
        }
        .fullScreenCover(isPresented: $showOnboarding) {
            OnboardingView(onFinish: { showOnboarding = false })
        }
    }

    private var cardBackRow: some View {
        HStack(spacing: 16) {
            ForEach(CardBack.allCases) { back in
                let selected = cardBackID == back.rawValue
                VStack(spacing: 6) {
                    ZStack {
                        Color.cardBack   // dark base so light card edges/corners don't blend into the Form
                        Image(back.assetName).resizable().scaledToFill().blur(radius: 4)
                        Image(back.assetName).resizable().scaledToFit()
                    }
                    .frame(width: 62, height: 90)
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .overlay(   // gold rim like the in-game card; accent ring when selected
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .strokeBorder(selected ? Color.accentColor : Color.cribGold.opacity(0.85),
                                          lineWidth: selected ? 3 : 1.5)
                    )
                    Text(back.displayName)
                        .font(.caption)
                        .fontWeight(selected ? .semibold : .regular)
                        .foregroundStyle(selected ? .primary : .secondary)
                }
                .contentShape(Rectangle())
                .onTapGesture { cardBackID = back.rawValue }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }

    private var colorRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Color").font(.subheadline).foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(Array(playerThemes.enumerated()), id: \.offset) { index, theme in
                        Circle()
                            .fill(theme.primary)
                            .frame(width: 30, height: 30)
                            .overlay(Circle().strokeBorder(.primary, lineWidth: colorID == index ? 3 : 0))
                            .onTapGesture { colorID = index }
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }
}

#Preview {
    SettingsView(onDone: {})
}
