# Pair for Two — Two-Phone Cribbage

## Context

Build a brand-new standalone iOS app, **"Pair for two,"** that lets two people play a full game of
cribbage using their phones instead of a physical board and cards. Each player sees only their own
hand; cards that are *played* are visible to both; hands and the crib are revealed to both only at
the show (counting). Scoring is **manual for v1**, entered through the **slider** taken from the
existing **Criboard** app — but the app is fully rule-aware and *flags* every scoring opportunity
(15s, pairs, runs, go, 31, last card, his heels, nobs) so nothing is missed. Automatic scoring is a
deliberate future option, not v1.

Decisions locked in with the user:
- **Reuse from Criboard = the slider score panel only** (`PlayerPanel` + `PointsSlider`), **not** the
  pegging board. Replace the name watermark behind the slider with a live **`XX / YY`** readout
  (your score / opponent's score).
- **Networking:** a `GameTransport` protocol abstraction. Ship **MultipeerConnectivity** first
  (in-person, Bluetooth + peer-to-peer Wi-Fi, **no internet, no accounts**). Add **Game Center
  (`GKMatch`)** for remote play later behind the same protocol.
- **Score assist:** flag-only. Detect and surface the correct count, never block or auto-correct.
  (Muggins / gentle-warn kept as future toggles.)
- **Match format:** single game to 121, reusing Criboard's skunk (< 91) / double-skunk (< 61) lines
  and winner celebration.
- **Code reuse:** copy the needed Criboard views into the new app and adapt (no shared package).

Orientation: **landscape**, held like Criboard. Top ~1/3 = the Criboard slider panel + phase/flag
banner. Bottom ~2/3 = your hand and the shared play area.

---

## New Xcode project (prerequisite — user action)

There is no MCP tool to scaffold an `.xcodeproj`, and editing `project.pbxproj` by hand is a hard
rule violation. So **step 0 is the user creating a blank project in Xcode**:

- File ▸ New ▸ Project ▸ **iOS App**, name **`Pair for two`**, Interface **SwiftUI**, Language
  **Swift**, save into `/Users/jirofeingold/Projects/Pair for two/`.
- Deployment target **iOS 17.0**; supported orientation **Landscape Left/Right only**.
- Once the project exists, this project appears to use **synchronized file groups** (like StarBattle),
  so new `.swift` files dropped on disk are auto-included — I add code by writing files into the
  target folder.

Everything below is the code I then write into that target.

---

## Architecture (MVVM, SwiftUI-only, async/await)

Layered so the game is testable without any networking:

```
Views (SwiftUI)  ─▶  GameViewModel (@MainActor, @Observable)  ─▶  CribbageEngine
                                    │                                   │
                                    ▼                                   ▼
                            GameTransport (protocol)            CribbageScorer + Models
                        ┌───────────┼────────────┐              (pure, `nonisolated`)
                 Multipeer     Loopback      (GameCenter,
                 (v1)          (dev/test)     future)
```

- **Pure types are `nonisolated`** (models, deck, scorer) so they never hop onto the main actor
  (per the project's main-actor-by-default rule).
- **ViewModels never import SwiftUI**; views stay thin.

### Models — `CribbageModels.swift`, `Card.swift` (pure, `nonisolated`)
- `Suit` (♠♥♦♣), `Rank` (A…K) with `countingValue` (A=1, face=10) and `orderValue` (A=1…K=13 for runs).
- `Card: Codable, Hashable, Identifiable`.
- `Deck` — 52 cards, `shuffled(seed:)` (seeded so the host can reproduce/verify).
- `Seat` (`.dealer` / `.pone`) and `PlayerID` (`.one` / `.two`); dealer alternates each hand.
- `GamePhase`: `.connecting`, `.cutForDeal`, `.dealing`, `.discardToCrib`, `.cutStarter`,
  `.pegging`, `.showPone`, `.showDealer`, `.showCrib`, `.handComplete`, `.gameOver`.
- `GameState` — authoritative: both hands, crib, starter, pegging pile + running count + who's to
  act, dealer seat, `p1Score`/`p2Score`, phase, cut-for-deal cards.
- `PlayerSnapshot` — the **redacted** per-player view sent to each device: your hand in full, the
  opponent's hand hidden (count only) until a reveal phase, the shared play pile, counts, scores,
  phase, whose turn, and any active scoring flags.

### Scorer — `CribbageScorer.swift` (pure, `nonisolated`, unit-tested)
- `peggingScore(pile:justPlayed:) -> [ScoreFlag]` → fifteen (2), thirty-one (2), pairs/trips/quads
  (2/6/12), runs (length), go (1), last-card (1).
- `handScore(hand:starter:isCrib:) -> [ScoreFlag]` → 15s, pairs, runs, flush (4 in hand / 5 with
  starter; crib needs 5), nobs (J of starter suit), his-heels handled at the cut.
- `ScoreFlag { title (localized, e.g. "Fifteen 2"), points }` — drives both the flag chips and,
  optionally, tapping a chip to pre-fill the slider (still manually confirmed).
- Legality helpers: `legalPlays(hand:count:)`, `mustSayGo(hand:count:)`, `isHisHeels(starter:)`.

### Engine — `CribbageEngine.swift` (pure/`nonisolated`, host-authoritative)
Owns the shuffled deck and RNG; validates intents and advances phases. The **host device is the
referee**: guests send *intents* (`didDiscard`, `didPlay`, `claimPoints`, `cutAt`, `sayGo`), the
host validates, mutates canonical `GameState`, and broadcasts fresh redacted `PlayerSnapshot`s.
Hidden-info guarantee: a player's hole cards are only ever in that player's snapshot until a reveal
phase — the opponent literally never receives them over the wire until the show.

### Transport — `GameTransport.swift`
```swift
protocol GameTransport {
    var isHost: Bool { get }
    var events: AsyncStream<TransportEvent> { get }   // .connected/.disconnected/.received(Message)
    func send(_ message: GameMessage) async
}
```
- `GameMessage: Codable` enum: `.hello(name,colorID)`, `.dealPrivate(hand)`, `.snapshot(PlayerSnapshot)`,
  `.intentDiscard([Card])`, `.intentPlay(Card)`, `.intentGo`, `.intentCut(index)`,
  `.claimPoints(player,amount)`, `.undo(player)`, `.playAgain`.
- **`MultipeerTransport.swift`** — `MCSession` + `MCNearbyServiceAdvertiser`/`Browser` (or
  `MCBrowserViewController` for the connect UI). Requires Info.plist `NSLocalNetworkUsageDescription`
  + `NSBonjourServices` (e.g. `_pairfortwo._tcp`). Works with zero internet.
- **`LoopbackTransport.swift`** — single-device hot-seat transport (host + guest in one process) so
  the entire game flow and UI can be exercised on one simulator/device without two phones. Also
  doubles as a legitimate "pass-and-play on one phone" mode. **This is the primary dev/test harness**
  because Multipeer is unreliable between two simulators.

### ViewModel — `GameViewModel.swift` (`@MainActor @Observable`, no SwiftUI import)
Bridges transport events → published UI state (current `PlayerSnapshot`, flags, banner text,
selection state for discard/play), and user actions → intents. Runs the engine when hosting.

---

## Reused Criboard code (copied in, adapted)

Copied from `/Users/jirofeingold/Projects/Criboard/Criboard/ContentView.swift`:
- **`PointsSlider`** (0–29 slider w/ per-step `DragTickHaptics`) — used **as-is**.
- **`PlayerPanel`** → renamed **`ScorePanel`**. Keep the slider + accumulating "+1" button + undo +
  confirm-after-release/`+1` options. **Change:** replace the giant name watermark (`Text(title)…`)
  with a centered **`"\(you) / \(opponent)"`** readout in the player's theme color. Each device shows
  exactly one panel (your own peg); `onAdd`/`onPlusOne`/`onUndo` become `claimPoints`/`undo` intents.
- **`WinnerOverlay`**, **`ConfettiBurst`**, **`SkunkLevel`** + `computeSkunk`, **`PlayerTheme`/
  `playerThemes`**, `Color` felt palette, **`WinHaptics`** / **`DragTickHaptics`** → into
  `Themes.swift`, `Haptics.swift`, `WinnerOverlay.swift`.
- **Dropped:** `CribbageBoardView`, `HorizontalCribbageBoardView`, `PlayerTrack`, `SkunkMarker`,
  replay logic — no pegging board in this app.

---

## New UI (landscape)

- **`ConnectView.swift`** — host or join over Multipeer; list nearby peers, tap to connect; pick your
  name + color (reuse `ColorSwatchRow`). "Play on one phone" entry for `LoopbackTransport`.
- **`GameTableView.swift`** — the root game screen:
  - **Top band (~1/3):** `ScorePanel` (the slider) + a **coach banner** ("Your lead" / "Waiting for
    opponent to discard" / "Count your hand — starter is 5♥") + the **running count** during
    pegging + **flag chips** ("Fifteen 2", "Run 3", "31 for 2", "Go", "His Nobs").
  - **Bottom band (~2/3):** `HandView` (your cards) + centered `PlayPileView` (the shared table:
    played cards both see, the cut/starter card, a crib pile indicator).
- **`CardView.swift`** — "classy, easy to read": cream face, continuous rounded corners, hairline
  inner border, soft shadow; rounded-serif rank+suit in two corners, large center suit glyph; red for
  ♥♦, near-black for ♠♣; elegant face-down back. Deal/flip via `matchedGeometryEffect`. Sized large
  for legibility; scales up on iPad.
- **`HandView.swift`** — fanned/row hand; tap-to-select-2 during discard, tap-to-play during pegging;
  illegal plays (would exceed 31) are dimmed/disabled with a "Go" affordance.
- **`ScoreFlagsView.swift`** — the flag chips; tapping a chip can pre-fill the slider value (still
  requires manual confirm, honoring flag-only).

### Full game flow wired to phases (each is a phase + messages)
1. **Connect** → assign Player 1/2, names, colors.
2. **Cut for deal** — each cuts; lower card deals; tie → recut (host arbitrates).
3. **Deal** — host deals 6 each; each device receives only its own hand.
4. **Discard to crib** — both pick 2 (crib belongs to dealer); wait for both.
5. **Cut starter** — pone cuts, dealer reveals; Jack ⇒ flag **"His Heels — 2 for dealer"** (manual add).
6. **Pegging** — pone leads; alternate legal plays ≤ 31; flags for 15/pair/run/31/go/last; count
   resets on go/31; continue until all 8 cards played. All scoring manual.
7. **The show** — reveal both hands + starter to both devices. Count order pone hand → dealer hand →
   dealer crib, each with its flag breakdown; enter via slider.
8. **Next hand** — deal passes to the other player; repeat.
9. **Game over** at 121 — `WinnerOverlay` + skunk lines + Play Again.

---

## Compelling additions proposed (beyond the original ask)
- **Coach banner + flag chips** — the concrete form of "smart about the rules" without auto-scoring.
- **`LoopbackTransport` pass-and-play** — testable on one device now; a real one-phone mode later.
- **Haptics** on play / cut / 31 / go (reuse Criboard's engines).
- **His-heels & nobs** handled explicitly (easy to forget manually).
- **iPad:** identical landscape layout; `CardView`/panel scale with size classes (no hard-coded
  device checks) — bigger, even easier-to-read cards on iPad.
- **Accessibility:** VoiceOver labels per card ("Seven of Hearts"), Dynamic Type on banner/flags.

### Reconnect / resume (built in v1)
Cribbage games are long, and Multipeer links drop (backgrounding, walking out of range, a phone
lock). The design keeps a game recoverable rather than lost:
- **Host is the single source of truth.** The full `GameState` lives only on the host; guests hold
  the latest redacted `PlayerSnapshot`. So recovery = the host re-sending the current snapshot; no
  distributed-state merge is ever needed.
- **Persist across app death.** On every state change the host writes `GameState`, and each device
  writes its last `PlayerSnapshot` + the peer identity/session token, to disk
  (`Persistence.swift`, JSON in Application Support). Relaunching within a session offers **"Resume
  game."**
- **Stable identity.** A `matchID` (UUID) + per-device `playerToken` are exchanged in `.hello` and
  stored, so a reconnecting device is recognized as the *same* player (not a new joiner) and gets its
  own hand back — never the opponent's.
- **Transport-level reconnect.** `MultipeerTransport` keeps advertising/browsing after a drop and
  auto-rejoins the known peer; `GameTransport` gains `.reconnecting` / `.connected` /
  `.disconnected` events. On `.connected`, the host replays `.snapshot(current)` and the resuming
  guest simply re-renders — mid-hand, mid-peg, wherever play was.
- **UI:** a non-blocking "Reconnecting…" banner (never a data-losing alert); intents are disabled
  while disconnected and re-enabled on resume. `LoopbackTransport` treats reconnect as a no-op.
- **Scope for v1:** covers drop-and-return during a live session and relaunch-resume on the same two
  devices. Cross-network handoff (e.g. Multipeer→Game Center mid-game) is explicitly out of scope.

### Future toggles (noted in the plan, wired as off-by-default settings, not implemented in v1)
Each is surfaced as a stub in a Settings screen / feature-flag enum now so the data model and UI
leave room for them, but the behavior ships later:
- **Automatic scoring** — engine already computes every count via `CribbageScorer`; the flag data is
  the same input auto-scoring would consume. Toggle would apply flags to the peg instead of prompting.
- **Muggins** — if you under-count your hand, opponent may claim the missed points. The scorer
  already knows the true count vs. what you entered, so this is additive.
- **Gentle wrong-count warning** — non-blocking "the app counts N" nudge when your entered score ≠
  true count. A middle ground between flag-only and auto.
- **Match play** — best-of-N / first-to-X-games across a session (single game to 121 stays default).
- **Stats** — games / wins / skunks history (mirrors StarBattle's `StatsView` pattern).
- **Game Center remote** — a second `GameTransport` impl (`GKMatch`) behind the existing protocol,
  with matchmaking/invites for remote play.

---

## Files to create (in the new target)
`PairForTwoApp.swift` · `Card.swift` · `CribbageModels.swift` · `CribbageScorer.swift` ·
`CribbageEngine.swift` · `GameTransport.swift` · `MultipeerTransport.swift` · `LoopbackTransport.swift` ·
`GameViewModel.swift` · `RootView.swift` · `ConnectView.swift` · `GameTableView.swift` ·
`ScorePanel.swift` · `CardView.swift` · `HandView.swift` · `PlayPileView.swift` ·
`ScoreFlagsView.swift` · `WinnerOverlay.swift` · `Themes.swift` · `Haptics.swift` ·
`Localizable.xcstrings` · Info.plist keys (`NSLocalNetworkUsageDescription`, `NSBonjourServices`).

## Suggested build order (incremental, each independently verifiable)
1. **Models + Scorer + unit tests** (Swift Testing) — verify known hands (the 29 hand, 15s, runs,
   flush, nobs) with `RunCodeSnippet`/tests. No UI needed.
2. **Engine + `LoopbackTransport`** — drive a whole game in code/hot-seat.
3. **Card + table UI** on Loopback — play a full game on one simulator.
4. **`ScorePanel`** (adapted Criboard slider) + flags + winner overlay.
5. **`MultipeerTransport`** + `ConnectView` — real two-device play.
6. Polish: haptics, iPad layout, accessibility, localization.

## Verification
- `CribbageScorer` unit tests (Swift Testing) — canonical hands incl. the 29-point hand.
- Play a complete game end-to-end via **`LoopbackTransport`** on `iPhone 16` **and** `iPad Pro 13-inch (M4)`
  simulators (landscape) — build with `BuildProject`, exercise deal → discard → cut → peg → show →
  win. Confirm hidden-info (opponent's hand never visible pre-show) and flag accuracy.
- Two-physical-device smoke test of `MultipeerTransport` (connect, deal, play, reconnect).
- Confirm landscape-only, iOS 17 API availability, skunk lines at 61/91, Play Again resets cleanly.
