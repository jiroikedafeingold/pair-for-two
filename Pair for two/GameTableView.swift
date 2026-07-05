import SwiftUI

/// The root game screen. Landscape: top ~1/3 is the scoreboard + coach banner + flag chips + manual
/// scoring; bottom ~2/3 is the shared play area and the current player's hand. Card sizes scale off
/// the geometry, so the same layout simply grows on iPad — no device checks.
struct GameTableView: View {
    @State var vm: GameViewModel

    var body: some View {
        GeometryReader { geo in
            let s = vm.snapshot
            let handWidth = min(geo.size.width * 0.105, geo.size.height * 0.30)
            let pileWidth = handWidth * 0.8
            // Cap the scoreboard band so it doesn't leave a tall dead zone on iPad; the play area
            // takes the rest, giving the cards more room on bigger screens.
            let topBandHeight = min(geo.size.height * 0.34, 210)

            VStack(spacing: 0) {
                topBand(s)
                    .frame(height: topBandHeight)
                    .frame(maxWidth: .infinity)
                    .background(Color.black.opacity(0.22))

                bottomBand(s, handWidth: handWidth, pileWidth: pileWidth)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(felt)
            .overlay(alignment: .top) { connectionBanner }
            .overlay { if s.phase == .gameOver { winnerOverlay(s) } }
        }
        .ignoresSafeArea(.container, edges: .bottom)
    }

    // MARK: Connection banner (non-blocking)

    @ViewBuilder private var connectionBanner: some View {
        if vm.connection == .reconnecting || vm.connection == .disconnected {
            HStack(spacing: 8) {
                ProgressView().tint(.white)
                Text(vm.connection == .reconnecting ? "Reconnecting…" : "Disconnected")
                    .font(.caption.weight(.semibold)).foregroundStyle(.white)
            }
            .padding(.horizontal, 14).padding(.vertical, 7)
            .background(Capsule().fill(Color.black.opacity(0.7)))
            .padding(.top, 6)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    // MARK: Background

    private var felt: some View {
        LinearGradient(colors: [.feltMid, .feltDark],
                       startPoint: .top, endPoint: .bottom)
            .ignoresSafeArea()
    }

    // MARK: Top band

    @ViewBuilder private func topBand(_ s: PlayerSnapshot) -> some View {
        VStack(spacing: 10) {
            Text(vm.coachBanner)
                .font(.headline.weight(.bold))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.7)
                .lineLimit(1)

            ScoreFlagsView(flags: s.flags)
                .padding(.horizontal, 16)

            // A slider panel per peg this device may score: both for pass-and-play, just the local
            // player's when networked. Constrain the width so a single panel doesn't stretch across
            // a wide iPad.
            HStack(spacing: 12) {
                ForEach(vm.scorablePlayers, id: \.self) { player in
                    scorePanel(for: player, s: s)
                }
            }
            .frame(maxWidth: 900)
            .padding(.horizontal, 12)
        }
        .frame(maxHeight: .infinity)   // center vertically within the capped band
        .padding(.vertical, 8)
    }

    @ViewBuilder private func scorePanel(for player: PlayerID, s: PlayerSnapshot) -> some View {
        let theme = vm.theme(for: player)
        ScorePanel(
            name: vm.name(of: player),
            score: vm.score(of: player),
            opponentScore: vm.score(of: player.opponent),
            primary: theme.primary,
            deep: theme.deep,
            disabled: s.phase == .gameOver,
            canUndo: vm.canUndo(for: player),
            onAdd: { vm.claim($0, for: player) },
            onPlusOne: { vm.claim(1, for: player) },
            onUndo: { vm.undo(for: player) }
        )
    }

    // MARK: Bottom band

    @ViewBuilder private func bottomBand(_ s: PlayerSnapshot, handWidth: CGFloat, pileWidth: CGFloat) -> some View {
        VStack(spacing: 12) {
            switch s.phase {
            case .cutForDeal:
                cutArea(s, title: "Tap to cut for deal", width: handWidth) { vm.cut() }
            case .discardToCrib:
                discardArea(s, width: handWidth)
            case .cutStarter:
                cutArea(s, title: "Tap to cut the starter", width: handWidth) { vm.cut() }
            case .pegging:
                peggingArea(s, handWidth: handWidth, pileWidth: pileWidth)
            case .showPone, .showDealer:
                showArea(s, cards: s.yourHand, width: handWidth, pileWidth: pileWidth,
                         label: s.phase == .showPone ? "Pone's hand" : "Dealer's hand")
            case .showCrib:
                showArea(s, cards: s.crib ?? [], width: handWidth, pileWidth: pileWidth, label: "The crib")
            case .handComplete:
                handCompleteArea(s)
            default:
                Color.clear
            }
        }
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Cut areas (deal + starter)

    @ViewBuilder private func cutArea(_ s: PlayerSnapshot, title: String, width: CGFloat, action: @escaping () -> Void) -> some View {
        // Single centered row so nothing spills off the bottom: P1 result · deck · P2 result.
        HStack(spacing: 28) {
            cutResult(for: .one, s: s, width: width * 0.7)
            Button(action: action) {
                VStack(spacing: 8) {
                    CardView(card: nil, faceUp: false, width: width * 0.9)
                    Text(title).font(.callout.weight(.semibold)).foregroundStyle(.white)
                }
            }
            .buttonStyle(.plain)
            cutResult(for: .two, s: s, width: width * 0.7)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private func cutResult(for player: PlayerID, s: PlayerSnapshot, width: CGFloat) -> some View {
        VStack(spacing: 4) {
            Text(vm.name(of: player)).font(.caption).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
            if let card = s.cutForDeal[player] {
                CardView(card: card, width: width)
            } else {
                CardView(card: nil, faceUp: false, width: width)
                    .opacity(0.35)
            }
        }
        .frame(width: width + 12)
    }

    // MARK: Discard

    @ViewBuilder private func discardArea(_ s: PlayerSnapshot, width: CGFloat) -> some View {
        VStack(spacing: 16) {
            Spacer(minLength: 0)
            HandView(cards: s.yourHand,
                     selected: vm.selectedForDiscard,
                     onTap: { vm.toggleDiscard($0) },
                     cardWidth: width)
            Button("Send 2 to \(s.yourSeat == .dealer ? "your crib" : "the crib")") {
                vm.confirmDiscard()
            }
            .buttonStyle(.borderedProminent)
            .tint(vm.theme(for: s.you).deep)
            .disabled(!vm.canConfirmDiscard)
            Spacer(minLength: 0)
        }
    }

    // MARK: Pegging

    @ViewBuilder private func peggingArea(_ s: PlayerSnapshot, handWidth: CGFloat, pileWidth: CGFloat) -> some View {
        VStack(spacing: 14) {
            PlayPileView(snapshot: s, vm: vm, cardWidth: pileWidth)
                .frame(maxHeight: .infinity)
            HStack(spacing: 16) {
                HandView(cards: s.yourHand,
                         isEnabled: { vm.isLegalPlay($0) },
                         onTap: { vm.play($0) },
                         cardWidth: handWidth)
                if vm.canSayGo {
                    Button("Go") { vm.sayGo() }
                        .buttonStyle(.borderedProminent)
                        .tint(.orange)
                        .controlSize(.large)
                }
            }
        }
    }

    // MARK: Show

    @ViewBuilder private func showArea(_ s: PlayerSnapshot, cards: [Card], width: CGFloat, pileWidth: CGFloat, label: String) -> some View {
        VStack(spacing: 12) {
            HStack(alignment: .top, spacing: 24) {
                VStack(spacing: 4) {
                    Text("Starter").font(.caption2).foregroundStyle(.white.opacity(0.7))
                    if let starter = s.starter { CardView(card: starter, width: pileWidth) }
                }
                VStack(spacing: 4) {
                    Text(label).font(.caption2).foregroundStyle(.white.opacity(0.7))
                    HStack(spacing: 8) {
                        ForEach(cards) { CardView(card: $0, width: pileWidth) }
                    }
                }
            }
            .frame(maxHeight: .infinity)
            Text("True count: \(s.flags.totalPoints) — claim it above, then Continue")
                .font(.caption).foregroundStyle(.white.opacity(0.7))
            Button("Continue") { vm.advance() }
                .buttonStyle(.borderedProminent).tint(.cribGold).foregroundStyle(.black)
        }
    }

    // MARK: Hand complete

    @ViewBuilder private func handCompleteArea(_ s: PlayerSnapshot) -> some View {
        VStack(spacing: 16) {
            Spacer()
            Text("Hand complete").font(.title3.weight(.bold)).foregroundStyle(.white)
            Text("\(s.yourName) \(s.yourScore)  •  \(s.opponentName) \(s.opponentScore)")
                .font(.headline).foregroundStyle(.white.opacity(0.85))
            Button("Deal next hand") { vm.advance() }
                .buttonStyle(.borderedProminent).tint(.cribGold).foregroundStyle(.black)
            Spacer()
        }
    }

    // MARK: Winner overlay (Criboard's confetti + skunk celebration)

    @ViewBuilder private func winnerOverlay(_ s: PlayerSnapshot) -> some View {
        if let info = vm.winnerInfo {
            WinnerOverlay(
                winner: info.winner,
                skunk: info.skunk,
                winnerTheme: vm.theme(for: info.winner),
                winnerName: vm.name(of: info.winner),
                onPlayAgain: { vm.playAgain() }
            )
        }
    }
}

// MARK: - Preview

private struct GameTablePreview: View {
    @State private var vm: GameViewModel = {
        let vm = GameViewModel.loopback(names: [.one: "Ann", .two: "Ben"], colorIDs: [.one: 1, .two: 7])
        vm.cut(); vm.cut()   // advance past cut-for-deal into a dealt hand
        return vm
    }()
    var body: some View { GameTableView(vm: vm) }
}

#Preview(traits: .landscapeLeft) {
    GameTablePreview()
}
