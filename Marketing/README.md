# Marketing / App Store submission kit

Everything for submitting **Pair for Two**.

## Contents
- **`APP_STORE.md`** — copy/paste metadata: name, subtitle, promo text, description, keywords, what's‑new, category, age rating, privacy answers, export compliance, and **App Review notes** (important: it's a two‑device game).
- **Website** — the single‑page **privacy policy + contact/support** (apps@feingold5.com) lives at **`docs/index.html`** (repo root) and is published via **GitHub Pages** at **https://jiroikedafeingold.github.io/pair-for-two/**. Use that URL for the Support URL, Marketing URL, and Privacy Policy URL fields. It covers **both apps** — iOS/iPadOS and the Android build in `~/Projects/PairForTwoAndroid` — so it also serves Play's privacy‑policy requirement and its data‑safety answers. Keep it that way: anything that changes what either app sends over the wire (a new transport, an online mode on Android) needs a matching edit here.
- **`screenshots/iphone-6.9/`** — 5 screenshots, **2868 × 1320** (iPhone 6.9", landscape). One 6.9" set covers all iPhone sizes.
- **`screenshots/ipad-13/`** — 5 screenshots, **2752 × 2064** (iPad 13", landscape).
- **`screenshots/raw/`** — the source renders before upscaling (safe to delete).

## Screenshots
1. Pegging — the core play, with the running count and both players' peg boards.
2. The show — counting a hand with the cut card.
3. The in‑person cut — tap the deck to cut for the starter.
4. Winner — the skunk celebration.

Generated from SwiftUI previews (landscape) and scaled to Apple's exact required pixel sizes. To regenerate crisper shots later, capture on a real 6.9" iPhone and 13" iPad at native resolution.

### Rules for regenerating (not optional)

- **Player responsibility scoring** (`ScoringMode.off`) in every shot — it's the app's default, so
  it's what a new player sees. `.feedback` puts scoring flag chips on the rail that most people
  never see.
- **Never capture through the debug pass-and-play (loopback) path.** It's `#if DEBUG` only and
  compiled out of release, so it isn't the shipping experience — and the phone there rotates to
  whoever is acting, which no real device does. `ScreenshotFixtures` instead drives the engine to a
  legal position, redacts it into the snapshot a guest really receives, and renders it through the
  ordinary guest path with the seat fixed (`GameViewModel.previewGuest`).
- The capture gotchas are handled in `GuestShot.init`, and are why it exists: a preview snapshot is
  taken on the **first frame**, where the deal-in animation has revealed nothing (`dealsCardsInstantly`
  starts the row fully dealt), and a finished game opens on the **pre-win scoring replay** unless
  `replayBeforeWin` is off. Xcode also preserves `@State` across edits, so bumping an initial value
  by hand won't fix the first of those.
- Fixtures search seeds rather than hard-coding a position: the first hand to hand is often "no card
  to play — say Go" (a greyed-out hand) or a four-point show, neither of which sells anything.

## Languages

The app ships in **11 languages**: English (source) plus Spanish, French, German, Japanese, Simplified
Chinese, Traditional Chinese, Brazilian Portuguese, Italian, Korean and Turkish. Everything on screen
lives in `Pair for two/Localizable.xcstrings`, and the two permission prompts in `InfoPlist.xcstrings`.

Chosen for App Store reach rather than for cribbage's own footprint (which is largely English-speaking):
the biggest storefronts by users and spend, plus the two Chinese scripts — cheap together and covering
mainland China, Taiwan and Hong Kong — and Turkish, where English proficiency is low enough for a
translation to make a real difference. Next in line if the list ever grows: Dutch, Polish and Russian.

Two deliberate exceptions, noted in code as well:
- **The app name is never translated** — `CFBundleDisplayName` / `CFBundleName` stay English in
  `InfoPlist.xcstrings`, and "Pair for Two" stays as it is inside translated sentences.
- **Cribbage terms of art keep their English form** where a language has no settled equivalent —
  *crib*, *Go*, *His Nobs*, *His Heels*, *skunk*. Everything around them is translated. Face-card
  letters do follow the local deck, though: the Jack is B in German and V in French.

`tools/merge-translations.py` merges a locale at a time and refuses to overwrite an existing
translation, invent a key, or accept a value whose `%@`/`%lld` specifiers don't match the key's.

The App Store listing itself is still English-only; `fastlane/metadata/` has just `en-US`. Adding a
locale there means a `fastlane/metadata/<locale>/` directory with the same `.txt` files, and every
locale you upload needs its own screenshots (deliver only replaces the sets it uploads).

## Game Center (achievements + leaderboard)

Configured in App Store Connect via the API (see the "Achievements & leaderboard" commit), with
artwork generated into `Marketing/gamecenter/` — 1024×1024, felt + gold, no alpha.

The **vendor identifiers are a shipped contract**: rename one and every player's earned achievement
is orphaned. They're mirrored in `GameCenterAwards.ID`.

| Identifier | Name | Points | Earned when |
| --- | --- | --- | --- |
| `first_win` | First Win | 50 | first game won |
| `skunk` | Skunk | 100 | win with the loser under 91 |
| `double_skunk` | Double Skunk | 100 | win with the loser under 61 |
| `big_hand_24` | Big Hand | 100 | claim 24+ for one hand or crib |
| `perfect_29` | Perfect 29 | 100 | claim 29 |
| `comeback_30` | Comeback | 100 | win after trailing by 30+ |
| `streak_5` | Five in a Row | 100 | five straight wins |
| `hands_100` | Hundred Hands | 100 | 100 hands played (reports partial progress) |

Leaderboard: `lifetime_wins` ("Lifetime Wins"), best-score, integer, descending.

Note the limit that bit during setup: **each achievement caps at 100 points**, not just the 1000
total — 150 and 200 were rejected with "You must provide points between 0 and 100".

Everything is derived from the local history in `StatsStore`, so deleting the app resets *progress*
toward what hasn't been earned yet; Game Center keeps what already has been.

## Order of operations in App Store Connect
1. Create the app record (bundle ID, name, primary language).
2. Fill **App Privacy** → Data Not Collected.
3. Set category (Games / Card), age rating (4+), price (Free).
4. Add the **Privacy Policy URL** (the hosted page above).
5. Create the 1.0 version → paste description, keywords, promo text, screenshots.
6. Attach a build (see build notes), add **App Review notes**, submit.
