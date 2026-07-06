# Pair for Two — Build Progress & Handoff

_Last updated: 2026-07-05 (end of day). Resume point for the next session._

A standalone iOS app: two people play a full game of **cribbage** on their phones instead of a
physical board and cards. Each player sees only their own hand; played cards are visible to both;
hands and crib are revealed at the show. **Three scoring modes** (Settings): **Automatic** (engine
scores everything), **Feedback** (flags opportunities, you tally on the slider), **Player
responsibility** (no hints). The engine is fully rule-aware.

Full original design is in **`PLAN.md`**; the remote-play design is in **`REMOTE_PLAY_PLAN.md`**.
This file tracks what's actually built.

---

## Status at a glance

**All core steps (1–7) are done and the 2-device Multipeer game is user-confirmed working.**
Current version **1.0.2 (build 3)**. Builds clean on iPhone 17 Pro / iPad Pro 13" (iOS 27 sims).
Active run destination: iPhone 17 Pro.

| Step | Feature | Status |
|------|---------|--------|
| 1–4 | Models, Scorer, Engine, table UI, ScorePanel, WinnerOverlay, Haptics | ✅ Done |
| 5 | MultipeerTransport + ConnectView (two-device) | ✅ Done + 2-device smoke test passed |
| 6 | Polish — iPad | ✅ Done |
| 6 | Polish — accessibility/VoiceOver, localization | ⛔ Deferred (user's call) |
| 7 | Reconnect / resume + persistence | ✅ Done |
| — | **Online play over Game Center** (Phases 0–5) | ✅ Built, **not yet device-tested** |
| — | Online play Phase 6 (disconnect/"opponent left" polish) | ⬜ Next |

### Long tail of refinements since the core build (all 2026-07-05, all committed & pushed)

- **Three scoring modes** (`ScoringMode`: `.auto`/`.feedback`/`.off`) chosen in Settings, synced live
  between devices via `.setScoringMode`. Auto mode hides the sliders and shows big names + scores.
- **Quit game**: a leave button (top-left of the table) → confirm → sends `.quitGame`, which **ends
  the game on both phones and clears the saved game on both** (so neither offers "Rejoin").
- **Robust resume**: both phones "rejoin" via a **rendezvous** (advertise *and* browse at once), and
  the host is chosen by which phone actually holds the saved state (`GamePersistence.hasSavedState`) —
  fixes the "both spin forever" deadlock. Guests clear their stale state file.
- **Join-list ghost peers fixed**: discovered peers are deduped by display name (each host relaunch
  mints a new `MCPeerID`, and MC's `lostPeer` is unreliable) — so the join list shows one live row.
- Scoring UX: opponent "+X" preview next to their score in their colour; feedback flags in the
  counter's colour led by their name; the non-counter's panel is inert during the show; "Continue"
  folds a pending slider value ("Add N & continue").
- Icon (higher-contrast two-queens crop), iPad show-screen centering, and other layout polish.

### Online play (Game Center) — what's built (Phases 0–5)

- **Entitlement**: `com.apple.developer.game-center` (via `AddEntitlement`).
- **`GameCenterManager.swift`**: authenticates `GKLocalPlayer` at launch, presents the sign-in VC,
  exposes `isAuthenticated`; builds the matchmaker VC; registers a `GKLocalPlayerListener` and
  surfaces accepted invites (`pendingInvite`/`inviteTick`/`takePendingInvite()`).
- **`MatchmakerView.swift`**: `UIViewControllerRepresentable` over `GKMatchmakerViewController`
  (+ `MatchmakerContext` Identifiable box) → reports the ready `GKMatch` / cancel / error.
- **`GameCenterTransport.swift`**: `GKMatch`-backed `GameTransport` (`@unchecked Sendable`) — JSON
  `GameMessage`s over `match.sendData(...reliable)`; connect/disconnect from `GKMatchDelegate`.
- **RootView**: an auth-gated **"Play online"** button presents the matchmaker (`fullScreenCover`);
  accepted invites auto-present it; a ready match → build transport → `GameViewModel.networked(...,
  resumable: false)` → game. Host elected deterministically by `gamePlayerID`.
- **`resumable` flag** on `GameViewModel` (false for GC) gates all `GamePersistence` writes so online
  games never write a Multipeer-only "Rejoin" marker.

---

## ▶️ Where to resume tomorrow

Online play (Game Center) is **built but never run on real hardware**. Two tracks:

1. **On-device smoke test of online play** (the blocker). Needs, outside the code:
   - **App Store Connect**: enable **Game Center** for the app's bundle ID.
   - **Two devices, two different Game Center accounts** (sandbox / TestFlight) that are **Game Center
     friends** — the matchmaker's picker shows friends/recent players, *not* a username search.
   - Then: both sign in → "Play online" on one → invite the friend → accept → confirm a full game
     (cut, discard, pegging, show, win), the **quit** flow, and what a mid-game disconnect looks like.
   - Note: in the **simulator** the "Play online" button stays disabled (its sign-in hint shows) —
     that's expected; Game Center needs a real device + configured app.
2. **Online play Phase 6** (polish, can do before/after the test): a real-time `GKMatch` can't be
   rejoined after a hard exit, so make a drop graceful — surface **"Opponent left"** and return to the
   menu instead of the nearby-style "Reconnecting…" spin. `GameCenterTransport.reconnect()` is a
   deliberate no-op; the disconnect currently just sets `connection = .disconnected`.

Deferred (unchanged): **accessibility/VoiceOver + localization** (`CardView` already sets a per-card
VoiceOver label via `Card.accessibleName`; localization would edit an `.xcstrings` catalog directly).

**Invite-UX caveat / fallback:** if the Game Center friend-invite flow proves annoying in practice,
the documented fallback (see `REMOTE_PLAY_PLAN.md`) is a **room-code WebSocket relay** — nicer pairing
(type a code) using only native `URLSessionWebSocketTask`, at the cost of running a small server.

---

## Architecture

```
Views (SwiftUI)  ─▶  GameViewModel (@MainActor @Observable, NO SwiftUI import)  ─▶  CribbageEngine
                                    │                                                    │
                                    ▼                                                    ▼
                            GameTransport (protocol)                        CribbageScorer + Models
              ┌──────────────┬─────┴────────┬───────────────┐               (pure, `nonisolated`)
          Loopback       Multipeer      Game Center
          (dev/test)     (nearby)       (online, built — untested on device)
```

- **Pure types are `nonisolated`** (models, deck, scorer, engine, state) so they never hop onto the
  main actor. The project sets `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, so pure types are
  explicitly marked `nonisolated`.
- **ViewModel never imports SwiftUI**; views stay thin.
- **Host-authoritative**: the host owns the one true `GameState` and runs the engine. Guests send
  *intents* and render redacted `PlayerSnapshot`s. A player's hole cards are only ever placed in that
  player's snapshot until a reveal phase — the wire never carries the opponent's hand pre-show.

### Files (all under `Pair for two/Pair for two/`)

| File | What it is |
|------|------------|
| `Card.swift` | `Suit`, `Rank` (countingValue A=1/face=10, orderValue A=1…K=13), `Card` (Codable/Hashable/Identifiable, `accessibleName` for VoiceOver). |
| `CribbageModels.swift` | `Deck` (52 cards, seeded reproducible shuffle via `SeededGenerator` SplitMix64), `PlayerID` (.one/.two), `Seat` (.dealer/.pone), `GamePhase`. |
| `CribbageScorer.swift` | Pure `nonisolated enum`. `ScoreFlag` (kind/points/detail). `handScore`, `peggingScore`, `legalPlays`, `mustSayGo`, `isHisHeels`. Correct on all canonical hands incl. the **29-hand**. |
| `CribbageEngine.swift` | Host referee. Validates intents, advances phases, surfaces `activeFlags` — **never auto-scores** (scores change only via `claim`). Manages pegging go/31/lap/last-card. |
| `GameState.swift` | Authoritative `GameState` + `snapshot(for:)` redaction + `PlayerSnapshot` (wire type). |
| `GameTransport.swift` | `GameTransport` protocol, `GameMessage` enum, `TransportEvent`. |
| `LoopbackTransport.swift` | Single-process transport for previews / dev. |
| `MultipeerTransport.swift` | `MultipeerSession` (MCSession + advertiser/browser, `@Observable`, `GameTransport`). Rendezvous + peer dedupe. |
| `GameCenterManager.swift` | Game Center auth + matchmaker VC factory + invite listener (`@MainActor @Observable`). |
| `GameCenterTransport.swift` | `GKMatch`-backed `GameTransport` (`@unchecked Sendable`). |
| `MatchmakerView.swift` | `UIViewControllerRepresentable` over `GKMatchmakerViewController` + `MatchmakerContext`. |
| `Persistence.swift` | `GamePersistence` — host state file + `ResumeMarker`; `hasSavedState`. |
| `SettingsView.swift` | Name/colour + 3 scoring modes + "Confirm after release" (`@AppStorage`). |
| `GameViewModel.swift` | 3 roles behind `.loopback(...)` / `.networked(..., resumable:)` / `.resumeHost(...)`; `quit()`/`ended`. |
| `Themes.swift` | Felt palette + 12 `playerThemes` (from Criboard), `colorID`→theme. |
| `Haptics.swift` | `WinHaptics` + `DragTickHaptics` (from Criboard, as-is). |
| `CardView`,`HandView`,`PlayPileView`,`ScoreFlagsView`,`ScorePanel`,`WinnerOverlay`,`GameTableView`,`ConnectView`,`RootView` | SwiftUI. |
| `ContentView.swift` | `@main PairForTwoApp` → `RootView()`. |

---

## Key decisions & deviations from PLAN.md

- **Added a `.advance` message** (not in the original PLAN's message list) to step through the three
  show sub-phases (pone → dealer → crib) and into the next deal. The original set had no way to
  progress the show.
- **Pegging keeps the 4-card `hands` intact** and derives `unplayed(of:)` from `playSequence`, so the
  show can still count the original hands after pegging.
- **Loopback shows BOTH score panels** (each player scores their own peg — correct for pass-and-play,
  matches Criboard). **Networked shows ONE panel** (the local player's), via `vm.scorablePlayers`.
- **Winner attribution / claims**: manual scoring is "trust the players." His-heels, pegging points,
  and the show are all claimed on the slider. `playersWithClaims` was added to `PlayerSnapshot` so a
  guest (no local state) can still enable/disable its Undo button.
- **Landscape-only** locked via `UpdateTargetBuildSetting` (iPhone + iPad orientations =
  LandscapeLeft/Right). No `.pbxproj` hand-edits.
- **Multipeer Info.plist**: `NSLocalNetworkUsageDescription` + `NSBonjourServices`
  (`_pairfortwo._tcp` / `_pairfortwo._udp`) added via the `AddInfoPlist` MCP tool → the generated
  `Pair-for-two-Info.plist`.

---

## Verification done so far

- **Scorer** (`RunCodeSnippet`): 29-hand = 29 (16 fifteens + 12 pairs + 1 nobs), runs incl.
  double-double = 24, flush rules (4 in hand, none in crib, 5 in crib), pegging 15/31/pair/run/
  pair-royal, `mustSayGo`/`legalPlays`/`isHisHeels`, seeded deck reproducible. All pass.
- **Engine** (`RunCodeSnippet`): full 11-hand game driven to 121 → gameOver + winner; dealer
  alternates; hidden info enforced (opponent hand nil pre-show, revealed at show, crib at showCrib);
  all 8 cards played each hand; `PlayerSnapshot` Codable round-trips.
- **UI (iPhone 17 Pro sim, device-interaction)**: start menu → cut → deal → discard render/advance;
  ScorePanel +1 increments and slider adds points on release; cut-for-deal fits on screen; pass-and-
  play regression intact after the networking refactor; Connect screen shows Host("waiting") /
  Join("looking").
- **iPad (RenderPreview, iPad Pro 13")**: balanced top band, panels not stretched, big legible cards.

### NOT yet verified
- **Real two-device Multipeer connection** (needs two physical devices — simulators don't reliably
  discover each other). Everything up to `.connected` is exercised by loopback; the actual peer
  handshake/data path is unverified.
- **Winner overlay driven to a live win on-device** (logic is a direct port of Criboard's working
  overlay; compiles and is wired in).
- **No unit-test target exists** (see gotchas). All logic verified via `RunCodeSnippet`.

---

## Project gotchas (important for next session)

- **`XcodeWrite` path**: to land a file in the app target, use the DOUBLE prefix
  `"Pair for two/Pair for two/<File>.swift"`. A single `"Pair for two/<File>.swift"` writes to the
  repo ROOT and adds a stray `PBXFileReference` → "Multiple commands produce …stringsdata". Fix a
  stray ref with `XcodeRM path:"Pair for two/<File>.swift" deleteFiles:false`.
- **No unit-test target.** Only the app target exists; creating one needs a user Xcode action
  (File ▸ New ▸ Target ▸ Unit Testing Bundle). Until then verify pure logic with `RunCodeSnippet`
  against a source file. (User deferred adding the test target.)
- **Never hand-edit `.pbxproj`** (hard rule). Use MCP tools: `UpdateTargetBuildSetting`,
  `AddInfoPlist`, `XcodeWrite`/`XcodeRM` (synchronized file groups auto-include dropped files).
- **Concurrency**: project is MainActor-by-default + `SWIFT_APPROACHABLE_CONCURRENCY`. In
  `MultipeerSession`, `session`/`myPeerID` are `nonisolated(unsafe) let` and the MC delegate methods
  are `nonisolated` (they hop to `@MainActor` via `Task`); `events`/`continuation` are `nonisolated`.
  In `GameViewModel`, `eventsTask` is `nonisolated(unsafe)` (deinit access) and `listen()` uses weak
  self to avoid a retain cycle.
- **iPad device-interaction session was flaky** ("invalid screen scale" on a cold-booted sim) — used
  `RenderPreview` instead. `GameTableView` has a `#Preview` (`GameTablePreview`, loopback) for this.
- Deployment target is **iOS 18.6** in the project (PLAN says min iOS 17). Write iOS-17-safe code but
  the target is higher. Don't bump the deployment target without asking.

---

## How to run / test

- **Build**: `BuildProject` MCP tool (or `xcodebuild -scheme "Pair for two" -destination
  'platform=iOS Simulator,name=iPhone 16' build`). Scheme name = `Pair for two`.
- **Nearby (two phones)**: run on two phones → "Play nearby" → one Hosts, the other Joins.
- **Online (Game Center)**: needs a real device signed into Game Center + the app configured for Game
  Center in App Store Connect → "Play online" → invite a Game Center friend. Disabled in the sim.
- **Verify pure logic**: `RunCodeSnippet` against `CribbageScorer.swift` or `CribbageEngine.swift`.
- **Preview**: `RenderPreview` (note: it has been throwing a transient "data couldn't be read" error
  lately — unrelated to the code; fall back to `BuildProject` to confirm compilation).

## Git

All work is **committed and pushed to `main`** (remote up to date). Latest: `a66be8e` "Online play
Phase 2-5". Versioning: bump build number + patch version (agvtool) after each push — currently
**1.0.2 (3)**. Never hand-edit `.pbxproj`.
