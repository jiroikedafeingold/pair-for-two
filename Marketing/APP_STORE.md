# App Store submission kit — Pair for Two

Everything you paste into App Store Connect. Character limits noted in parentheses.

---

## App name (30)
```
Pair for Two
```

## Subtitle (30)
```
Two-phone cribbage
```

## Promotional text (170) — editable any time, no review
```
Real cribbage across two phones—each player holds their own hand. Cut, peg, and count with rich haptics and sound. Play nearby or online; no sign-in to play locally.
```

## Keywords (100, comma-separated, no spaces to save room)
```
card game,2 player,multiplayer,local,nearby,bluetooth,peg,crib,skunk,couples,family,offline,classic
```

## Description (4000)
```
Pair for Two is cribbage the way it’s meant to be played — face to face, but on two phones. Each player holds their own hand on their own device, so nobody peeks. Deal, cut, peg, and count your way to 121.

TWO PHONES, ONE TABLE
Every player gets their own screen and their own private hand. Sit across from a friend and play a real game of cribbage — your cards stay yours.

PLAY NEARBY OR ONLINE
• Nearby: connect two phones directly over Bluetooth and peer-to-peer Wi-Fi. No internet, no accounts, no sign-in.
• Online: invite a friend through Game Center and play from anywhere.

A REAL CUT FOR THE STARTER
Just like at the kitchen table: the non-dealer taps the deck to cut it, and the dealer turns up the starter card. Little rituals, done right.

SCORE YOUR WAY
Pick the style that fits your table:
• Automatic — the app counts and pegs every point for you.
• Feedback — the app shows each score and the running total; you slide the points onto your own board.
• Player responsibility — no hints. Count it yourself, just like the real thing.

You’re nudged when it matters — when a “Go” passes to you, or when someone hits 31 — so nobody misses a point.

BUILT TO FEEL GREAT
• Rich haptics and sound for every card, cut, deal, and win.
• A proper skunk (and double-skunk!) celebration.
• Clean, legible cards that scale beautifully from iPhone to iPad.
• Landscape play designed for two people sitting across a table.

DROP-IN, DROP-OUT
Step away and come back — games reconnect quickly, and you can rejoin an interrupted match right where you left off.

Whether you’re teaching a beginner with automatic scoring or keeping it honest with manual counting, Pair for Two brings the classic two-hand game to the two phones already in your pockets.
```

## What's New (4000) — version 1.3
```
A big update — learn faster, play smoother, and celebrate (or commiserate) in style:

• Check your count — while counting a hand or the crib, tap the check button to see the correct score with proper cribbage terms (double run, pair royal, run of five, and more). Great for learning.
• Scoring replay — replay the whole game score-by-score on the win screen, or automatically right before it (Settings).
• Welcome tour + full "How to Play" guide — tap the ? on the board anytime for help with scoring, playing nearby or online, and the settings.
• Tidier table — hands are sorted by rank and suit, cards deal out as each hand is counted, and the crib is clearly marked.
• Win and lose in style — a bigger winner celebration with fireworks, and a gentle screen for the runner-up.
• Make it yours — new toggles for haptics, sound effects, and celebration effects.
• Smoother play — you're alerted when it's your Go, the count button folds in points you've queued, card ranks are clearer, reconnecting and rejoining are faster, and starting a new game clears any old one.
• Stability and layout fixes.

Thanks for playing! Questions or feedback? apps@feingold5.com
```

---

## App information

| Field | Value |
| --- | --- |
| Primary category | Games |
| Secondary category | Games — Card (subcategory: Card / Board) |
| Age rating | 4+ (no gambling, no real-money play, no objectionable content) |
| Price | Free |
| Copyright | © 2026 Jiro Feingold |
| Bundle display name | Pair for Two |

### URLs
| Field | Value |
| --- | --- |
| Support URL | https://jiroikedafeingold.github.io/pair-for-two/ |
| Marketing URL (optional) | https://jiroikedafeingold.github.io/pair-for-two/ |
| Privacy Policy URL (required) | https://jiroikedafeingold.github.io/pair-for-two/ |

> The single-page site (source: `docs/index.html`) is published via **GitHub Pages** at
> https://jiroikedafeingold.github.io/pair-for-two/ and covers privacy policy + support/contact, so
> the one URL serves all three fields. To use a custom domain later (e.g. feingold5.com), add a
> `CNAME` file to `docs/` and point DNS at GitHub Pages.

---

## App Privacy (nutrition label)
**Data collection: None.** In App Store Connect → App Privacy, select **“Data Not Collected.”**

Rationale (for your records): the app stores game state only on-device, has no analytics or third‑party SDKs, and no login for local play. Nearby play uses Apple’s MultipeerConnectivity (device‑to‑device, encrypted, no servers). Online play uses Apple’s Game Center for matchmaking; any data there is handled by Apple under their policy, not collected by this app.

---

## Export compliance
Answer: **No** — the app does **not** use non‑exempt encryption. It relies only on standard, OS‑provided encryption (MultipeerConnectivity, Game Center, HTTPS). This is now declared in `Info.plist` via `ITSAppUsesNonExemptEncryption = false`, so builds clear compliance automatically.

---

## App Review notes (IMPORTANT — paste into the “Notes” field)
```
Pair for Two is a two-device game — one phone per player, like sitting across a table.

TO REVIEW WITH TWO DEVICES (recommended):
1. On device A: tap “Play nearby,” then Host.
2. On device B: tap “Play nearby,” then Join, and select the host.
   (Both devices must be on the same Wi-Fi / have Bluetooth on. iOS will ask
   for Local Network permission the first time — please Allow.)
3. Each player cuts for deal, then play proceeds: discard to the crib, the
   non-dealer cuts the deck, the dealer turns up the starter, then pegging
   and counting to 121.

ONLINE PLAY: “Play online” uses Game Center; sign in to Game Center on both
devices and invite the other player.

There is no single-device mode by design (each player needs a private hand),
so a second device — or a second Game Center account on a second device — is
required to see a full match. If a second device isn’t available, the app’s
menu, settings, and connection screens are still reviewable on one device.

No account or purchase is required for nearby play. The app collects no data.
```

## Required device capabilities / permissions used
- **Local Network + Bonjour** (`_pairfortwo._tcp` / `_udp`) — nearby peer discovery. Usage string is set.
- **Game Center** — online matchmaking (entitlement present).
- No camera, location, contacts, mic, tracking, or notifications.
