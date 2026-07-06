import SwiftUI

/// The root game screen. Landscape: top ~1/3 is the scoreboard + coach banner + flag chips + manual
/// scoring; bottom ~2/3 is the shared play area and the current player's hand. Card sizes scale off
/// the geometry, so the same layout simply grows on iPad — no device checks.
struct GameTableView: View {
    @State var vm: GameViewModel
    @State private var showingSettings = false
    @AppStorage("confirmRelease") private var confirmRelease = true
    @AppStorage("localName") private var localName = "Player"
    @AppStorage("localColorID") private var localColorID = 1
    @AppStorage("scoringMode") private var scoringModeRaw = ScoringMode.feedback.rawValue

    // Opponent "+X" score preview: hold their displayed score for 3s while showing what they added.
    @State private var displayedOppScore: Int? = nil
    @State private var oppPending: Int = 0
    @State private var oppPendingTask: Task<Void, Never>? = nil

    // Uncommitted slider amount on the local panel, so Continue can fold it in ("Add N & continue").
    @State private var uncommittedLocal = 0
    @State private var clearScoreSignal = 0

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
            let peggingHandWidth = min(handWidth, (playHeight - 44) / 2.15)
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
                vm.setScoringMode(ScoringMode(rawValue: scoringModeRaw) ?? .feedback)
            }
        }
        // Preview the opponent's "+X" for 3s before their score updates on this device.
        .onChange(of: vm.snapshot.claimTick) { _, _ in previewOpponentClaim() }
        .ignoresSafeArea(.container, edges: .bottom)
    }

    private func previewOpponentClaim() {
        let s = vm.snapshot
        guard let claimer = s.lastClaimPlayer, s.lastClaimAmount > 0, claimer == s.you.opponent else { return }
        if oppPending == 0 {
            displayedOppScore = s.opponentScore - s.lastClaimAmount   // hold at the pre-claim value
        }
        oppPending += s.lastClaimAmount
        oppPendingTask?.cancel()
        oppPendingTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            withAnimation { displayedOppScore = nil; oppPending = 0 }
        }
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
                .minimumScaleFactor(0.6)
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 44)   // keep clear of the settings gear / screen edges

            ScoreFlagsView(flags: s.flags,
                           accent: vm.scoringPlayer.map { vm.theme(for: $0).primary } ?? .cribGold,
                           playerName: vm.scoringPlayer.map { vm.name(of: $0) })
                .padding(.horizontal, 16)

            if s.scoringMode == .auto {
                // Auto mode: no manual controls — just a big names + scores scoreboard.
                autoScoreboard(s)
            } else {
                // A slider panel per peg this device may score: both for pass-and-play, just the
                // local player's when networked. Constrain the width so a single panel doesn't
                // stretch across a wide iPad.
                HStack(spacing: 12) {
                    ForEach(vm.scorablePlayers, id: \.self) { player in
                        scorePanel(for: player, s: s)
                    }
                }
                .frame(maxWidth: 900)
                .padding(.horizontal, 12)
            }
        }
        .frame(maxHeight: .infinity)   // center vertically within the capped band
        .padding(.vertical, 8)
    }

    /// Auto-scoring scoreboard: each player's name over a big score, in their colour. The opponent's
    /// column carries the 3-second "+X" preview.
    @ViewBuilder private func autoScoreboard(_ s: PlayerSnapshot) -> some View {
        HStack(spacing: 0) {
            scoreColumn(for: s.you, s: s)
            Rectangle().fill(.white.opacity(0.15)).frame(width: 1, height: 64)
            scoreColumn(for: s.you.opponent, s: s)
        }
        .frame(maxWidth: 700)
        .padding(.horizontal, 12)
        .padding(.bottom, 14)   // breathing room under the scores
    }

    @ViewBuilder private func scoreColumn(for player: PlayerID, s: PlayerSnapshot) -> some View {
        let theme = vm.theme(for: player)
        let isOpponent = player != s.you
        let value = isOpponent ? (displayedOppScore ?? vm.score(of: player)) : vm.score(of: player)
        VStack(spacing: 2) {
            Text(vm.name(of: player).uppercased())
                .font(.title2.weight(.heavy))
                .foregroundStyle(theme.primary)
                .lineLimit(1).minimumScaleFactor(0.6)
            HStack(alignment: .center, spacing: 6) {   // "+X" centered vertically against the score
                Text("\(value)")
                    .font(.system(size: 64, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
                    .monospacedDigit()
                if isOpponent && oppPending > 0 {
                    Text("+\(oppPending)")
                        .font(.system(size: 22, weight: .heavy, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8).padding(.vertical, 2)
                        .background(Capsule().fill(theme.primary))
                        .transition(.scale.combined(with: .opacity))
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder private func scorePanel(for player: PlayerID, s: PlayerSnapshot) -> some View {
        let theme = vm.theme(for: player)
        let isLocal = player == s.you
        // On the local panel, delay the opponent's score by 3s and show their "+X" preview.
        let oppScore = isLocal ? (displayedOppScore ?? vm.score(of: player.opponent)) : vm.score(of: player.opponent)
        ScorePanel(
            name: vm.name(of: player),
            score: vm.score(of: player),
            opponentScore: oppScore,
            primary: theme.primary,
            deep: theme.deep,
            disabled: s.phase == .gameOver || vm.scoringDisabled(for: player),
            canUndo: vm.canUndo(for: player),
            requireConfirm: isLocal ? confirmRelease : false,
            opponentColor: vm.theme(for: player.opponent).primary,
            opponentPending: isLocal ? oppPending : 0,
            uncommitted: isLocal ? $uncommittedLocal : nil,
            clearSignal: isLocal ? clearScoreSignal : 0,
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
            case .showPone, .showDealer, .showCrib:
                showArea(s, pileWidth: showWidth)
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
            Button("Send 2 to \(s.yourSeat == .dealer ? "your crib" : "\(vm.name(of: s.dealer))'s crib")") {
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
        VStack(spacing: 8) {
            // The running count now lives inside the play pile, freeing this space for bigger cards.
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

    @ViewBuilder private func showArea(_ s: PlayerSnapshot, pileWidth: CGFloat) -> some View {
        VStack(spacing: 12) {
            HStack(alignment: .top, spacing: 24) {
                VStack(spacing: 4) {
                    Text("The Cut").font(.caption2).foregroundStyle(.white.opacity(0.7))
                    if let starter = s.starter { CardView(card: starter, width: pileWidth) }
                }
                VStack(spacing: 4) {
                    Text(vm.showLabel).font(.caption2).foregroundStyle(.white.opacity(0.7))
                    HStack(spacing: 8) {
                        ForEach(vm.showCards) { CardView(card: $0, width: pileWidth) }
                    }
                }
            }

            // A little space under the cards, then the prompt + button. The whole group is centered
            // vertically (below), so the button sits just under the cards — never pinned to the bottom.
            VStack(spacing: 10) {
                if vm.youAreCounting {
                    Text(s.scoringMode == .auto ? "Scored automatically" : "Count it on your slider, then Continue")
                        .font(.caption).foregroundStyle(.white.opacity(0.7))
                    // With a pending slider value (confirm-after-release), the button adds it, then advances.
                    Button(uncommittedLocal > 0 ? "Add \(uncommittedLocal) & continue" : "Continue") {
                        if uncommittedLocal > 0 {
                            vm.claim(uncommittedLocal, for: vm.snapshot.you)
                            clearScoreSignal += 1; uncommittedLocal = 0
                        }
                        vm.advance()
                    }
                    .buttonStyle(.borderedProminent).tint(.cribGold).foregroundStyle(.black)
                } else {
                    waitingLabel("Waiting for \(vm.name(of: vm.showCountingPlayer ?? s.you)) to count…")
                }
            }
            .padding(.top, 18)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)   // centers the cards + button group
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
        let vm = GameViewModel.loopback(names: [.one: "Ann", .two: "Ben"],
                                        colorIDs: [.one: 1, .two: 7], seed: 42, scoringMode: .feedback)
        vm.cut(); vm.cut(); vm.advance()          // both cut, then deal
        for _ in 0..<2 where vm.snapshot.phase == .discardToCrib {   // both discard 2 → pegging
            let hand = vm.snapshot.yourHand
            if hand.count >= 2 { vm.toggleDiscard(hand[0]); vm.toggleDiscard(hand[1]); vm.confirmDiscard() }
        }
        var guardCount = 0                        // play out pegging → the show
        while vm.snapshot.phase == .pegging && !vm.peggingComplete {
            guardCount += 1; if guardCount > 60 { break }
            let s = vm.snapshot
            let legal = CribbageScorer.legalPlays(hand: s.yourHand, count: s.runningCount)
            if let c = legal.min(by: { $0.countingValue < $1.countingValue }) { vm.play(c) } else { vm.sayGo() }
        }
        if vm.peggingComplete { vm.advance() }    // → showPone (count the pone's hand)
        return vm
    }()
    var body: some View { GameTableView(vm: vm) }
}

#Preview(traits: .landscapeLeft) {
    GameTablePreview()
}
