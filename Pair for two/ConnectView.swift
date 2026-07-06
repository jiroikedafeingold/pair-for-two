import SwiftUI
import MultipeerConnectivity

/// Which side is rejoining a saved game (host re-hosts its state, guest reconnects to the host).
enum ResumeRole { case host, guest }

/// Host or join a nearby game over MultipeerConnectivity. No internet, no accounts. On success it
/// hands the live `MultipeerSession` (a `GameTransport`) up to `RootView`, which builds the game.
struct ConnectView: View {
    let localName: String
    let localColorID: Int
    var resumeRole: ResumeRole? = nil    // set → auto-(re)connect in that role for a saved game
    var onConnected: (MultipeerSession) -> Void
    var onCancel: () -> Void

    @State private var session: MultipeerSession
    @State private var resumeStalled = false   // surfaced after a while so a stuck resume isn't a silent spinner

    private var resuming: Bool { resumeRole != nil }

    init(localName: String, localColorID: Int, resumeRole: ResumeRole? = nil,
         onConnected: @escaping (MultipeerSession) -> Void,
         onCancel: @escaping () -> Void) {
        self.localName = localName
        self.localColorID = localColorID
        self.resumeRole = resumeRole
        self.onConnected = onConnected
        self.onCancel = onCancel
        _session = State(initialValue: MultipeerSession(displayName: localName))
    }

    var body: some View {
        ZStack {
            LinearGradient(colors: [.feltMid, .feltDark], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()

            VStack(spacing: 20) {
                Text(resuming ? "Resume Game" : "Play Nearby")
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
                        session.stop()
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
        .onChange(of: session.phase) { _, phase in
            if phase == .connected { onConnected(session) }
        }
        .onAppear {
            // Resuming: both phones advertise *and* browse and auto-pair, regardless of their stored
            // role — so a stale "both are host" marker state can't deadlock. The host is decided by
            // who holds the saved state (in onConnected), not by who advertises.
            if resuming, session.phase == .idle { session.startRendezvous() }
        }
        .task {
            // If a resume hasn't paired after a while, stop pretending and offer a way out.
            guard resuming else { return }
            try? await Task.sleep(for: .seconds(15))
            if session.phase != .connected { resumeStalled = true }
        }
    }

    @ViewBuilder private var content: some View {
        switch session.phase {
        case .idle:
            VStack(spacing: 16) {
                Text("Playing as **\(localName)**")
                    .foregroundStyle(.white.opacity(0.85))
                HStack(spacing: 18) {
                    bigButton("Host a game", systemImage: "wifi.router.fill") { session.startHosting() }
                    bigButton("Join a game", systemImage: "magnifyingglass") { session.startBrowsing() }
                }
            }

        case .hosting:
            VStack(spacing: 14) {
                ProgressView().tint(.white).controlSize(.large)
                Text(resuming ? "Waiting for the other player to rejoin…" : "Waiting for a player to join…")
                    .foregroundStyle(.white)
                Text("Have the other player tap **\(resuming ? "Rejoin game" : "Join a game")** on their phone.")
                    .font(.caption).foregroundStyle(.white.opacity(0.6)).multilineTextAlignment(.center)
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
                if session.discoveredPeers.isEmpty {
                    Text("No hosts yet — make sure the other phone is hosting.")
                        .font(.caption).foregroundStyle(.white.opacity(0.6))
                } else {
                    VStack(spacing: 8) {
                        ForEach(session.discoveredPeers, id: \.self) { peer in
                            Button { session.invite(peer) } label: {
                                HStack {
                                    Image(systemName: "person.fill")
                                    Text(peer.displayName).fontWeight(.semibold)
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

        case .connecting, .reconnecting:
            VStack(spacing: 12) {
                ProgressView().tint(.white).controlSize(.large)
                Text(resuming ? "Reconnecting your game…" : "Connecting…").foregroundStyle(.white)
                if resuming {
                    Text("Make sure the other phone also tapped **Rejoin game**.")
                        .font(.caption).foregroundStyle(.white.opacity(0.6)).multilineTextAlignment(.center)
                }
                if resumeStalled {
                    VStack(spacing: 8) {
                        Text("Still can't find the other phone. If it keeps failing, both players can go back and start a **New game** — or check that Local Network access is allowed in Settings (it can reset after reinstalling).")
                            .font(.caption).foregroundStyle(Color.cribGold).multilineTextAlignment(.center)
                        Button("Back to menu") { session.stop(); onCancel() }
                            .buttonStyle(.borderedProminent).tint(.cribGold).foregroundStyle(.black)
                    }
                    .padding(.top, 6)
                    .frame(maxWidth: 360)
                }
            }

        case .connected:
            VStack(spacing: 12) {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 44)).foregroundStyle(.green)
                Text("Connected to \(session.connectedPeerName ?? "player")!").foregroundStyle(.white)
            }

        case .disconnected:
            VStack(spacing: 12) {
                Text("Disconnected.").foregroundStyle(.white)
                Button("Try again") { session.startBrowsing() }
                    .buttonStyle(.borderedProminent).tint(.cribGold).foregroundStyle(.black)
            }
        }
    }

    private func bigButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
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
