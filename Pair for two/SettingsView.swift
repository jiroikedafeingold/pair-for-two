import SwiftUI

/// Scoring-slider preferences, per player. Mirrors Criboard's options:
/// - **Confirm after release**: dragging the slider stages the value; you tap the +N button to apply.
/// - **Confirm after +1**: +1 taps batch up and commit together instead of scoring each tap.
///
/// In pass-and-play both players are shown; when networked, only the local player's peg exists but
/// both rows remain editable (the setting for the other seat is simply unused on this device).
struct SettingsView: View {
    var vm: GameViewModel
    var onDone: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                ForEach(playersToShow, id: \.self) { player in
                    Section {
                        Toggle("Confirm after release",
                               isOn: bindingRelease(player))
                        Toggle("Confirm after +1",
                               isOn: bindingPlus(player))
                    } header: {
                        HStack(spacing: 8) {
                            Circle().fill(vm.theme(for: player).primary).frame(width: 12, height: 12)
                            Text(vm.name(of: player).uppercased())
                        }
                    }
                }

                Section {
                    Text("“Confirm after release” holds the slider value until you tap the +N button. "
                         + "“Confirm after +1” batches +1 taps before adding them to your score.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Scoring")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: onDone).fontWeight(.semibold)
                }
            }
        }
    }

    private var playersToShow: [PlayerID] {
        vm.isLoopback ? [.one, .two] : [.one, .two]
    }

    private func bindingRelease(_ player: PlayerID) -> Binding<Bool> {
        Binding(get: { vm.confirmAfterRelease[player] ?? false },
                set: { vm.setConfirmAfterRelease($0, for: player) })
    }

    private func bindingPlus(_ player: PlayerID) -> Binding<Bool> {
        Binding(get: { vm.confirmAfterPlusOne[player] ?? false },
                set: { vm.setConfirmAfterPlusOne($0, for: player) })
    }
}
