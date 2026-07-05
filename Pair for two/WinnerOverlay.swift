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
    let onPlayAgain: () -> Void

    @State private var animateIn = false
    @State private var rotate = false
    @State private var pulse = false
    @State private var faceAngle: Double = 0

    // The phone is always landscape and shared between the two players (P1 bottom, P2 top).
    private var winnerAngle: Double { winner == .one ? 0 : 180 }
    private var loserAngle: Double { winner == .one ? 180 : 0 }
    private var winnerColor: Color { winnerTheme.primary }

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

            ConfettiBurst(colors: skunk == .none ? [winnerColor, .cribGold, .white] : skunk.accentColors)
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
            .rotationEffect(.degrees(faceAngle))
            .animation(.easeInOut(duration: 0.85), value: faceAngle)
        }
        .onAppear {
            faceAngle = winnerAngle
            withAnimation(.spring(response: 0.6, dampingFraction: 0.7)) { animateIn = true }
            rotate = true
            pulse = true
            WinHaptics.shared.play(skunk: skunk)
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                faceAngle = (faceAngle == winnerAngle) ? loserAngle : winnerAngle
            }
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
        for _ in 0..<70 {
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
