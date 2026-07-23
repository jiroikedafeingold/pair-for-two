import SwiftUI

/// A short, paged welcome shown on first launch: what the app is, how to connect (local + online),
/// how scoring works, and where the Settings options live. Sets `hasOnboarded` when finished.
struct OnboardingView: View {
    var onFinish: () -> Void

    @State private var page = 0

    private struct Slide: Identifiable {
        let id = UUID()
        let icon: String
        let title: String
        let body: String
    }

    private let slides: [Slide] = [
        Slide(icon: "suit.club.fill",
              title: "Pair for Two",
              body: "Cribbage on two phones — one for each player. Deal, cut, peg, and count your way to 121."),
        Slide(icon: "dot.radiowaves.left.and.right",
              title: "Two phones, one table",
              body: "Play nearby over Bluetooth and Wi‑Fi — no internet or account needed. One phone taps Host, the other taps Join. Or tap Play online to invite a friend through Game Center."),
        Slide(icon: "slider.horizontal.3",
              title: "Keep your own score",
              body: "Add your points at the top: drag the slider to the amount and let go, or tap +1 to count up one at a time. Turn on “Confirm after release” in Settings to review before it counts."),
        Slide(icon: "checkmark.seal.fill",
              title: "Learn as you go",
              body: "While counting a hand, tap the ✓ to see the correct count with proper cribbage terms. Choose Automatic, Feedback, or Player‑responsibility scoring in Settings."),
        Slide(icon: "gearshape.fill",
              title: "Make it yours",
              body: "In Settings: your name & colour, card back, scoring mode, and toggles for haptics, sound, and celebration effects. Tap the ? on the board anytime for the full how‑to.")
    ]

    var body: some View {
        ZStack {
            LinearGradient(colors: [.feltMid, .feltDark], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                HStack {
                    Spacer()
                    Button("Skip") { onFinish() }
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.8))
                }
                .padding(.horizontal, 20).padding(.top, 12)

                TabView(selection: $page) {
                    ForEach(Array(slides.enumerated()), id: \.offset) { idx, slide in
                        slideView(slide).tag(idx)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .always))

                Button(page == slides.count - 1 ? "Start playing" : "Continue") {
                    if page == slides.count - 1 { onFinish() }
                    else { withAnimation { page += 1 } }
                }
                .buttonStyle(.borderedProminent).tint(.cribGold).foregroundStyle(.black)
                .controlSize(.large)
                .padding(.bottom, 28)
            }
        }
    }

    private func slideView(_ slide: Slide) -> some View {
        VStack(spacing: 22) {
            Spacer(minLength: 0)
            Image(systemName: slide.icon)
                .font(.system(size: 64, weight: .bold))
                .foregroundStyle(Color.cribGold)
                .shadow(color: .black.opacity(0.35), radius: 8, y: 4)
            Text(slide.title)
                .font(.system(size: 30, weight: .heavy, design: .rounded))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
            Text(slide.body)
                .font(.body)
                .foregroundStyle(.white.opacity(0.85))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 520)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 32)
    }
}

#Preview(traits: .landscapeLeft) {
    OnboardingView(onFinish: {})
}
