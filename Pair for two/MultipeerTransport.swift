import Foundation
import Observation
import MultipeerConnectivity

/// In-person transport over MultipeerConnectivity (Bluetooth + peer-to-peer Wi-Fi, no internet, no
/// accounts). Also drives the connect UI: it is `@Observable`, exposing discovered peers and the
/// connection phase so `ConnectView` can render host/join without a UIKit browser controller.
///
/// The advertiser (host) auto-accepts the first invitation; the browser (guest) invites a tapped
/// peer. Once connected, `events` carries `.connected` / `.disconnected` / `.received(GameMessage)`
/// exactly like `LoopbackTransport`, so `GameViewModel` is transport-agnostic.
@MainActor
@Observable
final class MultipeerSession: NSObject, NearbyTransport {

    enum Phase: Sendable { case idle, hosting, browsing, connecting, connected, reconnecting, disconnected }

    var isHost: Bool = false
    let linkKind: LinkKind = .direct
    private(set) var phase: Phase = .idle
    private(set) var discoveredPeers: [MCPeerID] = []
    /// Set when iOS refused to start browsing or advertising at all. Denied Local Network access is the
    /// usual reason — and the one worth telling the player about, because nothing else in the app can
    /// hint at it: both radios look fine and the screen just searches forever.
    private(set) var searchBlocked = false
    private(set) var connectedPeerName: String?
    /// When something last arrived from the peer. `MCSession.connectedPeers` keeps listing a peer for
    /// its whole keep-alive window after the other app is suspended, and a `send` to that ghost
    /// succeeds locally, so traffic is the only honest evidence the link is alive.
    nonisolated(unsafe) private var lastInboundAt = Date()
    /// Silence longer than this and we stop believing `connectedPeers`.
    private static let inboundSilenceLimit: TimeInterval = 6
    private var didConnect = false   // once true, a drop triggers auto-rejoin rather than a plain disconnect
    private var recovering = false   // a reconnect is under way; further nudges shouldn't restart it
    private var rendezvousActive = false   // a "Rejoin" is in progress: keep retrying discovery+invite until connected
    private var rendezvousTask: Task<Void, Never>?
    /// Stamps each pairing-retry loop, so one clearing its handle on the way out can't clear a
    /// successor's — `cancel()` is asynchronous, so a cancelled loop can still be winding down after
    /// the next one has started.
    private var pairingGeneration = 0

    nonisolated let events: AsyncStream<TransportEvent>
    nonisolated private let continuation: AsyncStream<TransportEvent>.Continuation

    private let serviceType = "pairfortwo"     // Bonjour: _pairfortwo._tcp

    /// `.optional`, not `.required`: requiring encryption measurably lengthens the handshake, and it is
    /// slowest exactly where pairing already struggles — two phones with no network, negotiating over
    /// Bluetooth. What's on the wire is a cribbage position: two display names, a color choice, and
    /// which cards have been played. `.optional` still encrypts whenever the peer asks for it, so a
    /// phone on 1.9 or earlier (which required it) pairs with a 2.0 phone exactly as before.
    private static let encryption: MCEncryptionPreference = .optional
    // Confined to the main actor: it's reassigned on reconnect/rebuild, so any off-actor read while
    // it's being swapped is a data race (crashes in objc_retain). All access hops to the main actor.
    private var session: MCSession
    nonisolated(unsafe) private let myPeerID: MCPeerID
    private var advertiser: MCNearbyServiceAdvertiser?
    private var browser: MCNearbyServiceBrowser?

    // MARK: Pacing
    //
    // Everything below exists because MultipeerConnectivity punishes impatience, and it punishes it
    // hardest exactly where it hurts most: two phones with no Wi-Fi network, pairing over Bluetooth
    // (or over AWDL with the Wi-Fi radio on but unjoined). A handshake there routinely takes longer
    // than a few seconds, so retrying "quickly" produced overlapping invitations, sessions rebuilt
    // out from under an in-flight invite, and a browser restarted before discovery could finish.
    //
    // And impatience isn't the only way to get stuck: an invitation can go out and never come back at
    // all — no `.connected`, no `.notConnected`, nothing to drive recovery from. `discardDiscoveries`
    // and the stalled-invite branch of the retry loop are what get us out of that.

    /// One invitation at a time. A second invite to the same peer while the first is still open makes
    /// MC fail *both*, which reads as "it just won't connect".
    private var pendingInviteAt: Date?
    /// When MC reported `.connecting` for the invitation in flight, i.e. the peer answered and a
    /// handshake is genuinely under way. Nil means nobody has answered yet.
    private var handshakeStartedAt: Date?
    /// Generous on purpose: the old 10s was shorter than a cold Bluetooth-only handshake, so the
    /// first attempt timed out even when the peers could see each other perfectly well.
    private static let inviteTimeout: TimeInterval = 20
    /// But that generosity is for a *slow handshake*, not for an invitation nobody answered — and
    /// those are what a reconnect runs into, because the peer's advertiser may not be up yet. MC says
    /// `.connecting` the moment the other side accepts, so its silence tells the two apart: with no
    /// answer at all there is nothing to wait for, and waiting the full 20s just delays the next try.
    private static let unansweredInviteTimeout: TimeInterval = 8
    /// How long the invitation in flight gets before it counts as gone.
    private var currentInviteTimeout: TimeInterval {
        handshakeStartedAt == nil ? Self.unansweredInviteTimeout : Self.inviteTimeout
    }
    /// A failed invite leaves MCSession unusable, so recovery rebuilds it — but rebuilding on every
    /// failure thrashes. Rebuild at most this often.
    private var lastRebuildAt: Date?
    private static let minRebuildInterval: TimeInterval = 4
    /// Restarting the advertiser/browser restarts discovery from scratch. Doing that every couple of
    /// seconds means discovery never completes on Bluetooth; leave it alone for at least this long.
    private var lastDiscoveryRestartAt: Date?
    private static let minDiscoveryRestartInterval: TimeInterval = 9
    /// How many times a tapped invitation may fail before the connect screen goes terminal. Each
    /// retry rebuilds the session first, which is what makes retrying worth anything.
    private var failedInviteCount = 0
    private static let maxInviteAttempts = 4

    /// When we first declined to invite a discovered peer because the election said the other side
    /// should. See the retry loop: that deferral cannot be open-ended.
    private var deferredToPeerSince: Date?
    /// How long to leave the invitation to the peer the election picked before sending one anyway.
    private static let electionGrace: TimeInterval = 5

    /// Tiebreaker for `shouldInvite` when both phones show the same display name — which is the
    /// default case, since everyone starts out called "Player". Advertised in `discoveryInfo` and
    /// read back from the browser, so exactly one side invites even then.
    private let launchToken = String(UUID().uuidString.prefix(8))
    private var peerTokens: [String: String] = [:]   // display name → their launch token
    /// Which game this session is for (`GameState.matchID`), when it is known: sent with every
    /// invitation and checked against every invitation received.
    ///
    /// Advertising now runs for the whole game so a suspended partner can be found again the moment it
    /// returns — which also means an in-game phone can be *invited* by anything nearby, where before it
    /// couldn't even be seen. A live link is protected by the staleness check, but two interrupted
    /// games in one room were not: a phone rejoining game A could have been answered by a stale phone
    /// from game B, leaving both pairs joined to the wrong partner and neither game working. Matching
    /// the token keeps each rejoin inside its own game.
    private var matchToken: String?

    func setMatchToken(_ token: String?) { matchToken = token }

    /// Display names of peers whose advertisement says they are mid-game — see `makeAdvertiser`.
    private var inGamePeers: Set<String> = []
    /// Display names of peers whose advertisement says they are *looking to pair*, as opposed to
    /// merely staying findable through a game. Only these take part in the inviter election.
    private var pairingPeers: Set<String> = []

    /// The peers a player may actually join: everyone advertising who isn't already in a game.
    ///
    /// An in-game advertisement isn't an offer. It exists so the phone's *own* partner can find it
    /// again after a suspend, and putting it in a stranger's join list would only offer a row that
    /// declines them (see the advertiser delegate). Rejoining and reconnecting read the unfiltered
    /// `discoveredPeers`, which is the whole point.
    var joinablePeers: [MCPeerID] {
        discoveredPeers.filter { !inGamePeers.contains($0.displayName) }
    }

    init(displayName: String) {
        let trimmed = displayName.trimmingCharacters(in: .whitespaces)
        let name = String((trimmed.isEmpty ? String(localized: "Player", comment: "Fallback name shown to the other device when you have not set one") : trimmed).prefix(60))
        myPeerID = MCPeerID(displayName: name)
        session = MCSession(peer: myPeerID, securityIdentity: nil, encryptionPreference: Self.encryption)
        var captured: AsyncStream<TransportEvent>.Continuation!
        events = AsyncStream(bufferingPolicy: .unbounded) { captured = $0 }
        continuation = captured
        super.init()
        session.delegate = self
    }

    // MARK: Connect lifecycle

    func startHosting() {
        isHost = true
        phase = .hosting
        failedInviteCount = 0      // a fresh, player-initiated attempt gets the full retry budget
        startRole()
    }

    func startBrowsing() {
        isHost = false
        phase = .browsing
        failedInviteCount = 0
        startRole()
    }

    /// Rejoin a saved game without relying on the stored host/guest role: advertise *and* browse at
    /// once, so two phones both tapping "Rejoin" always discover each other. Whichever one holds the
    /// saved state becomes the host (decided by the caller). This avoids the deadlock where both
    /// markers say "host", so both would only advertise and never find each other.
    func startRendezvous() {
        rendezvousActive = true
        phase = .connecting
        startBoth()
        startPairingRetry()
    }

    /// True while we are actively trying to pair: a "Rejoin", an in-game reconnect, or a first
    /// connection whose invite is still being worked on.
    private var isPairing: Bool {
        rendezvousActive || phase == .reconnecting || phase == .connecting
    }

    /// Keep trying to pair while a first connect, a "Rejoin", or an in-game reconnect is in progress.
    /// The first invite can mistime (the other phone's advertiser may not be up yet — e.g. it
    /// foregrounded a moment later); rather than giving up until MultipeerConnectivity happens to
    /// re-discover (slow), the inviting peer tries again, and if nothing has been discovered at all we
    /// refresh discovery. Runs until connected (or the screen is dismissed).
    ///
    /// The waiting is the important part. An invitation gets `inviteTimeout` to resolve before another
    /// is sent, and discovery is left alone for `minDiscoveryRestartInterval` — without both of those
    /// this loop fought MultipeerConnectivity instead of driving it.
    ///
    /// Idempotent, and it clears its own handle on the way out, because `invite` asks for follow-up on
    /// every invitation — including the ones this loop sends itself. Cancelling and replacing the task
    /// from inside it would leave the old one spinning: `try? await Task.sleep` swallows the
    /// cancellation, so it would loop without ever sleeping again.
    private func startPairingRetry() {
        guard rendezvousTask == nil else { return }   // one loop is enough; it re-reads the state anyway
        pairingGeneration += 1
        let generation = pairingGeneration
        rendezvousTask = Task { @MainActor [weak self] in
            defer {
                if let self, self.pairingGeneration == generation {
                    self.rendezvousTask = nil
                    // `recovering` exists to stop every failed heartbeat restarting recovery while
                    // this loop is working. Once the loop is gone it would only block the next
                    // attempt — `reconnect` returns early on it — so leaving it set bricks recovery.
                    if self.session.connectedPeers.isEmpty { self.recovering = false }
                }
            }
            while true {
                try? await Task.sleep(for: .seconds(2))
                if Task.isCancelled { return }
                guard let self, self.isPairing, self.session.connectedPeers.isEmpty else { return }
                if self.inviteInFlight { continue }                     // give the open invite its time
                // An invitation that timed out *without MC saying so*. That happens — a peer whose
                // advertiser has gone, or an MCPeerID that outlived the browser that found it, gets no
                // delegate callback at all, so `handleDrop` (which is what normally rebuilds the
                // session and stands discovery back up) never runs. Do that work here instead;
                // otherwise the loop re-invites the same dead peer every 20 seconds, forever.
                if self.inviteWentQuiet {
                    self.pendingInviteAt = nil
                    self.rebuildSession(force: true)
                    if self.symmetricPairing { self.startBoth(force: true) } else { self.startRole() }
                    continue
                }
                if let peer = self.discoveredPeers.last(where: { self.shouldInvite($0) }) {
                    self.invite(peer)
                } else if let peer = self.discoveredPeers.last {
                    // Found the peer, but the election says it invites us. That holds only while the
                    // other phone is *also* trying to pair — and in the case that matters most it
                    // isn't: a phone whose partner switched apps carries on believing the link is
                    // live until MC's own keep-alive expires, so it isn't inviting anyone. Deferring
                    // to it forever is the deadlock, and the loop won't refresh discovery either
                    // because the peer list isn't empty. Wait out the grace period, then invite
                    // regardless. Two invitations crossing is the risk; both sides silent is worse,
                    // and by then the elected inviter has had its chance.
                    if let since = self.deferredToPeerSince {
                        if Date().timeIntervalSince(since) >= Self.electionGrace {
                            self.deferredToPeerSince = nil
                            self.invite(peer)
                        }
                    } else {
                        self.deferredToPeerSince = Date()
                    }
                } else {
                    self.deferredToPeerSince = nil
                    self.refreshDiscovery()   // no one found yet (rate-limited)
                }
            }
        }
    }

    /// Whether an invitation is still within its timeout, and so should be left to resolve.
    private var inviteInFlight: Bool {
        guard let sent = pendingInviteAt else { return false }
        return Date().timeIntervalSince(sent) < currentInviteTimeout
    }

    /// An invitation that outlived its timeout with MC never reporting anything, either way. Derived
    /// from the same timestamp rather than latched, so it can't outlive the invitation it describes:
    /// whatever clears `pendingInviteAt` — connecting, a reported failure, a session rebuild, a fresh
    /// invite — clears this with it.
    private var inviteWentQuiet: Bool {
        guard let sent = pendingInviteAt else { return false }
        return Date().timeIntervalSince(sent) >= currentInviteTimeout
    }

    /// (Re)create and start the advertiser (host) or browser (guest). Fresh instances are used so a
    /// resume-after-background reliably re-advertises/re-browses.
    private func startRole() {
        lastDiscoveryRestartAt = Date()
        if isHost {
            browser?.stopBrowsingForPeers(); browser = nil
            discardDiscoveries()
            advertiser?.stopAdvertisingPeer()
            advertiser = makeAdvertiser()
        } else {
            advertiser?.stopAdvertisingPeer(); advertiser = nil
            browser?.stopBrowsingForPeers()
            browser = makeBrowser()
        }
    }

    /// Advertise and browse simultaneously (fresh instances). Used for rendezvous and reconnect so
    /// discovery works regardless of which side each phone believes it is.
    ///
    /// Rate-limited: callers hit this from the retry loop and from every drop, and tearing discovery
    /// down and standing it back up resets whatever progress Bluetooth had made. If it was refreshed
    /// recently, leave the running instances alone — they are still looking.
    private func startBoth(force: Bool = false) {
        if !force, let last = lastDiscoveryRestartAt,
           Date().timeIntervalSince(last) < Self.minDiscoveryRestartInterval { return }
        lastDiscoveryRestartAt = Date()
        advertiser?.stopAdvertisingPeer()
        browser?.stopBrowsingForPeers()
        advertiser = makeAdvertiser()
        browser = makeBrowser()
    }

    /// Nothing found yet — stand discovery back up, rate-limited.
    ///
    /// Only the **browser** is replaced. Browsing is what has failed to turn anything up; the
    /// advertiser is the half a peer needs in order to invite *us*, and tearing it down and standing
    /// it back up every few seconds is a good way to make an inbound invitation land on an advertiser
    /// that no longer exists — the other phone then waits out its own invite timeout for nothing.
    /// (The advertiser does get replaced when recovery starts, in `startBoth`, which is where a
    /// resume-after-background needs it.) A plain join has no advertiser to keep.
    private func refreshDiscovery() {
        if let last = lastDiscoveryRestartAt,
           Date().timeIntervalSince(last) < Self.minDiscoveryRestartInterval { return }
        // If a half that should be running isn't, this is a start rather than a refresh.
        if browser == nil || (symmetricPairing && advertiser == nil) {
            startBoth(force: true)
            return
        }
        lastDiscoveryRestartAt = Date()
        browser?.stopBrowsingForPeers()
        browser = makeBrowser()
    }

    /// Whether this phone is advertising in order to be *rejoined* rather than joined: it is in a
    /// game, or picking one back up.
    private var advertisingInGame: Bool { didConnect || rendezvousActive }

    /// The advertisement carries `launchToken` so the other side can break a display-name tie — see
    /// `shouldInvite` — and, once there's a game on, a flag saying so.
    ///
    /// `discoveryInfo` is fixed when the advertiser is built, which is why the advertiser is rebuilt
    /// rather than left running whenever that flag changes.
    private func makeAdvertiser() -> MCNearbyServiceAdvertiser {
        var info = ["t": launchToken]
        if advertisingInGame { info["g"] = "1" }
        // "I am trying to pair", distinct from "I am in a game": a phone mid-game advertises to be
        // findable and will not invite anyone, so the other side must not wait for it to. See
        // `shouldInvite`.
        if isPairing { info["p"] = "1" }
        let adv = MCNearbyServiceAdvertiser(peer: myPeerID,
                                            discoveryInfo: info,
                                            serviceType: serviceType)
        adv.delegate = self
        adv.startAdvertisingPeer()
        return adv
    }

    /// A fresh browser starts with an empty peer list, so ours has to as well — see
    /// `discardDiscoveries`.
    private func makeBrowser() -> MCNearbyServiceBrowser {
        discardDiscoveries()
        let br = MCNearbyServiceBrowser(peer: myPeerID, serviceType: serviceType)
        br.delegate = self
        br.startBrowsingForPeers()
        return br
    }

    /// Forget every discovered peer, because the browser that found them is gone.
    ///
    /// **An `MCPeerID` is only invitable through the browser that discovered it.** That browser holds
    /// the connection data behind the peer; invite the same ID through a replacement and MC has nothing
    /// to dial, so the invitation goes nowhere *silently* — no `.connecting`, no `.notConnected`, no
    /// callback of any kind. The retry loop then sat out the full invite timeout against a peer that
    /// could never answer, and since discovery is only refreshed when the list is empty, a stale entry
    /// kept the list looking healthy and the loop kept picking it. That is the shape of "it sometimes
    /// just won't connect": everything looks busy and nothing can ever complete.
    ///
    /// Any invitation in flight belonged to the old browser too, so it goes with them.
    private func discardDiscoveries() {
        discoveredPeers.removeAll()
        peerTokens.removeAll()
        inGamePeers.removeAll()
        pairingPeers.removeAll()
        pendingInviteAt = nil
        handshakeStartedAt = nil
        deferredToPeerSince = nil
    }

    func invite(_ peer: MCPeerID) {
        guard !inviteInFlight else { return }   // never two open invitations — MC fails both
        phase = .connecting
        pendingInviteAt = Date()
        handshakeStartedAt = nil
        deferredToPeerSince = nil
        browser?.invitePeer(peer, to: session,
                            withContext: matchToken?.data(using: .utf8),
                            timeout: Self.inviteTimeout)
        // Follow it up. This is also the path a tap on the join list takes, and a tap used to be a
        // one-shot: if MC answered with a failure we recovered in `handleDrop`, but if it never
        // answered at all the screen spun forever with nothing behind it. `isPairing` is true now that
        // the phase is `.connecting`, so the loop stays alive until we're paired or the player leaves.
        startPairingRetry()
    }

    /// Nothing has arrived from the peer for a while, so `connectedPeers` listing it means little.
    private var linkLooksStale: Bool {
        Date().timeIntervalSince(lastInboundAt) > Self.inboundSilenceLimit
    }

    /// Whether both phones are browsing, so the inviter has to be elected: a rendezvous ("Rejoin" on
    /// both sides) or an in-game reconnect. A plain Host/Join is asymmetric — only the guest browses,
    /// so only the guest can invite and there is nothing to elect.
    private var symmetricPairing: Bool { rendezvousActive || phase == .reconnecting }

    /// Who sends the invitation. When both sides browse, only one may or they race two half-open
    /// connections; the peer with the lexicographically smaller name invites and the other
    /// auto-accepts.
    ///
    /// Names tie constantly in practice — the default name is "Player", so two fresh installs are both
    /// "Player" — and the old rule (`<=`) then had *both* sides inviting, which is the very race it
    /// exists to prevent. The advertised launch token breaks the tie.
    private func shouldInvite(_ peer: MCPeerID) -> Bool {
        // Plain Host/Join: the browser always invites. Electing by name here would be a deadlock —
        // whenever the guest's name sorted after the host's, nobody would ever send an invitation.
        guard symmetricPairing else { return !isHost }
        let mine = myPeerID.displayName, theirs = peer.displayName
        // Only elect between phones that are *both* pairing. One that is merely advertising its way
        // through a game — the partner who never noticed the link die — is not going to invite
        // anybody, and deferring to it is the deadlock the grace period in the retry loop exists to
        // break. Its advertisement says so, so there's no need to wait out the grace at all.
        if !pairingPeers.contains(theirs) { return true }
        if mine != theirs { return mine < theirs }
        guard let theirToken = peerTokens[theirs] else { return true }   // no token seen: fall back to inviting
        return launchToken <= theirToken
    }

    /// Attempt to re-establish the connection after a drop (e.g. resuming from the background).
    /// MCSession can't reliably re-add a peer after a disconnect, so we rebuild the session and, to be
    /// robust to either side reconnecting first, advertise and browse at once.
    ///
    /// After a background/foreground cycle the OS frequently still reports the peer in
    /// `connectedPeers` even though the link is dead — trusting that would make us wait out MC's own
    /// ~30s keep-alive timeout before recovering. `force` skips that check and rebuilds immediately,
    /// so foregrounding re-pairs in a few seconds instead.
    func reconnect(force: Bool) {
        guard didConnect else { return }
        if !force && !session.connectedPeers.isEmpty { return }   // still live and we're not forcing
        // Already recovering: leave the retry loop alone. The host's heartbeat fails every couple of
        // seconds while the link is down and each failure lands here, so restarting the loop would
        // cancel it before it ever finished a sleep — it would never get to send an invitation.
        if recovering { return }
        recovering = true
        phase = .reconnecting
        continuation.yield(.reconnecting)
        pendingInviteAt = nil
        rebuildSession()
        // Forced: the rate limiter exists to stop the retry loop thrashing discovery, and this is the
        // *start* of recovery, where both halves have to be running. Unforced, it silently did nothing
        // whenever the last restart was inside the floor — discovery is stopped the moment a game
        // connects, but the timestamp isn't, so a link that dropped soon after connecting left this
        // phone "recovering" while neither advertising nor browsing.
        startBoth(force: true)
        startPairingRetry()   // keep re-inviting until paired, instead of hoping the first invite lands
    }

    /// Tear down the current MCSession and stand up a fresh one (MCSession can't reliably re-add a peer
    /// after a disconnect, and a failed invite leaves it in a bad state).
    ///
    /// Rate-limited, because the recovery paths all call it and a rebuild every couple of seconds is
    /// worse than not rebuilding at all: it pulls the session out from under an invitation that is
    /// still being negotiated, so the peer completes a handshake into a session we have already thrown
    /// away — one side then believes it is connected while the other is still hunting.
    private func rebuildSession(force: Bool = false) {
        if !force, let last = lastRebuildAt,
           Date().timeIntervalSince(last) < Self.minRebuildInterval { return }
        lastRebuildAt = Date()
        pendingInviteAt = nil       // whatever was in flight belonged to the old session
        session.delegate = nil
        session.disconnect()
        session = MCSession(peer: myPeerID, securityIdentity: nil, encryptionPreference: Self.encryption)
        session.delegate = self
    }

    /// Tear everything down. Now that advertising runs for the whole game, this has to be called when
    /// the game screen is left — an advertiser outliving its `GameViewModel` would answer the partner's
    /// invitation and pair them to a session nobody is listening to.
    func stop() {
        rendezvousActive = false
        recovering = false
        rendezvousTask?.cancel(); rendezvousTask = nil
        advertiser?.stopAdvertisingPeer(); advertiser = nil
        browser?.stopBrowsingForPeers(); browser = nil
        session.disconnect()
        continuation.finish()
    }

    /// Paired: stop looking, but **keep advertising for the whole game**.
    ///
    /// This is what makes a returning phone fast. Discovery used to stop altogether on connect, so
    /// when one app was suspended the other was neither advertising nor browsing — the returning phone
    /// had nothing to find, and nothing could happen until its partner independently noticed the
    /// silence. Staying advertised means the phone that comes back finds its partner immediately and
    /// invites it; the partner's advertiser answers, and the stale-link check accepts.
    ///
    /// The advertiser is rebuilt rather than left alone because it now has to carry the in-game flag
    /// (`makeAdvertiser`), which keeps this advertisement out of strangers' join lists.
    ///
    /// The browser's objects are dropped, so `browser == nil` reliably means "not browsing" —
    /// `refreshDiscovery` reads it that way. Clearing the restart timestamp matters as much: browsing
    /// isn't running, so the "don't restart discovery too often" floor has nothing to protect and must
    /// not stand in the way of the next start.
    private func stayAdvertisedAndStopBrowsing() {
        browser?.stopBrowsingForPeers(); browser = nil
        lastDiscoveryRestartAt = nil
        discoveredPeers.removeAll()
        peerTokens.removeAll()
        inGamePeers.removeAll()
        pairingPeers.removeAll()
        advertiser?.stopAdvertisingPeer()
        advertiser = makeAdvertiser()      // now flagged as in-game
    }

    // MARK: GameTransport

    // Messages that couldn't be delivered (no peer connected at the moment) are held here and flushed
    // on the next connect, so a tap during a brief connectivity gap is never silently lost. Main-actor
    // confined alongside `session`.
    private var outbox: [GameMessage] = []

    /// Which wire format the peer understands. Multipeer pairs iOS with iOS, so this stays
    /// `.legacy` against a build that predates protocol v1 — see `PROTOCOL.md`.
    ///
    /// `nonisolated` because the MCSession delegate callback that observes the peer's `hello`
    /// runs off the main actor, same as `continuation` above. The type is internally locked.
    nonisolated private let negotiator = WireCodec.Negotiator()

    func send(_ message: GameMessage) async {
        let peers = session.connectedPeers
        guard !peers.isEmpty else {
            buffer(message)
            noteDeadLink()
            return
        }
        do {
            let data = try WireCodec.encode(message, as: negotiator.format)
            try session.send(data, toPeers: peers, with: .reliable)
        } catch {
            buffer(message)   // couldn't hand off — keep it for the next connect
            noteDeadLink()
        }
    }

    /// We believe we're connected, but the session has no peer to send to (or refused the send). That
    /// is the half-open state a background/foreground cycle leaves behind, and MC can sit in it for its
    /// full ~30s keep-alive without telling anyone. The host notices first, because its heartbeat is
    /// the thing failing every two seconds — so let that failure drive the re-pair instead of queueing
    /// snapshots into the void.
    private func noteDeadLink() {
        guard didConnect, phase == .connected else { return }
        reconnect(force: true)
    }

    private func buffer(_ message: GameMessage) {
        outbox.append(message)
        if outbox.count > 200 { outbox.removeFirst(outbox.count - 200) }   // safety cap
    }

    private func flushOutbox() {
        let peers = session.connectedPeers
        guard !peers.isEmpty else { return }
        let pending = outbox; outbox.removeAll()
        for message in pending {
            if let data = try? WireCodec.encode(message, as: negotiator.format) {
                try? session.send(data, toPeers: peers, with: .reliable)
            }
        }
    }

    // MARK: Main-actor state mutations (called from delegate callbacks)

    private func markConnected(peerName: String) {
        phase = .connected
        connectedPeerName = peerName
        didConnect = true
        rendezvousActive = false
        rendezvousTask?.cancel(); rendezvousTask = nil
        pendingInviteAt = nil
        failedInviteCount = 0
        recovering = false
        stayAdvertisedAndStopBrowsing()
        flushOutbox()               // deliver anything queued during the gap
        continuation.yield(.connected)
    }

    /// MC reached `.connecting` for a peer: our invitation was accepted, or we accepted theirs. Either
    /// way a handshake is under way and deserves the longer of the two invite timeouts.
    private func markConnecting() {
        handshakeStartedAt = Date()
        if phase != .reconnecting { phase = .connecting }
    }

    /// A session state drop. If we had already connected, treat it as a temporary drop and keep
    /// trying to rejoin the peer (advertise/browse again, guest auto-invites on rediscovery).
    private func handleDrop() {
        pendingInviteAt = nil
        if didConnect {
            reconnect(force: false)   // genuine drop (connectedPeers already empty) — rebuild and re-pair
        } else if rendezvousActive {
            // A rejoin invite timed out before ever connecting — don't go terminal. Rebuild and keep
            // advertising/browsing; the retry loop will invite again once the other phone is ready.
            rebuildSession()
            startBoth()
            phase = .connecting
        } else if isHost {
            // An inbound invitation failed before it ever connected. There is nothing for this side to
            // recover — but going terminal (what used to happen) left the host showing "Disconnected"
            // while the guest was still trying to join it. Freshen the session, which a failed invite
            // leaves unusable, and go back to advertising.
            rebuildSession(force: true)
            phase = .hosting
            startRole()
        } else {
            // Our invitation failed before we ever connected. Two things used to go wrong here, and
            // together they made a first failure look permanent: the session was left in the bad state
            // a failed invite produces (so every later attempt failed too, until the app was
            // relaunched), and there was no retry — the screen went straight to "Disconnected" and
            // waited for the player to tap again into that same broken session.
            //
            // Rebuild and keep trying for a few attempts before calling it a day. Browsing only, as
            // before: the host is advertising, and `shouldInvite` knows a plain join has no election.
            failedInviteCount += 1
            rebuildSession(force: true)
            guard failedInviteCount < Self.maxInviteAttempts else {
                failedInviteCount = 0
                phase = .disconnected
                continuation.yield(.disconnected)
                return
            }
            phase = .connecting
            startRole()
            startPairingRetry()
        }
    }

    private func addPeer(_ peer: MCPeerID) {
        // Each app launch mints a fresh MCPeerID even for the same display name, and MC's `lostPeer`
        // is slow/unreliable — so a relaunched or killed host leaves ghost entries. Collapse by name,
        // keeping the most recently found instance (the live one), so the join list shows one row
        // per host rather than a pile of stale duplicates.
        discoveredPeers.removeAll { $0.displayName == peer.displayName }
        discoveredPeers.append(peer)
    }

    private func removePeer(_ peer: MCPeerID) {
        // Only remove if this exact instance is still the one we're showing (a stale-instance lostPeer
        // shouldn't drop a fresher instance of the same host we've since discovered).
        discoveredPeers.removeAll { $0 == peer }
    }
}

// MARK: - MCSessionDelegate

extension MultipeerSession: MCSessionDelegate {
    nonisolated func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        let name = peerID.displayName
        switch state {
        case .connected:
            Task { @MainActor in self.markConnected(peerName: name) }
        case .connecting:
            Task { @MainActor in self.markConnecting() }
        case .notConnected:
            Task { @MainActor in self.handleDrop() }
        @unknown default:
            break
        }
    }

    nonisolated func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        lastInboundAt = Date()
        negotiator.observe(data)   // upgrade to v1 once the peer's hello announces it
        if let message = WireCodec.decode(data) {
            continuation.yield(.received(message))
        }
    }

    nonisolated func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}
    nonisolated func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {}
    nonisolated func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}
}

// MARK: - Advertiser (host)

extension MultipeerSession: MCNearbyServiceAdvertiserDelegate {
    nonisolated func advertiser(_ advertiser: MCNearbyServiceAdvertiser,
                                didNotStartAdvertisingPeer error: Error) {
        Task { @MainActor in self.noteSearchFailure() }
    }

    nonisolated func advertiser(_ advertiser: MCNearbyServiceAdvertiser,
                                didReceiveInvitationFromPeer peerID: MCPeerID,
                                withContext context: Data?,
                                invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        // Auto-accept: this is a two-player game, first invitation wins. Read `session` on the main
        // actor (it may be mid-rebuild); the handler can be invoked from any thread.
        let offeredToken = context.flatMap { String(data: $0, encoding: .utf8) }
        Task { @MainActor in
            // An invitation arriving at all means the service is up.
            self.searchBlocked = false
            // An invitation naming a game we aren't in. Two shapes, both wrong to accept:
            //
            //  - we're in (or resuming) a different game — the cross-pairing that advertising through
            //    a whole game newly makes possible;
            //  - we're setting a *fresh* game up and someone is resuming an old one. That pairing was
            //    always broken, since both sides then act as host and the position never syncs, and
            //    both players got a frozen table rather than an honest "still looking".
            //
            // An invitation with **no** token is left alone: it is a first connection, or a phone on a
            // build from before this check, or a game interrupted before markers recorded the id, and
            // all of those deserve the answer they always got.
            if let theirs = offeredToken, theirs != self.matchToken,
               self.matchToken != nil || !self.didConnect {
                invitationHandler(false, nil)
                return
            }
            if self.session.connectedPeers.isEmpty {
                invitationHandler(true, self.session)
            } else if self.didConnect, self.linkLooksStale {
                // We still believe we have a peer, but nothing has arrived from it for a while and now
                // somebody is asking to pair. That invitation is far better evidence than
                // `connectedPeers`, which MC keeps reporting for its whole keep-alive window after the
                // other app is suspended.
                //
                // Accepting into the stale session (what used to happen) got us nowhere: MC already has
                // that peer, so the handshake fails, and the failure can't start a recovery either
                // because `reconnect` sees a non-empty `connectedPeers` and returns. Both phones then
                // wait for the other. Rebuild first and accept into the fresh session instead.
                //
                // Judged on silence rather than on the peer's name, which was the first attempt at
                // this: a phone that has been force-quit comes back with a *new* `MCPeerID` carrying
                // whatever name its owner has since set in Settings, and a name that no longer matched
                // was declined — the very reconnect this branch exists to allow.
                self.recovering = false
                self.rebuildSession(force: true)
                self.phase = .connecting
                self.continuation.yield(.reconnecting)
                invitationHandler(true, self.session)
            } else {
                // Traffic is still flowing, so this is a third device and the seat is taken. Declining
                // leaves the game alone, where accepting would hand a second peer to a session the
                // game believes is a pair.
                invitationHandler(false, nil)
            }
        }
    }
}

// MARK: - When the service can't start
//
// Both of these were unimplemented, so a service that never started looked exactly like a room with
// nobody in it: a spinner, forever. They fire for denied Local Network access and for transient
// failures (a radio coming up, the app returning to the foreground), so the response is both to say so
// and to try again — the flag clears the moment a start succeeds.

extension MultipeerSession {
    private func noteSearchFailure() {
        searchBlocked = true
        // Transient failures are common and clear on their own, so keep trying rather than giving the
        // player a dead end. Rate-limited by `startRole`/`startBoth`'s own floor.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard let self, self.searchBlocked else { return }
            self.resumeSearch()
        }
    }

    /// Stand this side's discovery back up. Used when the app returns to the foreground — a browser can
    /// come back from a suspend dead, and nothing else would ever restart it — and while a search is
    /// getting nowhere.
    func resumeSearch() {
        switch phase {
        case .hosting, .browsing:
            startRole()
        case .connecting, .reconnecting:
            startBoth(force: true)
        case .idle, .connected, .disconnected:
            return
        }
    }
}

// MARK: - Browser (guest)

extension MultipeerSession: MCNearbyServiceBrowserDelegate {
    nonisolated func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        let peer = peerID
        let token = info?["t"]
        let inGame = info?["g"] == "1"
        let pairing = info?["p"] == "1"
        Task { @MainActor in
            self.searchBlocked = false                                   // clearly not blocked after all
            if let token { self.peerTokens[peer.displayName] = token }   // for the display-name tiebreak
            if inGame {
                self.inGamePeers.insert(peer.displayName)
            } else {
                self.inGamePeers.remove(peer.displayName)
            }
            if pairing {
                self.pairingPeers.insert(peer.displayName)
            } else {
                self.pairingPeers.remove(peer.displayName)
            }
            self.addPeer(peer)
            // Auto-pair during a reconnect or a rendezvous resume (both sides browse). The single
            // inviter rule stops the two phones racing two half-open connections, and `invite` itself
            // refuses to open a second invitation while one is still outstanding.
            if self.phase == .reconnecting || self.phase == .connecting {
                if self.shouldInvite(peer) { self.invite(peer) }
            }
        }
    }

    nonisolated func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        let peer = peerID
        Task { @MainActor in self.removePeer(peer) }
    }

    nonisolated func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {
        Task { @MainActor in self.noteSearchFailure() }
    }
}
