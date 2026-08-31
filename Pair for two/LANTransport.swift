import Foundation
import Network
import Observation

/// Cross-platform local transport: Bonjour discovery + a plain TCP socket carrying
/// newline-delimited JSON.
///
/// **Why this exists alongside `MultipeerSession`.** MultipeerConnectivity is Apple-only, so
/// an Android device can never join one. This is the transport the two platforms share. It
/// needs both devices on the same Wi-Fi network (a personal hotspot counts), which is the
/// trade-off for working at all across platforms — see PLAN.md §4.
///
/// iOS↔iOS play is unaffected: Multipeer remains the preferred path there because it needs no
/// network at all. `ConnectView` merges both peer lists so the user never picks a protocol.
///
/// Deliberately mirrors `MultipeerSession`'s shape — `@Observable` for the connect UI, a
/// nonisolated `events` stream, an outbox that survives brief gaps — so `GameViewModel` stays
/// transport-agnostic and the hard-won reconnect behavior is consistent between the two.
///
/// Always speaks protocol v1 (`PROTOCOL.md`): this transport is new, so it has no legacy peers.
@MainActor
@Observable
final class LANTransport: NearbyTransport {

    enum Phase: Sendable { case idle, hosting, browsing, connecting, connected, reconnecting, disconnected }

    /// A discovered host, for the join list.
    struct Peer: Identifiable, Hashable, Sendable {
        let id: String        // the Bonjour service name — stable for a given advertiser
        let name: String
        fileprivate let endpoint: NWEndpoint
    }

    /// **Deliberately not `_pairfortwo._tcp`.** `MultipeerSession`'s `serviceType = "pairfortwo"`
    /// makes MultipeerConnectivity register exactly that Bonjour type, so sharing it would make
    /// this browser discover Multipeer advertisements — and a guest would then open a raw TCP
    /// socket to a peer speaking MC's own protocol, which fails in a confusing way. A separate
    /// type keeps the two transports' discovery cleanly disjoint.
    static let serviceType = "_pairfortwo-lan._tcp"

    var isHost: Bool = false
    let linkKind: LinkKind = .wifiNetwork
    private(set) var phase: Phase = .idle
    private(set) var discoveredPeers: [Peer] = []
    private(set) var connectedPeerName: String?

    nonisolated let events: AsyncStream<TransportEvent>
    nonisolated private let continuation: AsyncStream<TransportEvent>.Continuation

    private let displayName: String
    private let queue = DispatchQueue(label: "com.jirofeingold.pairfortwo.lan")

    private var listener: NWListener?
    private var browser: NWBrowser?
    private var connection: NWConnection?

    /// Once true, a drop is treated as recoverable and we retry rather than going terminal —
    /// same rule as `MultipeerSession.didConnect`.
    private var didConnect = false
    /// Buffered sends, flushed on the next connect so a tap during a gap is never lost.
    private var outbox: [GameMessage] = []
    /// Partial line carried between `receive` callbacks — a TCP read can split mid-message.
    private var inboundBuffer = Data()
    private var reconnectTask: Task<Void, Never>?

    init(displayName: String) {
        let trimmed = displayName.trimmingCharacters(in: .whitespaces)
        self.displayName = String((trimmed.isEmpty ? String(localized: "Player", comment: "Fallback name shown to the other device when you have not set one") : trimmed).prefix(60))
        var captured: AsyncStream<TransportEvent>.Continuation!
        events = AsyncStream(bufferingPolicy: .unbounded) { captured = $0 }
        continuation = captured
    }

    // MARK: - Connect lifecycle

    /// Advertise over Bonjour and wait for a guest.
    func startHosting() {
        isHost = true
        phase = .hosting
        startListener()
    }

    /// Browse for advertised hosts. `discoveredPeers` drives the join list.
    func startBrowsing() {
        isHost = false
        phase = .browsing
        startBrowser()
    }

    func invite(_ peer: Peer) {
        phase = .connecting
        connectedPeerName = peer.name
        openConnection(to: peer.endpoint)
    }

    func stop() {
        reconnectTask?.cancel(); reconnectTask = nil
        listener?.cancel(); listener = nil
        browser?.cancel(); browser = nil
        connection?.cancel(); connection = nil
        continuation.finish()
    }

    private func startListener() {
        listener?.cancel()
        let params = NWParameters.tcp
        // Small, latency-sensitive messages — don't wait to coalesce them.
        (params.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options)?.noDelay = true
        // Peer-to-peer (AWDL) is deliberately off: Android can't use it, and Multipeer already
        // covers the no-network iOS↔iOS case. Keeping it off makes behavior predictable.
        params.includePeerToPeer = false

        guard let listener = try? NWListener(using: params) else {
            fail()
            return
        }
        listener.service = NWListener.Service(name: displayName, type: Self.serviceType)
        listener.newConnectionHandler = { [weak self] conn in
            Task { @MainActor in self?.accept(conn) }
        }
        listener.stateUpdateHandler = { [weak self] state in
            guard case .failed = state else { return }
            // Was terminal, which meant a host whose listener failed to start sat on "waiting for a
            // player" that could never arrive. Stand it back up instead, and only give up on the
            // hosting attempt if the player leaves the screen.
            Task { @MainActor in self?.restartListenerAfterFailure() }
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    private func restartListenerAfterFailure() {
        guard phase == .hosting || phase == .reconnecting else { fail(); return }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard let self, self.phase == .hosting || self.phase == .reconnecting else { return }
            self.startListener()
        }
    }

    /// Stand this side's discovery back up, for a return to the foreground or a search going nowhere.
    func resumeSearch() {
        switch phase {
        case .hosting: startListener()
        case .browsing: startBrowser()
        default: return
        }
    }

    private func startBrowser() {
        browser?.cancel()
        let params = NWParameters.tcp
        params.includePeerToPeer = false
        let browser = NWBrowser(for: .bonjour(type: Self.serviceType, domain: nil), using: params)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let peers = results.compactMap(Self.peer(from:))
            Task { @MainActor in self?.updatePeers(peers) }
        }
        // A browser can fail to start — denied local network access, most often — and this went
        // unwatched, so the failure was indistinguishable from an empty room. Try again rather than
        // searching forever; `waiting` covers the permission prompt still being open.
        browser.stateUpdateHandler = { [weak self] state in
            guard case .failed = state else { return }
            Task { @MainActor in self?.restartBrowserAfterFailure() }
        }
        browser.start(queue: queue)
        self.browser = browser
    }

    /// A failed browser is dead: `NWBrowser` doesn't recover, it has to be replaced. Paced so a
    /// permanently refused permission doesn't turn into a spin.
    private func restartBrowserAfterFailure() {
        guard phase == .browsing || phase == .reconnecting else { return }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard let self, self.phase == .browsing || self.phase == .reconnecting else { return }
            self.startBrowser()
        }
    }

    /// Only Bonjour service results are joinable, and the service name is the host's display
    /// name — so the join list needs no extra handshake to label its rows.
    private static func peer(from result: NWBrowser.Result) -> Peer? {
        guard case let .service(name, _, _, _) = result.endpoint else { return nil }
        return Peer(id: name, name: name, endpoint: result.endpoint)
    }

    private func updatePeers(_ peers: [Peer]) {
        // Collapse by name, like the Multipeer join list: a relaunched host can briefly appear
        // twice while the old advertisement times out.
        var seen = Set<String>()
        discoveredPeers = peers.filter { seen.insert($0.name).inserted }
    }

    /// The host accepts the first guest and stops advertising — this is a two-player game.
    private func accept(_ conn: NWConnection) {
        guard connection == nil else { conn.cancel(); return }   // already paired
        listener?.cancel(); listener = nil
        bind(conn)
    }

    private func openConnection(to endpoint: NWEndpoint) {
        let params = NWParameters.tcp
        (params.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options)?.noDelay = true
        params.includePeerToPeer = false
        bind(NWConnection(to: endpoint, using: params))
    }

    private func bind(_ conn: NWConnection) {
        connection?.cancel()   // never leave a half-open attempt running alongside a new one
        connection = conn
        conn.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                switch state {
                case .ready:
                    self.browser?.cancel(); self.browser = nil
                    self.markConnected()
                case .failed, .cancelled:
                    // Clear it only if it's still the live one, then recover. Dropping the reference
                    // is what lets the reconnect loop start a fresh attempt.
                    if self.connection === conn { self.connection = nil }
                    self.handleDrop()
                case .waiting:
                    // Usually the local-network permission prompt, or the host not up yet.
                    if self.phase != .reconnecting { self.phase = .connecting }
                default:
                    break
                }
            }
        }
        conn.start(queue: queue)
        receive(on: conn)
    }

    // MARK: - Framing
    //
    // Newline-delimited JSON: one message per line. Encoded JSON never contains a raw newline,
    // so this needs no length prefix and is debuggable with `nc`. See PROTOCOL.md.

    private func receive(on conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            if let data, !data.isEmpty {
                Task { @MainActor in self?.ingest(data) }
            }
            if isComplete || error != nil {
                Task { @MainActor in self?.handleDrop() }
                return
            }
            Task { @MainActor in
                // Only keep reading while this is still the live connection — a stale socket's
                // callback must not resurrect itself after a reconnect swapped it out.
                guard let self, self.connection === conn else { return }
                self.receive(on: conn)
            }
        }
    }

    private func ingest(_ data: Data) {
        inboundBuffer.append(data)
        let newline = UInt8(ascii: "\n")
        while let idx = inboundBuffer.firstIndex(of: newline) {
            let line = inboundBuffer[inboundBuffer.startIndex..<idx]
            inboundBuffer = inboundBuffer[inboundBuffer.index(after: idx)...]
            deliver(Data(line))
        }
        // A peer that never sends a newline must not grow this without bound.
        if inboundBuffer.count > 1 << 20 { inboundBuffer.removeAll() }
    }

    private func deliver(_ line: Data) {
        // Tolerate \r\n and blank keepalive lines.
        var body = line
        if body.last == UInt8(ascii: "\r") { body.removeLast() }
        guard !body.isEmpty else { return }
        // A corrupt frame is dropped, not fatal.
        guard let message = WireCodec.decode(body) else { return }
        continuation.yield(.received(message))
    }

    // MARK: - GameTransport

    func send(_ message: GameMessage) async {
        guard let conn = connection, phase == .connected else { buffer(message); return }
        guard let data = try? WireCodec.encode(message, as: .v1) else { return }
        var framed = data
        framed.append(UInt8(ascii: "\n"))
        conn.send(content: framed, completion: .contentProcessed { _ in })
    }

    private func buffer(_ message: GameMessage) {
        outbox.append(message)
        if outbox.count > 200 { outbox.removeFirst(outbox.count - 200) }   // safety cap
    }

    private func flushOutbox() {
        guard let conn = connection else { return }
        let pending = outbox; outbox.removeAll()
        for message in pending {
            guard var data = try? WireCodec.encode(message, as: .v1) else { continue }
            data.append(UInt8(ascii: "\n"))
            conn.send(content: data, completion: .contentProcessed { _ in })
        }
    }

    /// Re-establish after a drop or a background/foreground cycle.
    ///
    /// As with Multipeer, the OS can still report a dead socket as live after foregrounding, so
    /// `force` tears down and rebuilds rather than waiting out the TCP timeout.
    func reconnect(force: Bool) {
        guard didConnect else { return }
        if !force, phase == .connected { return }
        phase = .reconnecting
        continuation.yield(.reconnecting)
        connection?.cancel(); connection = nil
        inboundBuffer.removeAll()
        // The host re-advertises; the guest re-browses and re-invites on rediscovery.
        if isHost { startListener() } else { startBrowser(); startRebrowseRetry() }
    }

    /// While reconnecting, a guest re-invites the first host it rediscovers. The host may not
    /// be advertising again yet, so keep looking rather than giving up after one pass.
    ///
    /// The loop deliberately does *not* stop once it has opened a connection: if that attempt fails,
    /// `handleDrop` sees we're already `.reconnecting` and (rightly) doesn't start a second recovery,
    /// so returning here used to strand the guest in "reconnecting" forever after one bad attempt.
    /// It keeps going until the connection actually reports `.ready`, which clears `.reconnecting`.
    ///
    /// Restarting the browser only when nothing has been discovered, and no more than every third
    /// pass, so discovery isn't reset before Bonjour can finish.
    private func startRebrowseRetry() {
        reconnectTask?.cancel()
        reconnectTask = Task { @MainActor [weak self] in
            var pass = 0
            while true {
                try? await Task.sleep(for: .seconds(3))
                guard let self, self.phase == .reconnecting else { return }
                pass += 1
                if self.connection != nil { continue }          // an attempt is still in progress
                if let peer = self.discoveredPeers.first {
                    self.openConnection(to: peer.endpoint)
                } else if pass % 3 == 0 {
                    self.startBrowser()
                }
            }
        }
    }

    // MARK: - State transitions

    private func markConnected() {
        phase = .connected
        didConnect = true
        reconnectTask?.cancel(); reconnectTask = nil
        discoveredPeers.removeAll()
        flushOutbox()
        continuation.yield(.connected)
    }

    private func handleDrop() {
        guard phase != .reconnecting else { return }   // already recovering
        if didConnect {
            reconnect(force: true)
        } else {
            fail()
        }
    }

    private func fail() {
        phase = .disconnected
        continuation.yield(.disconnected)
    }
}
