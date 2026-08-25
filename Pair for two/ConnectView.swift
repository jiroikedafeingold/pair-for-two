import SwiftUI
import MultipeerConnectivity

/// Which side is rejoining a saved game (host re-hosts its state, guest reconnects to the host).
enum ResumeRole { case host, guest }

/// Host or join a nearby game. No internet, no accounts.
///
/// **Two transports run side by side.** `MultipeerSession` reaches other iPhones with no network
/// at all; `LANTransport` reaches Android (and iOS) over Bonjour + TCP on a shared Wi-Fi. Both
/// advertise when hosting and both browse when joining, and their discoveries are merged into a
/// single list — the player never picks a protocol. Whichever connects first is handed up to
/// `RootView`; the other is stopped.
///
/// Peers offering both are deduped by name with **Multipeer preferred**, since it doesn't need a
/// network. See PLAN.md §4.4.
struct ConnectView: View {
    let localName: String
    let localColorID: Int
    var resumeRole: ResumeRole? = nil    // set → auto-(re)connect in that role for a saved game
    var onConnected: (any NearbyTransport) -> Void
    var onCancel: () -> Void

    @State private var mc: MultipeerSession
    @State private var lan: LANTransport
    @State private var connectStalled = false  // surfaced after a while so a stuck connect isn't a silent spinner
    @State private var handedOff = false       // both transports can report .connected; only hand up once

    private var resuming: Bool { resumeRole != nil }

    /// Resume is Multipeer-only for now: rejoining relies on the rendezvous dance (both sides
    /// advertise *and* browse), which `LANTransport` doesn't implement yet. A cross-platform game
    /// therefore can't be rejoined after a hard exit — tracked as follow-up work in PLAN.md.
    private var lanActive: Bool { !resuming }

    init(localName: String, localColorID: Int, resumeRole: ResumeRole? = nil,
         onConnected: @escaping (any NearbyTransport) -> Void,
         onCancel: @escaping () -> Void) {
        self.localName = localName
        self.localColorID = localColorID
        self.resumeRole = resumeRole
        self.onConnected = onConnected
        self.onCancel = onCancel
        _mc = State(initialValue: MultipeerSession(displayName: localName))
        _lan = State(initialValue: LANTransport(displayName: localName))
    }

    // MARK: - Combined phase

    private enum UIPhase { case idle, hosting, browsing, connecting, connected, disconnected }

    /// One phase from two state machines. Ordered by precedence: a connection in progress on
    /// either transport outranks the other still idling in discovery.
    private var uiPhase: UIPhase {
        if mc.phase == .connected || (lanActive && lan.phase == .connected) { return .connected }
        if mc.phase == .connecting || mc.phase == .reconnecting { return .connecting }
        if lanActive, lan.phase == .connecting || lan.phase == .reconnecting { return .connecting }
        if mc.phase == .hosting || (lanActive && lan.phase == .hosting) { return .hosting }
        if mc.phase == .browsing || (lanActive && lan.phase == .browsing) { return .browsing }
        // Only terminal once every transport in play has given up.
        if mc.phase == .disconnected, !lanActive || lan.phase == .disconnected { return .disconnected }
        return .idle
    }

    // MARK: - Merged peer list

    private struct Row: Identifiable {
        let id: String
        let name: String
        let overWiFi: Bool
        let connect: () -> Void
    }

    private var rows: [Row] {
        var seen = Set<String>()
        var out: [Row] = []
        // Multipeer first, so it wins the dedupe: it works with no network present.
        for peer in mc.discoveredPeers where seen.insert(peer.displayName).inserted {
            out.append(Row(id: "mc-\(peer.displayName)", name: peer.displayName,
                           overWiFi: false, connect: { mc.invite(peer) }))
        }
        if lanActive {
            for peer in lan.discoveredPeers where seen.insert(peer.name).inserted {
                out.append(Row(id: "lan-\(peer.id)", name: peer.name,
                               overWiFi: true, connect: { lan.invite(peer) }))
            }
        }
        return out
    }

    var body: some View {
        ZStack {
            LinearGradient(colors: [.feltMid, .feltDark], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()

            VStack(spacing: 20) {
                Group {
                    if resuming {
                        Text("Resume Game", comment: "Title of the nearby-connect screen when picking a game back up")
                    } else {
                        Text("Play Nearby", comment: "Title of the nearby-connect screen")
                    }
                }
                    .font(.system(size: 34, weight: .heavy, design: .serif))
                    .foregroundStyle(.white)
                Text("Bluetooth / Wi-Fi · no internet needed")
                    .font(.subheadline).foregroundStyle(Color.cribGold)

                content
            }
            .padding(28)
            .frame(maxWidth: 520)

            VStack {
                HStack {
                    Button {
                        stopAll()
                        onCancel()
                    } label: {
                        Label("Back", systemImage: "chevron.left")
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(.white)
                    }
                    Spacer()
                }
                Spacer()
            }
            .padding(20)
        }
        .onChange(of: mc.phase) { _, phase in
            if phase == .connected { handOff(mc, stopping: lanActive ? lan : nil) }
        }
        .onChange(of: lan.phase) { _, phase in
            if lanActive, phase == .connected { handOff(lan, stopping: mc) }
        }
        .onAppear {
            // Resuming: both phones advertise *and* browse and auto-pair, regardless of their stored
            // role — so a stale "both are host" marker state can't deadlock. The host is decided by
            // who holds the saved state (in onConnected), not by who advertises.
            if resuming, mc.phase == .idle { mc.startRendezvous() }
        }
        // Pairing now retries by itself rather than failing after one timed-out invitation, so
        // "Connecting…" can legitimately last a while. Offer an escape hatch (and the likely fixes)
        // once it has gone on long enough to feel stuck — for a fresh connect as much as a resume,
        // which is all the old resume-only timer covered. Keyed on the phase, so it re-arms on each
        // new attempt and clears the moment something else happens.
        .task(id: uiPhase) {
            connectStalled = false
            guard uiPhase == .connecting else { return }
            try? await Task.sleep(for: .seconds(15))
            guard !Task.isCancelled else { return }
            connectStalled = true
        }
    }

    // MARK: - Actions

    private func startHosting() {
        mc.startHosting()
        if lanActive { lan.startHosting() }
    }

    private func startBrowsing() {
        mc.startBrowsing()
        if lanActive { lan.startBrowsing() }
    }

    private func stopAll() {
        mc.stop()
        lan.stop()
    }

    /// Hand the winning transport up and shut the other one down. Guarded because both can report
    /// `.connected` in the same runloop turn if two peers pair simultaneously.
    private func handOff(_ winner: any NearbyTransport, stopping loser: (any NearbyTransport)?) {
        guard !handedOff else { return }
        handedOff = true
        loser?.stop()
        onConnected(winner)
    }

    private var connectedPeerName: String? {
        mc.connectedPeerName ?? (lanActive ? lan.connectedPeerName : nil)
    }

    // MARK: - Content

    @ViewBuilder private var content: some View {
        switch uiPhase {
        case .idle:
            VStack(spacing: 16) {
                Text("Playing as **\(localName)**")
                    .foregroundStyle(.white.opacity(0.85))
                HStack(spacing: 18) {
                    bigButton("Host a game", systemImage: "wifi.router.fill", action: startHosting)
                    bigButton("Join a game", systemImage: "magnifyingglass", action: startBrowsing)
                }
                Text("Playing against an Android phone? Put both devices on the same Wi-Fi.")
                    .font(.caption).foregroundStyle(.white.opacity(0.55))
                    .multilineTextAlignment(.center)
            }

        case .hosting:
            VStack(spacing: 14) {
                ProgressView().tint(.white).controlSize(.large)
                Group {
                    if resuming {
                        Text("Waiting for the other player to rejoin…", comment: "Host is waiting during a resume")
                    } else {
                        Text("Waiting for a player to join…", comment: "Host is waiting for the second device")
                    }
                }
                    .foregroundStyle(.white)
                Group {
                    // Two whole sentences rather than one with a swapped-in button name: the name is
                    // itself a translated string, and where it falls in the sentence varies by language.
                    if resuming {
                        Text("Have the other player tap **Rejoin game** on their phone.",
                             comment: "Bold text matches the Rejoin game button's label")
                    } else {
                        Text("Have the other player tap **Join a game** on their phone.",
                             comment: "Bold text matches the Join a game button's label")
                    }
                }
                    .font(.caption).foregroundStyle(.white.opacity(0.6)).multilineTextAlignment(.center)
                radioHint
            }

        case .browsing where resumeRole == .guest:
            VStack(spacing: 12) {
                ProgressView().tint(.white).controlSize(.large)
                Text("Rejoining your game…").foregroundStyle(.white)
                Text("Make sure the other phone tapped **Rejoin game**.")
                    .font(.caption).foregroundStyle(.white.opacity(0.6)).multilineTextAlignment(.center)
            }

        case .browsing:
            VStack(spacing: 12) {
                HStack(spacing: 8) {
                    ProgressView().tint(.white)
                    Text("Looking for nearby games…").foregroundStyle(.white)
                }
                if rows.isEmpty {
                    VStack(spacing: 6) {
                        Text("No hosts yet — make sure the other phone is hosting.")
                            .font(.caption).foregroundStyle(.white.opacity(0.6))
                        Text("For an Android phone, both devices must be on the same Wi-Fi network.")
                            .font(.caption2).foregroundStyle(.white.opacity(0.45))
                        radioHint
                    }
                    .multilineTextAlignment(.center)
                } else {
                    VStack(spacing: 8) {
                        ForEach(rows) { row in
                            Button(action: row.connect) {
                                HStack {
                                    Image(systemName: row.overWiFi ? "wifi" : "person.fill")
                                    Text(verbatim: row.name).fontWeight(.semibold)
                                    Spacer()
                                    Image(systemName: "arrow.right.circle.fill")
                                }
                                .padding(.horizontal, 16).padding(.vertical, 12)
                                .background(RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(0.10)))
                                .foregroundStyle(.white)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .frame(maxWidth: 360)
                }
            }

        case .connecting:
            VStack(spacing: 12) {
                ProgressView().tint(.white).controlSize(.large)
                Group {
                    if resuming {
                        Text("Reconnecting your game…", comment: "Shown while a resumed game reconnects")
                    } else {
                        Text("Connecting…", comment: "Shown while two devices connect")
                    }
                }
                .foregroundStyle(.white)
                if resuming {
                    Text("Make sure the other phone also tapped **Rejoin game**.")
                        .font(.caption).foregroundStyle(.white.opacity(0.6)).multilineTextAlignment(.center)
                }
                if connectStalled {
                    VStack(spacing: 8) {
                        Group {
                            if resuming {
                                Text("Still trying. If it keeps failing, both players can go back and start a **New game** — or check that Local Network access is allowed in Settings (it can reset after reinstalling).",
                                     comment: "Stalled connection advice during a resume")
                            } else {
                                Text("Still trying — it keeps retrying on its own. Bring the phones closer, and check that Local Network access is allowed in Settings (it can reset after reinstalling).",
                                     comment: "Stalled connection advice")
                            }
                        }
                            .font(.caption).foregroundStyle(Color.cribGold).multilineTextAlignment(.center)
                        radioHint
                        Button("Back to menu") { stopAll(); onCancel() }
                            .buttonStyle(.borderedProminent).tint(.cribGold).foregroundStyle(.black)
                    }
                    .padding(.top, 6)
                    .frame(maxWidth: 380)
                }
            }

        case .connected:
            VStack(spacing: 12) {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 44)).foregroundStyle(.green)
                Text("Connected to \(connectedPeerName ?? String(localized: "player", comment: "Stand-in for an unknown peer's name"))!",
                     comment: "Shown once two devices are connected; %@ is the other device's name")
                    .foregroundStyle(.white)
            }

        case .disconnected:
            VStack(spacing: 12) {
                Text("Disconnected.").foregroundStyle(.white)
                Button("Try again", action: startBrowsing)
                    .buttonStyle(.borderedProminent).tint(.cribGold).foregroundStyle(.black)
            }
        }
    }

    /// The single most useful thing to tell someone whose phones won't pair. MultipeerConnectivity
    /// pairs over peer-to-peer Wi-Fi (AWDL) *or* Bluetooth; the Wi-Fi radio being switched on is what
    /// makes the fast path available, and it does not need to be joined to any network. With Wi-Fi off
    /// it's Bluetooth alone, which is dramatically slower to discover and to hand over — the case where
    /// "it just spins" comes from.
    private var radioHint: some View {
        Text("Tip: leave **Wi-Fi switched on** on both phones — you don't have to join a network. With Wi-Fi off, pairing falls back to Bluetooth alone and is much slower.")
            .font(.caption2).foregroundStyle(.white.opacity(0.5))
            .multilineTextAlignment(.center)
            .frame(maxWidth: 380)
    }

    private func bigButton(_ title: LocalizedStringKey, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 10) {
                Image(systemName: systemImage).font(.system(size: 30, weight: .bold))
                Text(title).font(.headline)
            }
            .frame(width: 160, height: 120)
            .background(RoundedRectangle(cornerRadius: 20).fill(Color.white.opacity(0.10)))
            .overlay(RoundedRectangle(cornerRadius: 20).stroke(Color.cribGold.opacity(0.5), lineWidth: 1))
            .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
    }
}
