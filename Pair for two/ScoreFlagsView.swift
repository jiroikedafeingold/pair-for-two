import SwiftUI

/// Horizontal row of coach "flag chips" — every scoring opportunity the engine detected for the
/// current context. Flag-only: they inform, they never auto-apply. The chips are tinted in the
/// scoring player's colour and led by their name, so it's clear whose points these are.
struct ScoreFlagsView: View {
    let flags: [ScoreFlag]
    var accent: Color = .cribGold
    var playerName: String? = nil

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                if let playerName, !flags.isEmpty {
                    Text(playerName.uppercased())
                        .font(.caption.weight(.heavy))
                        .foregroundStyle(accent)
                        .padding(.trailing, 2)
                }

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
                    .background(Capsule().fill(accent))
                    .foregroundStyle(.black.opacity(0.85))
                }

                // Running total of the detected points.
                if flags.count > 1 {
                    Text("= \(flags.totalPoints)")
                        .font(.caption.weight(.heavy))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(.white))
                        .foregroundStyle(.black)
                }
            }
            .padding(.horizontal, 2)
        }
        .frame(height: flags.isEmpty ? 0 : 30)
        .opacity(flags.isEmpty ? 0 : 1)
    }
}
