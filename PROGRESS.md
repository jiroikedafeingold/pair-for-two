# Pair for Two — Build Progress & Handoff

_Last updated: 2026-07-05. Resume point for the next session._

A brand-new standalone iOS app: two people play a full game of **cribbage** using their phones
instead of a physical board and cards. Each player sees only their own hand; played cards are
visible to both; hands and crib are revealed at the show. **Scoring is manual (flag-only) for v1** —
the app is fully rule-aware and *flags* every scoring opportunity but never auto-applies points.

Full original design is in **`PLAN.md`** (repo root). This file tracks what's actually built.

---

## Status at a glance

| Step | Feature | Status |
|------|---------|--------|
| 1 | Models + Scorer (+ verification) | ✅ Done |
| 2 | Engine + LoopbackTransport | ✅ Done |
| 3 | Card + table UI on Loopback | ✅ Done |
| 4 | ScorePanel slider + WinnerOverlay + Haptics | ✅ Done |
| 5 | MultipeerTransport + ConnectView (two-device) | ✅ Done + **2-device smoke test passed** |
| 6 | Polish — **iPad** | ✅ Done |
| 6 | Polish — accessibility/VoiceOver, localization | ⛔ Deferred (user's call) |
| 7 | Reconnect / resume + persistence | ✅ Done (relaunch-resume verified; live Multipeer reconnect built) |

**The project builds clean** on iPhone 17 Pro and iPad Pro 13" (iOS 27 simulators). Active run
destination is currently iPhone 17 Pro.

### Recent changes (2026-07-05)

- **Game-start flow reworked**: cut-for-deal now holds the result (each taps to cut → both cards
  shown → **lower card wins, deals & takes the first crib** → tap **Deal**). The separate manual
  "cut the starter" step is **gone** — the starter is auto-cut after discards and pegging begins
  immediately. **The starter card is not shown during pegging** (only at the show).
- **Reconnect/resume**: host persists `GameState` to Application Support (`Persistence.swift`); the
  menu offers **Resume game** after a relaunch (verified). `MultipeerSession` auto-rejoins after a
  drop (`.reconnecting` → re-advertise/browse → resync).
- **Settings** (gear, top-right of table): per-player **Confirm after release** / **Confirm after +1**
  toggles → `ScorePanel`, persisted to UserDefaults.
- **Bigger cards**: discard/show cards enlarged; pegging hand clamped so the pile+hand still fit the
  short landscape band. All phases verified within a 402pt-tall screen.
- Known minor: **his-heels** flag window is brief (overwritten by the first pegging play) — fine for
  v1 manual scoring.

---

## ▶️ Where to resume tomorrow

The recommended next milestone is a **two-physical-device Multipeer smoke test** (see below), because
the networking (step 5) and the future reconnect/resume (step 7) can't be meaningfully verified on a
single simulator. After that, the open work is:

1. **Two-device smoke test** of `MultipeerSession`: on two real phones, Play nearby → one Hosts, one
   Joins → confirm connect, deal, discard, pegging, the show, and hidden-info (opponent's hand never
   visible pre-show). Also try backgrounding one phone mid-hand to see what breaks (feeds step 7).
2. **Reconnect / resume + persistence** (step 7, PLAN.md "Reconnect / resume" section) — not built.
   Plan: a `Persistence.swift` that writes `GameState` (host) + each device's last `PlayerSnapshot` +
   peer/match token to Application Support (JSON); a "Resume game" entry on the menu; transport-level
   auto-rejoin in `MultipeerSession` (keep advertising/browsing after a drop, re-emit `.reconnecting`
   / `.connected`, host replays the current snapshot). The "Reconnecting…" **banner already exists**
   in `GameTableView`; the auto-rejoin + persistence do not.
3. **Accessibility/VoiceOver + localization** (deferred half of step 6). `CardView` already sets a
   VoiceOver label per card (`Card.accessibleName`, e.g. "Seven of Hearts"). Localization would edit
   an `.xcstrings` catalog directly (see the project's CLAUDE.md rules on bulk translation).

---

## Architecture

```
Views (SwiftUI)  ─▶  GameViewModel (@MainActor @Observable, NO SwiftUI import)  ─▶  CribbageEngine
                                    │                                                    │
                                    ▼                                                    ▼
                            GameTransport (protocol)                        CribbageScorer + Models
                     ┌──────────────┼───────────────┐                       (pure, `nonisolated`)
              Loopback        Multipeer        (Game Center, future)
              (dev/test)      (in-person)
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
| `LoopbackTransport.swift` | Single-process transport for pass-and-play / dev. |
| `MultipeerTransport.swift` | `MultipeerSession` (MCSession + advertiser/browser, `@Observable`, `GameTransport`). |
| `GameViewModel.swift` | 3 roles behind `.loopback(...)` / `.networked(...)` factories. |
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
- **Play now**: run on a simulator → "Play on one phone" (pass-and-play, both players on one device).
- **Two-device**: run on two phones → "Play nearby" → one Hosts, the other Joins.
- **Verify pure logic**: `RunCodeSnippet` against `CribbageScorer.swift` or `CribbageEngine.swift`.

## Git

Nothing has been committed yet — all step 1–6 work is uncommitted in the working tree (the repo has a
single "Initial Commit"). Consider committing before starting tomorrow.
