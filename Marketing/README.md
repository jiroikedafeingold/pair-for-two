# Marketing / App Store submission kit

Everything for submitting **Pair for Two**.

## Contents
- **`APP_STORE.md`** — copy/paste metadata: name, subtitle, promo text, description, keywords, what's‑new, category, age rating, privacy answers, export compliance, and **App Review notes** (important: it's a two‑device game).
- **`privacy/index.html`** — single‑page website with the **privacy policy** and **contact/support** (apps@feingold5.com). Host it and use its URL for the Support URL, Marketing URL, and Privacy Policy URL fields. Options: your domain (e.g. `feingold5.com/pairfortwo/`) or GitHub Pages.
- **`screenshots/iphone-6.9/`** — 4 screenshots, **2868 × 1320** (iPhone 6.9", landscape). One 6.9" set covers all iPhone sizes.
- **`screenshots/ipad-13/`** — 4 screenshots, **2752 × 2064** (iPad 13", landscape).
- **`screenshots/raw/`** — the source renders before upscaling (safe to delete).

## Screenshots
1. Pegging — the core play, with the running count and both players' peg boards.
2. The show — counting a hand with the cut card.
3. The in‑person cut — tap the deck to cut for the starter.
4. Winner — the skunk celebration.

Generated from SwiftUI previews (landscape) and scaled to Apple's exact required pixel sizes. To regenerate crisper shots later, capture on a real 6.9" iPhone and 13" iPad at native resolution.

## Order of operations in App Store Connect
1. Create the app record (bundle ID, name, primary language).
2. Fill **App Privacy** → Data Not Collected.
3. Set category (Games / Card), age rating (4+), price (Free).
4. Add the **Privacy Policy URL** (the hosted page above).
5. Create the 1.0 version → paste description, keywords, promo text, screenshots.
6. Attach a build (see build notes), add **App Review notes**, submit.
