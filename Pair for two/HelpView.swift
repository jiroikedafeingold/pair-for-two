import SwiftUI

/// The full "How to play" reference — reachable from the ? button on the board and from the menu.
/// Covers connecting (local + online), the flow of a hand, how to score, and the Settings options.
struct HelpView: View {
    var onDone: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section("The goal") {
                    helpText("Cribbage for two, one phone each. First to **121** wins. You each keep "
                             + "your own score on your own phone.")
                }

                Section("Play nearby (no internet)") {
                    helpText("Both phones on the same Wi‑Fi (or with Bluetooth on):")
                    bullet("On the menu, tap **Play nearby**.")
                    bullet("One phone taps **Host**, the other taps **Join** and picks the host.")
                    bullet("Allow **Local Network** access if asked — it's needed to find the other phone.")
                    helpText("No account or internet required.")
                }

                Section("Play online") {
                    helpText("Tap **Play online** to invite a friend through **Game Center** and play from "
                             + "anywhere. Sign in to Game Center on both devices first.")
                }

                Section("A hand, step by step") {
                    bullet("**Cut for deal:** each player taps to cut — low card deals and takes the crib.")
                    bullet("**Discard:** each player sends 2 cards to the dealer's crib.")
                    bullet("**Cut the starter:** the non‑dealer taps the deck to cut, the dealer turns up the starter card.")
                    bullet("**The play (pegging):** take turns laying cards, calling the running count. "
                           + "Say **Go** when you can't play without passing 31. You're nudged when a Go or 31 is yours to take.")
                    bullet("**The show:** count hands in order — the non‑dealer's hand, the dealer's hand, then the crib.")
                }

                Section("Scoring your points") {
                    helpText("You add your own points using the control at the top:")
                    bullet("**Slider:** drag to the number of points and let go.")
                    bullet("**+ button:** tap **+1** repeatedly to count up one at a time.")
                    bullet("**Confirm after release** (Settings): the slider holds the amount until you tap the "
                           + "**+N** button to confirm — handy so a stray drag doesn't over‑count.")
                    bullet("When counting a hand, **Continue** becomes **Add N & continue** and folds in any points you've queued.")
                    bullet("**Check my count:** tap the ✓ next to Continue to see the correct count and breakdown "
                           + "(double runs, pair royal, and so on) — great for learning.")
                    helpText("Scoring mode is set in Settings and applies to the whole game:")
                    bullet("**Automatic** — the app counts and adds every point for you.")
                    bullet("**Feedback** — the app shows each score; you add it yourself.")
                    bullet("**Player responsibility** — no hints; count it all yourself.")
                }

                Section("Settings") {
                    bullet("**Name & colour**, and your **card back** design.")
                    bullet("**Scoring mode** (above) — either player can change it.")
                    bullet("**Feel & effects:** toggle **Haptics**, **Sound effects**, and **Celebration effects** (win‑screen fireworks).")
                    bullet("**Scoring replay before win:** replay the whole game score‑by‑score before the win screen.")
                    helpText("Open Settings from the ⚙︎ on the board, or by tapping your name on the menu.")
                }

                Section("Tips") {
                    bullet("Tap the **?** on the board any time to reopen this guide.")
                    bullet("Step away mid‑game and come back — you can **Rejoin** an interrupted game from the menu.")
                }
            }
            .navigationTitle("How to Play")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: onDone).fontWeight(.semibold)
                }
            }
        }
    }

    private func helpText(_ markdown: String) -> some View {
        Text(.init(markdown)).font(.callout).foregroundStyle(.primary)
    }

    private func bullet(_ markdown: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "circle.fill").font(.system(size: 5)).foregroundStyle(.secondary).padding(.top, 6)
            Text(.init(markdown)).font(.callout)
        }
    }
}

#Preview {
    HelpView(onDone: {})
}
