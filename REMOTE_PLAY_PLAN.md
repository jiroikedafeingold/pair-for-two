# Remote play over Game Center — implementation plan

## Principle
Remote play adds **one transport + one pairing screen**. The engine, `GameViewModel`,
snapshots, scoring, and `GameMessage` protocol are untouched — everything already routes
through `GameTransport`:

```swift
protocol GameTransport: Sendable {
    var isHost: Bool { get }
    var events: AsyncStream<TransportEvent> { get }   // .connected/.disconnected/.received
    func send(_ message: GameMessage) async
    func reconnect()
}
```

Game Center maps almost 1:1:
- `GKMatch.send(_:to:.reliable)` ↔ `send(_:)`
- `match(_:didReceive:fromRemotePlayer:)` ↔ `.received(GameMessage)`
- `match(_:player:didChange:)` ↔ `.connected` / `.disconnected`
- host chosen deterministically (see Phase 4) ↔ `isHost`

Result: `GameViewModel.networked(transport:...)` works verbatim with a Game Center match.

## Phase 0 — Project / App Store Connect setup (config, not code)
- Add the **Game Center** capability (Signing & Capabilities). This adds the
  `com.apple.developer.game-center` entitlement. **Do not hand-edit the pbxproj** — use
  Xcode's capability UI or the `AddEntitlement` MCP tool.
- In App Store Connect, enable Game Center for the app's (real, explicit) bundle ID —
  already set up for Xcode Cloud. Real-time matches need no leaderboards/achievements.
- No server, no push certs. Apple relays the match and handles NAT.

## Phase 1 — Authentication (`GameCenterManager.swift`, no SwiftUI)
- `@Observable @MainActor final class GameCenterManager` with `isAuthenticated`.
- At launch: `GKLocalPlayer.local.authenticateHandler = { vc, error in ... }`.
  - `vc != nil` → present it (sign-in UI).
  - `error == nil && vc == nil` → `isAuthenticated = true`.
  - otherwise → disable online play, keep nearby play working.
- Register the invite listener once: `GKLocalPlayer.local.register(self)` (conform to
  `GKLocalPlayerListener`).

## Phase 2 — Pairing / invite UI
- Menu gains **"Play online"** (rename current "Play" → "Play nearby"; both remain).
- Tapping it presents `GKMatchmakerViewController(matchRequest:)` with
  `minPlayers = 2, maxPlayers = 2`, wrapped in a `UIViewControllerRepresentable`
  (the one sanctioned UIKit bridge).
- `GKMatchmakerViewControllerDelegate.matchmakerViewController(_:didFind:)` hands back a
  ready `GKMatch` → dismiss → build the transport (Phase 3).
- **Incoming invite:** `GKInviteEventListener.player(_:didAccept:)` fires → present
  `GKMatchmakerViewController(invite:)` → same `didFind:` → same path.

## Phase 3 — `GameCenterTransport.swift`
`final class GameCenterTransport: NSObject, GKMatchDelegate, GameTransport`
- Holds the `GKMatch`; builds the `events` `AsyncStream` + continuation (mirror
  `MultipeerSession`).
- `isHost: Bool` set once at construction (Phase 4).
- `send(_:)` → `try? match.send(JSONEncoder().encode(msg), to: match.players, dataMode: .reliable)`
  with the same outbox/buffer-on-failure pattern already in `MultipeerSession`.
- Delegate:
  - `match(_:didReceive:fromRemotePlayer:)` → decode → `yield(.received(msg))`
  - `match(_:player:didChange:)`: `.connected` → `.connected`; `.disconnected` → `.disconnected`
  - `match(_:didFailWithError:)` → `.disconnected`
- `reconnect()` → best-effort; real-time GKMatch can't re-add a dropped peer, so surface
  "connection lost" rather than silently spin (see Phase 6).

## Phase 4 — Host election
GKMatch has no built-in host. Pick one **deterministically, no round trip**:
`isHost = GKLocalPlayer.local.gamePlayerID < opponent.gamePlayerID`.
Construct the transport with that value, then build the VM — same ordering we already use
in `RootView.onConnected` (set `isHost` before creating the `GameViewModel`).
(Alternative: `match.chooseBestHostingPlayer` picks the best-connected peer, but it's async
and unnecessary for a 2-player game.)

## Phase 5 — Wire into `RootView`
- Add the "Play online" button + a `@State` for the matchmaker sheet.
- On `didFind: match`:
  ```swift
  let t = GameCenterTransport(match: match, isHost: elected)
  vm = GameViewModel.networked(transport: t, localName: playerName,
                               localColorID: colorID, scoringMode: mode)
  screen = .game
  ```
- Nothing else changes — the table, scoring, show, winner overlay all just work.

## Phase 6 — Lifecycle, resume, background
- Real-time GKMatch **ends** when a player force-quits/backgrounds too long — it does not
  persist like Multipeer. Decisions:
  - **v1:** remote games are *not* offered for "Rejoin" after a hard exit. Gate the resume
    marker so it's only written for nearby (Multipeer) games. A brief drop still shows the
    existing "Reconnecting…" banner; a real end → "Opponent left" → back to menu.
  - **later (optional):** for true async/resume, add a `GKTurnBasedMatch` transport — same
    protocol, different backing. Bigger change; defer.
- Reuse the existing `quit`/`.quitGame` flow: on remote quit, `match.disconnect()` after the
  message flushes.

## Phase 7 — Testing
- **Two physical devices, two different sandbox Game Center accounts** (or TestFlight
  builds). Simulator Game Center is flaky — prefer devices.
- Checklist: auth on both → invite sent → accepted → match forms → exactly one host →
  full game (cut, discard, pegging, show, win) → disconnect handling → quit propagates.

## Honest caveats (the reason this is "medium effort")
- **Invite UX:** `GKMatchmakerViewController`'s friend picker shows Game Center **friends /
  recent players** — there's no "search by username." For two known people this means they
  either add each other as Game Center friends once, or use "recent players" after a first
  automatch. If that friction is unacceptable, the room-code relay gives a nicer pairing
  experience at the cost of running a server.
- **Config tax:** the code is modest; the time goes into the capability/App Store Connect
  setup and sandbox-account testing. Budget ~1–2 sessions.

## File touch list
- **New:** `GameCenterManager.swift`, `GameCenterTransport.swift`,
  `MatchmakerView.swift` (UIViewControllerRepresentable).
- **Edit:** `RootView.swift` (menu + match handling), entitlements (via capability UI / MCP).
- **Unchanged:** `CribbageEngine`, `GameViewModel`, `GameState`, all views, `GameMessage`.
