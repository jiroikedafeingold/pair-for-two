import SwiftUI

// MARK: - Score Panel (adapted from Criboard's PlayerPanel)

/// The manual scoring control: a 0–29 points slider, an accumulating +1 / +N button, and undo.
/// Adapted from Criboard's `PlayerPanel` — the giant name watermark is replaced with a live
/// `your-score / opponent-score` readout in the player's theme colour. `onAdd`/`onPlusOne`/`onUndo`
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
    var requirePlusConfirm: Bool = false
    /// Opponent's colour + a pending "+X" they're about to add (shown for a few seconds before their
    /// score updates), so this player can see what the other is scoring.
    var opponentColor: Color = .gray
    var opponentPending: Int = 0
    /// Reports this panel's currently-uncommitted amount (slider/​+1 staged in a confirm mode) so the
    /// screen can prompt before advancing. `clearSignal` (when it changes) tells the panel to drop its
    /// staged pending — used after the amount has been claimed elsewhere.
    var uncommitted: Binding<Int>? = nil
    var clearSignal: Int = 0
    let onAdd: (Int) -> Void
    let onPlusOne: () -> Void
    let onUndo: () -> Void

    @State private var pending: Int = 0
    @State private var sliderIsDragging: Bool = false
    @State private var plusPending: Int = 0
    @State private var plusSettled: Bool = false
    @State private var plusTask: Task<Void, Never>? = nil
    @State private var plusHeavy = UIImpactFeedbackGenerator(style: .heavy)
    @State private var plusRigid = UIImpactFeedbackGenerator(style: .rigid)
    @State private var glowPulse: Bool = false

    private let plusSettleDelay: TimeInterval = 0.8
    private let plusAutoAcceptDelay: TimeInterval = 2.2

    private var awaitingConfirm: Bool { requireConfirm && pending > 0 && !sliderIsDragging }
    private var awaitingPlusConfirm: Bool { requirePlusConfirm && plusPending > 0 }

    private var displayValue: Int {
        if sliderIsDragging || awaitingConfirm { return pending }
        if plusPending > 0 { return plusPending }
        return 1
    }

    private var showingElevatedValue: Bool { displayValue != 1 }
    private var highlighted: Bool { showingElevatedValue || awaitingConfirm || awaitingPlusConfirm }

    private func firePlusHaptic() {
        plusHeavy.impactOccurred(intensity: 1.0)
        plusHeavy.prepare()
    }

    private func fireCommitHaptic() {
        plusHeavy.impactOccurred(intensity: 1.0)
        plusRigid.impactOccurred(intensity: 1.0)
        plusHeavy.prepare(); plusRigid.prepare()
    }

    private func handlePlusTap() {
        if requirePlusConfirm {
            if plusSettled { commitPlus(); return }
            firePlusHaptic()
            withAnimation(.spring(response: 0.3, dampingFraction: 0.78)) { plusPending += 1 }
            schedulePlusConfirm()
        } else {
            firePlusHaptic()
            onPlusOne()
            withAnimation(.spring(response: 0.3, dampingFraction: 0.78)) { plusPending += 1 }
            scheduleStreakReset()
        }
    }

    private func schedulePlusConfirm() {
        plusTask?.cancel()
        plusSettled = false
        plusTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(plusSettleDelay))
            guard !Task.isCancelled else { return }
            plusSettled = true
            try? await Task.sleep(for: .seconds(plusAutoAcceptDelay - plusSettleDelay))
            guard !Task.isCancelled else { return }
            commitPlus()
        }
    }

    private func scheduleStreakReset() {
        plusTask?.cancel()
        plusTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            withAnimation(.spring(response: 0.3, dampingFraction: 0.78)) { plusPending = 0 }
        }
    }

    private func commitPlus() {
        plusTask?.cancel()
        let amount = plusPending
        plusSettled = false
        withAnimation(.spring(response: 0.3, dampingFraction: 0.78)) { plusPending = 0 }
        if amount > 0 {
            onAdd(amount)
            fireCommitHaptic()
        }
    }

    private func cancelPlus() {
        plusTask?.cancel()
        plusSettled = false
        withAnimation(.spring(response: 0.3, dampingFraction: 0.78)) { plusPending = 0 }
    }

    var body: some View {
        ZStack {
            // Live score readout behind the controls (replaces Criboard's name watermark): your score
            // in your colour, the opponent's in theirs, with their pending "+X" right beside it.
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
                    if !requireConfirm {
                        onAdd(committed)
                        let gen = UIImpactFeedbackGenerator(style: .medium)
                        gen.impactOccurred()
                        withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) { pending = 0 }
                    }
                }
                .frame(height: 44)
                .disabled(disabled)
                .opacity(disabled ? 0.4 : 1.0)

                Button {
                    if pending > 0 {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.78)) { pending = 0 }
                    } else if awaitingPlusConfirm {
                        cancelPlus()
                    } else {
                        onUndo()
                    }
                    let gen = UIImpactFeedbackGenerator(style: .light)
                    gen.impactOccurred()
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
                .disabled((!canUndo && pending == 0 && !awaitingPlusConfirm) || disabled)
                .opacity(((!canUndo && pending == 0 && !awaitingPlusConfirm) || disabled) ? 0.30 : 1.0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
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
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: opponentPending)
        .onChange(of: pending) { _, _ in reportUncommitted() }
        .onChange(of: plusPending) { _, _ in reportUncommitted() }
        .onChange(of: clearSignal) { _, _ in
            plusTask?.cancel()
            withAnimation(.spring(response: 0.3, dampingFraction: 0.78)) {
                pending = 0; plusPending = 0; plusSettled = false
            }
            reportUncommitted()
        }
    }

    /// The amount staged but not yet added (only in the confirm modes).
    private func reportUncommitted() {
        let amount = (requireConfirm ? pending : 0) + (requirePlusConfirm ? plusPending : 0)
        uncommitted?.wrappedValue = amount
    }
}

#Preview(traits: .landscapeLeft) {
    ScorePanel(name: "Ann", score: 42, opponentScore: 67,
               primary: playerThemes[1].primary, deep: playerThemes[1].deep,
               disabled: false, canUndo: true,
               opponentColor: playerThemes[7].primary, opponentPending: 3,
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
