import SwiftUI

// MARK: - Score Panel (adapted from Criboard's PlayerPanel)

/// The manual scoring control: a 0–29 points slider, an accumulating +1 / +N button, and undo.
/// Adapted from Criboard's `PlayerPanel` — the giant name watermark is replaced with a live
/// `your-score / opponent-score` readout in the player's theme color. `onAdd`/`onPlusOne`/`onUndo`
/// map to `claimPoints` / `undo` intents.
struct ScorePanel: View {
    let name: String
    let score: Int
    let opponentScore: Int
    let primary: Color
    let deep: Color
    let disabled: Bool
    let canUndo: Bool
    var requireConfirm: Bool = false
    /// Opponent's color + a pending "+X" they're about to add (shown for a few seconds before their
    /// score updates), so this player can see what the other is scoring.
    var opponentColor: Color = .gray
    var opponentPending: Int = 0
    /// When true this is the only panel on screen (networked play), so it carries *both* players'
    /// progress loops — your color on the outer edge, the opponent's just inside it. When false
    /// (pass-and-play, one panel per player) only this player's own loop is drawn.
    var showOpponentTrack: Bool = false
    /// Set false to drop this panel's own score readout and progress loop, for a screen that shows the
    /// score elsewhere — the board mode puts both in a shared band between the two players, and having
    /// them here as well says the same number three times.
    var showsScore: Bool = true
    /// Reports this panel's currently-uncommitted amount (slider/​+1 staged in a confirm mode) so the
    /// screen can prompt before advancing. `clearSignal` (when it changes) tells the panel to drop its
    /// staged pending — used after the amount has been claimed elsewhere.
    var uncommitted: Binding<Int>? = nil
    var clearSignal: Int = 0
    let onAdd: (Int) -> Void
    let onPlusOne: () -> Void
    let onUndo: () -> Void
    /// Fired whenever this player touches the panel at all — dragging the slider, tapping +1, undoing.
    /// The board uses it to turn the shared score to face whoever is using it, which has to happen the
    /// moment they start, not when they finish. No-op everywhere else.
    var onActivity: () -> Void = {}

    @State private var pending: Int = 0
    @State private var sliderIsDragging: Bool = false
    @State private var plusPending: Int = 0
    @State private var plusTask: Task<Void, Never>? = nil
    @State private var plusHeavy = UIImpactFeedbackGenerator(style: .heavy)
    @State private var plusRigid = UIImpactFeedbackGenerator(style: .rigid)
    @State private var glowPulse: Bool = false
    @AppStorage("scoreTrackEnabled") private var scoreTrackEnabled = true

    private var awaitingConfirm: Bool { requireConfirm && pending > 0 && !sliderIsDragging }

    private var displayValue: Int {
        if sliderIsDragging || awaitingConfirm { return pending }
        if plusPending > 0 { return plusPending }
        return 1
    }

    private var showingElevatedValue: Bool { displayValue != 1 }
    private var highlighted: Bool { showingElevatedValue || awaitingConfirm }

    private func firePlusHaptic() {
        guard HapticsSetting.enabled else { return }
        plusHeavy.impactOccurred(intensity: 1.0)
        plusHeavy.prepare()
    }

    private func fireCommitHaptic() {
        guard HapticsSetting.enabled else { return }
        plusHeavy.impactOccurred(intensity: 1.0)
        plusRigid.impactOccurred(intensity: 1.0)
        plusHeavy.prepare(); plusRigid.prepare()
    }

    // +1 always adds immediately; `plusPending` is just a fading running count of the streak.
    private func handlePlusTap() {
        onActivity()
        firePlusHaptic()
        onPlusOne()
        withAnimation(.spring(response: 0.3, dampingFraction: 0.78)) { plusPending += 1 }
        scheduleStreakReset()
    }

    private func scheduleStreakReset() {
        plusTask?.cancel()
        plusTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            withAnimation(.spring(response: 0.3, dampingFraction: 0.78)) { plusPending = 0 }
        }
    }

    var body: some View {
        ZStack {
            // Live score readout behind the controls (replaces Criboard's name watermark): your score
            // in your color, the opponent's in theirs, with their pending "+X" right beside it.
            if showsScore {
            HStack(spacing: 6) {
                Text("\(score)").foregroundStyle(primary.opacity(0.85))
                Text("/").foregroundStyle(.white.opacity(0.35))
                Text("\(opponentScore)").foregroundStyle(opponentColor.opacity(0.85))
                if opponentPending > 0 {
                    Text("+\(opponentPending)")
                        .font(.system(size: 26, weight: .heavy, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8).padding(.vertical, 2)
                        .background(Capsule().fill(opponentColor))
                        .overlay(Capsule().stroke(.white.opacity(0.5), lineWidth: 1))
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .font(.system(size: 56, weight: .black, design: .rounded))
            .tracking(2)
            .lineLimit(1)
            .minimumScaleFactor(0.4)
            .monospacedDigit()
            .shadow(color: primary.opacity(0.4), radius: 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .allowsHitTesting(false)
            .accessibilityLabel("\(name): \(score) points, opponent \(opponentScore)")
            }

            HStack(spacing: 12) {
                Button {
                    if awaitingConfirm {
                        let value = pending
                        onAdd(value)
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.78)) { pending = 0 }
                        fireCommitHaptic()
                    } else if !sliderIsDragging {
                        handlePlusTap()
                    }
                } label: {
                    Text("+\(displayValue)")
                        .font(.system(size: 22, weight: .black, design: .rounded))
                        .foregroundStyle(
                            highlighted
                            ? AnyShapeStyle(.white)
                            : AnyShapeStyle(LinearGradient(colors: [primary, deep], startPoint: .top, endPoint: .bottom))
                        )
                        .monospacedDigit()
                        .contentTransition(.numericText(value: Double(displayValue)))
                        .frame(minWidth: 56, minHeight: 44)
                        .padding(.horizontal, 8)
                        .background(
                            Capsule()
                                .fill(primary.opacity(highlighted ? 0.42 : 0.16))
                                .overlay(
                                    Capsule().stroke(
                                        primary.opacity(highlighted ? 0.95 : 0.55),
                                        lineWidth: highlighted ? 1.6 : 1
                                    )
                                )
                        )
                        .scaleEffect(highlighted ? 1.05 : 1.0)
                        .shadow(color: primary.opacity(highlighted ? 0.75 : 0.0), radius: 10)
                        .shadow(
                            color: primary.opacity(highlighted ? (glowPulse ? 0.9 : 0.35) : 0.0),
                            radius: highlighted ? (glowPulse ? 24 : 12) : 0
                        )
                        .animation(.easeInOut(duration: 0.22), value: highlighted)
                        .onChange(of: highlighted) { _, isShowing in
                            if isShowing {
                                withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true)) {
                                    glowPulse = true
                                }
                            } else {
                                withAnimation(.easeInOut(duration: 0.5)) { glowPulse = false }
                            }
                        }
                }
                .buttonStyle(.plain)
                .disabled(disabled)
                .opacity(disabled ? 0.4 : 1.0)
                .onAppear { plusHeavy.prepare(); plusRigid.prepare() }

                PointsSlider(value: $pending, isDragging: $sliderIsDragging, primary: primary, deep: deep) { committed in
                    onActivity()
                    if !requireConfirm {
                        onAdd(committed)
                        if HapticsSetting.enabled { UIImpactFeedbackGenerator(style: .medium).impactOccurred() }
                        withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) { pending = 0 }
                    }
                }
                .frame(height: 44)
                .disabled(disabled)
                .opacity(disabled ? 0.4 : 1.0)

                Button {
                    onActivity()
                    if pending > 0 {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.78)) { pending = 0 }
                    } else {
                        onUndo()
                    }
                    if HapticsSetting.enabled { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.system(size: 13, weight: .black))
                        .foregroundStyle(.white.opacity(0.85))
                        .frame(width: 38, height: 38)
                        .background(
                            Circle()
                                .fill(Color.white.opacity(0.08))
                                .overlay(Circle().stroke(Color.white.opacity(0.15), lineWidth: 1))
                        )
                }
                .disabled((!canUndo && pending == 0) || disabled)
                .opacity(((!canUndo && pending == 0) || disabled) ? 0.30 : 1.0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .onChange(of: sliderIsDragging) { _, dragging in if dragging { onActivity() } }
            .onChange(of: pending) { _, _ in onActivity() }
        }
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color.white.opacity(0.06), Color.white.opacity(0.02)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(Color.white.opacity(0.10), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.35), radius: 14, y: 6)
        )
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        // The panel edge doubles as a cribbage track: each player's color fills around the oval as
        // they climb toward 121, closing into a complete loop at game point. Overlaid (not clipped)
        // so the stroke rides the rounded edge.
        .overlay {
            if scoreTrackEnabled, showsScore {
                ScoreTrackOverlay(youFraction: loopFraction(score), youColor: primary,
                                  opponentFraction: showOpponentTrack ? loopFraction(opponentScore) : nil,
                                  opponentColor: opponentColor)
                    // Sit a touch outside the controls so the lines stay clear of the numbers.
                    .padding(-4)
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: opponentPending)
        .onChange(of: pending) { _, _ in reportUncommitted() }
        .onChange(of: clearSignal) { _, _ in
            plusTask?.cancel()
            withAnimation(.spring(response: 0.3, dampingFraction: 0.78)) {
                pending = 0; plusPending = 0
            }
            reportUncommitted()
        }
    }

    /// The amount staged but not yet added (only "confirm after release").
    private func reportUncommitted() {
        uncommitted?.wrappedValue = requireConfirm ? pending : 0
    }

    /// How much of the loop a score fills: 0 at the start, a full loop (1) at the 121 game point.
    private func loopFraction(_ points: Int) -> Double {
        min(1, max(0, Double(points) / 121))
    }
}

/// One or two cribbage progress loops (0 → 121) traced around a rounded region, plus a small tick
/// at the bottom-middle marking where the loop starts and finishes. Used on the manual score panels
/// and, in auto-scoring, around the names + scores. Subtle by design so it frames the numbers
/// without competing with them.
struct ScoreTrackOverlay: View {
    var youFraction: Double
    var youColor: Color
    /// nil draws a single loop (one oval per player); a value adds a nested opponent loop just
    /// inside (a lone oval carrying both players).
    var opponentFraction: Double? = nil
    var opponentColor: Color = .gray
    var cornerRadius: CGFloat = 22

    var body: some View {
        ZStack {
            ScoreLoop(fraction: youFraction, color: youColor,
                      cornerRadius: cornerRadius, inset: 3, lineWidth: 2)
            if let opp = opponentFraction {
                ScoreLoop(fraction: opp, color: opponentColor,
                          cornerRadius: cornerRadius, inset: 8.5, lineWidth: 1.75)
            }
            StartTick(long: opponentFraction != nil)
            // The double-skunk (60) and skunk (90) marks: two little skunks and one, on the track.
            SkunkMark(fraction: 60.0 / 121.0, count: 2, cornerRadius: cornerRadius)
            SkunkMark(fraction: 90.0 / 121.0, count: 1, cornerRadius: cornerRadius)
        }
        .allowsHitTesting(false)
    }
}

/// A single progress loop traced around a rounded edge, in one player's color. A faint full-loop
/// track sits behind it so the remaining distance to 121 stays visible; the filled portion glows,
/// brightening into a closed ring at game point.
private struct ScoreLoop: View {
    let fraction: Double
    let color: Color
    var cornerRadius: CGFloat = 22
    /// How far inside the edge this loop sits — lets a second (opponent) loop nest within.
    let inset: CGFloat
    let lineWidth: CGFloat

    private var complete: Bool { fraction >= 1 }

    var body: some View {
        let shape = TrackShape(cornerRadius: cornerRadius).inset(by: inset)
        ZStack {
            shape.stroke(color.opacity(0.12), lineWidth: lineWidth)
            shape
                .trim(from: 0, to: fraction)
                .stroke(color.opacity(0.9), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .shadow(color: color.opacity(complete ? 0.7 : 0.3),
                        radius: complete ? 6 : 3)
        }
        .animation(.easeInOut(duration: 0.5), value: fraction)
    }
}

/// The small tick at the bottom-middle where the loops start and finish (the 0 / 121 point).
private struct StartTick: View {
    let long: Bool

    var body: some View {
        Capsule()
            .fill(.white.opacity(0.28))
            .frame(width: 1.5, height: long ? 10 : 6)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    }
}

/// A small, faint skunk placed on the track at `fraction` — two skunks for the double-skunk line
/// (60) and one for the skunk line (90). The position is read off the same `TrackShape` the loops
/// use, so each mark sits right on the ring.
private struct SkunkMark: View {
    let fraction: Double
    let count: Int
    var cornerRadius: CGFloat = 22
    var glyphSize: CGFloat = 13

    var body: some View {
        GeometryReader { geo in
            let path = TrackShape(cornerRadius: cornerRadius).inset(by: 5.5)
                .path(in: CGRect(origin: .zero, size: geo.size))
            let r = path.trimmedPath(from: max(0, CGFloat(fraction) - 0.004),
                                     to: min(1, CGFloat(fraction) + 0.004)).boundingRect
            HStack(spacing: -glyphSize * 0.32) {
                ForEach(0..<count, id: \.self) { _ in
                    Text("🦨").font(.system(size: glyphSize))
                }
            }
            .opacity(0.5)
            .position(x: r.midX, y: r.midY)
        }
    }
}

/// The rounded-rectangle perimeter as a path that *starts at the bottom-middle* and winds
/// counter-clockwise, so a `.trim` fills the loop from the bottom outward the way the score climbs.
/// (SwiftUI's `RoundedRectangle` starts near the top and goes clockwise.)
private struct TrackShape: InsettableShape {
    var cornerRadius: CGFloat
    var insetAmount: CGFloat = 0

    func inset(by amount: CGFloat) -> TrackShape {
        var copy = self
        copy.insetAmount += amount
        return copy
    }

    func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx: insetAmount, dy: insetAmount)
        let rad = max(0, min(cornerRadius - insetAmount, min(r.width, r.height) / 2))
        var p = Path()
        // Start at bottom-middle, then head right and wind counter-clockwise (right side up, across
        // the top, down the left) back to the start.
        p.move(to: CGPoint(x: r.midX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - rad, y: r.maxY))
        p.addArc(tangent1End: CGPoint(x: r.maxX, y: r.maxY),
                 tangent2End: CGPoint(x: r.maxX, y: r.maxY - rad), radius: rad)
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY + rad))
        p.addArc(tangent1End: CGPoint(x: r.maxX, y: r.minY),
                 tangent2End: CGPoint(x: r.maxX - rad, y: r.minY), radius: rad)
        p.addLine(to: CGPoint(x: r.minX + rad, y: r.minY))
        p.addArc(tangent1End: CGPoint(x: r.minX, y: r.minY),
                 tangent2End: CGPoint(x: r.minX, y: r.minY + rad), radius: rad)
        p.addLine(to: CGPoint(x: r.minX, y: r.maxY - rad))
        p.addArc(tangent1End: CGPoint(x: r.minX, y: r.maxY),
                 tangent2End: CGPoint(x: r.minX + rad, y: r.maxY), radius: rad)
        p.addLine(to: CGPoint(x: r.midX, y: r.maxY))
        return p
    }
}

#Preview(traits: .landscapeLeft) {
    ScorePanel(name: "Ann", score: 42, opponentScore: 67,
               primary: playerThemes[1].primary, deep: playerThemes[1].deep,
               disabled: false, canUndo: true,
               opponentColor: playerThemes[7].primary, opponentPending: 3,
               showOpponentTrack: true,
               onAdd: { _ in }, onPlusOne: {}, onUndo: {})
        .frame(width: 420, height: 90)
        .padding()
        .background(Color.feltDark)
}

// MARK: - Points Slider (reused as-is from Criboard)

struct PointsSlider: View {
    @Binding var value: Int
    @Binding var isDragging: Bool
    let primary: Color
    let deep: Color
    let onCommit: (Int) -> Void

    @State private var dragStartValue: Int = 0

    private let maxValue = 29

    var body: some View {
        GeometryReader { geo in
            let knobSize: CGFloat = 32
            let trackHeight: CGFloat = 10
            let usable = geo.size.width - knobSize
            let progress = CGFloat(value) / CGFloat(maxValue)
            let knobX = progress * usable

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.08))
                    .frame(height: trackHeight)

                HStack(spacing: 0) {
                    ForEach(0...maxValue, id: \.self) { i in
                        Rectangle()
                            .fill(Color.white.opacity(i % 5 == 0 ? 0.28 : 0.0))
                            .frame(width: 1, height: i % 5 == 0 ? 6 : 0)
                        if i < maxValue { Spacer(minLength: 0) }
                    }
                }
                .padding(.horizontal, knobSize / 2)

                Capsule()
                    .fill(LinearGradient(colors: [deep, primary], startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(trackHeight, knobX + knobSize / 2), height: trackHeight)

                ZStack {
                    Circle().fill(.white)
                    Circle()
                        .fill(LinearGradient(colors: [primary.opacity(0.0), primary.opacity(0.25)], startPoint: .top, endPoint: .bottom))
                }
                .frame(width: knobSize, height: knobSize)
                .scaleEffect(isDragging ? 1.12 : 1.0)
                .shadow(color: primary.opacity(0.5), radius: isDragging ? 14 : 8)
                .shadow(color: .black.opacity(0.35), radius: 4, y: 2)
                .offset(x: knobX)
                .animation(.interactiveSpring(response: 0.25, dampingFraction: 0.85), value: value)
                .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isDragging)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        if !isDragging {
                            isDragging = true
                            dragStartValue = value
                            DragTickHaptics.shared.prepare()
                        }
                        let stepWidth = usable / CGFloat(maxValue)
                        let delta = Int((g.translation.width / max(stepWidth, 1)).rounded())
                        let newValue = min(maxValue, max(0, dragStartValue + delta))
                        if newValue != value {
                            value = newValue
                            DragTickHaptics.shared.tick(progress: Double(newValue) / Double(maxValue))
                        }
                    }
                    .onEnded { _ in
                        guard isDragging else { return }
                        isDragging = false
                        if value > 0 { onCommit(value) }
                    }
            )
        }
        .onAppear { DragTickHaptics.shared.prepare() }
    }
}
