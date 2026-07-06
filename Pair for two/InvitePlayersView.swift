import SwiftUI
import GameKit

/// Custom "invite a friend" screen for online play. Lists Game Center friends / recent players and
/// invites the tapped one directly (no automatch — that path is flaky in the sandbox). Because Game
/// Center gates friend access, the list can be empty; a fallback presents Apple's own picker.
struct InvitePlayersView: View {
    let gameCenter: GameCenterManager
    var onUseGameCenterPicker: () -> Void
    var onCancel: () -> Void

    @State private var friends: [GKPlayer] = []
    @State private var loaded = false

    var body: some View {
        ZStack {
            LinearGradient(colors: [.feltMid, .feltDark], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()

            VStack(spacing: 18) {
                Text("Invite a Friend")
                    .font(.system(size: 30, weight: .heavy, design: .serif))
                    .foregroundStyle(.white)

                content
            }
            .padding(28)
            .frame(maxWidth: 520)

            VStack {
                HStack {
                    Button {
                        gameCenter.cancelInvite()
                        onCancel()
                    } label: {
                        Label("Back", systemImage: "chevron.left")
                            .font(.callout.weight(.semibold)).foregroundStyle(.white)
                    }
                    Spacer()
                }
                Spacer()
            }
            .padding(20)
        }
        .task {
            friends = await gameCenter.loadInvitablePlayers()
            loaded = true
        }
    }

    @ViewBuilder private var content: some View {
        switch gameCenter.inviteState {
        case .inviting(let name):
            VStack(spacing: 14) {
                ProgressView().tint(.white).controlSize(.large)
                Text("Inviting \(name)…").foregroundStyle(.white)
                Text("They'll get a Game Center notification — keep this screen open until they join.")
                    .font(.caption).foregroundStyle(.white.opacity(0.6)).multilineTextAlignment(.center)
                Button("Cancel invite") { gameCenter.cancelInvite() }
                    .buttonStyle(.bordered).tint(.white)
            }

        case .failed(let message):
            VStack(spacing: 14) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 34)).foregroundStyle(Color.cribGold)
                Text(message).foregroundStyle(.white).multilineTextAlignment(.center)
                Button("Back to friends") { gameCenter.cancelInvite() }
                    .buttonStyle(.borderedProminent).tint(.cribGold).foregroundStyle(.black)
            }

        default:
            friendList
        }
    }

    @ViewBuilder private var friendList: some View {
        if !loaded {
            VStack(spacing: 12) {
                ProgressView().tint(.white).controlSize(.large)
                Text("Loading your Game Center friends…")
                    .font(.caption).foregroundStyle(.white.opacity(0.7))
            }
        } else if friends.isEmpty {
            VStack(spacing: 14) {
                Image(systemName: "person.2.slash.fill")
                    .font(.system(size: 34)).foregroundStyle(.white.opacity(0.5))
                Text("No friends to show yet")
                    .font(.headline).foregroundStyle(.white)
                Text("Add each other as Game Center friends and open Pair for Two once, or use Game Center's own inviter.")
                    .font(.caption).foregroundStyle(.white.opacity(0.6)).multilineTextAlignment(.center)
                Button("Invite with Game Center") { onUseGameCenterPicker() }
                    .buttonStyle(.borderedProminent).tint(.cribGold).foregroundStyle(.black)
            }
        } else {
            VStack(spacing: 12) {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(friends, id: \.gamePlayerID) { player in
                            Button { gameCenter.invite(player) } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "person.crop.circle.fill")
                                    Text(player.displayName).fontWeight(.semibold)
                                    Spacer()
                                    Image(systemName: "paperplane.fill")
                                }
                                .padding(.horizontal, 16).padding(.vertical, 12)
                                .background(RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(0.10)))
                                .foregroundStyle(.white)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(maxHeight: 320)

                Button("Invite with Game Center instead") { onUseGameCenterPicker() }
                    .font(.footnote.weight(.semibold)).foregroundStyle(Color.cribGold)
            }
        }
    }
}
