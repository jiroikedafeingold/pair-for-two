import SwiftUI

/// A short, paged welcome shown on first launch — what the app is, how to connect, how scoring works,
/// where Settings live — ending with a name prompt. On a true first run it also picks a random colour.
/// Sets `hasOnboarded` when finished (via `onFinish`).
struct OnboardingView: View {
    var onFinish: () -> Void

    @State private var page = 0
    @State private var askName = false
    @FocusState private var nameFocused: Bool

    @AppStorage("localName") private var name = "Player"
    @AppStorage("localColorID") private var colorID = 1
    @AppStorage("hasOnboarded") private var hasOnboarded = false

    private var lastSlide: Bool { page == slides.count - 1 }

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

            if askName { nameEntry } else { tour }
        }
        .onAppear {
            // Only a true first run personalises: pick a random colour and start the name blank.
            if !hasOnboarded {
                colorID = Int.random(in: 0..<max(playerThemes.count, 1))
                if name == "Player" { name = "" }
            }
        }
    }

    // MARK: Tour

    private var tour: some View {
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

            HStack(spacing: 8) {
                ForEach(0..<slides.count, id: \.self) { i in
                    Circle()
                        .fill(i == page ? Color.cribGold : Color.white.opacity(0.3))
                        .frame(width: 7, height: 7)
                }
            }
            .padding(.bottom, 14)

            Button(lastSlide && hasOnboarded ? "Done" : "Continue") {
                if lastSlide {
                    // First run ends with the name prompt; a replay from Help just finishes.
                    if hasOnboarded { onFinish() } else { withAnimation { askName = true } }
                } else {
                    withAnimation { page += 1 }
                }
            }
            .buttonStyle(.borderedProminent).tint(.cribGold).foregroundStyle(.black)
            .controlSize(.large)
            .padding(.bottom, 28)
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
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 520)
            Spacer(minLength: 8)
        }
        .padding(.horizontal, 32)
        .padding(.bottom, 6)
    }

    // MARK: Name entry

    private var nameEntry: some View {
        VStack(spacing: 16) {
            Spacer(minLength: 8)

            HStack(spacing: 10) {
                Circle().fill(playerTheme(colorID: colorID).primary)
                    .frame(width: 26, height: 26)
                    .overlay(Circle().stroke(.white.opacity(0.5), lineWidth: 1))
                Image(systemName: "person.crop.circle.fill")
                    .font(.system(size: 40, weight: .bold))
                    .foregroundStyle(.white.opacity(0.85))
            }

            Text("What's your name?")
                .font(.system(size: 26, weight: .heavy, design: .rounded))
                .foregroundStyle(.white)

            TextField("", text: $name, prompt: Text("Your name").foregroundStyle(.white.opacity(0.45)))
                .textInputAutocapitalization(.words)
                .submitLabel(.go)
                .focused($nameFocused)
                .multilineTextAlignment(.center)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 18).padding(.vertical, 12)
                .background(Capsule().fill(Color.white.opacity(0.12)))
                .overlay(Capsule().stroke(Color.cribGold.opacity(0.5), lineWidth: 1))
                .frame(maxWidth: 360)
                .onSubmit { onFinish() }

            Text("Your colour was picked for you — change either in Settings.")
                .font(.caption).foregroundStyle(.white.opacity(0.6))
                .multilineTextAlignment(.center)

            Button("Start playing") { onFinish() }
                .buttonStyle(.borderedProminent).tint(.cribGold).foregroundStyle(.black)
                .controlSize(.large)
                .padding(.top, 2)

            Spacer(minLength: 8)
        }
        .padding(.horizontal, 32)
        .padding(.bottom, 12)
        .onAppear { nameFocused = true }
    }
}

#Preview(traits: .landscapeLeft) {
    OnboardingView(onFinish: {})
}
