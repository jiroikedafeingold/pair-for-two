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

    var body: some View {
        HStack(spacing: cardWidth * 0.18) {
            ForEach(cards) { card in
                CardView(card: card,
                         isSelected: selected.contains(card),
                         isDimmed: !isEnabled(card),
                         width: cardWidth)
                    .onTapGesture { onTap(card) }
                    .allowsHitTesting(isEnabled(card) || selected.contains(card))
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: cards)
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
