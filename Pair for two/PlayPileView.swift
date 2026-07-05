import SwiftUI

/// The shared table centre during pegging: the cut card set off to the side (it counts for everyone's
/// hands but is never played during the pegging), the running count, the sequence of played cards
/// (visible to both players), and a face-down crib indicator.
struct PlayPileView: View {
    let snapshot: PlayerSnapshot
    var vm: GameViewModel
    var cardWidth: CGFloat = 60

    var body: some View {
        HStack(alignment: .top, spacing: cardWidth * 0.4) {
            cutStack
            Rectangle()                       // divider making clear the cut isn't part of the play
                .fill(Color.white.opacity(0.15))
                .frame(width: 1, height: cardWidth * 1.35)
            playedStack
            cribStack
        }
    }

    // MARK: The cut card (off to the side — counts for hands, but isn't played)

    private var cutStack: some View {
        VStack(spacing: 6) {
            Text("The Cut").font(.caption2.weight(.semibold)).foregroundStyle(Color.cribGold)
            if let cut = snapshot.starter {
                CardView(card: cut, width: cardWidth)
            } else {
                CardView(card: nil, faceUp: false, width: cardWidth)
            }
        }
    }

    // MARK: Played cards + running count

    private var playedStack: some View {
        VStack(spacing: 6) {
            Text("Count \(snapshot.runningCount)")
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 10).padding(.vertical, 3)
                .background(Capsule().fill(Color.black.opacity(0.35)))

            if snapshot.playSequence.isEmpty {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5]))
                    .foregroundStyle(.white.opacity(0.25))
                    .frame(width: cardWidth * 2.2, height: cardWidth * 1.45)
                    .overlay(Text("Play area").font(.caption2).foregroundStyle(.white.opacity(0.4)))
            } else {
                HStack(spacing: -cardWidth * 0.55) {
                    ForEach(snapshot.playSequence) { pc in
                        CardView(card: pc.card,
                                 isHighlighted: pc == snapshot.playSequence.last,
                                 width: cardWidth)
                            .overlay(alignment: .bottom) {
                                Circle()
                                    .fill(vm.theme(for: pc.player).primary)
                                    .frame(width: cardWidth * 0.18, height: cardWidth * 0.18)
                                    .offset(y: cardWidth * 0.12)
                            }
                    }
                }
            }
        }
    }

    // MARK: Crib

    private var cribStack: some View {
        VStack(spacing: 6) {
            Text("Crib").font(.caption2.weight(.semibold)).foregroundStyle(Color.cribGold)
            ZStack {
                if let crib = snapshot.crib {          // revealed at the show
                    HStack(spacing: -cardWidth * 0.6) {
                        ForEach(crib) { CardView(card: $0, width: cardWidth) }
                    }
                } else {
                    ForEach(0..<max(snapshot.cribCount, 1), id: \.self) { i in
                        CardView(card: nil, faceUp: false, width: cardWidth)
                            .offset(x: CGFloat(i) * 3, y: CGFloat(i) * 3)
                    }
                }
            }
            .opacity(snapshot.cribCount == 0 && snapshot.crib == nil ? 0.3 : 1)
        }
    }
}
