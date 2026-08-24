import SwiftUI

/// The board: one phone lying flat between two players, real cards in their hands. Each player gets
/// their own half, oriented to them, and the shared score in the middle turns to face each of them in
/// turn.
///
/// **The rotation is the whole design.** The far player's half is drawn upside down (`rotationEffect`
/// of 180°), which also rotates its hit-testing — so their slider drags the way *they* see it, toward
/// their own right. The shared readout between the halves can only face one player at a time, so it
/// turns to whoever just changed their score, and otherwise alternates on a timer rather than picking a
/// favourite. Pegging is the moment you most want to read the number, so that beats the timer.
///
/// Deliberately just a pegboard: no hands, no crib, no cut, because the app can't see the cards. Games
/// played here aren't recorded in Stats either — this is a utility, and lifetime "hands played" or
/// "best hand" would be diluted by games that can't contribute to them.
struct BoardView: View {
    var onExit: () -> Void

    /// Preview seam: the shared readout's starting orientation, so both states can be rendered.
    var startFlipped = false

    @State private var game = BoardGame()
    @State private var flipped: Bool
    @State private var lastInteraction = Date()
    @State private var bottomPending = 0
    @State private var topPending = 0
    @State private var editing: BoardSide?
    @State private var confirmingNewGame = false

    /// The near player is whoever set the app up; the far player is named on the board itself, since
    /// two people share this phone and only one of them owns it.
    @AppStorage("localName") private var nearName = "Player"
    @AppStorage("localColorID") private var nearColorID = 1
    @AppStorage("boardFarName") private var farName = "Opponent"
    @AppStorage("boardFarColorID") private var farColorID = 7
    @AppStorage("confirmRelease") private var confirmRelease = true
    @AppStorage("scoreTrackEnabled") private var trackEnabled = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// How much of the loop a score fills: nothing at the start, a closed ring at game point.
    private func loopFraction(_ points: Int) -> Double {
        min(1, max(0, Double(points) / Double(BoardGame.gamePoint)))
    }

    init(onExit: @escaping () -> Void, startFlipped: Bool = false) {
        self.onExit = onExit
        self.startFlipped = startFlipped
        _flipped = State(initialValue: startFlipped)
    }

    /// Display names, never blank: onboarding deliberately starts the local name empty, and a nameless
    /// side would render as a gap where a name should be.
    private var nearLabel: String {
        let trimmed = nearName.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "You" : trimmed
    }
    private var farLabel: String {
        let trimmed = farName.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "Opponent" : trimmed
    }

    /// How long the shared score faces one player before turning to the other.
    private static let flipInterval: TimeInterval = 5
    /// Don't turn it while someone is mid-peg, or in the moment just after one — they're looking at it.
    private static let settleTime: TimeInterval = 2

    var body: some View {
        GeometryReader { geo in
            let bandHeight: CGFloat = min(96, geo.size.height * 0.24)
            VStack(spacing: 0) {
                // The far player's half, turned to face them.
                panel(for: .top)
                    .rotationEffect(.degrees(180))

                sharedBand
                    .frame(height: bandHeight)

                panel(for: .bottom)
            }
            .padding(.vertical, 8)
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .background(felt)
        .overlay { if game.isFinished { winner } }
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
        .onAppear { if let saved = BoardGameStore.load() { game = saved } }
        .onChange(of: game) { _, updated in BoardGameStore.save(updated) }
        .onDisappear { BoardGameStore.save(game) }
    }

    // MARK: One player's half

    @ViewBuilder private func panel(for side: BoardSide) -> some View {
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
                   })
            .padding(.horizontal, 10)
            .frame(maxHeight: .infinity)
            // Tap your own name to change it (or your colour) without leaving the game.
            .overlay(alignment: .bottomLeading) {
                Button { editing = side } label: {
                    Image(systemName: "pencil.circle.fill")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.45))
                        .padding(10)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Edit \(isNear ? nearLabel : farLabel)'s name and colour")
            }
    }

    // MARK: The shared middle

    /// Both scores, large, turning to face each player in turn. It sits between the two halves because
    /// that's the one place neither player owns.
    private var sharedBand: some View {
        ZStack {
            Rectangle().fill(Color.black.opacity(0.22))
            HStack(spacing: 0) {
                exitButton
                sharedScore(.bottom)
                Capsule()
                    .fill(LinearGradient(colors: [.white.opacity(0.05), .white.opacity(0.4), .white.opacity(0.05)],
                                         startPoint: .top, endPoint: .bottom))
                    .frame(width: 2, height: 44)
                sharedScore(.top)
                newGameButton
            }
            .padding(.horizontal, 12)

            // The 121 track, with both players' loops and the skunk marks on it — the same overlay the
            // connected game draws, here framing the shared score.
            if trackEnabled {
                ScoreTrackOverlay(youFraction: loopFraction(game.score(.bottom)),
                                  youColor: playerTheme(colorID: nearColorID).primary,
                                  opponentFraction: loopFraction(game.score(.top)),
                                  opponentColor: playerTheme(colorID: farColorID).primary,
                                  cornerRadius: 26)
                    // Clear of the buttons at either end of the band, so the loop doesn't run through them.
                    .padding(.horizontal, 66)
                    .padding(.vertical, 4)
            }
        }
        // Tap it to turn it now rather than waiting for the timer.
        .contentShape(Rectangle())
        .onTapGesture {
            flipped.toggle()
            lastInteraction = Date()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(nearLabel) \(game.score(.bottom)), \(farLabel) \(game.score(.top))")
        .accessibilityHint("Turns to face each player in turn. Double tap to turn it now.")
    }

    @ViewBuilder private func sharedScore(_ side: BoardSide) -> some View {
        // Only the scores turn; the buttons either side of them stay put.
        let isNear = side == .bottom
        let theme = playerTheme(colorID: isNear ? nearColorID : farColorID)
        VStack(spacing: 0) {
            Text((isNear ? nearLabel : farLabel).uppercased())
                .font(.caption.weight(.heavy))
                .foregroundStyle(theme.primary)
                .lineLimit(1).minimumScaleFactor(0.6)
            Text("\(game.score(side))")
                .font(.system(size: 40, weight: .heavy, design: .rounded))
                .foregroundStyle(.white)
                .monospacedDigit()
                .contentTransition(.numericText(value: Double(game.score(side))))
        }
        .frame(maxWidth: .infinity)
        // Each score turns in place rather than the row turning as a whole: the pair keeps its
        // positions, and every number stays labelled with whose it is, so there's nothing to work out
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

    private var newGameButton: some View {
        Button {
            if game.hasProgress { confirmingNewGame = true } else { newGame() }
        } label: {
            Image(systemName: "arrow.counterclockwise")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white.opacity(0.7))
                .padding(9)
                .background(Circle().fill(Color.black.opacity(0.3)))
        }
        .padding(.top, 6).padding(.trailing, 10)
        .accessibilityLabel("New game")
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
        bottomPending = 0
        topPending = 0
        touch()
    }

    /// Note an interaction, so the shared score doesn't turn under someone's finger.
    private func touch() { lastInteraction = Date() }

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
            try? await Task.sleep(for: .seconds(Self.flipInterval))
            guard !Task.isCancelled, !game.isFinished else { continue }
            let busy = bottomPending > 0 || topPending > 0
                || Date().timeIntervalSince(lastInteraction) < Self.settleTime
            if busy { continue }
            flipped.toggle()
        }
    }
}

// MARK: - Name / colour sheet

/// `BoardSide` as a sheet item.
extension BoardSide: Identifiable {
    public var id: String { rawValue }
}

/// Rename a side, or change its colour, from the board itself — two people share this phone, so the
/// far player has to be able to put their own name on it without going through Settings.
private struct BoardPlayerSheet: View {
    let side: BoardSide
    @Binding var name: String
    @Binding var colorID: Int
    /// The near side's name and colour are the app-wide ones from Settings; the far side's belong to
    /// the board alone. Worth saying, so changing one here isn't a surprise elsewhere.
    let isShared: Bool
    var onDone: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                        .textInputAutocapitalization(.words)
                        .submitLabel(.done)
                } header: {
                    Text(side == .bottom ? "This side" : "Other side")
                } footer: {
                    Text(isShared
                         ? "This is your name from Settings — changing it here changes it everywhere."
                         : "Just for the board on this phone.")
                }

                Section("Colour") {
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
            }
            .navigationTitle("Player")
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
#endif
