import SwiftUI

extension ScoreFlag {
    /// The chip's wording, localized.
    ///
    /// `detail` is deliberately English on the wire (the host computes it and both devices may be
    /// running different languages), so it doubles as the localization key: every string the scorer
    /// can produce has an entry in the catalog, and anything unrecognized falls back to the English
    /// it arrived as. That also means each device shows the flags in *its own* language.
    var localizedDetail: LocalizedStringKey { LocalizedStringKey(detail) }
}

/// Horizontal row of coach "flag chips" — every scoring opportunity the engine detected for the
/// current context. Flag-only: they inform, they never auto-apply. The chips are tinted in the
/// scoring player's color and led by their name, so it's clear whose points these are.
struct ScoreFlagsView: View {
    let flags: [ScoreFlag]
    var accent: Color = .cribGold
    var playerName: String? = nil
    /// Lay the chips out in a column (for the narrow action rail) instead of a horizontal row.
    var vertical: Bool = false

    /// The column in the action rail shares its height with the prompt and buttons, so its chips are a
    /// size down and tighter than the row layout's — that keeps a hand's chips *and* its total visible
    /// in a short slot, instead of the total being pushed out of sight.
    private var chipFont: Font { vertical ? .caption2.weight(.semibold) : .caption.weight(.semibold) }
    private var totalFont: Font { vertical ? .caption2.weight(.heavy) : .caption.weight(.heavy) }
    private var chipHPad: CGFloat { vertical ? 8 : 10 }
    private var chipVPad: CGFloat { vertical ? 4 : 5 }

    var body: some View {
        if vertical {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 4) { chips }
                    .frame(maxWidth: .infinity)
            }
            .opacity(flags.isEmpty ? 0 : 1)
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) { chips }
                    .padding(.horizontal, 2)
            }
            .frame(height: flags.isEmpty ? 0 : 30)
            .opacity(flags.isEmpty ? 0 : 1)
        }
    }

    @ViewBuilder private var chips: some View {
        if let playerName, !flags.isEmpty {
            Text(verbatim: playerName.uppercased())
                .font(.caption.weight(.heavy))
                .foregroundStyle(accent)
                .lineLimit(1).minimumScaleFactor(0.7)
        }

        ForEach(flags) { flag in
            HStack(spacing: 4) {
                Text(flag.localizedDetail)
                if flag.points > 0 {
                    Text(verbatim: "+\(flag.points)").fontWeight(.heavy)
                }
            }
            .font(chipFont)
            .lineLimit(1).minimumScaleFactor(0.75)
            .padding(.horizontal, chipHPad)
            .padding(.vertical, chipVPad)
            .background(Capsule().fill(accent))
            .foregroundStyle(.black.opacity(0.85))
        }

        // Running total of the detected points.
        if flags.count > 1 {
            Text(verbatim: "= \(flags.totalPoints)")
                .font(totalFont)
                .padding(.horizontal, 12)
                .padding(.vertical, chipVPad)
                .background(Capsule().fill(.white))
                .foregroundStyle(.black)
        }
    }
}
