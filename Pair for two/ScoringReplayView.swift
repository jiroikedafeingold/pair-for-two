import SwiftUI

/// Replays how the scores were built over the whole game: it steps through every claim in order,
/// incrementing each player's running total so you can watch the race to 121. Shown from the win
/// screen (a "Replay scoring" button) or automatically before the win screen (a Settings option).
struct ScoringReplayView: View {
    let events: [Claim]
    let p1Name: String
    let p2Name: String
    let p1Theme: PlayerTheme
    let p2Theme: PlayerTheme
    let onFinish: () -> Void

    @State private var step = 0            // how many events have been applied
    @State private var appeared = false
    @State private var task: Task<Void, Never>?

    /// Running score for a player over the first `step` events.
    private func score(_ player: PlayerID) -> Int {
        events.prefix(step).filter { $0.player == player }.reduce(0) { $0 + $1.amount }
    }

    private var current: Claim? { step > 0 ? events[step - 1] : nil }

    private func phaseLabel(_ phase: GamePhase) -> String {
        switch phase {
        case .pegging:                 return "Pegging"
        case .showPone, .showDealer:   return "Hand"
        case .showCrib:                return "Crib"
        default:                        return "Cut"
        }
    }

    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial).ignoresSafeArea()
            LinearGradient(colors: [.feltMid.opacity(0.6), .feltDark.opacity(0.85)],
                           startPoint: .top, endPoint: .bottom).ignoresSafeArea()

            VStack(spacing: 18) {
                Text("SCORING REPLAY")
                    .font(.system(size: 14, weight: .black, design: .rounded)).tracking(3)
                    .foregroundStyle(.white.opacity(0.8))

                HStack(spacing: 0) {
                    column(.one, name: p1Name, theme: p1Theme)
                    Rectangle().fill(.white.opacity(0.15)).frame(width: 1, height: 70)
                    column(.two, name: p2Name, theme: p2Theme)
                }
                .frame(maxWidth: 640)

                // What the most recent step scored.
                if let c = current {
                    Text("\(phaseLabel(c.phase)) · +\(c.amount)")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.85))
                        .padding(.horizontal, 14).padding(.vertical, 6)
                        .background(Capsule().fill(.white.opacity(0.12)))
                        .id(step)
                        .transition(.scale.combined(with: .opacity))
                } else {
                    Text("The whole game, score by score")
                        .font(.callout).foregroundStyle(.white.opacity(0.7))
                }

                // Progress through the events.
                ProgressView(value: Double(step), total: Double(max(events.count, 1)))
                    .tint(.cribGold)
                    .frame(maxWidth: 320)

                Button(step >= events.count ? "Show result" : "Skip") { finish() }
                    .buttonStyle(.borderedProminent).tint(.cribGold).foregroundStyle(.black)
            }
            .padding(28)
            .opacity(appeared ? 1 : 0)
            .scaleEffect(appeared ? 1 : 0.94)
        }
        .onAppear { start() }
        .onDisappear { task?.cancel() }
    }

    @ViewBuilder private func column(_ player: PlayerID, name: String, theme: PlayerTheme) -> some View {
        let isScoring = current?.player == player
        VStack(spacing: 4) {
            Text(name.uppercased())
                .font(.title3.weight(.heavy)).foregroundStyle(theme.primary)
                .lineLimit(1).minimumScaleFactor(0.6)
            HStack(alignment: .center, spacing: 6) {
                Text("\(score(player))")
                    .font(.system(size: 54, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white).monospacedDigit()
                    .contentTransition(.numericText(value: Double(score(player))))
                if isScoring, let c = current {
                    Text("+\(c.amount)")
                        .font(.system(size: 22, weight: .heavy, design: .rounded)).monospacedDigit()
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8).padding(.vertical, 2)
                        .background(Capsule().fill(theme.primary))
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .scaleEffect(isScoring ? 1.06 : 1.0)
        }
        .frame(maxWidth: .infinity)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: step)
    }

    private func start() {
        withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) { appeared = true }
        guard !events.isEmpty else { return }
        // Keep the whole replay to a snappy ~7s regardless of how many scores there were.
        let per = max(0.12, min(0.5, 7.0 / Double(events.count)))
        task = Task { @MainActor in
            for i in 1...events.count {
                try? await Task.sleep(for: .seconds(per))
                guard !Task.isCancelled else { return }
                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { step = i }
                GameFeedback.shared.play(.score)
            }
            try? await Task.sleep(for: .seconds(1.0))
            guard !Task.isCancelled else { return }
            onFinish()
        }
    }

    private func finish() {
        task?.cancel()
        step = events.count      // jump to final totals
        onFinish()
    }
}

#Preview("Scoring replay", traits: .landscapeLeft) {
    ScoringReplayView(
        events: [
            Claim(player: .one, amount: 2, phase: .pegging),
            Claim(player: .two, amount: 1, phase: .pegging),
            Claim(player: .one, amount: 8, phase: .showPone),
            Claim(player: .two, amount: 12, phase: .showDealer),
            Claim(player: .two, amount: 4, phase: .showCrib),
            Claim(player: .one, amount: 6, phase: .pegging)
        ],
        p1Name: "Ann", p2Name: "Ben",
        p1Theme: playerThemes[1], p2Theme: playerThemes[7],
        onFinish: {}
    )
}
