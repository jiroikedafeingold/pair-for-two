import SwiftUI

/// The board: one phone lying flat between two players, real cards in their hands. Each player gets
/// their own half, oriented to them, and the shared score in the middle turns to face each of them in
/// turn.
///
/// **The rotation is the whole design.** The far player's half is drawn upside down (`rotationEffect`
/// of 180°), which also rotates its hit-testing — so their slider drags the way *they* see it, toward
/// their own right. The shared readout between the halves can only face one player at a time, so it
/// turns to whoever just changed their score, and otherwise alternates on a timer rather than picking a
/// favorite. Pegging is the moment you most want to read the number, so that beats the timer.
///
/// Deliberately just a pegboard: no hands, no crib, no cut, because the app can't see the cards. Games
/// played here aren't recorded in Stats either — this is a utility, and lifetime "hands played" or
/// "best hand" would be diluted by games that can't contribute to them.
struct BoardView: View {
    var onExit: () -> Void

    /// Preview seam: the shared readout's starting orientation, so both states can be rendered.
    var startFlipped = false
    /// Preview seam: start from a given position. There's no other way to render a *finished* board — the
    /// store deliberately refuses to keep one, so it can't be loaded back in.
    var startGame: BoardGame?

    @State private var game = BoardGame()
    @State private var flipped: Bool
    @State private var lastInteraction = Date()
    @State private var bottomPending = 0
    @State private var topPending = 0
    @State private var editing: BoardSide?
    @State private var confirmingNewGame = false
    @State private var saveTask: Task<Void, Never>?
    /// Flips once the pre-win replay has run, so the celebration can take over. Re-armed by a new game.
    @State private var preWinReplayShown = false
    /// Watches which way the device is leaning; nil while it lies flat.
    @State private var tilt = BoardTiltReader()

    /// The near player is whoever set the app up; the far player is named on the board itself, since
    /// two people share this phone and only one of them owns it.
    @AppStorage("localName") private var nearName = "Player"
    @AppStorage("localColorID") private var nearColorID = 1
    @AppStorage("boardFarName") private var farName = "Opponent"
    @AppStorage("boardFarColorID") private var farColorID = 7
    @AppStorage("confirmRelease") private var confirmRelease = true
    @AppStorage("scoreTrackEnabled") private var trackEnabled = true
    @AppStorage("replayBeforeWin") private var replayBeforeWin = true
    @AppStorage("boardTiltTurns") private var tiltTurns = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Compact height means a phone in landscape; regular means an iPad. Drives how much of the screen
    /// the sliders keep versus the score — not a device check, a space check.
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    /// How much of the loop a score fills: nothing at the start, a closed ring at game point.
    private func loopFraction(_ points: Int) -> Double {
        min(1, max(0, Double(points) / Double(BoardGame.gamePoint)))
    }

    init(onExit: @escaping () -> Void, startFlipped: Bool = false, startGame: BoardGame? = nil) {
        self.onExit = onExit
        self.startFlipped = startFlipped
        self.startGame = startGame
        _flipped = State(initialValue: startFlipped)
        _game = State(initialValue: startGame ?? BoardGame())
    }

    /// Display names, never blank: onboarding deliberately starts the local name empty, and a nameless
    /// side would render as a gap where a name should be. "Player" rather than "You" because the same
    /// string goes into the win screen, and "YOU WINS" is not a sentence.
    private var nearLabel: String {
        let trimmed = nearName.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? String(localized: "Player", comment: "Stand-in for your own name when you have not set one") : trimmed
    }
    private var farLabel: String {
        let trimmed = farName.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? String(localized: "Opponent", comment: "Stand-in for the other player's name when it is not set") : trimmed
    }

    /// Whoever is holding the device, per the accelerometer — nil when it's flat on the table and the
    /// score belongs to both of them.
    private var tiltFacing: BoardSide? { tiltTurns ? tilt.facing : nil }

    /// How long the shared score faces one player before turning to the other.
    private static let flipInterval: TimeInterval = 5
    /// Don't turn it while someone is mid-peg, or in the moment just after one — they're looking at it.
    private static let settleTime: TimeInterval = 2
    /// The win screen turns more slowly than the score: there's more of it to take in.
    private static let winFlipInterval: TimeInterval = 6

    var body: some View {
        GeometryReader { geo in
            // The sliders take a fixed slice at each edge and the score gets everything else — it's the
            // thing both players are actually reading, so it should dominate. A phone in landscape is
            // tight, so its sliders go close to the edges to leave the middle as much room as possible;
            // an iPad keeps them comfortably inset and still has hundreds of points to spare.
            let sliderHeight: CGFloat = verticalSizeClass == .compact ? 86 : 250
            let bandHeight = max(140, geo.size.height - 16 - sliderHeight * 2)
            VStack(spacing: 0) {
                // The far player's half, turned to face them.
                panel(for: .top)
                    .frame(height: sliderHeight)
                    .rotationEffect(.degrees(180))

                sharedBand(height: bandHeight)
                    .frame(height: bandHeight)

                panel(for: .bottom)
                    .frame(height: sliderHeight)
            }
            .padding(.vertical, 8)
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .background(felt)
        .overlay {
            if game.isFinished {
                // Both of these turn as a whole, not just the score: they're the screens both players
                // want to look at, and they belong to neither side of the table.
                Group {
                    if wantsPreWinReplay { boardReplay } else { winner }
                }
                .rotationEffect(.degrees(flipped ? 180 : 0))
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.7), value: flipped)
            }
        }
        .sheet(item: $editing) { side in
            BoardPlayerSheet(side: side,
                             name: side == .bottom ? $nearName : $farName,
                             colorID: side == .bottom ? $nearColorID : $farColorID,
                             isShared: side == .bottom,
                             onDone: { editing = nil })
        }
        .confirmationDialog("Start a new game?", isPresented: $confirmingNewGame, titleVisibility: .visible) {
            Button("New game", role: .destructive) { newGame() }
            Button("Keep playing", role: .cancel) {}
        } message: {
            Text("This clears both scores.")
        }
        .task { await runFlipTimer() }
        .task(id: tiltTurns) {
            // Nothing is read while the setting is off, so nothing is sampled either.
            guard tiltTurns else { tilt.stop(); return }
            tilt.start()
        }
        .onDisappear { tilt.stop() }
        .onChange(of: tiltFacing) { _, side in
            // Picking the device up is the clearest statement of who's reading, so it turns at once —
            // and `face` marks it as an interaction, which keeps the timer off it for a beat after.
            if let side { face(side) }
        }
        .onAppear {
            guard startGame == nil else { return }   // a seeded preview keeps its own position
            if let saved = BoardGameStore.load() { game = saved }
        }
        .onChange(of: game) { _, updated in scheduleSave(updated) }
        .onDisappear { saveTask?.cancel(); BoardGameStore.save(game) }
    }

    // MARK: One player's half

    @ViewBuilder private func slider(for side: BoardSide) -> some View {
        let isNear = side == .bottom
        let theme = playerTheme(colorID: isNear ? nearColorID : farColorID)
        let otherTheme = playerTheme(colorID: isNear ? farColorID : nearColorID)
        ScorePanel(name: isNear ? nearLabel : farLabel,
                   score: game.score(side),
                   opponentScore: game.score(side.other),
                   primary: theme.primary,
                   deep: theme.deep,
                   disabled: game.isFinished,
                   canUndo: game.canUndo(side),
                   requireConfirm: confirmRelease,
                   opponentColor: otherTheme.primary,
                   showsScore: false,   // the shared band between the halves carries the score
                   uncommitted: isNear ? $bottomPending : $topPending,
                   onAdd: { peg($0, to: side) },
                   onPlusOne: { peg(1, to: side) },
                   onUndo: {
                       GameFeedback.shared.play(.advance)
                       face(side)   // correcting your own score counts too — face the person doing it
                       game.undo(side)
                   },
                   onActivity: { face(side) })   // sliding, tapping, undoing: all of it turns the score
    }

    /// A player's slider with the edit button beside it — to the right as that player sees it, since the
    /// far half is rotated. Beside rather than below on purpose: under the slider it was eating the
    /// vertical space the score wants.
    @ViewBuilder private func panel(for side: BoardSide) -> some View {
        let isNear = side == .bottom
        HStack(spacing: 6) {
            slider(for: side)
            Button {
                face(side)
                editing = side
            } label: {
                Image(systemName: "pencil.circle.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.45))
                    .frame(width: 34, height: 34)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Edit \(isNear ? nearLabel : farLabel)'s name and color")
        }
        .padding(.horizontal, 10)
    }

    // MARK: The shared middle

    /// Both scores, large, turning to face each player in turn. It sits between the two halves because
    /// that's the one place neither player owns.
    private func sharedBand(height: CGFloat) -> some View {
        // Everything in here scales with the space it's been given: a big region with small numbers in
        // the middle of it would be a waste of the room.
        let scoreSize = min(150, max(40, height * 0.42))
        let nameSize = min(30, max(13, height * 0.085))
        let inset = min(96, max(58, height * 0.16))
        return ZStack {
            Rectangle().fill(Color.black.opacity(0.22))
            HStack(spacing: 0) {
                exitButton
                sharedScore(.bottom, scoreSize: scoreSize, nameSize: nameSize)
                resetControl(lineHeight: height * 0.18)
                sharedScore(.top, scoreSize: scoreSize, nameSize: nameSize)
                // Balances the exit button on the other side so the scores stay centered.
                Color.clear.frame(width: 34, height: 1)
            }
            .padding(.horizontal, 12)

            // The 121 track, with both players' loops and the skunk marks on it — the same overlay the
            // connected game draws, here framing the shared score.
            if trackEnabled {
                ScoreTrackOverlay(youFraction: loopFraction(game.score(.bottom)),
                                  youColor: playerTheme(colorID: nearColorID).primary,
                                  opponentFraction: loopFraction(game.score(.top)),
                                  opponentColor: playerTheme(colorID: farColorID).primary,
                                  cornerRadius: min(60, height * 0.28))
                    // Clear of the buttons at either end of the band, so the loop doesn't run through them.
                    .padding(.horizontal, inset)
                    .padding(.vertical, 6)
            }
        }
        // Tap it to turn it now rather than waiting for the timer.
        .contentShape(Rectangle())
        .onTapGesture {
            flipped.toggle()
            lastInteraction = Date()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(nearLabel) \(game.score(.bottom)), \(farLabel) \(game.score(.top))",
                                 comment: "VoiceOver: both players' names and scores on the shared board"))
        .accessibilityHint("Turns to face each player in turn. Double tap to turn it now.")
    }

    @ViewBuilder private func sharedScore(_ side: BoardSide, scoreSize: CGFloat, nameSize: CGFloat) -> some View {
        // Only the scores turn; the buttons either side of them stay put.
        let isNear = side == .bottom
        let theme = playerTheme(colorID: isNear ? nearColorID : farColorID)
        VStack(spacing: 0) {
            Text(verbatim: (isNear ? nearLabel : farLabel).uppercased())
                .font(.system(size: nameSize, weight: .heavy, design: .rounded))
                .foregroundStyle(theme.primary)
                .lineLimit(1).minimumScaleFactor(0.6)
            Text(verbatim: "\(game.score(side))")
                .font(.system(size: scoreSize, weight: .heavy, design: .rounded))
                .foregroundStyle(.white)
                .monospacedDigit()
                .contentTransition(.numericText(value: Double(game.score(side))))
        }
        .frame(maxWidth: .infinity)
        // Each score turns in place rather than the row turning as a whole: the pair keeps its
        // positions, and every number stays labeled with whose it is, so there's nothing to work out
        // when it comes round to face you.
        .rotationEffect(.degrees(flipped ? 180 : 0))
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.55), value: flipped)
    }

    // MARK: Chrome

    private var felt: some View {
        LinearGradient(colors: [.feltMid, .feltDark], startPoint: .top, endPoint: .bottom)
            .ignoresSafeArea()
    }

    private var exitButton: some View {
        Button {
            BoardGameStore.save(game)
            onExit()
        } label: {
            Image(systemName: "chevron.left")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white.opacity(0.7))
                .padding(9)
                .background(Circle().fill(Color.black.opacity(0.3)))
        }
        .padding(.top, 6).padding(.leading, 10)
        .accessibilityLabel("Back to menu")
    }

    /// The divider between the two scores, with the reset on it: the middle of the board belongs to
    /// neither player, which is exactly right for the one control that affects them both. Circular, so it
    /// reads the same from either side, and it always asks first once there's a game to lose.
    private func resetControl(lineHeight: CGFloat) -> some View {
        VStack(spacing: 10) {
            dividerLine.frame(height: lineHeight)
            Button {
                if game.hasProgress { confirmingNewGame = true } else { newGame() }
            } label: {
                Image(systemName: "arrow.counterclockwise")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white.opacity(0.75))
                    .frame(width: 38, height: 38)
                    .background(Circle().fill(Color.black.opacity(0.35)))
                    .overlay(Circle().stroke(.white.opacity(0.15), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Reset the board")
            .accessibilityHint("Clears both scores. Asks first.")
            dividerLine.frame(height: lineHeight)
        }
        .frame(width: 44)
    }

    private var dividerLine: some View {
        Capsule()
            .fill(LinearGradient(colors: [.white.opacity(0.05), .white.opacity(0.35), .white.opacity(0.05)],
                                 startPoint: .top, endPoint: .bottom))
            .frame(width: 2)
    }

    /// Whether to replay the game's pegs before revealing the winner.
    private var wantsPreWinReplay: Bool {
        replayBeforeWin && game.hasProgress && !preWinReplayShown
    }

    /// The same score-by-score replay the dealt game uses, fed from the board's peg history. Every peg is
    /// there in order — what's missing is *why* each one was scored, since the app never sees the cards,
    /// so the steps show the points alone rather than inventing a phase for them.
    @ViewBuilder private var boardReplay: some View {
        ScoringReplayView(
            events: game.pegs.map {
                Claim(player: $0.side == .bottom ? .one : .two, amount: $0.amount, phase: .pegging)
            },
            p1Name: nearLabel, p2Name: farLabel,
            p1Theme: playerTheme(colorID: nearColorID),
            p2Theme: playerTheme(colorID: farColorID),
            showsPhase: false,
            onFinish: { withAnimation { preWinReplayShown = true } }
        )
    }

    @ViewBuilder private var winner: some View {
        if let side = game.winner {
            let isNear = side == .bottom
            WinnerOverlay(winner: isNear ? .one : .two,
                          skunk: computeSkunk(loserScore: game.loserScore),
                          winnerTheme: playerTheme(colorID: isNear ? nearColorID : farColorID),
                          winnerName: isNear ? nearLabel : farLabel,
                          canReplay: false,
                          opponentLeft: false,
                          onPlayAgain: { newGame() },
                          onReplay: {},
                          onExit: { onExit() })
        }
    }

    // MARK: Actions

    private func peg(_ amount: Int, to side: BoardSide) {
        GameFeedback.shared.play(.score)
        face(side)
        game.add(amount, to: side)
    }

    private func newGame() {
        game = BoardGame()
        BoardGameStore.clear()
        preWinReplayShown = false
        bottomPending = 0
        topPending = 0
        touch()
    }

    /// Note an interaction, so the shared score doesn't turn under someone's finger.
    private func touch() { lastInteraction = Date() }

    /// Persist a moment after the last change, off the main thread.
    ///
    /// This used to write on every change, synchronously, from `onChange` — so each `+1` tap encoded the
    /// game and wrote a file before the next tap could be handled, which is precisely the kind of work
    /// that swallows a quick run of taps. Nothing needs the file to be current mid-game: leaving the
    /// screen and backgrounding both save directly.
    private func scheduleSave(_ game: BoardGame) {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            await Task.detached(priority: .utility) { BoardGameStore.save(game) }.value
        }
    }

    /// Turn the shared score to face a particular player, now. Used whenever someone changes their own
    /// score: they've just pegged, so the new total should be the right way up for them without waiting
    /// on the timer. The settle window then keeps it there for a moment before the timer resumes
    /// alternating, so the other player still gets to read it.
    private func face(_ side: BoardSide) {
        touch()
        flipped = (side == .top)
    }

    /// Turn the shared score over on a timer, skipping any tick that lands while a peg is being staged
    /// or has just been made.
    private func runFlipTimer() async {
        while !Task.isCancelled {
            // A finished game gets a longer beat: the celebration is worth reading, and it's bigger than
            // a number, so it needs a moment before it turns away.
            try? await Task.sleep(for: .seconds(game.isFinished ? Self.winFlipInterval : Self.flipInterval))
            guard !Task.isCancelled else { continue }
            if game.isFinished {
                if let held = tiltFacing {
                    flipped = (held == .top)
                } else {
                    flipped.toggle()   // nobody is pegging any more, so nothing to wait for
                }
                continue
            }
            // While the device is tipped toward one player it's theirs, and the timer stands down:
            // turning the score away from someone who is holding it up to read would be perverse.
            if let held = tiltFacing {
                flipped = (held == .top)
                continue
            }
            let busy = bottomPending > 0 || topPending > 0
                || Date().timeIntervalSince(lastInteraction) < Self.settleTime
            if busy { continue }
            flipped.toggle()
        }
    }
}

// MARK: - Name / color sheet

/// `BoardSide` as a sheet item.
extension BoardSide: Identifiable {
    public var id: String { rawValue }
}

/// Rename a side, or change its color, from the board itself — two people share this phone, so the
/// far player has to be able to put their own name on it without going through Settings.
private struct BoardPlayerSheet: View {
    let side: BoardSide
    @Binding var name: String
    @Binding var colorID: Int
    /// The near side's name and color are the app-wide ones from Settings; the far side's belong to
    /// the board alone. Worth saying, so changing one here isn't a surprise elsewhere.
    let isShared: Bool
    var onDone: () -> Void

    // The app-wide preferences that mean something on a scoreboard. Left out: the card back (no cards
    // here) and the scoring mode, which only governs a game the app deals.
    @AppStorage("confirmRelease") private var confirmRelease = true
    @AppStorage("scoreTrackEnabled") private var scoreTrackEnabled = true
    @AppStorage("hapticsEnabled") private var hapticsEnabled = true
    @AppStorage("soundEnabled") private var soundEnabled = true
    @AppStorage("celebrationEffects") private var celebrationEffects = true
    @AppStorage("replayBeforeWin") private var replayBeforeWin = true
    @AppStorage("boardTiltTurns") private var tiltTurns = true

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                        .textInputAutocapitalization(.words)
                        .submitLabel(.done)
                } header: {
                    if side == .bottom {
                        Text("This side", comment: "Header when editing the near player on the shared board")
                    } else {
                        Text("Other side", comment: "Header when editing the far player on the shared board")
                    }
                } footer: {
                    if isShared {
                        Text("This is your name from Settings — changing it here changes it everywhere.",
                             comment: "Footer when editing the name that is shared with the rest of the app")
                    } else {
                        Text("Just for the board on this phone.",
                             comment: "Footer when editing a name used only by the scoreboard")
                    }
                }

                Section("Color") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            ForEach(Array(playerThemes.enumerated()), id: \.offset) { index, theme in
                                Circle()
                                    .fill(theme.primary)
                                    .frame(width: 30, height: 30)
                                    .overlay(Circle().strokeBorder(.primary, lineWidth: colorID == index ? 3 : 0))
                                    .onTapGesture { colorID = index }
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }

                // The rest of the app's settings that actually apply to a scoreboard. Reachable from
                // here because the board is a place you sit down and play from — walking back out to the
                // menu to turn the sound off would be silly.
                Section {
                    Toggle("Confirm after release", isOn: $confirmRelease)
                } header: {
                    Text("Scoring slider")
                } footer: {
                    Text("Holds the slider value until you tap the +N button, instead of adding it the moment you let go.")
                }

                Section {
                    Toggle("Score track", isOn: $scoreTrackEnabled)
                    Toggle("Scoring replay before win", isOn: $replayBeforeWin)
                } footer: {
                    Text("The track is the loop around the score, tracing each player's progress to 121 with the skunk lines marked on it. The replay walks back through every peg of the game before the winner is shown.")
                }

                Section {
                    Toggle("Turn with the tilt", isOn: $tiltTurns)
                } footer: {
                    Text("Pick the \(deviceWord()) up to read the score and it turns the right way up for whoever is holding it. Flat on the table it goes back to taking turns.")
                }

                Section("Sound & feel") {
                    Toggle("Haptics", isOn: $hapticsEnabled)
                    Toggle("Sound effects", isOn: $soundEnabled)
                    Toggle("Celebration effects", isOn: $celebrationEffects)
                }

                Section {
                    Text("Scoring mode and the card back live in the main Settings — they're for a game the app deals, and on the board you're playing with your own cards.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Player & settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: onDone).fontWeight(.semibold)
                }
            }
        }
    }
}

#if DEBUG
#Preview("Board", traits: .landscapeLeft) {
    BoardView(onExit: {})
}

#Preview("Board — score flipped", traits: .landscapeLeft) {
    BoardView(onExit: {}, startFlipped: true)
}

/// A won game, so the celebration (which turns as a whole, to face each player in turn) can be seen.
#Preview("Board — won", traits: .landscapeLeft) {
    var finished = BoardGame()
    finished.add(58, to: .top)
    finished.add(121, to: .bottom)
    return BoardView(onExit: {}, startGame: finished)
}
#endif
