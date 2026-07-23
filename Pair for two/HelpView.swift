import SwiftUI

/// The full "How to play" reference — reachable from the ? on the menu and on the board. Uses the
/// app's real cards and scoring control as inline illustrations so it shows what's going on.
struct HelpView: View {
    var onDone: () -> Void
    /// When provided (from the menu), offers a "Replay the welcome tour" action.
    var onReplayOnboarding: (() -> Void)? = nil

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(spacing: 10) {
                        feltStrip { cardFan([c(.five, .hearts), c(.six, .spades), c(.seven, .diamonds),
                                             c(.eight, .clubs), c(.jack, .hearts)]) }
                        Text("Cribbage for two, one phone each. First to **121** wins.")
                            .font(.callout).multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)
                    }
                    .padding(.vertical, 4)
                }

                Section("Play nearby (no internet)") {
                    helpText("Both phones on the same Wi‑Fi (or with Bluetooth on):")
                    bullet("On the menu, tap **Play nearby**.")
                    bullet("One phone taps **Host**, the other taps **Join** and picks the host.")
                    bullet("Allow **Local Network** access if asked — it's needed to find the other phone.")
                }

                Section("Play online") {
                    helpText("Tap **Play online** to invite a friend through **Game Center** and play from "
                             + "anywhere. Sign in to Game Center on both devices first.")
                }

                Section("A hand, step by step") {
                    feltStrip {
                        HStack(alignment: .bottom, spacing: 16) {
                            VStack(spacing: 3) {
                                Text("The Cut").font(.caption2).foregroundStyle(.white.opacity(0.7))
                                CardView(card: c(.five, .clubs), width: 40)
                            }
                            cardFan([c(.four, .diamonds), c(.five, .hearts), c(.six, .spades), c(.jack, .hearts)], width: 40)
                        }
                    }
                    bullet("**Cut for deal:** each player taps to cut — low card deals and takes the crib.")
                    bullet("**Discard:** each player sends 2 cards to the dealer's crib.")
                    bullet("**Cut the starter:** the non‑dealer taps the deck; the dealer turns up the starter card.")
                    bullet("**The play (pegging):** take turns laying cards and calling the count. Say **Go** when "
                           + "you can't play without passing 31 — you're nudged when a Go or 31 is yours to take.")
                    bullet("**The show:** count in order — non‑dealer's hand, dealer's hand, then the crib.")
                }

                Section("Scoring your points") {
                    feltStrip {
                        ScorePanel(name: "You", score: 12, opponentScore: 9,
                                   primary: playerThemes[1].primary, deep: playerThemes[1].deep,
                                   disabled: false, canUndo: false,
                                   onAdd: { _ in }, onPlusOne: {}, onUndo: {})
                            .frame(height: 88)
                    }
                    bullet("**Slider:** drag to the number of points and let go.")
                    bullet("**+ button:** tap **+1** repeatedly to count up one at a time.")
                    bullet("**Confirm after release** (Settings): holds the amount until you tap **+N** to confirm.")
                    bullet("**Check my count:** the ✓ next to Continue shows the correct count and breakdown — "
                           + "double runs, pair royal, and so on.")
                    helpText("Scoring mode (Settings) applies to the whole game:")
                    bullet("**Automatic** — the app counts and adds every point.")
                    bullet("**Feedback** — the app shows each score; you add it yourself.")
                    bullet("**Player responsibility** — no hints; count it all yourself.")
                }

                Section("Settings") {
                    bullet("**Name & colour**, and your **card back**.")
                    bullet("**Scoring mode** — either player can change it.")
                    bullet("**Feel & effects:** toggle **Haptics**, **Sound effects**, and **Celebration effects**.")
                    bullet("**Scoring replay before win:** replay the game score‑by‑score before the win screen.")
                }

                if let onReplayOnboarding {
                    Section {
                        Button {
                            onReplayOnboarding()
                        } label: {
                            Label("Replay the welcome tour", systemImage: "sparkles")
                                .fontWeight(.semibold)
                        }
                    }
                }

                Section("Tips") {
                    bullet("Tap the **?** on the board any time to reopen this guide.")
                    bullet("Step away mid‑game and come back — **Rejoin** an interrupted game from the menu.")
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

    // MARK: Building blocks

    private func c(_ rank: Rank, _ suit: Suit) -> Card { Card(rank: rank, suit: suit) }

    private func cardFan(_ cards: [Card], width: CGFloat = 44) -> some View {
        HStack(spacing: -width * 0.42) {
            ForEach(cards) { CardView(card: $0, width: width) }
        }
    }

    /// Puts an illustration on a felt panel so cards/controls look like they do on the table.
    private func feltStrip<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(LinearGradient(colors: [.feltMid, .feltDark], startPoint: .top, endPoint: .bottom))
            )
            .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
    }

    private func helpText(_ markdown: String) -> some View {
        Text(.init(markdown)).font(.callout).foregroundStyle(.primary)
    }

    private func bullet(_ markdown: String) -> some View {
        Text(.init(markdown))
            .font(.callout)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

#Preview {
    HelpView(onDone: {}, onReplayOnboarding: {})
}
