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
                .tabViewStyle(.page(indexDisplayMode: .never))

                // Custom page dots, kept clear of the slide text (the built-in dots overlapped it).
                HStack(spacing: 8) {
                    ForEach(0..<slides.count, id: \.self) { i in
                        Circle()
                            .fill(i == page ? Color.cribGold : Color.white.opacity(0.3))
                            .frame(width: 7, height: 7)
                    }
                }
                .padding(.bottom, 14)

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
        VStack(spacing: 16) {
            Spacer(minLength: 8)
            Image(systemName: slide.icon)
                .font(.system(size: 50, weight: .bold))
                .foregroundStyle(Color.cribGold)
                .shadow(color: .black.opacity(0.35), radius: 8, y: 4)
            Text(slide.title)
                .font(.system(size: 26, weight: .heavy, design: .rounded))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.8)
            Text(slide.body)
                .font(.callout)
                .foregroundStyle(.white.opacity(0.85))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)   // show the full text, never clip
                .frame(maxWidth: 520)
            Spacer(minLength: 8)
        }
        .padding(.horizontal, 32)
        .padding(.bottom, 6)
    }
}

#Preview(traits: .landscapeLeft) {
    OnboardingView(onFinish: {})
}
