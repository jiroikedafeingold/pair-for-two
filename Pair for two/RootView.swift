import SwiftUI
import GameKit

/// App entry. Two-phone play: set up your own name/color, then Play nearby (Multipeer) or Play
/// online (Game Center). Single-device pass-and-play was removed — this is a two-phone game.
struct RootView: View {
    private enum Screen { case menu, connect, rejoiningOnline, game, board }

    @State private var screen: Screen = .menu
    @State private var vm: GameViewModel?
    @State private var showingSettings = false
    @State private var resumeMarker: GamePersistence.ResumeMarker? = GamePersistence.loadMarker()
    @State private var resumeRole: ResumeRole? = nil
    @State private var gameCenter = GameCenterManager()
    @State private var showingInvite = false                  // custom "invite a friend" sheet
    @State private var pendingFallbackPicker = false          // present Apple's picker after the sheet closes
    @State private var activeMatchmaker: MatchmakerContext?   // Apple's matchmaking UI (fallback)
    @State private var wasBackgrounded = false                // distinguish a real background from a transient inactive
    @State private var showingHelp = false
    @State private var showingStats = false
    /// The live online transport, if the current game is an online one. Held so a Game Center match
    /// that arrives *during* a game (the other player re-inviting us after a drop) can be handed to it
    /// rather than starting a new game over the top of the one in progress.
    @State private var onlineTransport: GameCenterTransport?
    /// Online rejoin-after-force-quit bookkeeping: who we're waiting for, whether this device holds the
    /// saved position (and so does the inviting), and anything that went wrong worth telling them.
    @State private var rejoinOpponentName: String?
    @State private var rejoinIsHost = false
    @State private var rejoinFailure: String?
    /// Whether the board has a game part-way through, so the menu can offer to go back to it. Held in
    /// state rather than read per render — it's a file check.
    @State private var boardResumeAvailable = BoardGameStore.load() != nil
    @State private var showOnboarding = false
    /// The screen's width inside its evened-out safe areas — see `menuScales`.
    @Environment(\.balancedContentWidth) private var balancedContentWidth
    @Environment(\.windowSize) private var windowSize
    /// The open iPhone Duo held upright — the only phone that runs taller than wide. Its inner screen
    /// has regular size classes, so it gets the iPad's roomy menu, but only 669 points across.
    private var upright: Bool { isPhoneHardware && windowSize.height > windowSize.width }
    /// Width of a menu button's label, before scaling. Narrower on the upright Duo so the captions
    /// beside the buttons still fit.
    private var menuButtonWidth: CGFloat { roomy ? (upright ? 190 : 250) : 168 }
    @AppStorage("hasOnboarded") private var hasOnboarded = false
    @Environment(\.scenePhase) private var scenePhase
    /// Regular height means an iPad: room to center the menu on the screen and scale it up. A phone in
    /// landscape (compact) has barely enough height for the rows, so it stays top-aligned and compact.
    @Environment(\.verticalSizeClass) private var vSizeClass
    private var roomy: Bool { vSizeClass == .regular }

    @AppStorage("localName") private var name = "Player"
    @AppStorage("localColorID") private var colorID = 1
    @AppStorage("scoringMode") private var scoringModeRaw = ScoringMode.off.rawValue

    /// One menu button. Fixed width so the captions beside them line up into a column. `scale`
    /// multiplies every dimension — the menu is drawn at the largest scale that fits the screen
    /// (see `menu`), so four rows fill a landscape phone and a fifth row shrinks everything to fit.
    private func menuButton(_ title: Text,
                            systemImage: String,
                            tint: Color,
                            foreground: Color,
                            swatch: Color? = nil,
                            disabled: Bool = false,
                            scale: CGFloat = 1,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                // Every row's icon gets the same slot, so the labels beside them start on one line
                // however wide the symbol happens to be — "dot.radiowaves.left.and.right" is nearly
                // twice the width of "globe".
                Group {
                    if let swatch {
                        // Drawn as a symbol rather than a Circle so it takes its size and baseline
                        // from the same font as the other icons instead of a hardcoded diameter.
                        Image(systemName: "circle.fill")
                            .foregroundStyle(swatch)
                            .overlay(Image(systemName: "circle").foregroundStyle(.white.opacity(0.55)))
                    } else {
                        Image(systemName: systemImage)
                    }
                }
                .frame(width: (roomy ? 30 : 24) * scale)
                title.fontWeight(.bold)
                Spacer(minLength: 0)
            }
            // Sized in points rather than text styles so the fitting scale can multiply them —
            // 17/semibold and 20/regular are what .headline and .title3 resolve to.
            .font(.system(size: (roomy ? 20 : 17) * scale, weight: roomy ? .regular : .semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .frame(width: menuButtonWidth * scale, alignment: .leading)
            .padding(.horizontal, (roomy ? 22 : 16) * scale)
            .padding(.vertical, (roomy ? 16 : 7) * scale)
        }
        .buttonStyle(.borderedProminent)
        .tint(tint)
        .foregroundStyle(foreground)
        .disabled(disabled)
    }

    /// The right-hand column: what the button beside it actually does. Literals, so **bold** works.
    private func menuCaption(_ text: LocalizedStringKey, scale: CGFloat = 1) -> some View {
        captionStyle(Text(text), scale: scale)
    }

    /// Same, for a caption that comes from a value (an already-localized error message) rather than
    /// a literal.
    private func menuCaption(verbatim text: String, scale: CGFloat = 1) -> some View {
        captionStyle(Text(verbatim: text), scale: scale)
    }

    private func captionStyle(_ text: Text, scale: CGFloat) -> some View {
        text
            // 12 and 16 are .caption and .callout at the default Dynamic Type size.
            .font(.system(size: (roomy ? 16 : 12) * scale))
            .foregroundStyle(.white.opacity(0.62))
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: captionMaxWidth(scale: scale), alignment: .leading)
    }

    /// What to call the device in copy that points at it ("use the iPad as the board").
    ///
    /// Stand-in when a saved game doesn't record who it was against.
    private static var opponentStandIn: String {
        String(localized: "your opponent", comment: "Used in a sentence in place of an unknown player's name")
    }

    private var rejoinOpponentDisplayName: String { rejoinOpponentName ?? Self.opponentStandIn }

    /// Trimmed, non-empty player name. The fallback is localized; the stored default deliberately
    /// isn't, because onboarding compares against it before blanking it.
    private var playerName: String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? String(localized: "Player", comment: "Stand-in for your own name when you have not set one") : trimmed
    }

    var body: some View {
        content
            .task { gameCenter.authenticate() }   // Game Center sign-in for online play
            .task { if !hasOnboarded { showOnboarding = true } }   // first-run welcome
            .fullScreenCover(isPresented: $showOnboarding) {
                OnboardingView(onFinish: { hasOnboarded = true; showOnboarding = false })
                    .balancedHorizontalSafeArea()   // a cover doesn't inherit the root's balancing
            }
            .sheet(isPresented: $showingHelp) {
                HelpView(onDone: { showingHelp = false },
                         onReplayOnboarding: { showingHelp = false; showOnboarding = true })
            }
            .onChange(of: scenePhase) { _, phase in
                switch phase {
                case .active:
                    // After a real background the link is almost certainly dead but the OS may still
                    // report it connected — force a rebuild so we re-pair in seconds, not ~30s. A mere
                    // transient inactive (control center, a banner) does a plain, non-destructive nudge.
                    vm?.reconnect(force: wasBackgrounded)
                    vm?.resumeSearch()
                    wasBackgrounded = false
                case .background:
                    wasBackgrounded = true
                    vm?.persist()      // save the game if we're being closed
                case .inactive:
                    vm?.persist()
                @unknown default:
                    break
                }
            }
            // A match connected (a friend accepted our invite, or we accepted theirs) — start it with
            // the host role the manager elected once both players were actually connected.
            //
            // Unless a game is already running on this device: then the match is a *rejoin* of it (the
            // other phone dropped and re-invited us), so it's handed to the live transport instead.
            // Starting a new game here would throw away the position we're mid-way through.
            .onChange(of: gameCenter.matchTick) { _, _ in
                guard let ready = gameCenter.takePendingMatch() else { return }
                if screen == .game, let transport = onlineTransport {
                    transport.adopt(ready.match)
                } else if let marker = GamePersistence.loadMarker(), marker.isOnline {
                    // An online game was interrupted and still has a saved position, so a match
                    // arriving now *is* that game being picked back up — whatever screen we're on.
                    // Keying this off the marker rather than the rejoin screen matters: accepting the
                    // invitation can cold-launch the app, and starting a fresh game there would throw
                    // the saved position away. Explicitly starting a new online game clears the marker
                    // first (see the Play online button), so that case still lands below.
                    resumeOnlineGame(ready.match, marker: marker)
                } else {
                    startOnlineGame(ready.match, isHost: ready.isHost)
                }
            }
            // Custom "invite a friend" list. Tapping a friend sends a one-tap invite in place; the
            // "Invite with Game Center" button closes this sheet and opens Apple's picker (presented
            // only after dismissal completes, since SwiftUI can't present while dismissing).
            .sheet(isPresented: $showingInvite, onDismiss: {
                if pendingFallbackPicker { pendingFallbackPicker = false; presentApplePicker() }
            }) {
                InvitePlayersView(gameCenter: gameCenter,
                                  onUseGameCenterPicker: { pendingFallbackPicker = true; showingInvite = false },
                                  onCancel: { gameCenter.cancelInvite(); showingInvite = false })
            }
            .fullScreenCover(item: $activeMatchmaker) { context in
                MatchmakerView(controller: context.controller,
                               onMatch: { activeMatchmaker = nil; gameCenter.beginMatch($0) },
                               onCancel: { activeMatchmaker = nil },
                               onError: { error in activeMatchmaker = nil; gameCenter.report(error) })
                    .ignoresSafeArea()
            }
            .alert("Online play unavailable",
                   isPresented: Binding(get: { gameCenter.presentedError != nil },
                                        set: { if !$0 { gameCenter.presentedError = nil } })) {
                Button("OK", role: .cancel) { gameCenter.presentedError = nil }
            } message: {
                Text(verbatim: gameCenter.presentedError ?? "")
            }
    }

    // MARK: Online (Game Center) matchmaking

    private func presentApplePicker() {
        guard let controller = gameCenter.makeMatchmakerViewController() else { return }
        activeMatchmaker = MatchmakerContext(controller: controller)
    }

    // MARK: Rejoining an online game after a force-quit

    /// Pick an online game back up after the app was killed. Both matches are gone, so this is about
    /// finding the same Game Center player again and rebuilding around the saved state.
    ///
    /// Exactly one device holds the authoritative `GameState` (only a host ever writes it), and that's
    /// the device that invites: it has the position, so it decides who hosts, regardless of the
    /// gamePlayerID election a fresh match would use. The other device waits for the invitation —
    /// deterministic, and it can't produce two matches the way both sides inviting would.
    private func rejoinOnlineGame(_ marker: GamePersistence.ResumeMarker) {
        rejoinOpponentName = marker.opponentName
        rejoinIsHost = GamePersistence.hasSavedState
        rejoinFailure = nil
        screen = .rejoiningOnline

        guard rejoinIsHost else { return }   // guest: just wait for their invitation to arrive
        guard let id = marker.opponentGamePlayerID else {
            // Nothing to invite (a marker from before this existed). Let them pick from the list.
            rejoinFailure = String(localized: "Choose who to rejoin from your Game Center friends and recent players.",
                                   comment: "Shown when the saved opponent can't be identified")
            return
        }
        Task { @MainActor in
            if let player = await gameCenter.recentPlayer(withGamePlayerID: id) {
                gameCenter.invite(player)
            } else {
                rejoinFailure = String(localized: "Couldn't find \(marker.opponentName ?? Self.opponentStandIn) in Game Center. They may need to invite you instead — or pick them from your friends and recent players.",
                                       comment: "%@ is the other player's name, or a stand-in for it")
            }
        }
    }

    /// Pick the interrupted online game back up over a freshly rebuilt match. Whoever holds the saved
    /// `GameState` re-hosts it; the other device joins as a guest and gets resynced from it, exactly as
    /// a nearby resume does. Only one device can hold it — a guest's marker deletes any stale state
    /// file — so the roles can't collide.
    private func resumeOnlineGame(_ match: GKMatch, marker: GamePersistence.ResumeMarker) {
        showingInvite = false
        activeMatchmaker = nil
        resumeRole = nil
        let saved = GamePersistence.loadState()
        let transport = GameCenterTransport(match: match, isHost: saved != nil)
        onlineTransport = transport
        if let saved {
            vm = GameViewModel.resumeHost(transport: transport, savedState: saved,
                                          isOnline: true,
                                          onlineOpponentID: marker.opponentGamePlayerID,
                                          onlineOpponentName: marker.opponentName)
        } else {
            vm = GameViewModel.networked(transport: transport,
                                         localName: playerName, localColorID: colorID,
                                         scoringMode: ScoringMode.stored(scoringModeRaw),
                                         isOnline: true,
                                         onlineOpponentID: marker.opponentGamePlayerID,
                                         onlineOpponentName: marker.opponentName)
        }
        rejoinFailure = nil
        screen = .game
    }

    /// Build the online transport from a connected match (with the host role the manager already
    /// elected) and start a networked game.
    private func startOnlineGame(_ match: GKMatch, isHost: Bool) {
        showingInvite = false
        activeMatchmaker = nil
        // Starting an online game also forgets any in-progress nearby game.
        GamePersistence.clear()
        resumeMarker = nil
        let transport = GameCenterTransport(match: match, isHost: isHost)
        onlineTransport = transport   // kept so a rejoin can be handed to the running game
        resumeRole = nil
        let opponent = match.players.first
        vm = GameViewModel.networked(transport: transport,
                                     localName: playerName, localColorID: colorID,
                                     scoringMode: ScoringMode.stored(scoringModeRaw),
                                     isOnline: true,
                                     onlineOpponentID: opponent?.gamePlayerID,
                                     onlineOpponentName: opponent?.displayName)
        screen = .game
    }

    @ViewBuilder private var content: some View {
        switch screen {
        case .menu:
            menu

        case .connect:
            ConnectView(localName: playerName, localColorID: colorID, resumeRole: resumeRole,
                        resumeMatchID: resumeRole != nil ? GamePersistence.loadMarker()?.matchID : nil,
                        onConnected: { session in
                            // For a resume, the host is whichever phone actually holds the saved
                            // state — not the (possibly stale) role marker. This keeps the two phones
                            // from both trying to host after a rendezvous reconnect.
                            if resumeRole != nil, let saved = GamePersistence.loadState() {
                                session.isHost = true
                                vm = GameViewModel.resumeHost(transport: session, savedState: saved)
                            } else if resumeRole != nil {
                                session.isHost = false   // guest rejoining; the host resyncs it
                                vm = GameViewModel.networked(transport: session,
                                                             localName: playerName,
                                                             localColorID: colorID,
                                                             scoringMode: ScoringMode.stored(scoringModeRaw))
                            } else {
                                // Fresh game — isHost was already set by Host/Join. Starting a new game
                                // forgets any other in-progress game on this device (the new game writes
                                // its own resume marker as it plays).
                                GamePersistence.clear()
                                resumeMarker = nil
                                vm = GameViewModel.networked(transport: session,
                                                             localName: playerName,
                                                             localColorID: colorID,
                                                             scoringMode: ScoringMode.stored(scoringModeRaw))
                            }
                            screen = .game
                        },
                        onCancel: { screen = .menu })

        case .rejoiningOnline:
            onlineRejoinWaiting

        case .board:
            BoardView(onExit: {
                boardResumeAvailable = BoardGameStore.load() != nil
                screen = .menu
            })

        case .game:
            if let vm {
                GameTableView(vm: vm, onExit: {
                    self.vm?.close()   // release the radios; the saved game (if any) stays
                    self.vm = nil
                    onlineTransport = nil
                    resumeRole = nil
                    resumeMarker = nil    // the game was cleared on quit — no "Rejoin" to offer
                    screen = .menu
                })
            } else {
                Color.feltDark.ignoresSafeArea()
            }
        }
    }

    /// Waiting to pick a force-quit online game back up. Which side you're on decides what happens:
    /// the device holding the saved position invites, the other waits to be invited — so this screen
    /// mostly exists to say which of those is going on, since GameKit needs a human to accept.
    private var onlineRejoinWaiting: some View {
        ZStack {
            FeltSurface()
                .ignoresSafeArea()

            VStack(spacing: 16) {
                Text("Rejoining your game")
                    .font(.system(size: 30, weight: .heavy, design: .serif))
                    .foregroundStyle(.white)

                if rejoinFailure == nil {
                    ProgressView().tint(.white).controlSize(.large)
                    Group {
                        if rejoinIsHost {
                            Text("Inviting \(rejoinOpponentDisplayName) back…",
                                 comment: "%@ is the other player's name, or a stand-in for it")
                        } else {
                            Text("Waiting for \(rejoinOpponentDisplayName) to invite you back…",
                                 comment: "%@ is the other player's name, or a stand-in for it")
                        }
                    }
                        .font(.headline).foregroundStyle(.white)
                    Group {
                        if rejoinIsHost {
                            Text("They'll get a Game Center invitation — they need to accept it to pick the game up where you left off.",
                                 comment: "Explains what the other player has to do")
                        } else {
                            Text("This phone has the invitation coming to it. Ask them to open Pair for Two and tap Rejoin online game.",
                                 comment: "Explains what the other player has to do; the app name is a brand")
                        }
                    }
                        .font(.caption).foregroundStyle(.white.opacity(0.7))
                        .multilineTextAlignment(.center).frame(maxWidth: 420)
                } else {
                    Text(verbatim: rejoinFailure ?? "")
                        .font(.callout).foregroundStyle(Color.cribGold)
                        .multilineTextAlignment(.center).frame(maxWidth: 420)
                    Button("Choose from Game Center") {
                        rejoinFailure = nil
                        showingInvite = true
                    }
                    .buttonStyle(.borderedProminent).tint(.cribGold).foregroundStyle(.black)
                }

                Group {
                    if rejoinIsHost {
                        Text("The position is safe on this phone — it's kept until the game is finished or you start a new one.",
                             comment: "Reassurance on the rejoin screen when this device holds the game")
                    } else {
                        Text("The position is safe on their phone — it's kept until the game is finished or you start a new one.",
                             comment: "Reassurance on the rejoin screen when the other device holds the game")
                    }
                }
                    .font(.caption2).foregroundStyle(.white.opacity(0.5))
                    .multilineTextAlignment(.center).frame(maxWidth: 420)

                Button("Back to menu") {
                    gameCenter.cancelInvite()
                    rejoinFailure = nil
                    screen = .menu
                }
                .buttonStyle(.bordered).tint(.white)
                .padding(.top, 4)
            }
            .padding(28)
        }
    }

    /// "Pair for Two" over its line of explanation. Two layouts rather than one that bends: an iPad
    /// stacks them with the title big, a phone in landscape puts them on a single line, because there
    /// the height belongs to the buttons — with a "Rejoin game" row there are five of them.
    @ViewBuilder private func masthead(scale: CGFloat) -> some View {
        if roomy {
            VStack(spacing: 2) {
                embossedTitle(size: 46 * scale)
                Text("Two-phone cribbage")
                    .font(.system(size: 20 * scale)).foregroundStyle(Color.cribGold)
            }
            .padding(.bottom, 2)
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 9) {
                embossedTitle(size: 27 * scale)
                Text("Two-phone cribbage")
                    .font(.system(size: 13 * scale, weight: .semibold)).foregroundStyle(Color.cribGold)
            }
            .lineLimit(1)
            .minimumScaleFactor(0.65)      // a longer translation shrinks rather than wraps
        }
    }

    /// Letterpress: a top-lit fill, a dark edge dropped below the glyphs and a faint highlight above,
    /// so the title reads as pressed into the felt rather than printed on it. Kept subtle — at this
    /// size a heavy bevel would look like a sticker.
    private func embossedTitle(size: CGFloat) -> some View {
        Text("Pair for Two")
            .font(.system(size: size, weight: .heavy, design: .serif))
            .foregroundStyle(
                LinearGradient(colors: [.white, Color(white: 0.78)],
                               startPoint: .top, endPoint: .bottom)
            )
            .shadow(color: .black.opacity(0.7), radius: 1, x: 0, y: size * 0.055)
            .shadow(color: .white.opacity(0.25), radius: 0.5, x: 0, y: -size * 0.03)
    }

    /// The scales the menu is offered at, biggest first. `ViewThatFits` keeps the first that fits the
    /// height, so four rows draw large enough to fill a landscape phone, a fifth (Rejoin) drops the
    /// menu a size or two, and a long translation that wraps its captions does the same. 1 — today's
    /// layout — is the floor, with a scrolling copy behind it as the safety net.
    ///
    /// `ViewThatFits` doesn't notice a menu that's too *wide*: the fixed-width button column just pushes
    /// the grid past the screen's edge. Both iPhone Duo screens are narrow enough for that — the cover
    /// screen, and the inner one held upright — so on a phone the scales are also limited by width:
    /// the button and its padding, the column gap, the narrowest a caption gets before it wraps word
    /// by word (about 150 points at the phone's caption size, 200 at the roomy one), all times the
    /// scale, plus the menu's side padding. Every other iPhone has room for the largest scale (637
    /// points), so for them this changes nothing.
    private var menuScales: [CGFloat] {
        let scales: [CGFloat] = roomy ? [1.4, 1.25, 1.1, 1.0] : [1.6, 1.45, 1.3, 1.15, 1.0]
        guard let width = narrowMenuWidth else { return scales }
        return scales.filter { (menuButtonColumn + (roomy ? 200 : 150)) * $0 + 48 + 24 <= width }
    }

    /// The menu's width on the two Duo screens that can't fit it at full size: the cover screen
    /// (between its evened-out safe areas) and the inner screen held upright. Nil everywhere else.
    private var narrowMenuWidth: CGFloat? {
        guard isPhoneHardware else { return nil }
        return upright ? windowSize.width : balancedContentWidth
    }

    /// A button with its padding plus the gap to its caption, before scaling. (The 48s and 24s beside
    /// it are the menu's side padding and the bordered button style's own, which don't scale.)
    private var menuButtonColumn: CGFloat { roomy ? menuButtonWidth + 44 + 26 : menuButtonWidth + 32 + 18 }

    /// The widest a caption may be at `scale`. The grid otherwise sizes the caption column to its own
    /// liking rather than to what's left beside the buttons, so on a narrow screen it's capped at that.
    private func captionMaxWidth(scale: CGFloat) -> CGFloat {
        let preferred = (roomy ? 480 : 400) * scale
        guard let width = narrowMenuWidth else { return preferred }
        return min(preferred, width - 48 - 24 - menuButtonColumn * scale)
    }

    private var menu: some View {
        ZStack {
            FeltSurface()
                .ignoresSafeArea()

            ViewThatFits(in: .vertical) {
                ForEach(menuScales, id: \.self) { menuContent(scale: $0) }
                ScrollView { menuContent(scale: 1) }
                    .scrollBounceBehavior(.basedOnSize)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)   // center whichever size won
        }
        .overlay(alignment: .topTrailing) {
            menuChrome
        }
        .onAppear {
            resumeMarker = GamePersistence.loadMarker()
            boardResumeAvailable = BoardGameStore.load() != nil
        }
        .sheet(isPresented: $showingStats) {
            StatsView(onDone: { showingStats = false })
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView(onDone: { showingSettings = false })
        }
    }

    /// The whole menu at one scale — intrinsically sized, so `ViewThatFits` can judge it honestly.
    /// One row per thing you can do: the control on the left, what it does on the right. The
    /// buttons alone weren't self-explanatory — "Play nearby" versus "Play online" versus a
    /// scoreboard is a real choice, and the answer shouldn't be buried in the help.
    private func menuContent(scale: CGFloat) -> some View {
                VStack(spacing: (roomy ? 26 : 10) * scale) {
                    masthead(scale: scale)

                    Grid(alignment: .leading, horizontalSpacing: (roomy ? 26 : 18) * scale,
                         verticalSpacing: (roomy ? 16 : 7) * scale) {
                        GridRow {
                            menuButton(Text(verbatim: playerName), systemImage: "person.crop.circle",
                                       tint: Color.white.opacity(0.18), foreground: .white,
                                       swatch: playerTheme(colorID: colorID).primary, scale: scale) {
                                showingSettings = true
                            }
                            menuCaption("Your name, color and all the app's settings. Tap to edit.",
                                        scale: scale)
                        }

                        if let resumeMarker {
                            GridRow {
                                menuButton(resumeMarker.isOnline
                                           ? Text("Rejoin online", comment: "Menu: pick up an interrupted online game")
                                           : Text("Rejoin game", comment: "Menu: pick up an interrupted nearby game"),
                                           systemImage: resumeMarker.isOnline ? "globe" : "arrow.clockwise.circle.fill",
                                           tint: .cribGold, foreground: .black,
                                           disabled: resumeMarker.isOnline && !gameCenter.isAuthenticated,
                                           scale: scale) {
                                    if resumeMarker.isOnline {
                                        rejoinOnlineGame(resumeMarker)
                                    } else {
                                        resumeRole = resumeMarker.isHost ? .host : .guest
                                        screen = .connect
                                    }
                                }
                                menuCaption(resumeMarker.isOnline
                                            ? "Pick up the game **\(resumeMarker.summary)** — we'll invite them back."
                                            : "Pick up the game **\(resumeMarker.summary)** — both phones tap this.",
                                            scale: scale)
                            }
                        }

                        GridRow {
                            menuButton(resumeMarker == nil
                                       ? Text("Play nearby", comment: "Menu: start a game with a device in the room")
                                       : Text("New nearby", comment: "Menu: start a fresh nearby game, discarding the saved one"),
                                       systemImage: "dot.radiowaves.left.and.right",
                                       tint: resumeMarker == nil ? .cribGold : Color.white.opacity(0.18),
                                       foreground: resumeMarker == nil ? .black : .white, scale: scale) {
                                resumeRole = nil
                                GamePersistence.clear()   // fresh game supersedes any saved one
                                resumeMarker = nil
                                screen = .connect
                            }
                            menuCaption("Two phones in the same room, a hand each. No internet or account — leave Wi-Fi on and it pairs faster.",
                                        scale: scale)
                        }

                        GridRow {
                            menuButton(resumeMarker?.isOnline == true
                                       ? Text("New online", comment: "Menu: start a fresh online game, discarding the saved one")
                                       : Text("Play online", comment: "Menu: start a game over Game Center"),
                                       systemImage: "globe",
                                       tint: Color.white.opacity(0.18), foreground: .white,
                                       disabled: !gameCenter.isAuthenticated, scale: scale) {
                                // Asking for a new online game supersedes any saved one, exactly like the
                                // nearby button. It also has to clear the marker *before* a match arrives:
                                // an online marker is what tells the match handler "this is a rejoin", so
                                // leaving it would resume the old game instead of starting this one.
                                GamePersistence.clear()
                                resumeMarker = nil
                                showingInvite = true
                            }
                            if gameCenter.isAuthenticated {
                                menuCaption("Invite a Game Center friend, wherever they are. A hand each, same as nearby.",
                                            scale: scale)
                            } else {
                                menuCaption(verbatim: gameCenter.unavailableReason
                                            ?? "Sign in to Game Center to play online.", scale: scale)
                            }
                        }

                        GridRow {
                            // The board on its own: one device between two players, real cards in hand.
                            // Not the pass-and-play mode that was removed — nothing is dealt here.
                            menuButton(Text("Scoreboard", comment: "Menu: use the device as a cribbage board"), systemImage: "rectangle.split.2x1",
                                       tint: Color.white.opacity(0.18), foreground: .white, scale: scale) {
                                screen = .board
                            }
                            menuCaption(boardResumeAvailable
                                        ? "Game in progress. Real cards, this \(deviceWord()) between you as the board."
                                        : "Playing with real cards? Lay this \(deviceWord()) between you and it keeps score.",
                                        scale: scale)
                        }
                    }
                    .frame(maxWidth: (roomy ? 820 : 660) * scale)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, roomy ? 14 : 6)
    }

    /// The stats/help buttons in the top corner. Unscaled on purpose: chrome, not menu.
    private var menuChrome: some View {
            HStack(spacing: 14) {
                Button { showingStats = true } label: {
                    Image(systemName: "chart.bar.fill")
                        .font(.system(size: 21, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.85))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Stats and game history")

                Button { showingHelp = true } label: {
                    Image(systemName: "questionmark.circle.fill")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.85))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("How to play")
            }
            .padding(.top, 8).padding(.trailing, 14)
    }

}

#Preview("Menu", traits: .landscapeLeft) {
    RootView()
}

#if DEBUG
/// The tight case: a saved game adds a fifth row, and all of it still has to be on screen at once on
/// a phone in landscape. Writes a marker to the real store, like the stats preview does, and marks
/// onboarding as seen — otherwise the first-run welcome covers the very thing being checked.
#Preview("Menu — with a saved game", traits: .landscapeLeft) {
    UserDefaults.standard.set(true, forKey: "hasOnboarded")
    UserDefaults.standard.set("Ann", forKey: "localName")
    GamePersistence.saveMarker(isHost: true, summary: "Ann 41 · Ben 33",
                               online: false, opponentGamePlayerID: nil, opponentName: "Ben")
    var board = BoardGame()          // so the scoreboard row shows its in-progress caption too
    board.add(37, to: .bottom)
    board.add(24, to: .top)
    BoardGameStore.save(board)
    return RootView()
}
#endif
