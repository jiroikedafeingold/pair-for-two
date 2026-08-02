import SwiftUI

/// The root game screen. Landscape: top ~1/3 is the scoreboard + coach banner + flag chips + manual
/// scoring; bottom ~2/3 is the shared play area and the current player's hand. Card sizes scale off
/// the geometry, so the same layout simply grows on iPad — no device checks.
struct GameTableView: View {
    @State var vm: GameViewModel
    var onExit: () -> Void = {}
    @State private var showingSettings = false
    @State private var showingHelp = false
    @State private var showingQuitConfirm = false
    @AppStorage("confirmRelease") private var confirmRelease = true
    @AppStorage("localName") private var localName = "Player"
    @AppStorage("localColorID") private var localColorID = 1
    @AppStorage("scoringMode") private var scoringModeRaw = ScoringMode.off.rawValue

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

    // "Check my count" — shows the correct scoring for the hand/crib currently being counted.
    @State private var showCheck = false

    // Set when THIS device changes the scoring mode, so the resulting snapshot change doesn't also
    // toast us — only the other player is told "so-and-so switched scoring".
    @State private var initiatedScoringChange = false

    // Scoring replay (win screen). `replayIsPreWin` = the auto replay shown *before* the win screen.
    @State private var showReplay = false
    @State private var replayIsPreWin = false
    @AppStorage("replayBeforeWin") private var replayBeforeWin = true
    @AppStorage("scoreTrackEnabled") private var scoreTrackEnabled = true

    // One brief gold flash on the help/settings icons when the play screen appears (and on
    // foreground), so players notice where to find help and change scoring mid-game.
    @State private var glowTrigger = 0
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var hSizeClass

    // The body is split into layered `some View` properties on purpose: a single long chain of
    // modifiers (sheets + ~10 onChange handlers) makes the Swift type-checker blow up (multi-minute
    // builds). Each boundary below gives the checker a fixed anchor, keeping builds fast.
    var body: some View {
        interactiveScreen
            .modifier(FeedbackHandlers(vm: vm,
                                       onCardPlay: { GameFeedback.shared.play(.cardPlay) },
                                       onCutTap: { GameFeedback.shared.play(.cutTap) },
                                       onDeckLift: { GameFeedback.shared.play(.deckLift) },
                                       onPhase: handlePhaseChange,
                                       onPegEvent: handlePegEvent,
                                       onClaimTick: previewOpponentClaim,
                                       onOpponentOut: handleOpponentOut,
                                       onAppear: { GameFeedback.shared.prepare(); triggerIconGlow() }))
            .ignoresSafeArea(.container, edges: .bottom)
            .onChange(of: scenePhase) { _, phase in if phase == .active { triggerIconGlow() } }
    }

    /// Flash the help + settings icons once to point players to them. Runs when the play screen
    /// appears and on every foreground.
    private func triggerIconGlow() { glowTrigger += 1 }

    /// The table plus the sheets, quit dialog, and the state-sync handlers.
    private var interactiveScreen: some View {
        tableScreen
            .sheet(isPresented: $showingSettings) {
                SettingsView(onDone: { showingSettings = false })
            }
            .sheet(isPresented: $showingHelp) {
                HelpView(onDone: { showingHelp = false })
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
                    let newMode = ScoringMode(rawValue: scoringModeRaw) ?? .feedback
                    // Note that WE changed it, so we don't toast ourselves when the shared state updates.
                    if newMode != vm.snapshot.scoringMode { initiatedScoringChange = true }
                    vm.setScoringMode(newMode)
                }
            }
            // The scoring mode is shared: whoever changes it, both devices switch. Tell the other
            // player, and keep this device's Settings in sync so closing it doesn't revert the change.
            .onChange(of: vm.snapshot.scoringMode) { _, newMode in
                scoringModeRaw = newMode.rawValue
                if initiatedScoringChange {
                    initiatedScoringChange = false
                } else {
                    showPegAlert("\(vm.snapshot.opponentName) switched scoring to \(newMode.title)")
                }
            }
    }

    private var tableScreen: some View {
        GeometryReader { geo in
            // Explicit CGFloat types keep these arithmetic bindings cheap for the type-checker.
            let height: CGFloat = geo.size.height
            let width: CGFloat = geo.size.width
            // Cap the scoreboard band so it doesn't leave a tall dead zone on iPad; the play area
            // takes the rest. 0.40 is enough for the (top-anchored) banner + flags + scoreboard/panel
            // while leaving the play area room for the show cards AND the Continue button below them.
            let topBandHeight: CGFloat = min(height * 0.37, 190)
            let playHeight: CGFloat = height - topBandHeight
            // Every phase reserves a fixed trailing "action rail" for its scoring flags + prompt +
            // button, so nothing stacks below the cards. iPad gets a much wider rail (it dwarfed the
            // big screen at the iPhone width); iPhone keeps it narrow so the cards get the space.
            let railWidth: CGFloat = hSizeClass == .regular ? min(width * 0.30, 420) : 156
            let playWidth: CGFloat = width - railWidth
            // Card aspect is height = width * 1.45. Each phase's cards fill as much of the play area as
            // its layout allows, capped by the width the row needs. Discard: a 6-card hand. Pegging: a
            // pile ABOVE the hand, so shorter. Show: the cut + a 4-card row. Cut: just two big cards.
            let handWidth: CGFloat = min((playWidth - 34) / 7.0, (playHeight - 64) / 1.45)
            let peggingHandWidth: CGFloat = min(handWidth, (playHeight - 44) / 2.15)
            let pileWidth: CGFloat = peggingHandWidth * 0.5
            // The show row is: cut card + 16pt gap + a 4-card hand (8pt spacing) = 5 cards + ~44pt,
            // so /5 keeps it inside the play column instead of spilling into the rail.
            let showWidth: CGFloat = min((playWidth - 44) / 5.0, (playHeight - 40) / 1.45)
            let cutWidth: CGFloat = min((playWidth - 50) / 2.2, (playHeight - 76) / 1.45)

            tableLayout(topBandHeight: topBandHeight, railWidth: railWidth, handWidth: handWidth,
                        peggingHandWidth: peggingHandWidth, pileWidth: pileWidth,
                        showWidth: showWidth, cutWidth: cutWidth)
        }
    }

    /// The band-split layout + overlays. Extracted from the `GeometryReader` closure so that closure
    /// stays a few cheap bindings + one call — keeping the Swift type-checker fast.
    @ViewBuilder private func tableLayout(topBandHeight: CGFloat, railWidth: CGFloat, handWidth: CGFloat,
                                          peggingHandWidth: CGFloat, pileWidth: CGFloat,
                                          showWidth: CGFloat, cutWidth: CGFloat) -> some View {
        let s = vm.snapshot
        VStack(spacing: 0) {
            topBand(s)
                .frame(maxWidth: .infinity)
                .frame(height: topBandHeight)
                .clipped()   // clip any bottom overflow to the band (banner is top-anchored, so safe)
                // Full-bleed dark band: the background (added after the clip) extends into the top +
                // side safe areas so it spans the whole screen width, while the content inside stays
                // within the safe area.
                .background(alignment: .top) {
                    Color.black.opacity(0.22).ignoresSafeArea(edges: [.top, .horizontal])
                }

            bottomBand(s, railWidth: railWidth, handWidth: handWidth, peggingHandWidth: peggingHandWidth,
                       pileWidth: pileWidth, showWidth: showWidth, cutWidth: cutWidth)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(felt)
        // Sit the reconnect/peg toasts just below the top band so they never cover the coach banner.
        .overlay(alignment: .top) { connectionBanner.padding(.top, topBandHeight + 12) }
        .overlay(alignment: .top) { pegAlertBanner.padding(.top, topBandHeight + 12) }
        .overlay(alignment: .topLeading) { quitButton }
        .overlay(alignment: .topTrailing) { topRightControls }
        .overlay { fullScreenOverlays(s) }
    }

    /// The modal, full-screen overlays (win, replay, check, opponent-left), grouped into one overlay
    /// so `tableScreen`'s modifier chain stays short.
    @ViewBuilder private func fullScreenOverlays(_ s: PlayerSnapshot) -> some View {
        if s.phase == .gameOver && !(showReplay && replayIsPreWin) { winnerOverlay(s) }
        if showReplay { replayOverlay(s) }
        if showCheck { checkOverlay(s) }
        if vm.opponentLeft { opponentLeftOverlay }
    }

    /// Routes a phase change to the right feedback / replay trigger.
    private func handlePhaseChange(_ old: GamePhase, _ new: GamePhase) {
        if new == .discardToCrib { GameFeedback.shared.play(.deal) }
        else if old == .cutStarter && new == .pegging { GameFeedback.shared.play(.starterReveal) }
        else if new == .gameOver && replayBeforeWin && !vm.scoreLog.isEmpty {
            // Auto-play the scoring replay first; the win screen shows when it finishes.
            replayIsPreWin = true
            showReplay = true
        }
    }

    /// The opponent just ran out of cards while you still hold more — nudge you to keep laying.
    private func handleOpponentOut() {
        if vm.opponentOutKeepPlaying {
            GameFeedback.shared.play(.go)
            showPegAlert("\(vm.snapshot.opponentName) is out — keep playing")
        }
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
        scheduleClearPegAlert()
    }

    /// Show the gold toast, then clear it after a couple of seconds.
    private func showPegAlert(_ text: String) {
        withAnimation { pegAlert = text }
        scheduleClearPegAlert()
    }

    private func scheduleClearPegAlert() {
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

    private var topRightControls: some View {
        HStack(spacing: 10) {
            controlButton("questionmark") { showingHelp = true }
                .accessibilityLabel("How to play")
            controlButton("gearshape.fill") { showingSettings = true }
                .accessibilityLabel("Settings")
        }
        .padding(.top, 6)
        .padding(.trailing, 10)
    }

    private func controlButton(_ systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white.opacity(0.7))
                .frame(width: 32, height: 32)
                .background(Circle().fill(Color.black.opacity(0.3)))
                .attentionGlow(trigger: glowTrigger)
        }
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
        VStack(spacing: 8) {
            Text(vm.coachBanner)
                .font(.headline.weight(.bold))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.6)
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 44)   // keep clear of the settings gear / screen edges

            // The scoring flags ("Fifteen 2 +2" …) live at the top of the felt now (see `bottomBand`),
            // so the dark band holds only the coach line + the scoreboard — giving the scores room.
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
        // Anchor to the top (not centered) with clearance below the top controls, so the coach
        // banner is always visible near the top and can never be pushed off the top edge, whatever
        // the scoreboard/panel height. Any excess spills downward within the band.
        .frame(maxHeight: .infinity, alignment: .top)
        .padding(.top, 12)
        .padding(.bottom, 4)
    }

    /// Auto-scoring scoreboard: each player's name over a big score, in their colour. The opponent's
    /// column carries the 3-second "+X" preview.
    @ViewBuilder private func autoScoreboard(_ s: PlayerSnapshot) -> some View {
        let you = s.you, opp = s.you.opponent
        let oppValue = displayedOppScore ?? vm.score(of: opp)
        HStack(spacing: 0) {
            scoreColumn(for: you, s: s)
            // A clear centre divider between the two scores (a soft-capped vertical bar), distinct
            // from the thin progress ring so the two aren't confused.
            Capsule()
                .fill(LinearGradient(colors: [.white.opacity(0.06), .white.opacity(0.45), .white.opacity(0.06)],
                                     startPoint: .top, endPoint: .bottom))
                .frame(width: 2.5, height: 58)
            scoreColumn(for: opp, s: s)
        }
        .frame(maxWidth: 760)
        // An imagined oval around both names + scores, carrying each player's progress loop.
        .padding(.horizontal, 34)
        .padding(.vertical, 10)
        .overlay {
            if scoreTrackEnabled {
                ScoreTrackOverlay(youFraction: loopFraction(vm.score(of: you)),
                                  youColor: vm.theme(for: you).primary,
                                  opponentFraction: loopFraction(oppValue),
                                  opponentColor: vm.theme(for: opp).primary,
                                  cornerRadius: 200)
            }
        }
        .padding(.horizontal, 12)
    }

    /// How much of the loop a score fills: 0 at the start, a full loop (1) at the 121 game point.
    private func loopFraction(_ points: Int) -> Double {
        min(1, max(0, Double(points) / 121))
    }

    @ViewBuilder private func scoreColumn(for player: PlayerID, s: PlayerSnapshot) -> some View {
        let theme = vm.theme(for: player)
        let isOpponent = player != s.you
        let value = isOpponent ? (displayedOppScore ?? vm.score(of: player)) : vm.score(of: player)
        VStack(spacing: 4) {
            Text(vm.name(of: player).uppercased())
                .font(.title3.weight(.heavy))
                .foregroundStyle(theme.primary)
                .lineLimit(1).minimumScaleFactor(0.5)
            HStack(alignment: .center, spacing: 6) {   // "+X" centered vertically against the score
                Text("\(value)")
                    .font(.system(size: 44, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
                    .monospacedDigit()
                    .minimumScaleFactor(0.7)
                if isOpponent && oppPending > 0 {
                    Text("+\(oppPending)")
                        .font(.system(size: 20, weight: .heavy, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8).padding(.vertical, 2)
                        .background(Capsule().fill(theme.primary))
                        .transition(.scale.combined(with: .opacity))
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 10)   // keep names/scores clear of the divider and the oval's ends
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
            // A lone panel (networked play) carries both players' loops; with two panels
            // (pass-and-play) each shows only its own player's loop.
            showOpponentTrack: vm.scorablePlayers.count == 1,
            uncommitted: isLocal ? $uncommittedLocal : nil,
            clearSignal: isLocal ? clearScoreSignal : 0,
            onAdd: { GameFeedback.shared.play(.score); vm.claim($0, for: player) },
            onPlusOne: { GameFeedback.shared.play(.score); vm.claim(1, for: player) },
            onUndo: { vm.undo(for: player) }
        )
    }

    // MARK: Bottom band

    @ViewBuilder private func bottomBand(_ s: PlayerSnapshot, railWidth: CGFloat, handWidth: CGFloat, peggingHandWidth: CGFloat, pileWidth: CGFloat, showWidth: CGFloat, cutWidth: CGFloat) -> some View {
        VStack(spacing: 12) {
            switch s.phase {
            case .cutForDeal:
                cutForDealArea(s, width: cutWidth, railWidth: railWidth)
            case .discardToCrib:
                discardArea(s, width: handWidth, railWidth: railWidth)
            case .cutStarter:
                starterCutArea(s, width: cutWidth, railWidth: railWidth)
            case .pegging:
                peggingArea(s, handWidth: peggingHandWidth, pileWidth: pileWidth, railWidth: railWidth)
            case .showPone, .showDealer, .showCrib:
                showArea(s, pileWidth: showWidth, railWidth: railWidth)
            case .handComplete:
                handCompleteArea(s, railWidth: railWidth)
            default:
                Color.clear
            }
        }
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// One consistent landscape layout for every play phase: the cards/primary visual fill and centre
    /// the space that's left, while the phase's prompt, status, and primary button sit in a fixed-width
    /// column on the trailing side — the same place on every screen. Nothing stacks below the cards, so
    /// the action never runs off the bottom on a short landscape phone.
    @ViewBuilder private func playScene<Play: View, Action: View>(
        _ s: PlayerSnapshot,
        railWidth: CGFloat,
        @ViewBuilder play: () -> Play,
        @ViewBuilder action: () -> Action
    ) -> some View {
        // The rail's width is ALWAYS reserved, whether or not it currently holds flags/a button, so
        // the cards keep a fixed centred position and never jump when a "Go" or message appears. The
        // scoring flags ("Fifteen 2 +2" …) live at the top of the rail, above the prompt/button.
        HStack(spacing: 12) {
            play()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            // The prompt/button is centred so it lines up horizontally with the (also centred) cards;
            // the scoring flags float at the top of the rail above it, rather than pushing it down.
            ZStack(alignment: .top) {
                railFlags(s)
                VStack(spacing: 10) { action() }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(width: railWidth)
            .frame(maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 4)
    }

    /// The scoring flags for the current context, as a vertical column pinned to the top of the rail.
    /// Bounded in height and scrollable, so a big hand's list never reaches the centred button.
    @ViewBuilder private func railFlags(_ s: PlayerSnapshot) -> some View {
        if !s.flags.isEmpty {
            ScoreFlagsView(flags: s.flags,
                           accent: vm.scoringPlayer.map { vm.theme(for: $0).primary } ?? .cribGold,
                           playerName: vm.scoringPlayer.map { vm.name(of: $0) },
                           vertical: true)
                .frame(maxWidth: .infinity, maxHeight: 96, alignment: .top)
        }
    }

    // MARK: Cut for deal

    /// Each player cuts once. Their card is shown to both. Once both have cut, the lower card wins the
    /// deal (and the first crib); the dealer then taps "Deal".
    @ViewBuilder private func cutForDealArea(_ s: PlayerSnapshot, width: CGFloat, railWidth: CGFloat) -> some View {
        playScene(s, railWidth: railWidth) {
            HStack(spacing: 34) {
                cutResult(for: .one, s: s, width: width)
                cutResult(for: .two, s: s, width: width)
            }
        } action: {
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
    }

    /// A spinner-over-text status, laid out to sit comfortably in the narrow action rail.
    private func waitingLabel(_ text: String) -> some View {
        VStack(spacing: 8) {
            ProgressView().tint(.white)
            Text(text).font(.callout).foregroundStyle(.white.opacity(0.8))
                .multilineTextAlignment(.center)
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

    @ViewBuilder private func discardArea(_ s: PlayerSnapshot, width: CGFloat, railWidth: CGFloat) -> some View {
        playScene(s, railWidth: railWidth) {
            HandView(cards: s.yourHand.sortedForDisplay(),
                     selected: vm.selectedForDiscard,
                     onTap: { GameFeedback.shared.play(.discardSelect); vm.toggleDiscard($0) },
                     cardWidth: width,
                     dealSignal: AnyHashable(s.yourHand.map(\.id)))   // deal cards in on a fresh hand
        } action: {
            Button("Send 2 to \(s.yourSeat == .dealer ? "your crib" : "\(vm.name(of: s.dealer))'s crib")") {
                GameFeedback.shared.play(.discardConfirm)
                vm.confirmDiscard()
            }
            .buttonStyle(.borderedProminent)
            .tint(vm.theme(for: s.you).deep)
            .disabled(!vm.canConfirmDiscard)
        }
    }

    // MARK: Starter cut (pone lifts the deck, dealer turns up the cut — like an in-person cut)

    @ViewBuilder private func starterCutArea(_ s: PlayerSnapshot, width: CGFloat, railWidth: CGFloat) -> some View {
        let lifted = vm.starterCutLifted
        playScene(s, railWidth: railWidth) {
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
        } action: {
            if vm.youLiftCut {
                Text("Tap the deck to cut").font(.callout.weight(.semibold)).foregroundStyle(.white)
                    .multilineTextAlignment(.center)
            } else if vm.youRevealStarter {
                Text("Tap the deck to turn up the cut").font(.callout.weight(.semibold)).foregroundStyle(.white)
                    .multilineTextAlignment(.center)
            } else {
                waitingLabel(lifted ? "Waiting for \(vm.name(of: s.dealer)) to turn up the cut…"
                                    : "Waiting for \(vm.name(of: s.pone)) to cut the deck…")
            }
        }
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

    @ViewBuilder private func peggingArea(_ s: PlayerSnapshot, handWidth: CGFloat, pileWidth: CGFloat, railWidth: CGFloat) -> some View {
        playScene(s, railWidth: railWidth) {
            VStack(spacing: 8) {
                // The running count lives inside the play pile, freeing this space for bigger cards.
                PlayPileView(snapshot: s, vm: vm, cardWidth: pileWidth)
                    .frame(maxHeight: .infinity)

                if !vm.peggingComplete {
                    HandView(cards: s.yourHand.sortedForDisplay(),
                             isEnabled: { vm.isLegalPlay($0) },
                             onTap: { vm.play($0) },
                             cardWidth: handWidth)
                }
            }
        } action: {
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
            } else if vm.canSayGo {
                Button("Go") { GameFeedback.shared.play(.advance); vm.sayGo() }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                    .controlSize(.large)
            }
        }
    }

    // MARK: Show

    @ViewBuilder private func showArea(_ s: PlayerSnapshot, pileWidth: CGFloat, railWidth: CGFloat) -> some View {
        let isCrib = s.phase == .showCrib
        // The crib adds a badge + backing, so shrink its cards only a hair.
        let cardW = isCrib ? pileWidth * 0.92 : pileWidth
        playScene(s, railWidth: railWidth) {
            HStack(alignment: .top, spacing: 16) {
                VStack(spacing: 4) {
                    Text("The Cut").font(.caption2).foregroundStyle(.white.opacity(0.7))
                    if let starter = s.starter { RankSuitTile(card: starter, width: cardW) }
                }
                VStack(spacing: 6) {
                    // The crib gets a distinct gold badge + backing so it's obvious it's the crib
                    // being counted (not another hand).
                    if isCrib {
                        Label("\(vm.name(of: s.dealer))'s crib".uppercased(), systemImage: "square.stack.3d.up.fill")
                            .font(.caption2.weight(.heavy))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 10).padding(.vertical, 3)
                            .background(Capsule().fill(Color.cribGold))
                    } else {
                        Text(vm.showLabel).font(.caption2).foregroundStyle(.white.opacity(0.7))
                    }
                    // Cards deal out one-by-one as they're shown (re-triggers each show sub-phase).
                    DealtCardsRow(cards: vm.showCards.sortedForDisplay(), cardWidth: cardW, dealSignal: s.phase)
                        .padding(isCrib ? 5 : 0)
                        .background {
                            if isCrib {
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(Color.cribGold.opacity(0.12))
                                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .stroke(Color.cribGold.opacity(0.55), lineWidth: 1))
                            }
                        }
                }
            }
        } action: {
            if vm.youAreCounting {
                Text(s.scoringMode == .auto ? "Scored automatically" : "Count it on your slider, then Continue")
                    .font(.caption).foregroundStyle(.white.opacity(0.7))
                    .multilineTextAlignment(.center)
                // With a pending slider value (confirm-after-release), the button adds it, then advances.
                // In manual modes a check button sits below to verify the count.
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

                if s.scoringMode != .auto {
                    Button {
                        GameFeedback.shared.play(.advance)
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { showCheck = true }
                    } label: {
                        Label("Check", systemImage: "checkmark.circle.fill")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.cribGold)
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .background(Capsule().fill(Color.white.opacity(0.12)))
                            .overlay(Capsule().stroke(Color.cribGold.opacity(0.6), lineWidth: 1.2))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Check my count")
                }
            } else {
                waitingLabel("Waiting for \(vm.name(of: vm.showCountingPlayer ?? s.you)) to count…")
            }
        }
    }

    // MARK: Hand complete

    @ViewBuilder private func handCompleteArea(_ s: PlayerSnapshot, railWidth: CGFloat) -> some View {
        playScene(s, railWidth: railWidth) {
            VStack(spacing: 10) {
                Text("Hand complete").font(.title2.weight(.bold)).foregroundStyle(.white)
                Text("\(s.yourName) \(s.yourScore)  •  \(s.opponentName) \(s.opponentScore)")
                    .font(.title3).foregroundStyle(.white.opacity(0.85))
                    .multilineTextAlignment(.center)
            }
        } action: {
            // Only the next dealer starts the deal (the deal passes to the former pone).
            if vm.youStartNextDeal {
                Button("Deal next hand") { vm.advance() }
                    .buttonStyle(.borderedProminent).tint(.cribGold).foregroundStyle(.black)
                    .controlSize(.large)
            } else {
                waitingLabel("Waiting for \(vm.name(of: vm.nextDealer)) to deal…")
            }
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

    // MARK: Check-my-count overlay

    /// Shows the correct count for the hand/crib being counted, so a manual scorer can verify.
    @ViewBuilder private func checkOverlay(_ s: PlayerSnapshot) -> some View {
        let flags = vm.checkScoreFlags
        let total = vm.checkScoreTotal
        ZStack {
            Color.black.opacity(0.6).ignoresSafeArea()
                .onTapGesture { withAnimation { showCheck = false } }

            VStack(spacing: 12) {
                Text("Correct count").font(.title3.weight(.bold)).foregroundStyle(.white)
                Text(vm.showLabel).font(.caption).foregroundStyle(.white.opacity(0.7))

                if flags.isEmpty {
                    Text("0").font(.system(size: 46, weight: .heavy, design: .rounded)).foregroundStyle(Color.cribGold)
                    Text("Nothing scores in this hand.").font(.caption).foregroundStyle(.white.opacity(0.7))
                } else {
                    ScrollView {
                        VStack(spacing: 6) {
                            ForEach(Array(flags.enumerated()), id: \.offset) { _, f in
                                HStack {
                                    Text(f.detail).font(.callout).foregroundStyle(.white.opacity(0.9))
                                    Spacer(minLength: 16)
                                    Text("+\(f.points)").font(.callout.weight(.heavy)).foregroundStyle(Color.cribGold)
                                }
                            }
                        }
                    }
                    .frame(maxWidth: 300).frame(maxHeight: 150)
                    Rectangle().fill(.white.opacity(0.15)).frame(height: 1).frame(maxWidth: 300)
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(total)").font(.system(size: 44, weight: .heavy, design: .rounded)).foregroundStyle(Color.cribGold)
                        Text(total == 1 ? "point" : "points").font(.caption).foregroundStyle(.white.opacity(0.7))
                    }
                }

                Button("Got it") { withAnimation { showCheck = false } }
                    .buttonStyle(.borderedProminent).tint(.cribGold).foregroundStyle(.black)
                    .padding(.top, 2)
            }
            .padding(24)
            .frame(maxWidth: 380)
            .background(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .stroke(Color.cribGold.opacity(0.4), lineWidth: 1))
            )
            .padding(24)
        }
        .transition(.opacity)
    }

    // MARK: Winner overlay (Criboard's confetti + skunk celebration)

    @ViewBuilder private func winnerOverlay(_ s: PlayerSnapshot) -> some View {
        if let info = vm.winnerInfo {
            // Pass-and-play shows the winner celebration; networked shows each device its own result.
            let youWon = vm.isLoopback || info.winner == s.you
            if youWon {
                WinnerOverlay(
                    winner: info.winner,
                    skunk: info.skunk,
                    winnerTheme: vm.theme(for: info.winner),
                    winnerName: vm.name(of: info.winner),
                    canReplay: !vm.scoreLog.isEmpty,
                    onPlayAgain: { vm.playAgain() },
                    onReplay: { replayIsPreWin = false; withAnimation { showReplay = true } },
                    onExit: { vm.quit() }
                )
            } else {
                LoserOverlay(
                    winnerName: vm.name(of: info.winner),
                    skunk: info.skunk,
                    canReplay: !vm.scoreLog.isEmpty,
                    onPlayAgain: { vm.playAgain() },
                    onReplay: { replayIsPreWin = false; withAnimation { showReplay = true } },
                    onExit: { vm.quit() }
                )
            }
        }
    }

    /// The scoring replay — steps through every score of the game. Shown before the win screen (auto
    /// option) or from the win screen's "Replay scoring" button.
    @ViewBuilder private func replayOverlay(_ s: PlayerSnapshot) -> some View {
        ScoringReplayView(
            events: vm.scoreLog,
            p1Name: vm.name(of: .one), p2Name: vm.name(of: .two),
            p1Theme: vm.theme(for: .one), p2Theme: vm.theme(for: .two),
            onFinish: { withAnimation { showReplay = false; replayIsPreWin = false } }
        )
        .transition(.opacity)
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
            // One riffle for the whole deal-out. Per-card feedback fired a synchronous Core Haptics
            // start() on every card, which stalled the reveal animation on iPhone (iPads have no
            // haptics, so they stayed smooth) — the start-of-round deal has no per-card feedback and
            // is smooth, so we match it here.
            GameFeedback.shared.play(.deal)
            try? await Task.sleep(for: .milliseconds(140))
            for i in 1...cards.count {
                revealed = i
                try? await Task.sleep(for: .milliseconds(105))
            }
        }
    }
}

// MARK: - Feedback handlers

/// The cluster of state-driven feedback `onChange` handlers, pulled into its own `ViewModifier`.
/// Keeping these out of the main view body is what stops the Swift type-checker from blowing up on
/// one enormous modifier chain (which turned builds into multi-minute affairs).
private struct FeedbackHandlers: ViewModifier {
    let vm: GameViewModel
    let onCardPlay: () -> Void
    let onCutTap: () -> Void
    let onDeckLift: () -> Void
    let onPhase: (GamePhase, GamePhase) -> Void
    let onPegEvent: () -> Void
    let onClaimTick: () -> Void
    let onOpponentOut: () -> Void
    let onAppear: () -> Void

    func body(content: Content) -> some View {
        content
            .onAppear(perform: onAppear)
            // Preview the opponent's "+X" for 3s before their score updates on this device.
            .onChange(of: vm.snapshot.claimTick) { _, _ in onClaimTick() }
            // Tactile + audio feedback, driven by the state so BOTH devices feel each moment of play.
            .onChange(of: vm.snapshot.playSequence.count) { old, new in if new > old { onCardPlay() } }
            .onChange(of: vm.snapshot.cutForDeal.count) { old, new in if new > old { onCutTap() } }
            .onChange(of: vm.snapshot.starterCutLifted) { old, new in if new && !old { onDeckLift() } }
            .onChange(of: vm.snapshot.phase) { old, new in onPhase(old, new) }
            .onChange(of: vm.pegEventTick) { old, new in if new > old { onPegEvent() } }
            .onChange(of: vm.snapshot.opponentHandCount) { old, new in if new == 0 && old > 0 { onOpponentOut() } }
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

private struct AutoScoreboardPreview: View {
    @State private var vm: GameViewModel = {
        let vm = GameViewModel.loopback(names: [.one: "Ann", .two: "Ben"],
                                        colorIDs: [.one: 1, .two: 7], seed: 42, scoringMode: .auto)
        vm.cut(); vm.cut(); vm.advance()
        for _ in 0..<2 where vm.snapshot.phase == .discardToCrib {
            let hand = vm.snapshot.yourHand
            if hand.count >= 2 { vm.toggleDiscard(hand[0]); vm.toggleDiscard(hand[1]); vm.confirmDiscard() }
        }
        if vm.snapshot.phase == .cutStarter { vm.liftCut(); vm.revealStarter() }
        var guardCount = 0                        // play out pegging → the show (count the hands)
        while vm.snapshot.phase == .pegging && !vm.peggingComplete {
            guardCount += 1; if guardCount > 60 { break }
            let s = vm.snapshot
            let legal = CribbageScorer.legalPlays(hand: s.yourHand, count: s.runningCount)
            if let c = legal.min(by: { $0.countingValue < $1.countingValue }) { vm.play(c) } else { vm.sayGo() }
        }
        if vm.peggingComplete { vm.advance() }    // → showPone
        return vm
    }()
    var body: some View { GameTableView(vm: vm) }
}

#Preview("Auto scoreboard", traits: .landscapeLeft) {
    AutoScoreboardPreview()
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

