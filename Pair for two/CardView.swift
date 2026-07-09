import SwiftUI

/// A classy, easy-to-read playing card: cream face, continuous rounded corners, hairline inner
/// border, soft shadow; heavy rounded rank+suit in opposite corners and a large centre suit glyph.
/// Pass `card == nil` (or `faceUp == false`) for an elegant face-down back.
struct CardView: View {
    let card: Card?
    var faceUp: Bool = true
    var isSelected: Bool = false
    var isDimmed: Bool = false
    var isHighlighted: Bool = false
    var width: CGFloat = 72

    /// The user's chosen face-down back design (shared setting).
    @AppStorage("cardBackID") private var cardBackID = 0

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

            // Thin dark inner edge so the gold rim reads cleanly against the cream face.
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .strokeBorder(Color.black.opacity(0.15), lineWidth: 0.75)
        }
        .frame(width: width, height: height)
        // Gold rim on every card so it stands out from the felt (and adjacent cards); brighter/thicker
        // when highlighted (the most-recent play, the winning cut, etc.).
        .overlay(
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .strokeBorder(Color.cribGold.opacity(isHighlighted ? 1 : 0.85),
                              lineWidth: isHighlighted ? 3 : 1.5)
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
            cornerIndex(for: card, ink: ink)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(width * 0.09)

            // Centre pip. Sized to sit clearly inside the middle so it never collides with the corner
            // indices — especially the wider two-character "10".
            Text(card.suit.symbol)
                .font(.system(size: width * 0.44))
                .foregroundStyle(ink.opacity(0.92))

            cornerIndex(for: card, ink: ink)
                .rotationEffect(.degrees(180))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .padding(width * 0.09)
        }
    }

    /// The rank-over-suit corner index. A heavy rounded face keeps every rank — especially the
    /// letters A/J/Q/K — crisp and unambiguous at small sizes (the serif "J" read poorly). `lineLimit`
    /// / `fixedSize` keep the two-character "10" on one line; a slight negative kerning keeps it compact
    /// so it doesn't creep toward the centre pip.
    private func cornerIndex(for card: Card, ink: Color) -> some View {
        VStack(alignment: .leading, spacing: -width * 0.02) {
            Text(card.rank.label)
                .font(.system(size: width * 0.30, weight: .heavy, design: .rounded))
                .kerning(-width * 0.012)
                .lineLimit(1)
                .fixedSize()
            Text(card.suit.symbol)
                .font(.system(size: width * 0.22, weight: .bold))
        }
        .foregroundStyle(ink)
    }

    // MARK: Back

    /// Shows the whole back design (`scaledToFit`) so none of the art is cropped, over a soft blurred
    /// copy that fills the side margins (the designs are taller than the card, so a fit leaves gaps).
    private var back: some View {
        let asset = CardBack.from(cardBackID).assetName
        return ZStack {
            Image(asset)
                .resizable()
                .scaledToFill()
                .blur(radius: width * 0.06)
            Image(asset)
                .resizable()
                .scaledToFit()
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
    }
}

#Preview {
    HStack(spacing: 10) {
        CardView(card: Card(rank: .jack, suit: .spades))
        CardView(card: Card(rank: .jack, suit: .hearts))
        CardView(card: Card(rank: .queen, suit: .clubs), isSelected: true)
        CardView(card: Card(rank: .king, suit: .spades))
        CardView(card: Card(rank: .ten, suit: .diamonds), isHighlighted: true)
        CardView(card: nil, faceUp: false)
    }
    .padding()
    .background(Color.feltDark)
}
