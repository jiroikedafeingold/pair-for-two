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
    private(set) var connectedPeerName: String?
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
    /// Generous on purpose: the old 10s was shorter than a cold Bluetooth-only handshake, so the
    /// first attempt timed out even when the peers could see each other perfectly well.
    private static let inviteTimeout: TimeInterval = 20
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

    /// Tiebreaker for `shouldInvite` when both phones show the same display name — which is the
    /// default case, since everyone starts out called "Player". Advertised in `discoveryInfo` and
    /// read back from the browser, so exactly one side invites even then.
    private let launchToken = String(UUID().uuidString.prefix(8))
    private var peerTokens: [String: String] = [:]   // display name → their launch token

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
            defer { if self?.pairingGeneration == generation { self?.rendezvousTask = nil } }
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
                } else if self.discoveredPeers.isEmpty {
                    self.refreshDiscovery()   // no one found yet (rate-limited)
                }
            }
        }
    }

    /// Whether an invitation is still within its timeout, and so should be left to resolve.
    private var inviteInFlight: Bool {
        guard let sent = pendingInviteAt else { return false }
        return Date().timeIntervalSince(sent) < Self.inviteTimeout
    }

    /// An invitation that outlived its timeout with MC never reporting anything, either way. Derived
    /// from the same timestamp rather than latched, so it can't outlive the invitation it describes:
    /// whatever clears `pendingInviteAt` — connecting, a reported failure, a session rebuild, a fresh
    /// invite — clears this with it.
    private var inviteWentQuiet: Bool {
        guard let sent = pendingInviteAt else { return false }
        return Date().timeIntervalSince(sent) >= Self.inviteTimeout
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

    /// Nothing found yet — stand discovery back up, rate-limited. Symmetric pairing needs both halves
    /// running; a plain join only needs this side's role, so it doesn't start advertising as a guest.
    private func refreshDiscovery() {
        if let last = lastDiscoveryRestartAt,
           Date().timeIntervalSince(last) < Self.minDiscoveryRestartInterval { return }
        if symmetricPairing { startBoth(force: true) } else { startRole() }
    }

    /// The advertisement carries `launchToken` so the other side can break a display-name tie — see
    /// `shouldInvite`.
    private func makeAdvertiser() -> MCNearbyServiceAdvertiser {
        let adv = MCNearbyServiceAdvertiser(peer: myPeerID,
                                            discoveryInfo: ["t": launchToken],
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
        pendingInviteAt = nil
    }

    func invite(_ peer: MCPeerID) {
        guard !inviteInFlight else { return }   // never two open invitations — MC fails both
        phase = .connecting
        pendingInviteAt = Date()
        browser?.invitePeer(peer, to: session, withContext: nil, timeout: Self.inviteTimeout)
        // Follow it up. This is also the path a tap on the join list takes, and a tap used to be a
        // one-shot: if MC answered with a failure we recovered in `handleDrop`, but if it never
        // answered at all the screen spun forever with nothing behind it. `isPairing` is true now that
        // the phase is `.connecting`, so the loop stays alive until we're paired or the player leaves.
        startPairingRetry()
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
        startBoth()
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

    func stop() {
        rendezvousActive = false
        recovering = false
        rendezvousTask?.cancel(); rendezvousTask = nil
        advertiser?.stopAdvertisingPeer()
        browser?.stopBrowsingForPeers()
        session.disconnect()
        continuation.finish()
    }

    private func stopDiscovery() {
        advertiser?.stopAdvertisingPeer()
        browser?.stopBrowsingForPeers()
        discoveredPeers.removeAll()
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
        stopDiscovery()
        flushOutbox()               // deliver anything queued during the gap
        continuation.yield(.connected)
    }

    private func markConnecting() { if phase != .reconnecting { phase = .connecting } }

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
                                didReceiveInvitationFromPeer peerID: MCPeerID,
                                withContext context: Data?,
                                invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        // Auto-accept: this is a two-player game, first invitation wins. Read `session` on the main
        // actor (it may be mid-rebuild); the handler can be invoked from any thread.
        let name = peerID.displayName
        Task { @MainActor in
            if self.session.connectedPeers.isEmpty {
                invitationHandler(true, self.session)
            } else if self.didConnect, self.connectedPeerName == name {
                // Our own partner, asking to pair again while we still believe they're here. That
                // invitation is proof the link is dead — they only send one after tearing their side
                // down — so it's better evidence than `connectedPeers`, which MC can keep reporting for
                // its whole keep-alive window after a background/foreground cycle.
                //
                // Accepting into the stale session (what used to happen) got us nowhere: MC already has
                // that peer, so the handshake fails, and the failure can't start a recovery either
                // because `reconnect` sees a non-empty `connectedPeers` and returns. Both phones then
                // wait for the other. Rebuild first and accept into the fresh session instead.
                self.recovering = false
                self.rebuildSession(force: true)
                self.phase = .connecting
                self.continuation.yield(.reconnecting)
                invitationHandler(true, self.session)
            } else {
                // A third device. The seat is taken — declining leaves the game alone, where accepting
                // would hand a second peer to a session the game believes is a pair.
                invitationHandler(false, nil)
            }
        }
    }
}

// MARK: - Browser (guest)

extension MultipeerSession: MCNearbyServiceBrowserDelegate {
    nonisolated func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        let peer = peerID
        let token = info?["t"]
        Task { @MainActor in
            if let token { self.peerTokens[peer.displayName] = token }   // for the display-name tiebreak
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
}
