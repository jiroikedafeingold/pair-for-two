import SwiftUI

/// Horizontal row of coach "flag chips" — every scoring opportunity the engine detected for the
/// current context. Flag-only: they inform, they never auto-apply. Tap a chip to read its detail;
/// the player still enters the points manually on their `ScorePanel` slider.
struct ScoreFlagsView: View {
    let flags: [ScoreFlag]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(flags) { flag in
                    HStack(spacing: 4) {
                        Text(flag.detail)
                        if flag.points > 0 {
                            Text("+\(flag.points)").fontWeight(.heavy)
                        }
                    }
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(Color.cribGold))
                    .foregroundStyle(Color.black.opacity(0.82))
                }
            }
            .padding(.horizontal, 2)
        }
        .frame(height: flags.isEmpty ? 0 : 30)
        .opacity(flags.isEmpty ? 0 : 1)
    }
}
