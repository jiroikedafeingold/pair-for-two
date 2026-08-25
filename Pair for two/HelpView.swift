import SwiftUI

/// The full "How to play" reference — reachable from the ? on the menu and on the board. Uses the
/// app's real cards and scoring control as inline illustrations so it shows what's going on.
struct HelpView: View {
    var onDone: () -> Void
    /// When provided (from the menu), offers a "Replay the welcome tour" action.
    var onReplayOnboarding: (() -> Void)? = nil

    /// A live, throwaway score so the help panel's slider actually works. Wraps back to 0 at 121.
    @State private var demoScore = 0

    /// Naming the hardware in a sentence ("lay the iPad between you") — not a layout decision, so an
    /// idiom check is the right tool.
    private var deviceWord: String {
        UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "phone"
    }

    private func addDemo(_ points: Int) {
        demoScore += points
        if demoScore >= 121 { demoScore = 0 }   // hitting/passing 121 just resets the demo
    }

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
                    helpText("Tap **Play online** to invite a friend through **Game Center** and play from anywhere. Sign in to Game Center on both devices first.")
                    bullet("**If someone drops out** — closing the app, losing signal — the game isn't over. The other phone invites them back, and whoever left just accepts the Game Center invitation to carry on from the same hand.")
                    bullet("**Force-quit the app?** Tap **Rejoin online** on the menu. The phone holding the position invites the other one back.")
                }

                Section("Scoreboard (playing with real cards)") {
                    helpText("Dealing real cards? Tap **Scoreboard** and lay the \(deviceWord) between you. The app keeps score and nothing else — no hands, no crib, no cut, because it can't see your cards.")
                    bullet("**A slider each**, at your own edge of the screen, the right way up for you.")
                    bullet("**The score in the middle turns** to face whoever last pegged, then keeps turning so you both get to read it. Tap it to turn it now.")
                    bullet("**The pencil** beside your slider sets your name and color, and the sound, haptics and score-track settings.")
                    bullet("**The circle on the divider** starts a new game. It asks first.")
                    bullet("**At 121** the board replays every peg of the game, then shows the winner — both turning to face each of you in turn. Turn the replay off in the board's own settings if you'd rather go straight to the celebration.")
                    bullet("Scoreboard games aren't added to your stats — the app never sees the hands, so there'd be nothing to record beyond the result.")
                }

                Section("Stats & achievements") {
                    bullet("**Stats** (the chart on the menu) keeps every finished game on this device: wins, skunks for and against, your best hand, streaks and time played.")
                    bullet("It's **only on this phone** — no accounts, nothing synced — so a reinstall clears it.")
                    bullet("**Achievements and the wins leaderboard** are in Game Center, reached from the bottom of Stats: first win, skunks, a 24-hand, the perfect 29, a comeback from 30 behind, five in a row, and a hundred hands.")
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
                    bullet("**The play (pegging):** take turns laying cards and calling the count. Say **Go** when you can't play without passing 31 — you're nudged when a Go or 31 is yours to take.")
                    bullet("**The show:** count in order — non‑dealer's hand, dealer's hand, then the crib.")
                }

                Section("Scoring your points") {
                    helpText("**Try it below** — drag the slider and release, then tap the **+N** button to confirm and add the points. (This demo resets at 121.)")
                    feltStrip {
                        ScorePanel(name: "You", score: demoScore, opponentScore: 0,
                                   primary: playerThemes[1].primary, deep: playerThemes[1].deep,
                                   disabled: false, canUndo: false, requireConfirm: true,
                                   onAdd: { addDemo($0) }, onPlusOne: { addDemo(1) }, onUndo: {})
                            .frame(height: 88)
                    }
                    bullet("**Slider:** drag to the number of points and let go.")
                    bullet("**+ button:** tap **+1** repeatedly to count up one at a time.")
                    bullet("**Confirm after release** (Settings): holds the amount until you tap **+N** to confirm.")
                    bullet("**Check my count:** the ✓ next to Continue shows the correct count and breakdown — double runs, pair royal, and so on.")
                    helpText("Scoring mode (Settings) applies to the whole game:")
                    bullet("**Automatic** — the app counts and adds every point.")
                    bullet("**Feedback** — the app shows each score; you add it yourself.")
                    bullet("**Player responsibility** — no hints; count it all yourself.")
                }

                Section("Settings") {
                    bullet("**Name & color**, and your **card back**.")
                    bullet("**Scoring mode** — either player can change it. New games start on **Player responsibility**: you keep score, as you would on a wooden board.")
                    bullet("**Feel & effects:** toggle **Haptics**, **Sound effects**, and **Celebration effects**.")
                    bullet("**Scoring replay before win:** replay the game score‑by‑score before the win screen.")
                    bullet("**Score track:** the loop around your score tracing the way to 121, with the skunk lines marked.")
                    helpText("The scoreboard has its own copy of most of these, behind the pencil beside your slider — everything except the scoring mode and the card back, which only apply to a game the app deals.")
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

    /// `LocalizedStringKey`, not `String`: the extractor only sees literals if the parameter itself
    /// is a key. Markdown in the string still renders.
    private func helpText(_ markdown: LocalizedStringKey) -> some View {
        Text(markdown).font(.callout).foregroundStyle(.primary)
    }

    private func bullet(_ markdown: LocalizedStringKey) -> some View {
        Text(markdown)
            .font(.callout)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

#Preview {
    HelpView(onDone: {}, onReplayOnboarding: {})
}
