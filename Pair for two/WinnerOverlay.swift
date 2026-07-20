import SwiftUI

// MARK: - Skunk level (reused from Criboard)

enum SkunkLevel {
    case none, single, double

    var title: String {
        switch self {
        case .none:   return "VICTORY"
        case .single: return "SKUNKED!"
        case .double: return "DOUBLE SKUNK!"
        }
    }

    var subtitle: String {
        switch self {
        case .none:   return "Well played"
        case .single: return "A clean sweep"
        case .double: return "An absolute thrashing"
        }
    }

    var accentColors: [Color] {
        switch self {
        case .none:   return [.cribGold, Color(red: 1.0, green: 0.85, blue: 0.45)]
        case .single: return [Color(red: 1.0, green: 0.75, blue: 0.25), Color(red: 1.0, green: 0.45, blue: 0.15)]
        case .double: return [Color(red: 1.0, green: 0.35, blue: 0.45), Color(red: 0.85, green: 0.20, blue: 0.65), Color(red: 0.45, green: 0.30, blue: 0.95)]
        }
    }
}

/// Cribbage skunk lines: loser under 61 = double skunk, under 91 = skunk (reused from Criboard).
func computeSkunk(loserScore: Int) -> SkunkLevel {
    if loserScore < 61 { return .double }
    if loserScore < 91 { return .single }
    return .none
}

// MARK: - Winner overlay (adapted from Criboard for PlayerID; always landscape)

struct WinnerOverlay: View {
    let winner: PlayerID
    let skunk: SkunkLevel
    let winnerTheme: PlayerTheme
    let winnerName: String
    var loserChar: String = "🦨"
    var canReplay: Bool = false
    let onPlayAgain: () -> Void
    var onReplay: () -> Void = {}

    @State private var animateIn = false
    @State private var rotate = false
    @State private var pulse = false
    @State private var flash = false

    /// Settings → "Celebration effects": the extra fireworks + opening flash (the win card always shows).
    @AppStorage("celebrationEffects") private var celebrationEffects = true

    private var winnerColor: Color { winnerTheme.primary }
    private var effectColors: [Color] { skunk == .none ? [winnerColor, .cribGold, .white] : skunk.accentColors }

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)
                .ignoresSafeArea()
                .opacity(animateIn ? 1 : 0)

            if skunk == .double {
                Canvas { ctx, size in
                    let center = CGPoint(x: size.width / 2, y: size.height / 2)
                    let rayCount = 18
                    for i in 0..<rayCount {
                        let angle = Double(i) / Double(rayCount) * .pi * 2 + (rotate ? .pi / 6 : 0)
                        var path = Path()
                        let r1 = 80.0
                        let r2 = max(size.width, size.height)
                        let w = 0.06
                        let p1 = CGPoint(x: center.x + cos(angle - w) * r1, y: center.y + sin(angle - w) * r1)
                        let p2 = CGPoint(x: center.x + cos(angle + w) * r1, y: center.y + sin(angle + w) * r1)
                        let p3 = CGPoint(x: center.x + cos(angle + w * 2) * r2, y: center.y + sin(angle + w * 2) * r2)
                        let p4 = CGPoint(x: center.x + cos(angle - w * 2) * r2, y: center.y + sin(angle - w * 2) * r2)
                        path.move(to: p1)
                        path.addLine(to: p2)
                        path.addLine(to: p3)
                        path.addLine(to: p4)
                        path.closeSubpath()
                        let colors = skunk.accentColors
                        let color = colors[i % colors.count]
                        ctx.fill(path, with: .color(color.opacity(0.18)))
                    }
                }
                .ignoresSafeArea()
                .blendMode(.plusLighter)
                .animation(.linear(duration: 8).repeatForever(autoreverses: false), value: rotate)
            }

            if celebrationEffects {
                FireworksView(colors: effectColors)
                    .opacity(animateIn ? 1 : 0)
            }

            ConfettiBurst(colors: effectColors)
                .opacity(animateIn ? 1 : 0)

            VStack(spacing: 16) {
                ZStack {
                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [winnerColor.opacity(0.6), winnerColor.opacity(0.0)],
                                center: .center, startRadius: 10, endRadius: 110
                            )
                        )
                        .frame(width: 200, height: 200)
                        .scaleEffect(pulse ? 1.08 : 0.95)
                        .animation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true), value: pulse)

                    iconView
                }

                VStack(spacing: 6) {
                    Text("\(winnerName.uppercased()) WINS")
                        .font(.system(size: 13, weight: .black, design: .rounded))
                        .tracking(3.2)
                        .foregroundStyle(.white.opacity(0.75))

                    Text(LocalizedStringKey(skunk.title))
                        .font(.system(size: skunk == .double ? 36 : 44, weight: .black, design: .rounded))
                        .foregroundStyle(
                            LinearGradient(
                                colors: skunk == .none ? [.white, .cribGold] : skunk.accentColors,
                                startPoint: .leading, endPoint: .trailing
                            )
                        )
                        .multilineTextAlignment(.center)
                        .minimumScaleFactor(0.6)
                        .lineLimit(1)
                        .shadow(color: winnerColor.opacity(0.5), radius: 10)

                    Text(LocalizedStringKey(skunk.subtitle))
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.6))
                        .italic()
                }

                Button(action: onPlayAgain) {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.counterclockwise.circle.fill")
                            .font(.system(size: 18, weight: .bold))
                        Text("PLAY AGAIN")
                            .font(.system(size: 15, weight: .black, design: .rounded))
                            .tracking(2.2)
                    }
                    .foregroundStyle(.black.opacity(0.88))
                    .padding(.horizontal, 26)
                    .padding(.vertical, 13)
                    .background(
                        Capsule()
                            .fill(
                                LinearGradient(
                                    colors: [.cribGold, Color(red: 0.78, green: 0.55, blue: 0.20)],
                                    startPoint: .topLeading, endPoint: .bottomTrailing
                                )
                            )
                    )
                    .overlay(Capsule().stroke(.white.opacity(0.4), lineWidth: 1.2))
                    .shadow(color: .black.opacity(0.45), radius: 10, y: 4)
                }
                .padding(.top, 4)

                if canReplay {
                    Button(action: onReplay) {
                        Label("Replay scoring", systemImage: "play.circle.fill")
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.9))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(28)
            .frame(maxWidth: 320)
            .background(
                RoundedRectangle(cornerRadius: 32, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: 32, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [Color.white.opacity(0.05), Color.black.opacity(0.20)],
                                    startPoint: .top, endPoint: .bottom
                                )
                            )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 32, style: .continuous)
                            .stroke(
                                LinearGradient(
                                    colors: skunk == .none ? [winnerColor.opacity(0.7), winnerColor.opacity(0.2)] : skunk.accentColors,
                                    startPoint: .topLeading, endPoint: .bottomTrailing
                                ),
                                lineWidth: 1.5
                            )
                    )
                    .shadow(color: winnerColor.opacity(0.45), radius: 30, y: 10)
            )
            .scaleEffect(animateIn ? 1 : 0.8)
            .opacity(animateIn ? 1 : 0)

            // A bright opening flash that quickly fades — the "pop" as the celebration lands.
            if celebrationEffects {
                Rectangle()
                    .fill(.white)
                    .ignoresSafeArea()
                    .opacity(flash ? 0 : 0.65)
                    .animation(.easeOut(duration: 0.65), value: flash)
                    .allowsHitTesting(false)
            }
        }
        .onAppear {
            withAnimation(.spring(response: 0.6, dampingFraction: 0.7)) { animateIn = true }
            rotate = true
            pulse = true
            flash = true
            WinHaptics.shared.play(skunk: skunk)
            if celebrationEffects { GameFeedback.shared.playCelebration() }
        }
    }

    @ViewBuilder
    private var iconView: some View {
        switch skunk {
        case .none:
            Image(systemName: "crown.fill")
                .font(.system(size: 96, weight: .black))
                .foregroundStyle(
                    LinearGradient(
                        colors: [.cribGold, Color(red: 0.85, green: 0.65, blue: 0.20)],
                        startPoint: .top, endPoint: .bottom
                    )
                )
                .shadow(color: .black.opacity(0.4), radius: 8, y: 4)
                .rotationEffect(.degrees(rotate ? 6 : -6))
                .animation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true), value: rotate)
        case .single:
            Text(loserChar)
                .font(.system(size: 132))
                .shadow(color: .black.opacity(0.55), radius: 14, y: 6)
                .rotationEffect(.degrees(rotate ? 10 : -10))
                .animation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true), value: rotate)
        case .double:
            HStack(spacing: -18) {
                Text(loserChar)
                    .font(.system(size: 110))
                    .shadow(color: .black.opacity(0.55), radius: 12, y: 6)
                    .rotationEffect(.degrees(rotate ? -18 : -8))
                    .animation(.easeInOut(duration: 1.3).repeatForever(autoreverses: true), value: rotate)
                Text(loserChar)
                    .font(.system(size: 110))
                    .shadow(color: .black.opacity(0.55), radius: 12, y: 6)
                    .rotationEffect(.degrees(rotate ? 18 : 8))
                    .animation(.easeInOut(duration: 1.3).repeatForever(autoreverses: true), value: rotate)
            }
        }
    }
}

// MARK: - Fireworks (extra celebration; toggleable in Settings)

/// Continuous bursts of particles that shoot outward from random points, arc down, and fade —
/// layered behind the win card for a bigger celebration. Pure SwiftUI Canvas, no assets.
struct FireworksView: View {
    let colors: [Color]

    @State private var start = Date()

    private struct Burst {
        let cx: CGFloat, cy: CGFloat   // 0…1 position
        let t0: Double                 // start offset within the cycle
        let color: Color
        let count: Int
        let phase: Double              // angle offset so bursts don't align
    }
    private let bursts: [Burst]
    private let cycle: Double = 6.5
    private let life: Double = 1.6

    init(colors: [Color]) {
        self.colors = colors
        var arr: [Burst] = []
        for _ in 0..<34 {
            arr.append(Burst(
                cx: CGFloat.random(in: 0.08...0.92),
                cy: CGFloat.random(in: 0.08...0.68),
                t0: Double.random(in: 0...(cycle - life)),
                color: colors.randomElement() ?? .white,
                count: Int.random(in: 22...36),
                phase: Double.random(in: 0...(.pi * 2))
            ))
        }
        bursts = arr
    }

    var body: some View {
        TimelineView(.animation) { tl in
            let elapsed = tl.date.timeIntervalSince(start).truncatingRemainder(dividingBy: cycle)
            Canvas { ctx, size in
                for b in bursts {
                    let age = elapsed - b.t0
                    guard age >= 0, age < life else { continue }
                    let prog = age / life
                    let alpha = 1.0 - prog
                    let center = CGPoint(x: b.cx * size.width, y: b.cy * size.height)
                    for k in 0..<b.count {
                        let a = Double(k) / Double(b.count) * .pi * 2 + b.phase
                        let speed = 155.0 + Double(k % 3) * 34.0
                        let dist = speed * age
                        let gravity = 175.0 * age * age
                        let x = center.x + CGFloat(cos(a) * dist)
                        let y = center.y + CGFloat(sin(a) * dist + gravity)
                        let r = 4.5 * alpha + 1.0
                        ctx.fill(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)),
                                 with: .color(b.color.opacity(alpha)))
                    }
                }
            }
        }
        .allowsHitTesting(false)
        .ignoresSafeArea()
        .blendMode(.plusLighter)
    }
}

// MARK: - Confetti (reused from Criboard)

struct ConfettiPiece: Identifiable {
    let id = UUID()
    let color: Color
    let startX: CGFloat
    let endX: CGFloat
    let startRotation: Double
    let endRotation: Double
    let size: CGFloat
    let duration: Double
    let delay: Double
    let shape: Int  // 0 = rect, 1 = circle, 2 = capsule
}

struct ConfettiBurst: View {
    let colors: [Color]
    @State private var animate = false

    private let pieces: [ConfettiPiece]

    init(colors: [Color]) {
        self.colors = colors
        var arr: [ConfettiPiece] = []
        for _ in 0..<120 {
            arr.append(
                ConfettiPiece(
                    color: colors.randomElement() ?? .white,
                    startX: CGFloat.random(in: 0.2...0.8),
                    endX: CGFloat.random(in: 0.0...1.0),
                    startRotation: Double.random(in: 0...360),
                    endRotation: Double.random(in: 360...720),
                    size: CGFloat.random(in: 6...14),
                    duration: Double.random(in: 2.5...4.5),
                    delay: Double.random(in: 0...0.6),
                    shape: Int.random(in: 0...2)
                )
            )
        }
        self.pieces = arr
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                ForEach(pieces) { p in
                    confettiPiece(p)
                        .frame(width: p.size, height: p.size * (p.shape == 0 ? 0.55 : 1.0))
                        .rotationEffect(.degrees(animate ? p.endRotation : p.startRotation))
                        .position(
                            x: (animate ? p.endX : p.startX) * geo.size.width,
                            y: animate ? geo.size.height + 40 : -40
                        )
                        .opacity(animate ? 0 : 1)
                        .animation(.easeIn(duration: p.duration).delay(p.delay), value: animate)
                }
            }
        }
        .allowsHitTesting(false)
        .onAppear { animate = true }
    }

    @ViewBuilder
    private func confettiPiece(_ p: ConfettiPiece) -> some View {
        switch p.shape {
        case 0: Rectangle().fill(p.color)
        case 1: Circle().fill(p.color)
        default: Capsule().fill(p.color)
        }
    }
}
