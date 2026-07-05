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
final class MultipeerSession: NSObject, GameTransport {

    enum Phase: Sendable { case idle, hosting, browsing, connecting, connected, reconnecting, disconnected }

    var isHost: Bool = false
    private(set) var phase: Phase = .idle
    private(set) var discoveredPeers: [MCPeerID] = []
    private(set) var connectedPeerName: String?
    private var didConnect = false   // once true, a drop triggers auto-rejoin rather than a plain disconnect

    nonisolated let events: AsyncStream<TransportEvent>
    nonisolated private let continuation: AsyncStream<TransportEvent>.Continuation

    private let serviceType = "pairfortwo"     // Bonjour: _pairfortwo._tcp
    nonisolated(unsafe) private let session: MCSession
    nonisolated(unsafe) private let myPeerID: MCPeerID
    private var advertiser: MCNearbyServiceAdvertiser?
    private var browser: MCNearbyServiceBrowser?

    init(displayName: String) {
        let trimmed = displayName.trimmingCharacters(in: .whitespaces)
        let name = String((trimmed.isEmpty ? "Player" : trimmed).prefix(60))
        myPeerID = MCPeerID(displayName: name)
        session = MCSession(peer: myPeerID, securityIdentity: nil, encryptionPreference: .required)
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
        let adv = MCNearbyServiceAdvertiser(peer: myPeerID, discoveryInfo: nil, serviceType: serviceType)
        adv.delegate = self
        adv.startAdvertisingPeer()
        advertiser = adv
    }

    func startBrowsing() {
        isHost = false
        phase = .browsing
        let br = MCNearbyServiceBrowser(peer: myPeerID, serviceType: serviceType)
        br.delegate = self
        br.startBrowsingForPeers()
        browser = br
    }

    func invite(_ peer: MCPeerID) {
        phase = .connecting
        browser?.invitePeer(peer, to: session, withContext: nil, timeout: 20)
    }

    func stop() {
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
    // on the next connect, so a tap during a brief connectivity gap is never silently lost.
    nonisolated(unsafe) private var outbox: [GameMessage] = []
    private let outboxLock = NSLock()

    nonisolated func send(_ message: GameMessage) async {
        let peers = session.connectedPeers
        guard !peers.isEmpty else { buffer(message); return }
        do {
            let data = try JSONEncoder().encode(message)
            try session.send(data, toPeers: peers, with: .reliable)
        } catch {
            buffer(message)   // couldn't hand off — keep it for the next connect
        }
    }

    private nonisolated func buffer(_ message: GameMessage) {
        outboxLock.lock(); defer { outboxLock.unlock() }
        outbox.append(message)
        if outbox.count > 200 { outbox.removeFirst(outbox.count - 200) }   // safety cap
    }

    private nonisolated func flushOutbox() {
        let peers = session.connectedPeers
        guard !peers.isEmpty else { return }
        outboxLock.lock(); let pending = outbox; outbox.removeAll(); outboxLock.unlock()
        for message in pending {
            if let data = try? JSONEncoder().encode(message) {
                try? session.send(data, toPeers: peers, with: .reliable)
            }
        }
    }

    // MARK: Main-actor state mutations (called from delegate callbacks)

    private func markConnected(peerName: String) {
        phase = .connected
        connectedPeerName = peerName
        didConnect = true
        stopDiscovery()
        flushOutbox()               // deliver anything queued during the gap
        continuation.yield(.connected)
    }

    private func markConnecting() { if phase != .reconnecting { phase = .connecting } }

    /// A session state drop. If we had already connected, treat it as a temporary drop and keep
    /// trying to rejoin the peer (advertise/browse again, guest auto-invites on rediscovery).
    private func handleDrop() {
        if didConnect {
            phase = .reconnecting
            continuation.yield(.reconnecting)
            if isHost {
                advertiser?.startAdvertisingPeer()
            } else {
                browser?.startBrowsingForPeers()
            }
        } else {
            phase = .disconnected
            continuation.yield(.disconnected)
        }
    }

    private func addPeer(_ peer: MCPeerID) {
        if !discoveredPeers.contains(peer) { discoveredPeers.append(peer) }
    }

    private func removePeer(_ peer: MCPeerID) {
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
        if let message = try? JSONDecoder().decode(GameMessage.self, from: data) {
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
        // Auto-accept: this is a two-player game, first invitation wins.
        invitationHandler(true, session)
    }
}

// MARK: - Browser (guest)

extension MultipeerSession: MCNearbyServiceBrowserDelegate {
    nonisolated func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        let peer = peerID
        Task { @MainActor in
            self.addPeer(peer)
            if self.phase == .reconnecting { self.invite(peer) }   // auto-rejoin after a drop
        }
    }

    nonisolated func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        let peer = peerID
        Task { @MainActor in self.removePeer(peer) }
    }
}
