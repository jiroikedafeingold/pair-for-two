import SwiftUI

/// The opening: the launch screen's poster, with the link between the two phones brought to life.
///
/// A launch screen can't animate — the system draws it before any of our code runs, and caches the
/// result — so this picks up where it leaves off. It draws the *same* image, laid out by the same rule
/// (aspect-fit, centered, on the same backdrop), which makes the handover invisible; then it paints
/// over the connector baked into the artwork and redraws it live: gold dashes flowing from one phone
/// to the other, and each player's dot breathing.
///
/// Deliberately brief. An opening is charming once and tiresome by the fiftieth launch, so it runs for
/// a beat and gets out of the way, and a tap anywhere skips it. With Reduce Motion on it holds still
/// and leaves sooner.
struct OpeningView: View {
    var onFinish: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dashPhase: CGFloat = 0
    @State private var breathing = false
    @State private var leaving = false

    /// Where the connector sits in the artwork, in its own pixels, measured from the poster's centre.
    /// The poster is full-width and vertically centred in both the phone and the iPad canvas, so one
    /// set of numbers works for both — only the scale changes.
    private enum Art {
        static let width: CGFloat = 1852          // the poster's own width, the unit for `scale`
        static let row: CGFloat = 27.5            // the connector's line, below the centre
        static let lineFrom: CGFloat = -104       // left end, at the near phone's edge
        static let lineTo: CGFloat = 103          // right end, at the far phone's edge
        static let nearDot = CGPoint(x: -46.8, y: 28)
        static let farDot = CGPoint(x: 43.6, y: 28)
        static let dotRadius: CGFloat = 10.5
        /// The felt patch that hides the connector printed into the artwork.
        static let patch = CGRect(x: -121, y: 0.5, width: 240, height: 55)
    }

    /// Sampled from the artwork, so the redrawn connector is the same connector.
    private static let gold = Color(red: 250 / 255, green: 191 / 255, blue: 108 / 255)
    private static let nearColor = Color(red: 63 / 255, green: 174 / 255, blue: 254 / 255)
    private static let farColor = Color(red: 255 / 255, green: 125 / 255, blue: 69 / 255)
    /// The launch screen's backdrop, so the letterbox on an iPad matches through the handover.
    private static let backdrop = Color(red: 0, green: 29 / 255, blue: 23 / 255)

    /// The same image the launch screen uses, including its `~ipad` variant.
    private let poster = UIImage(named: "Splash")
    private let patch = UIImage(named: "SplashConnectorPatch")

    var body: some View {
        GeometryReader { geo in
            let art = poster?.size ?? CGSize(width: Art.width, height: 849)
            // Aspect-fit, exactly as the launch storyboard's image view does it.
            let scale = min(geo.size.width / art.width, geo.size.height / art.height)
            let shown = CGSize(width: art.width * scale, height: art.height * scale)
            let centre = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            let unit = shown.width / Art.width        // artwork pixels → points on screen

            ZStack {
                Self.backdrop.ignoresSafeArea()

                if let poster {
                    Image(uiImage: poster)
                        .resizable()
                        .scaledToFit()
                        .frame(width: shown.width, height: shown.height)
                        .position(centre)
                }

                connector(centre: centre, unit: unit)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .ignoresSafeArea()
        .opacity(leaving ? 0 : 1)
        .contentShape(Rectangle())
        .onTapGesture { finish() }
        .task { await run() }
        .accessibilityElement()
        .accessibilityLabel(Text("Pair for Two", comment: "VoiceOver name for the opening screen"))
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(Text("Double tap to skip", comment: "VoiceOver hint on the opening screen"))
    }

    // MARK: The connector

    @ViewBuilder private func connector(centre: CGPoint, unit: CGFloat) -> some View {
        // 1. Hide the printed connector. The patch is felt interpolated from the rows either side of
        //    it, so it disappears into the poster rather than sitting on top of it as a block.
        if let patch {
            Image(uiImage: patch)
                .resizable()
                .frame(width: Art.patch.width * unit, height: Art.patch.height * unit)
                .position(x: centre.x + Art.patch.midX * unit, y: centre.y + Art.patch.midY * unit)
        }

        // 2. The line, redrawn as flowing dashes.
        Path { path in
            path.move(to: CGPoint(x: centre.x + Art.lineFrom * unit, y: centre.y + Art.row * unit))
            path.addLine(to: CGPoint(x: centre.x + Art.lineTo * unit, y: centre.y + Art.row * unit))
        }
        .stroke(Self.gold.opacity(0.9),
                style: StrokeStyle(lineWidth: 3 * unit, lineCap: .round,
                                   dash: [7 * unit, 11 * unit], dashPhase: dashPhase * unit))
        .shadow(color: Self.gold.opacity(0.35), radius: 3 * unit)

        // 3. The two players' dots, breathing out of step so the pair reads as a conversation.
        dot(Self.nearColor, at: Art.nearDot, centre: centre, unit: unit, offBeat: false)
        dot(Self.farColor, at: Art.farDot, centre: centre, unit: unit, offBeat: true)
    }

    private func dot(_ color: Color, at point: CGPoint, centre: CGPoint, unit: CGFloat,
                     offBeat: Bool) -> some View {
        let grown = breathing != offBeat        // one leads, the other follows
        return Circle()
            .fill(color)
            .frame(width: Art.dotRadius * 2 * unit, height: Art.dotRadius * 2 * unit)
            .shadow(color: color.opacity(0.9), radius: (grown ? 9 : 5) * unit)
            .scaleEffect(grown ? 1.16 : 0.94)
            .position(x: centre.x + point.x * unit, y: centre.y + point.y * unit)
    }

    // MARK: Timing

    private func run() async {
        guard !reduceMotion else {
            // No motion: just let the poster stand for a moment.
            try? await Task.sleep(for: .milliseconds(450))
            finish()
            return
        }
        withAnimation(.linear(duration: 0.65).repeatForever(autoreverses: false)) {
            dashPhase = -18                     // negative pulls the dashes toward the far phone
        }
        withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) {
            breathing = true
        }
        try? await Task.sleep(for: .milliseconds(1_150))
        finish()
    }

    private func finish() {
        guard !leaving else { return }           // a tap during the fade shouldn't restart it
        withAnimation(.easeOut(duration: 0.35)) { leaving = true }
        Task {
            try? await Task.sleep(for: .milliseconds(350))
            onFinish()
        }
    }
}

#if DEBUG
#Preview("Opening", traits: .landscapeLeft) {
    OpeningView(onFinish: {})
}
#endif
