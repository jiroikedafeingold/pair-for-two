import SwiftUI

/// The root game screen. Landscape: top ~1/3 is the scoreboard + coach banner + flag chips + manual
/// scoring; bottom ~2/3 is the shared play area and the current player's hand. Card sizes scale off
/// the geometry, so the same layout simply grows on iPad — no device checks.
struct GameTableView: View {
    @State var vm: GameViewModel
    @State private var showingSettings = false
    @AppStorage("confirmRelease") private var confirmRelease = false
    @AppStorage("confirmPlus") private var confirmPlus = false
    @AppStorage("localName") private var localName = "Player"
    @AppStorage("localColorID") private var localColorID = 1

    var body: some View {
        GeometryReader { geo in
            let s = vm.snapshot
            // Cap the scoreboard band so it doesn't leave a tall dead zone on iPad; the play area
            // takes the rest, giving the cards more room on bigger screens.
            let topBandHeight = min(geo.size.height * 0.34, 210)
            let playHeight = geo.size.height - topBandHeight
            // Discard shows a full 6-card hand and nothing else, so those cards can be large (fill the
            // width, leave room for one button). Pegging must stack a pile ABOVE the hand, so its cards
            // are clamped to the shorter vertical budget. Show cards sit in a single row.
            let handWidth = min((geo.size.width - 40) / 7.0, (playHeight - 60) / 1.55)
            let peggingHandWidth = min(handWidth, (playHeight - 64) / 2.25)
            let pileWidth = peggingHandWidth * 0.5
            let showWidth = handWidth * 0.72
            // Cut-for-deal stacks two cards vertically, so size them to the band height to avoid spill.
            let cutWidth = min(handWidth * 0.6, playHeight * 0.24)

            VStack(spacing: 0) {
                topBand(s)
                    .frame(height: topBandHeight)
                    .frame(maxWidth: .infinity)
                    .background(Color.black.opacity(0.22))

                bottomBand(s, handWidth: handWidth, peggingHandWidth: peggingHandWidth,
                           pileWidth: pileWidth, showWidth: showWidth, cutWidth: cutWidth)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(felt)
            .overlay(alignment: .top) { connectionBanner }
            .overlay(alignment: .topTrailing) { settingsButton }
            .overlay { if s.phase == .gameOver { winnerOverlay(s) } }
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView(onDone: { showingSettings = false })
        }
        // Push name/colour changes into the running game when Settings closes, so the highlight,
        // slider and score colours update live (for this device and the opponent).
        .onChange(of: showingSettings) { _, isShowing in
            if !isShowing {
                vm.updateLocalIdentity(name: localName.trimmingCharacters(in: .whitespaces), colorID: localColorID)
            }
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

    private var settingsButton: some View {
        Button { showingSettings = true } label: {
            Image(systemName: "gearshape.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white.opacity(0.7))
                .padding(8)
                .background(Circle().fill(Color.black.opacity(0.3)))
        }
        .padding(.top, 6)
        .padding(.trailing, 10)
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
            requireConfirm: player == s.you ? confirmRelease : false,
            requirePlusConfirm: player == s.you ? confirmPlus : false,
            onAdd: { vm.claim($0, for: player) },
            onPlusOne: { vm.claim(1, for: player) },
            onUndo: { vm.undo(for: player) }
        )
    }

    // MARK: Bottom band

    @ViewBuilder private func bottomBand(_ s: PlayerSnapshot, handWidth: CGFloat, peggingHandWidth: CGFloat, pileWidth: CGFloat, showWidth: CGFloat, cutWidth: CGFloat) -> some View {
        VStack(spacing: 12) {
            switch s.phase {
            case .cutForDeal:
                cutForDealArea(s, width: cutWidth)
            case .discardToCrib:
                discardArea(s, width: handWidth)
            case .pegging:
                peggingArea(s, handWidth: peggingHandWidth, pileWidth: pileWidth)
            case .showPone, .showDealer:
                showArea(s, cards: s.yourHand, width: handWidth, pileWidth: showWidth,
                         label: s.phase == .showPone ? "Pone's hand" : "Dealer's hand")
            case .showCrib:
                showArea(s, cards: s.crib ?? [], width: handWidth, pileWidth: showWidth, label: "The crib")
            case .handComplete:
                handCompleteArea(s)
            default:
                Color.clear
            }
        }
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Cut for deal

    /// Each player cuts once. Their card is shown to both. Once both have cut, the lower card wins the
    /// deal (and the first crib); the dealer then taps "Deal".
    @ViewBuilder private func cutForDealArea(_ s: PlayerSnapshot, width: CGFloat) -> some View {
        VStack(spacing: 14) {
            HStack(spacing: 34) {
                cutResult(for: .one, s: s, width: width)
                cutResult(for: .two, s: s, width: width)
            }

            if vm.cutForDealDecided {
                if vm.youDeal {
                    Button("Deal") { vm.advance() }
                        .buttonStyle(.borderedProminent).tint(.cribGold).foregroundStyle(.black)
                        .controlSize(.large)
                } else {
                    waitingLabel("Waiting for \(vm.name(of: s.dealer)) to deal…")
                }
            } else if vm.youNeedToCut {
                Button { vm.cut() } label: {
                    VStack(spacing: 6) {
                        CardView(card: nil, faceUp: false, width: width * 0.85)
                        Text("Tap to cut").font(.callout.weight(.semibold)).foregroundStyle(.white)
                    }
                }
                .buttonStyle(.plain)
            } else {
                waitingLabel("Waiting for \(s.opponentName) to cut…")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func waitingLabel(_ text: String) -> some View {
        HStack(spacing: 8) {
            ProgressView().tint(.white)
            Text(text).font(.callout).foregroundStyle(.white.opacity(0.8))
        }
    }

    @ViewBuilder private func cutResult(for player: PlayerID, s: PlayerSnapshot, width: CGFloat) -> some View {
        let isWinner = vm.cutForDealDecided && s.dealer == player
        VStack(spacing: 4) {
            Text(vm.name(of: player)).font(.caption).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
            if let card = s.cutForDeal[player] {
                CardView(card: card, isHighlighted: isWinner, width: width)
            } else {
                CardView(card: nil, faceUp: false, width: width)
                    .opacity(0.35)
            }
            Text(isWinner ? "deals · crib" : " ")
                .font(.caption2.weight(.bold))
                .foregroundStyle(Color.cribGold)
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
        VStack(spacing: 10) {
            // Running count — always visible during the play.
            Text("Count  \(s.runningCount)")
                .font(.title3.weight(.heavy)).monospacedDigit()
                .foregroundStyle(.white)
                .padding(.horizontal, 16).padding(.vertical, 5)
                .background(Capsule().fill(Color.black.opacity(0.45)))

            PlayPileView(snapshot: s, vm: vm, cardWidth: pileWidth)
                .frame(maxHeight: .infinity)

            if vm.peggingComplete {
                Button("Count the hands") { vm.advance() }
                    .buttonStyle(.borderedProminent).tint(.cribGold).foregroundStyle(.black)
                    .controlSize(.large)
            } else {
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
    }

    // MARK: Show

    @ViewBuilder private func showArea(_ s: PlayerSnapshot, cards: [Card], width: CGFloat, pileWidth: CGFloat, label: String) -> some View {
        VStack(spacing: 12) {
            HStack(alignment: .top, spacing: 24) {
                VStack(spacing: 4) {
                    Text("The Cut").font(.caption2).foregroundStyle(.white.opacity(0.7))
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
        vm.cut(); vm.cut(); vm.advance()          // both cut, then deal
        for _ in 0..<2 {                          // both players discard 2 → into pegging
            let hand = vm.snapshot.yourHand
            vm.toggleDiscard(hand[0]); vm.toggleDiscard(hand[1]); vm.confirmDiscard()
        }
        return vm
    }()
    var body: some View { GameTableView(vm: vm) }
}

#Preview(traits: .landscapeLeft) {
    GameTablePreview()
}
