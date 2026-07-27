import SwiftUI

/// The current player's hand as a centered row. During discard it selects up to two cards; during
/// pegging it plays a card, dimming illegal (would-exceed-31) plays.
struct HandView: View {
    let cards: [Card]
    var selected: Set<Card> = []
    /// Returns whether a card is currently a legal tap (used to dim illegal pegging plays).
    var isEnabled: (Card) -> Bool = { _ in true }
    var onTap: (Card) -> Void
    var cardWidth: CGFloat = 74
    /// When set, the cards deal in one-by-one (dropping from above) whenever this value changes —
    /// used for a fresh deal. Left nil during pegging so cards don't re-animate on every play.
    var dealSignal: AnyHashable? = nil

    @State private var revealed = 0

    var body: some View {
        HStack(spacing: cardWidth * 0.18) {
            ForEach(Array(cards.enumerated()), id: \.element.id) { idx, card in
                let shown = dealSignal == nil || idx < revealed
                CardView(card: card,
                         isSelected: selected.contains(card),
                         isDimmed: !isEnabled(card),
                         width: cardWidth)
                    .opacity(shown ? 1 : 0)
                    .scaleEffect(shown ? 1 : 0.5, anchor: .top)
                    .offset(y: shown ? 0 : -80)
                    .rotationEffect(.degrees(shown ? 0 : (idx.isMultiple(of: 2) ? -12 : 12)))
                    .animation(.spring(response: 0.4, dampingFraction: 0.72), value: revealed)
                    .onTapGesture { if shown { onTap(card) } }
                    .allowsHitTesting(shown && (isEnabled(card) || selected.contains(card)))
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: cards)
        .task(id: dealSignal) {
            guard dealSignal != nil else { return }
            revealed = 0
            try? await Task.sleep(for: .milliseconds(140))
            for i in 1...max(cards.count, 1) {
                revealed = i
                try? await Task.sleep(for: .milliseconds(105))
            }
        }
    }
}

#Preview {
    HandView(cards: [
        Card(rank: .ace, suit: .spades),
        Card(rank: .five, suit: .hearts),
        Card(rank: .jack, suit: .clubs),
        Card(rank: .ten, suit: .diamonds),
    ], selected: [Card(rank: .five, suit: .hearts)], onTap: { _ in })
    .padding()
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color.feltMid)
}
