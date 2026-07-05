import SwiftUI

/// Your player settings: name, colour, the scoring mode, and the two scoring-slider confirm options.
/// Backed by `@AppStorage`, so the same screen works from the start menu and from inside a game, and
/// changes persist. Only the current player is configured (this is a two-phone game — the other
/// player sets their own on their device). The scoring mode is set by whoever hosts the game.
struct SettingsView: View {
    var onDone: () -> Void

    @AppStorage("localName") private var name = "Player"
    @AppStorage("localColorID") private var colorID = 1
    @AppStorage("confirmRelease") private var confirmRelease = false
    @AppStorage("scoringMode") private var scoringModeRaw = ScoringMode.feedback.rawValue

    private var scoringMode: ScoringMode { ScoringMode(rawValue: scoringModeRaw) ?? .feedback }

    var body: some View {
        NavigationStack {
            Form {
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

                if scoringMode != .off {
                    Section {
                        Toggle("Confirm after release", isOn: $confirmRelease)
                    } header: {
                        Text("Scoring slider")
                    } footer: {
                        Text("Holds the slider value until you tap the +N button, instead of adding it "
                             + "the moment you let go.")
                    }
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
    }

    private var colorRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Colour").font(.subheadline).foregroundStyle(.secondary)
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
