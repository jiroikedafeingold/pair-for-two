import SwiftUI

/// The game-over screen shown on the **losing** player's device — a subdued, rainy "you lost" card,
/// scaled by how badly they lost (skunk level). Still offers Play Again and the scoring replay.
struct LoserOverlay: View {
    let winnerName: String
    let skunk: SkunkLevel
    var canReplay: Bool = false
    let onPlayAgain: () -> Void
    var onReplay: () -> Void = {}

    @State private var animateIn = false
    @State private var droop = false

    @AppStorage("celebrationEffects") private var celebrationEffects = true

    private let slate = Color(red: 0.52, green: 0.57, blue: 0.68)

    private var title: String {
        switch skunk {
        case .none:   return "YOU LOST"
        case .single: return "SKUNKED"
        case .double: return "DOUBLE SKUNKED"
        }
    }

    private var subtitle: String {
        switch skunk {
        case .none:   return "Good game — rematch?"
        case .single: return "Ouch. Run it back?"
        case .double: return "Brutal. Get 'em next time."
        }
    }

    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial).ignoresSafeArea().opacity(animateIn ? 1 : 0)
            LinearGradient(colors: [Color.black.opacity(0.35), Color.black.opacity(0.55)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea().opacity(animateIn ? 1 : 0)

            if celebrationEffects {
                SadRainView().opacity(animateIn ? 0.9 : 0)
            }

            VStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(RadialGradient(colors: [slate.opacity(0.5), slate.opacity(0.0)],
                                             center: .center, startRadius: 8, endRadius: 72))
                        .frame(width: 130, height: 130)
                    Text("😔")
                        .font(.system(size: 60))
                        .offset(y: droop ? 5 : -3)
                        .animation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true), value: droop)
                }

                VStack(spacing: 6) {
                    Text(title)
                        .font(.system(size: skunk == .double ? 30 : 34, weight: .black, design: .rounded))
                        .foregroundStyle(LinearGradient(colors: [.white.opacity(0.9), slate],
                                                        startPoint: .leading, endPoint: .trailing))
                        .multilineTextAlignment(.center).minimumScaleFactor(0.6).lineLimit(1)
                    Text("\(winnerName) wins")
                        .font(.system(size: 13, weight: .black, design: .rounded)).tracking(2)
                        .foregroundStyle(.white.opacity(0.7))
                    Text(subtitle)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.55)).italic()
                }

                Button(action: onPlayAgain) {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.counterclockwise.circle.fill").font(.system(size: 18, weight: .bold))
                        Text("PLAY AGAIN").font(.system(size: 15, weight: .black, design: .rounded)).tracking(2.2)
                    }
                    .foregroundStyle(.black.opacity(0.88))
                    .padding(.horizontal, 26).padding(.vertical, 11)
                    .background(Capsule().fill(LinearGradient(colors: [.cribGold, Color(red: 0.78, green: 0.55, blue: 0.20)],
                                                              startPoint: .topLeading, endPoint: .bottomTrailing)))
                    .overlay(Capsule().stroke(.white.opacity(0.4), lineWidth: 1.2))
                    .shadow(color: .black.opacity(0.45), radius: 10, y: 4)
                }
                .padding(.top, 2)

                if canReplay {
                    Button(action: onReplay) {
                        Label("Replay scoring", systemImage: "play.circle.fill")
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.9))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(20)
            .frame(maxWidth: 320)
            .background(
                RoundedRectangle(cornerRadius: 32, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(RoundedRectangle(cornerRadius: 32, style: .continuous)
                        .fill(LinearGradient(colors: [Color.white.opacity(0.04), Color.black.opacity(0.25)],
                                             startPoint: .top, endPoint: .bottom)))
                    .overlay(RoundedRectangle(cornerRadius: 32, style: .continuous)
                        .stroke(slate.opacity(0.5), lineWidth: 1.5))
                    .shadow(color: .black.opacity(0.5), radius: 26, y: 10)
            )
            .scaleEffect(animateIn ? 1 : 0.85)
            .opacity(animateIn ? 1 : 0)
        }
        .onAppear {
            withAnimation(.spring(response: 0.6, dampingFraction: 0.8)) { animateIn = true }
            droop = true
            LoseHaptics.shared.play()
        }
    }
}

// MARK: - Sad rain

/// Slow, thin grey rain streaks falling behind the loser card. Pure Canvas, no assets.
struct SadRainView: View {
    @State private var start = Date()

    private struct Drop { let x: CGFloat; let speed: Double; let len: CGFloat; let phase: Double; let opacity: Double }
    private let drops: [Drop]

    init() {
        var arr: [Drop] = []
        for _ in 0..<70 {
            arr.append(Drop(x: .random(in: 0...1),
                            speed: .random(in: 0.6...1.3),
                            len: .random(in: 10...26),
                            phase: .random(in: 0...1),
                            opacity: .random(in: 0.12...0.35)))
        }
        drops = arr
    }

    var body: some View {
        TimelineView(.animation) { tl in
            let t = tl.date.timeIntervalSince(start)
            Canvas { ctx, size in
                for d in drops {
                    let cycle = 1.7 / d.speed
                    let p = ((t / cycle) + d.phase).truncatingRemainder(dividingBy: 1)
                    let y = CGFloat(p) * (size.height + 40) - 20
                    let x = d.x * size.width
                    var path = Path()
                    path.move(to: CGPoint(x: x, y: y))
                    path.addLine(to: CGPoint(x: x - 1.5, y: y + d.len))
                    ctx.stroke(path, with: .color(.white.opacity(d.opacity)), lineWidth: 1.4)
                }
            }
        }
        .allowsHitTesting(false)
        .ignoresSafeArea()
    }
}

#Preview("Loser", traits: .landscapeLeft) {
    ZStack {
        LinearGradient(colors: [.feltMid, .feltDark], startPoint: .top, endPoint: .bottom).ignoresSafeArea()
        LoserOverlay(winnerName: "Ann", skunk: .single, canReplay: true, onPlayAgain: {}, onReplay: {})
    }
}
