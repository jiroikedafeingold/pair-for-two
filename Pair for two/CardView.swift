import SwiftUI

/// A classy, easy-to-read playing card: cream face, continuous rounded corners, hairline inner
/// border, soft shadow; rounded-serif rank+suit in opposite corners and a large centre suit glyph.
/// Pass `card == nil` (or `faceUp == false`) for an elegant face-down back.
struct CardView: View {
    let card: Card?
    var faceUp: Bool = true
    var isSelected: Bool = false
    var isDimmed: Bool = false
    var isHighlighted: Bool = false
    var width: CGFloat = 72

    private var height: CGFloat { width * 1.45 }
    private var corner: CGFloat { width * 0.13 }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .fill(faceUp ? Color.cardFace : Color.cardBack)

            if faceUp, let card {
                face(for: card)
            } else {
                back
            }

            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .strokeBorder(Color.black.opacity(faceUp ? 0.12 : 0.0), lineWidth: 0.75)
        }
        .frame(width: width, height: height)
        .overlay(
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .strokeBorder(Color.cribGold, lineWidth: isHighlighted ? 3 : 0)
        )
        .shadow(color: .black.opacity(0.35), radius: width * 0.06, x: 0, y: width * 0.04)
        .opacity(isDimmed ? 0.4 : 1)
        .offset(y: isSelected ? -width * 0.22 : 0)
        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: isSelected)
        .accessibilityElement()
        .accessibilityLabel(faceUp ? (card?.accessibleName ?? "Card") : "Face-down card")
    }

    // MARK: Face

    private func face(for card: Card) -> some View {
        let ink = card.suit.isRed ? Color.cardRed : Color.cardInk
        return ZStack {
            VStack(alignment: .leading, spacing: -width * 0.04) {
                Text(card.rank.label)
                    .font(.system(size: width * 0.30, weight: .bold, design: .serif))
                Text(card.suit.symbol)
                    .font(.system(size: width * 0.24, weight: .semibold))
            }
            .foregroundStyle(ink)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(width * 0.10)

            Text(card.suit.symbol)
                .font(.system(size: width * 0.52))
                .foregroundStyle(ink.opacity(0.92))

            VStack(alignment: .trailing, spacing: -width * 0.04) {
                Text(card.rank.label)
                    .font(.system(size: width * 0.30, weight: .bold, design: .serif))
                Text(card.suit.symbol)
                    .font(.system(size: width * 0.24, weight: .semibold))
            }
            .foregroundStyle(ink)
            .rotationEffect(.degrees(180))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            .padding(width * 0.10)
        }
    }

    // MARK: Back

    private var back: some View {
        RoundedRectangle(cornerRadius: corner * 0.7, style: .continuous)
            .strokeBorder(Color.white.opacity(0.35), lineWidth: 1.5)
            .background(
                RoundedRectangle(cornerRadius: corner * 0.7, style: .continuous)
                    .fill(Color.white.opacity(0.06))
            )
            .padding(width * 0.12)
            .overlay(
                Image(systemName: "suit.spade.fill")
                    .font(.system(size: width * 0.34))
                    .foregroundStyle(Color.white.opacity(0.22))
            )
    }
}

#Preview {
    HStack(spacing: 12) {
        CardView(card: Card(rank: .seven, suit: .hearts))
        CardView(card: Card(rank: .king, suit: .spades), isSelected: true)
        CardView(card: Card(rank: .ten, suit: .diamonds), isHighlighted: true)
        CardView(card: nil, faceUp: false)
    }
    .padding()
    .background(Color.feltDark)
}
