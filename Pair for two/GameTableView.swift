import SwiftUI

/// The root game screen. Landscape: top ~1/3 is the scoreboard + coach banner + flag chips + manual
/// scoring; bottom ~2/3 is the shared play area and the current player's hand. Card sizes scale off
/// the geometry, so the same layout simply grows on iPad — no device checks.
struct GameTableView: View {
    @State var vm: GameViewModel
    var onExit: () -> Void = {}
    @State private var showingSettings = false
    @State private var showingQuitConfirm = false
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

    // Transient "Go / 31 — take the score" alert, shown for a couple of seconds when the event fires.
    @State private var pegAlert: String? = nil
    @State private var pegAlertTask: Task<Void, Never>? = nil

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
            .overlay(alignment: .top) { pegAlertBanner.padding(.top, topBandHeight + 12) }
            .overlay(alignment: .topLeading) { quitButton }
            .overlay(alignment: .topTrailing) { settingsButton }
            .overlay { if s.phase == .gameOver { winnerOverlay(s) } }
            .overlay { if vm.opponentLeft { opponentLeftOverlay } }
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView(onDone: { showingSettings = false })
        }
        .confirmationDialog("Quit this game?", isPresented: $showingQuitConfirm, titleVisibility: .visible) {
            Button("Quit game", role: .destructive) { vm.quit() }
            Button("Keep playing", role: .cancel) {}
        } message: {
            Text("This ends the game for both players.")
        }
        // The game was quit (by you or the other player) — return to the menu.
        .onChange(of: vm.ended) { _, ended in if ended { onExit() } }
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
        // Tactile + audio feedback, driven by the state so BOTH devices feel each moment of play.
        .onAppear { GameFeedback.shared.prepare() }
        .onChange(of: vm.snapshot.playSequence.count) { old, new in
            if new > old { GameFeedback.shared.play(.cardPlay) }
        }
        .onChange(of: vm.snapshot.cutForDeal.count) { old, new in
            if new > old { GameFeedback.shared.play(.cutTap) }
        }
        .onChange(of: vm.snapshot.starterCutLifted) { old, new in
            if new && !old { GameFeedback.shared.play(.deckLift) }
        }
        .onChange(of: vm.snapshot.phase) { old, new in
            if new == .discardToCrib { GameFeedback.shared.play(.deal) }
            else if old == .cutStarter && new == .pegging { GameFeedback.shared.play(.starterReveal) }
        }
        .onChange(of: vm.pegEventTick) { old, new in
            if new > old { handlePegEvent() }
        }
        .ignoresSafeArea(.container, edges: .bottom)
    }

    // MARK: Go / 31 alert

    /// Fires the notification (haptic + sound + banner) when a go or 31 occurs, so the player who earns
    /// the point knows to take it.
    private func handlePegEvent() {
        guard let event = vm.lastPegEvent else { return }
        let auto = vm.snapshot.scoringMode == .auto
        let mine = event.scorer == vm.snapshot.you || vm.isLoopback
        let who = vm.name(of: event.scorer)
        switch event.kind {
        case .go:
            if event.points == 0 {
                // "Go" was said and the play passed to the other player — notify only them.
                guard !mine else { return }
                GameFeedback.shared.play(.go)
                pegAlert = "\(who) said Go — your play"
            } else {
                GameFeedback.shared.play(.go)
                pegAlert = auto ? "Go — \(who) pegs 1"
                                : (mine ? "Go — take 1" : "\(who) takes 1 for the go")
            }
        case .thirtyOne:
            GameFeedback.shared.play(.thirtyOne)
            pegAlert = auto ? "31 for \(event.points)!"
                            : (mine ? "31 — take \(event.points)" : "\(who) hits 31 for \(event.points)")
        }
        pegAlertTask?.cancel()
        pegAlertTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.6))
            guard !Task.isCancelled else { return }
            withAnimation { pegAlert = nil }
        }
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
        if !vm.opponentLeft, vm.connection == .reconnecting || vm.connection == .disconnected {
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

    /// The go/31 "take the score" toast — bold and briefly shown so a player never misses their point.
    @ViewBuilder private var pegAlertBanner: some View {
        if let text = pegAlert {
            Text(text)
                .font(.title3.weight(.heavy))
                .foregroundStyle(.black)
                .padding(.horizontal, 20).padding(.vertical, 10)
                .background(Capsule().fill(Color.cribGold))
                .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
                .transition(.scale.combined(with: .opacity))
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

    /// Leave the current game (ends it for both players). Confirmed before it takes effect.
    private var quitButton: some View {
        Button { showingQuitConfirm = true } label: {
            Image(systemName: "rectangle.portrait.and.arrow.right")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white.opacity(0.7))
                .padding(8)
                .background(Circle().fill(Color.black.opacity(0.3)))
        }
        .padding(.top, 6)
        .padding(.leading, 10)
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
            Rectangle().fill(.white.opacity(0.15)).frame(width: 1, height: 48)
            scoreColumn(for: s.you.opponent, s: s)
        }
        .frame(maxWidth: 700)
        .padding(.horizontal, 12)
    }

    @ViewBuilder private func scoreColumn(for player: PlayerID, s: PlayerSnapshot) -> some View {
        let theme = vm.theme(for: player)
        let isOpponent = player != s.you
        let value = isOpponent ? (displayedOppScore ?? vm.score(of: player)) : vm.score(of: player)
        VStack(spacing: 2) {
            Text(vm.name(of: player).uppercased())
                .font(.title3.weight(.heavy))
                .foregroundStyle(theme.primary)
                .lineLimit(1).minimumScaleFactor(0.6)
            HStack(alignment: .center, spacing: 6) {   // "+X" centered vertically against the score
                Text("\(value)")
                    .font(.system(size: 50, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
                    .monospacedDigit()
                    .minimumScaleFactor(0.7)
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
            onAdd: { GameFeedback.shared.play(.score); vm.claim($0, for: player) },
            onPlusOne: { GameFeedback.shared.play(.score); vm.claim(1, for: player) },
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
            case .cutStarter:
                starterCutArea(s, width: cutWidth)
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
                     onTap: { GameFeedback.shared.play(.discardSelect); vm.toggleDiscard($0) },
                     cardWidth: width)
            Button("Send 2 to \(s.yourSeat == .dealer ? "your crib" : "\(vm.name(of: s.dealer))'s crib")") {
                GameFeedback.shared.play(.discardConfirm)
                vm.confirmDiscard()
            }
            .buttonStyle(.borderedProminent)
            .tint(vm.theme(for: s.you).deep)
            .disabled(!vm.canConfirmDiscard)
            Spacer(minLength: 0)
        }
    }

    // MARK: Starter cut (pone lifts the deck, dealer turns up the cut — like an in-person cut)

    @ViewBuilder private func starterCutArea(_ s: PlayerSnapshot, width: CGFloat) -> some View {
        let lifted = vm.starterCutLifted
        VStack(spacing: 18) {
            Spacer(minLength: 0)
            HStack(alignment: .center, spacing: lifted ? 30 : 0) {
                // The remaining ("bottom") deck. The dealer taps it to turn up the starter.
                deckPile(width: width, highlighted: vm.youLiftCut || vm.youRevealStarter)
                    .onTapGesture {
                        if vm.youLiftCut { vm.liftCut() }
                        else if vm.youRevealStarter { vm.revealStarter() }
                    }
                    .allowsHitTesting(vm.youLiftCut || vm.youRevealStarter)

                // The portion the pone lifted off, set aside once the cut is made.
                if lifted {
                    deckPile(width: width, highlighted: false)
                        .opacity(0.8)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .animation(.spring(response: 0.45, dampingFraction: 0.72), value: lifted)

            // Instruction sits under the deck — the deck itself is the tap target.
            if vm.youLiftCut {
                Text("Tap the deck to cut").font(.callout.weight(.semibold)).foregroundStyle(.white)
            } else if vm.youRevealStarter {
                Text("Tap the deck to turn up the cut").font(.callout.weight(.semibold)).foregroundStyle(.white)
            } else {
                waitingLabel(lifted ? "Waiting for \(vm.name(of: s.dealer)) to turn up the cut…"
                                    : "Waiting for \(vm.name(of: s.pone)) to cut the deck…")
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// A small stack of face-down cards drawn as a deck.
    private func deckPile(width: CGFloat, highlighted: Bool) -> some View {
        ZStack {
            ForEach(0..<4, id: \.self) { i in
                CardView(card: nil, faceUp: false,
                         isHighlighted: highlighted && i == 3,
                         width: width)
                    .offset(x: CGFloat(i) * 2.5, y: CGFloat(i) * -2.5)
            }
        }
        .scaleEffect(highlighted ? 1.04 : 1)
        .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: highlighted)
    }

    // MARK: Pegging

    @ViewBuilder private func peggingArea(_ s: PlayerSnapshot, handWidth: CGFloat, pileWidth: CGFloat) -> some View {
        VStack(spacing: 8) {
            // The running count now lives inside the play pile, freeing this space for bigger cards.
            PlayPileView(snapshot: s, vm: vm, cardWidth: pileWidth)
                .frame(maxHeight: .infinity)

            if vm.peggingComplete {
                if vm.youStartCount {
                    // Fold any pending slider points in before advancing (like the show's Continue),
                    // so last-card / go / 31 points aren't stranded when moving to the count.
                    Button(uncommittedLocal > 0 ? "Add \(uncommittedLocal) & count the hands" : "Count the hands") {
                        if uncommittedLocal > 0 {
                            GameFeedback.shared.play(.score)
                            vm.claim(uncommittedLocal, for: vm.snapshot.you)
                            clearScoreSignal += 1; uncommittedLocal = 0
                        } else {
                            GameFeedback.shared.play(.advance)
                        }
                        vm.advance()
                    }
                    .buttonStyle(.borderedProminent).tint(.cribGold).foregroundStyle(.black)
                    .controlSize(.large)
                } else {
                    waitingLabel("Waiting for \(vm.name(of: vm.snapshot.lastToPlay ?? vm.snapshot.you))…")
                }
            } else {
                HStack(spacing: 16) {
                    HandView(cards: s.yourHand,
                             isEnabled: { vm.isLegalPlay($0) },
                             onTap: { vm.play($0) },
                             cardWidth: handWidth)
                    if vm.canSayGo {
                        Button("Go") { GameFeedback.shared.play(.advance); vm.sayGo() }
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
        let isCrib = s.phase == .showCrib
        VStack(spacing: 12) {
            HStack(alignment: .top, spacing: 24) {
                VStack(spacing: 4) {
                    Text("The Cut").font(.caption2).foregroundStyle(.white.opacity(0.7))
                    if let starter = s.starter { CardView(card: starter, width: pileWidth) }
                }
                VStack(spacing: 6) {
                    // The crib gets a distinct gold badge + backing so it's obvious it's the crib
                    // being counted (not another hand).
                    if isCrib {
                        Label("\(vm.name(of: s.dealer))'s crib".uppercased(), systemImage: "square.stack.3d.up.fill")
                            .font(.caption.weight(.heavy))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 12).padding(.vertical, 4)
                            .background(Capsule().fill(Color.cribGold))
                    } else {
                        Text(vm.showLabel).font(.caption2).foregroundStyle(.white.opacity(0.7))
                    }
                    // Cards deal out one-by-one as they're shown (re-triggers each show sub-phase).
                    DealtCardsRow(cards: vm.showCards, cardWidth: pileWidth, dealSignal: s.phase)
                        .padding(isCrib ? 8 : 0)
                        .background {
                            if isCrib {
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .fill(Color.cribGold.opacity(0.12))
                                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        .stroke(Color.cribGold.opacity(0.55), lineWidth: 1))
                            }
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
                            GameFeedback.shared.play(.score)
                            vm.claim(uncommittedLocal, for: vm.snapshot.you)
                            clearScoreSignal += 1; uncommittedLocal = 0
                        } else {
                            GameFeedback.shared.play(.advance)
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
            // Only the next dealer starts the deal (the deal passes to the former pone).
            if vm.youStartNextDeal {
                Button("Deal next hand") { vm.advance() }
                    .buttonStyle(.borderedProminent).tint(.cribGold).foregroundStyle(.black)
            } else {
                waitingLabel("Waiting for \(vm.name(of: vm.nextDealer)) to deal…")
            }
            Spacer()
        }
    }

    // MARK: Opponent-left overlay (online games can't be rejoined)

    @ViewBuilder private var opponentLeftOverlay: some View {
        ZStack {
            Color.black.opacity(0.65).ignoresSafeArea()
            VStack(spacing: 16) {
                Image(systemName: "wifi.slash").font(.system(size: 44)).foregroundStyle(.white)
                Text("Opponent left").font(.title2.weight(.bold)).foregroundStyle(.white)
                Text("The connection to your opponent was lost. Online games can't be resumed.")
                    .font(.callout).foregroundStyle(.white.opacity(0.8))
                    .multilineTextAlignment(.center).frame(maxWidth: 360)
                Button("Back to menu") { onExit() }
                    .buttonStyle(.borderedProminent).tint(.cribGold).foregroundStyle(.black)
                    .controlSize(.large)
            }
            .padding(28)
        }
        .transition(.opacity)
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

// MARK: - Dealt cards row (show phase)

/// Renders the counted cards dealing out one at a time — each drops in from above with a spring —
/// so the hand (and the crib) is clearly presented as it's shown. Re-deals whenever `dealSignal`
/// changes (pone hand → dealer hand → crib).
private struct DealtCardsRow: View {
    let cards: [Card]
    let cardWidth: CGFloat
    let dealSignal: GamePhase
    @State private var revealed = 0

    var body: some View {
        HStack(spacing: 8) {
            ForEach(Array(cards.enumerated()), id: \.element.id) { idx, card in
                let shown = idx < revealed
                CardView(card: card, width: cardWidth)
                    .opacity(shown ? 1 : 0)
                    .scaleEffect(shown ? 1 : 0.6, anchor: .top)
                    .offset(y: shown ? 0 : -60)
                    .rotationEffect(.degrees(shown ? 0 : (idx.isMultiple(of: 2) ? -10 : 10)))
                    .animation(.spring(response: 0.45, dampingFraction: 0.68), value: revealed)
            }
        }
        .task(id: dealSignal) {
            revealed = 0
            guard !cards.isEmpty else { return }
            try? await Task.sleep(for: .milliseconds(180))
            for i in 1...cards.count {
                revealed = i
                GameFeedback.shared.play(.cardPlay)   // a deal tick as each card lands
                try? await Task.sleep(for: .milliseconds(150))
            }
        }
    }
}

// MARK: - Preview

private struct GameTablePreview: View {
    @State private var vm: GameViewModel = {
        let vm = GameViewModel.loopback(names: [.one: "Ann", .two: "Ben"],
                                        colorIDs: [.one: 1, .two: 7], seed: 42, scoringMode: .feedback)
        vm.cut(); vm.cut(); vm.advance()          // both cut, then deal
        for _ in 0..<2 where vm.snapshot.phase == .discardToCrib {   // both discard 2 → starter cut
            let hand = vm.snapshot.yourHand
            if hand.count >= 2 { vm.toggleDiscard(hand[0]); vm.toggleDiscard(hand[1]); vm.confirmDiscard() }
        }
        if vm.snapshot.phase == .cutStarter { vm.liftCut(); vm.revealStarter() }   // pone cuts, dealer reveals → pegging
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

// The manual starter cut, stopped with the pone about to lift the deck.
private struct StarterCutPreview: View {
    @State private var vm: GameViewModel = {
        let vm = GameViewModel.loopback(names: [.one: "Ann", .two: "Ben"],
                                        colorIDs: [.one: 1, .two: 7], seed: 42, scoringMode: .feedback)
        vm.cut(); vm.cut(); vm.advance()
        for _ in 0..<2 where vm.snapshot.phase == .discardToCrib {
            let hand = vm.snapshot.yourHand
            if hand.count >= 2 { vm.toggleDiscard(hand[0]); vm.toggleDiscard(hand[1]); vm.confirmDiscard() }
        }
        return vm   // stops at .cutStarter, not yet lifted
    }()
    var body: some View { GameTableView(vm: vm) }
}

#Preview("Starter cut", traits: .landscapeLeft) {
    StarterCutPreview()
}

// The starter cut after the pone has lifted — the dealer is about to turn up the cut.
private struct StarterRevealPreview: View {
    @State private var vm: GameViewModel = {
        let vm = GameViewModel.loopback(names: [.one: "Ann", .two: "Ben"],
                                        colorIDs: [.one: 1, .two: 7], seed: 42, scoringMode: .feedback)
        vm.cut(); vm.cut(); vm.advance()
        for _ in 0..<2 where vm.snapshot.phase == .discardToCrib {
            let hand = vm.snapshot.yourHand
            if hand.count >= 2 { vm.toggleDiscard(hand[0]); vm.toggleDiscard(hand[1]); vm.confirmDiscard() }
        }
        vm.liftCut()   // pone has lifted; dealer now reveals
        return vm
    }()
    var body: some View { GameTableView(vm: vm) }
}

#Preview("Starter reveal", traits: .landscapeLeft) {
    StarterRevealPreview()
}

// Mid-pegging, stopped just after a lap reset so the delineation line between the finished lap and the
// current one is visible.
private struct PeggingLapPreview: View {
    @State private var vm: GameViewModel = {
        let vm = GameViewModel.loopback(names: [.one: "Ann", .two: "Ben"],
                                        colorIDs: [.one: 1, .two: 7], seed: 13, scoringMode: .feedback)
        vm.cut(); vm.cut(); vm.advance()
        for _ in 0..<2 where vm.snapshot.phase == .discardToCrib {
            let hand = vm.snapshot.yourHand
            if hand.count >= 2 { vm.toggleDiscard(hand[0]); vm.toggleDiscard(hand[1]); vm.confirmDiscard() }
        }
        if vm.snapshot.phase == .cutStarter { vm.liftCut(); vm.revealStarter() }
        var guardCount = 0
        while vm.snapshot.phase == .pegging && !vm.peggingComplete {
            guardCount += 1; if guardCount > 40 { break }
            let s = vm.snapshot
            // Stop once a lap has finished (some cards out of play) and the new lap has begun.
            if s.playSequence.count - s.lapCardCount > 0 && s.lapCardCount > 0 { break }
            let legal = CribbageScorer.legalPlays(hand: s.yourHand, count: s.runningCount)
            if let c = legal.min(by: { $0.countingValue < $1.countingValue }) { vm.play(c) } else { vm.sayGo() }
        }
        return vm
    }()
    var body: some View { GameTableView(vm: vm) }
}

#Preview("Pegging lap divider", traits: .landscapeLeft) {
    PeggingLapPreview()
}

// Game over — the winner celebration overlay.
private struct WinnerPreview: View {
    @State private var vm: GameViewModel = {
        let vm = GameViewModel.loopback(names: [.one: "Ann", .two: "Ben"],
                                        colorIDs: [.one: 1, .two: 7], seed: 42, scoringMode: .feedback)
        vm.cut(); vm.cut(); vm.advance()
        for _ in 0..<2 where vm.snapshot.phase == .discardToCrib {
            let hand = vm.snapshot.yourHand
            if hand.count >= 2 { vm.toggleDiscard(hand[0]); vm.toggleDiscard(hand[1]); vm.confirmDiscard() }
        }
        if vm.snapshot.phase == .cutStarter { vm.liftCut(); vm.revealStarter() }
        vm.claim(24, for: .two)          // give Ben a respectable score
        vm.claim(121, for: .one)         // Ann goes out — winner celebration
        return vm
    }()
    var body: some View { GameTableView(vm: vm) }
}

#Preview("Winner", traits: .landscapeLeft) {
    WinnerPreview()
}

// The crib being counted — distinct gold badge + backing, cards dealing out.
private struct CribShowPreview: View {
    @State private var vm: GameViewModel = {
        let vm = GameViewModel.loopback(names: [.one: "Ann", .two: "Ben"],
                                        colorIDs: [.one: 1, .two: 7], seed: 42, scoringMode: .feedback)
        vm.cut(); vm.cut(); vm.advance()
        for _ in 0..<2 where vm.snapshot.phase == .discardToCrib {
            let hand = vm.snapshot.yourHand
            if hand.count >= 2 { vm.toggleDiscard(hand[0]); vm.toggleDiscard(hand[1]); vm.confirmDiscard() }
        }
        if vm.snapshot.phase == .cutStarter { vm.liftCut(); vm.revealStarter() }
        var g = 0
        while vm.snapshot.phase == .pegging && !vm.peggingComplete {
            g += 1; if g > 60 { break }
            let s = vm.snapshot
            let legal = CribbageScorer.legalPlays(hand: s.yourHand, count: s.runningCount)
            if let c = legal.min(by: { $0.countingValue < $1.countingValue }) { vm.play(c) } else { vm.sayGo() }
        }
        if vm.peggingComplete { vm.advance() }   // → showPone
        vm.advance()                             // → showDealer
        vm.advance()                             // → showCrib
        return vm
    }()
    var body: some View { GameTableView(vm: vm) }
}

#Preview("Crib show", traits: .landscapeLeft) {
    CribShowPreview()
}
