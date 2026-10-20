import Foundation
import Network
import Observation
import WiFiAware

/// The fast path between two iPhones that have been paired once.
///
/// **Why a third nearby transport.** MultipeerConnectivity has to *discover* the other phone every
/// time, and discovery is what makes pairing slow and reconnecting slower (see the pacing notes in
/// `MultipeerSession`). Wi-Fi Aware turns that around: the two phones are paired once, through a
/// system sheet, and from then on a connection is made on demand to a device the system already
/// knows — authenticated and encrypted at the Wi-Fi layer, no network, no account, usually a second
/// or two. That is the shape of a *first* connection, and it is what a reconnect gets here too.
///
/// Needs iOS 26 on an iPhone 12 or later (`isSupported`) and that one-time pairing. Where any of
/// that is missing the other two transports carry on exactly as before: `ConnectView` runs all three
/// side by side and hands up whichever connects first.
///
/// Roles are fixed — the host publishes the service and accepts, the guest subscribes and dials. A
/// resume ("Rejoin") takes its role from who holds the saved game, which the two phones can't both
/// do, so there is no inviter election to get wrong.
///
/// Mirrors `LANTransport`'s shape — `@Observable` for the connect UI, a `nonisolated` events stream,
/// an outbox that survives gaps — so `GameViewModel` stays transport-agnostic. Speaks protocol v1
/// (`PROTOCOL.md`); each frame is one `WireCodec` message, carried by the Network framework's `Coder`
/// so the byte stream is framed for us.
///
/// **Lifetimes.** The Network framework's `NetworkListener`, `NetworkBrowser` and `NetworkConnection`
/// have no cancel: each lives as long as the task running it and the references to it. So "stop"
/// here always means cancelling a task and dropping a reference, never calling anything.
@available(iOS 26, *)
@MainActor
@Observable
final class WiFiAwareTransport: NearbyTransport {

    enum Phase: Sendable { case idle, hosting, browsing, connecting, connected, reconnecting, disconnected }

    /// Declared under `WiFiAwareServices` in the Info.plist as both publishable and subscribable.
    nonisolated static let serviceName = "_pairfortwo-wa._tcp"

    /// Whether this device has the radio for it (iPhone 12 and later, recent iPads) and the service
    /// is declared, so the accessors at the bottom of the file can't come back empty.
    static var isSupported: Bool {
        WACapabilities.supportedFeatures.contains(.wifiAware)
            && WAPublishableService.pairForTwo != nil && WASubscribableService.pairForTwo != nil
    }

    /// One message per frame. `WireCodec` produces the bytes; the Network framework's JSON coder
    /// frames them. A wrapper rather than bare `Data`, so the send and receive overloads are unambiguous.
    nonisolated struct Frame: Codable, Sendable { var payload: Data }   // encoded off the main actor
    typealias Stack = Coder<Frame, Frame, NetworkJSONCoder>
    typealias Link = NetworkConnection<Stack>

    /// When any instance last saw a paired partner — found by a guest, or dialing in to a host.
    /// `GameViewModel` reads it so that, on the occasions Multipeer wins the race to connect, it
    /// doesn't offer a pairing to a phone we are already paired with. Static because the instance
    /// that saw it is stopped the moment another transport is handed up.
    static var lastPairedPeerSighting: Date?

    var isHost: Bool = false
    let linkKind: LinkKind = .wifiAware
    private(set) var phase: Phase = .idle
    private(set) var connectedPeerName: String?
    /// How many devices this app has been paired with. Zero means the pairing sheet is the next step:
    /// the system refuses to publish or subscribe with nobody to do it for.
    private(set) var pairedDeviceCount = 0

    nonisolated let events: AsyncStream<TransportEvent>
    nonisolated private let continuation: AsyncStream<TransportEvent>.Continuation

    /// The running listener or browser — whichever this side's role calls for.
    private var roleTask: Task<Void, Never>?
    private var pairingWatch: Task<Void, Never>?
    /// Reads the live link. Cancelling it is also what closes an inbound link (see `serve`).
    private var receiveTask: Task<Void, Never>?
    private var link: Link?
    /// Once true, a drop is treated as recoverable and we re-pair rather than going terminal — the
    /// same rule as the other nearby transports.
    private var didConnect = false
    /// Buffered sends, flushed on the next connect so a tap during a gap is never lost.
    private var outbox: [GameMessage] = []

    init() {
        var captured: AsyncStream<TransportEvent>.Continuation!
        events = AsyncStream(bufferingPolicy: .unbounded) { captured = $0 }
        continuation = captured
        watchPairedDevices()
    }

    // MARK: - Connect lifecycle

    func startHosting() {
        isHost = true
        phase = .hosting
        startRole()
    }

    func startBrowsing() {
        isHost = false
        phase = .browsing
        startRole()
    }

    /// Rejoin a saved game. Only a host ever writes the saved state, and a guest's marker deletes any
    /// stale copy, so holding it is what decides who publishes — the two phones can't both.
    func startRendezvous() {
        isHost = GamePersistence.hasSavedState
        phase = .connecting
        startRole()
    }

    func stop() {
        pairingWatch?.cancel(); pairingWatch = nil
        roleTask?.cancel(); roleTask = nil
        dropLink()
        continuation.finish()
    }

    /// Stand this side back up, for a return to the foreground or a search going nowhere.
    func resumeSearch() {
        switch phase {
        case .hosting, .browsing, .connecting, .reconnecting: startRole()
        case .idle, .connected, .disconnected: return
        }
    }

    /// Re-establish after a drop or a background/foreground cycle. As with the other transports, the
    /// OS can still report a dead link as live after foregrounding, so `force` rebuilds regardless.
    func reconnect(force: Bool) {
        guard didConnect else { return }
        if !force, phase == .connected, link != nil { return }
        phase = .reconnecting
        continuation.yield(.reconnecting)
        dropLink()
        startRole()
    }

    // MARK: - Paired devices

    /// Follow the paired-device list. Pairing happens in a system sheet the connect screen presents,
    /// so this is how the transport learns it now has someone to publish to or look for — and a phone
    /// paired mid-search starts straight away rather than waiting for another tap.
    private func watchPairedDevices() {
        pairingWatch = Task { @MainActor [weak self] in
            do {
                for try await devices in WAPairedDevice.allDevices {
                    guard let self else { return }
                    let grew = devices.count > self.pairedDeviceCount
                    self.pairedDeviceCount = devices.count
                    if grew, self.phase != .idle, self.phase != .connected { self.startRole() }
                }
            } catch {
                // Wi-Fi Aware unavailable after all; the other transports carry the connect screen.
            }
        }
    }

    // MARK: - Roles

    private func startRole() {
        roleTask?.cancel(); roleTask = nil
        guard pairedDeviceCount > 0 else { return }   // nothing to publish to or look for yet
        roleTask = isHost ? makeListenerTask() : makeBrowserTask()
    }

    private static func stack() -> Stack {
        Coder(receiving: Frame.self, sending: Frame.self, using: NetworkJSONCoder()) { TCP() }
    }

    /// Publish for the paired devices and take what dials in. Kept running through the whole game, so
    /// a guest that drops can dial straight back without the host having to notice first.
    private func makeListenerTask() -> Task<Void, Never>? {
        guard let service = WAPublishableService.pairForTwo else { return nil }
        return Task { @MainActor [weak self] in
            do {
                let listener = try NetworkListener(
                    for: .wifiAware(.connecting(to: service, from: .allPairedDevices)),
                    using: .parameters { Self.stack() })
                try await listener.run { connection in
                    await self?.serve(connection)
                }
            } catch {
                // Most often the pairing sheet still publishing this very service, or a radio coming
                // up. Stand it back up after a pause rather than going terminal.
                guard let self, !Task.isCancelled else { return }
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled, self.isHost, self.phase != .connected else { return }
                self.startRole()
            }
        }
    }

    /// Look for a paired host and dial the first one found.
    private func makeBrowserTask() -> Task<Void, Never>? {
        guard let service = WASubscribableService.pairForTwo else { return nil }
        return Task { @MainActor [weak self] in
            do {
                let browser = NetworkBrowser(for: .wifiAware(.connecting(to: .allPairedDevices, from: service)))
                try await browser.run { endpoints in
                    self?.found(endpoints)
                }
            } catch {
                guard let self, !Task.isCancelled else { return }
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled, !self.isHost, self.phase != .connected else { return }
                self.startRole()
            }
        }
    }

    /// A paired host is publishing. Dial it straight away: pairing was the moment of choosing, so
    /// there is nothing to ask the player here.
    private func found(_ endpoints: [WAEndpoint]) {
        guard link == nil, let endpoint = endpoints.first else { return }
        Self.lastPairedPeerSighting = Date()
        if phase == .browsing { phase = .connecting }
        let device = endpoint.device
        let connection = Link(to: endpoint, using: .parameters { Self.stack() })
        connectedPeerName = device.name ?? device.pairingInfo?.pairingName
        receiveTask = adopt(connection)
    }

    /// The host side of a dial. A newcomer replaces whatever link is live: only a paired device can
    /// get this far, this is a two-player game, and a partner dialing again is the surest sign its
    /// previous link is dead from its end — however live it still looks from here.
    ///
    /// Awaits the link's whole life, so the connection the listener handed over stays owned for as
    /// long as it is being read, and cancelling `receiveTask` is what lets it go.
    private func serve(_ connection: Link) async {
        Self.lastPairedPeerSighting = Date()
        connectedPeerName = nil
        let reading = adopt(connection)
        receiveTask = reading
        await reading.value
    }

    // MARK: - The link

    /// Make `connection` the live link and start reading it. Returns the reading task; the caller
    /// keeps it as `receiveTask`.
    private func adopt(_ connection: Link) -> Task<Void, Never> {
        dropLink()
        link = connection
        connection.onStateUpdate { [weak self] conn, state in
            guard let self, self.link === conn else { return }   // a superseded link's news is stale
            switch state {
            case .ready:
                self.markConnected()
            case .failed, .cancelled:
                self.link = nil
                self.handleDrop()
            default:
                break
            }
        }
        // Reading is also what starts an outbound connection; there is no separate start.
        return Task { @MainActor [weak self] in
            do {
                for try await (frame, _) in connection.messages {
                    guard let self, self.link === connection else { return }
                    // A corrupt frame is dropped, not fatal.
                    if let message = WireCodec.decode(frame.payload) {
                        self.continuation.yield(.received(message))
                    }
                }
            } catch {
                // The stream ends when the peer closes or the link fails; the state handler recovers.
            }
        }
    }

    private func dropLink() {
        receiveTask?.cancel(); receiveTask = nil
        link = nil
    }

    private func markConnected() {
        phase = .connected
        didConnect = true
        // The guest has what it was looking for; the host keeps publishing for a re-dial.
        if !isHost { roleTask?.cancel(); roleTask = nil }
        flushOutbox()
        continuation.yield(.connected)
        if connectedPeerName == nil, let link { fetchPeerName(from: link) }
    }

    /// The host learns who dialed from the path, once there is one. Best effort: it only labels the
    /// "Connected to …" line, and the game carries the player's chosen name itself.
    private func fetchPeerName(from connection: Link) {
        Task { @MainActor [weak self] in
            guard let device = try? await connection.currentPath?.wifiAware?.endpoint.device else { return }
            guard let self, self.link === connection else { return }
            self.connectedPeerName = device.name ?? device.pairingInfo?.pairingName
        }
    }

    private func handleDrop() {
        guard phase != .reconnecting else { return }   // already recovering
        if didConnect { reconnect(force: true); return }
        if isHost { return }   // the listener is still up; the guest will dial again
        // A dial that failed before ever connecting — the host may not be publishing yet. Look again,
        // after a pause so a host that keeps refusing isn't dialed in a tight loop.
        phase = .browsing
        roleTask?.cancel(); roleTask = nil
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, self.phase == .browsing else { return }
            self.startRole()
        }
    }

    // MARK: - GameTransport

    func send(_ message: GameMessage) async {
        guard let link, phase == .connected else { buffer(message); return }
        guard let data = try? WireCodec.encode(message, as: .v1) else { return }
        do {
            try await link.send(Frame(payload: data))
        } catch {
            // Couldn't hand it off: keep it for the next connect, and treat the link as gone.
            buffer(message)
            if self.link === link { reconnect(force: true) }
        }
    }

    private func buffer(_ message: GameMessage) {
        outbox.append(message)
        if outbox.count > 200 { outbox.removeFirst(outbox.count - 200) }   // safety cap
    }

    private func flushOutbox() {
        guard let link else { return }
        let pending = outbox; outbox.removeAll()
        Task { @MainActor in
            for message in pending {
                guard let data = try? WireCodec.encode(message, as: .v1) else { continue }
                try? await link.send(Frame(payload: data))
            }
        }
    }
}

// MARK: - The declared service

@available(iOS 26, *)
extension WAPublishableService {
    /// Our service as declared in the Info.plist; nil only if that declaration is missing.
    static var pairForTwo: WAPublishableService? { allServices[WiFiAwareTransport.serviceName] }
}

@available(iOS 26, *)
extension WASubscribableService {
    static var pairForTwo: WASubscribableService? { allServices[WiFiAwareTransport.serviceName] }
}
