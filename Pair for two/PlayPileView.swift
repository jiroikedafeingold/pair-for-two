import SwiftUI

/// The shared table centre during pegging: the cut card set off to the side (it counts for everyone's
/// hands but is never played during the pegging), the running count, the sequence of played cards
/// (visible to both players), and a face-down crib indicator.
struct PlayPileView: View {
    let snapshot: PlayerSnapshot
    var vm: GameViewModel
    var cardWidth: CGFloat = 60

    var body: some View {
        HStack(alignment: .top, spacing: cardWidth * 0.5) {
            cutStack      // labelled "The Cut" + the extra spacing keeps it clearly apart from the play
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
            // Running count lives here (frees vertical space above the play area for bigger cards).
            Text("Count \(snapshot.runningCount)")
                .font(.caption.weight(.bold)).monospacedDigit()
                .foregroundStyle(.white)
                .lineLimit(1).fixedSize()
                .padding(.horizontal, 10).padding(.vertical, 2)
                .background(Capsule().fill(Color.black.opacity(0.4)))

            if snapshot.playSequence.isEmpty {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5]))
                    .foregroundStyle(.white.opacity(0.25))
                    .frame(width: cardWidth * 2.2, height: cardWidth * 1.45)
                    .overlay(Text("Play area").font(.caption2).foregroundStyle(.white.opacity(0.4)))
            } else {
                // Cards from finished laps (count reset via a go or 31) stay full-strength on the table;
                // a vertical divider separates them from the current lap so it's clear what's still in
                // play, without greying anything out.
                let firstActive = snapshot.playSequence.count - snapshot.lapCardCount
                HStack(spacing: 8) {
                    if firstActive > 0 && snapshot.lapCardCount > 0 {
                        laneRow(Array(snapshot.playSequence.prefix(firstActive)))
                        lapDivider
                        laneRow(Array(snapshot.playSequence.suffix(snapshot.lapCardCount)))
                    } else {
                        laneRow(snapshot.playSequence)
                    }
                }
            }
        }
    }

    /// A run of played cards (overlapping fan), each with a colour bar showing who played it.
    private func laneRow(_ cards: [PlayedCard]) -> some View {
        HStack(spacing: -cardWidth * 0.55) {
            ForEach(cards) { pc in
                CardView(card: pc.card,
                         isHighlighted: pc == snapshot.playSequence.last,
                         width: cardWidth)
                    .overlay(alignment: .bottom) {
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(vm.theme(for: pc.player).primary)
                            .frame(height: max(3, cardWidth * 0.07))
                            .padding(.horizontal, cardWidth * 0.12)
                            .padding(.bottom, cardWidth * 0.05)
                    }
            }
        }
    }

    /// The line delineating finished laps from the current one.
    private var lapDivider: some View {
        RoundedRectangle(cornerRadius: 1, style: .continuous)
            .fill(Color.cribGold.opacity(0.55))
            .frame(width: 2, height: cardWidth * 1.35)
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
