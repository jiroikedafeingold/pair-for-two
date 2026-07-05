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
    @AppStorage("confirmPlus") private var confirmPlus = false
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
                    Picker("Scoring", selection: $scoringModeRaw) {
                        ForEach(ScoringMode.allCases, id: \.rawValue) { mode in
                            Text(mode.title).tag(mode.rawValue)
                        }
                    }
                    .pickerStyle(.inline)
                } header: {
                    Text("Scoring")
                } footer: {
                    Text(scoringMode.detail + "  (The host's choice is used for the game.)")
                }

                if scoringMode != .off {
                    Section {
                        Toggle("Confirm after release", isOn: $confirmRelease)
                        Toggle("Confirm after +1", isOn: $confirmPlus)
                    } header: {
                        Text("Scoring slider")
                    } footer: {
                        Text("“Confirm after release” holds the slider value until you tap the +N button. "
                             + "“Confirm after +1” batches +1 taps before adding them to your score.")
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
