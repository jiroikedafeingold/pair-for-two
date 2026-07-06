# Xcode Cloud setup — Pair for Two

Xcode Cloud is Apple's CI/CD. Enabling it is a one-time flow done in **Xcode + App Store Connect**
(it can't be scripted from the command line). The repo is already prepared for it; this doc lists what
was done and the exact steps you finish in the GUI.

## ✅ Already prepared in the repo

- **Shared scheme** — `Pair for two.xcodeproj/xcshareddata/xcschemes/Pair for two.xcscheme`. Xcode
  Cloud only sees *shared* schemes; this is required.
- **Real bundle identifier** — `com.feingold5.pairfortwo`.
- **Development team** — `TJ8LYQ4D36`, automatic signing (Xcode Cloud manages distribution signing
  for you — no certificates/profiles to upload).
- **Archive action uses Release** (verified in the shared scheme).
- **Entitlement**: Game Center (`com.apple.developer.game-center`). Automatic signing + Xcode Cloud
  provision it from the App ID capability — nothing extra to upload.
- No third-party dependencies / no custom build steps, so **no `ci_scripts/` are needed**. (If you
  add SPM packages later they resolve automatically. Only add `ci_scripts/ci_post_clone.sh` etc. if
  you need custom steps.)
- Repo: `https://github.com/jiroikedafeingold/pair-for-two` (private). Current version 1.0.5 (6).

## 1. Register the App in App Store Connect  — ✅ DONE

Already completed (this is how the Game Center "code 15 / not recognized" error got resolved):
- App ID **`com.feingold5.pairfortwo`** registered with the **Game Center** capability.
- App Store Connect app record **Pair for Two** created for that bundle ID, with **Game Center
  enabled on the app version**.

Nothing to do here unless you rename the bundle ID.

## 2. Turn on Xcode Cloud  (~5 min)

In **Xcode** (with this project open):

1. **Product ▸ Xcode Cloud ▸ Create Workflow…** (or the **Integrate** menu).
2. Pick the **Pair for two** app/target, click **Grant Access** and connect your **GitHub** account —
   authorize Apple's GitHub app for the private repo `jiroikedafeingold/pair-for-two`.
3. Xcode proposes a default workflow. Review and **Start Build**. Apple provisions the cloud signing
   assets automatically the first time.

## 3. Recommended workflow for distribution

Edit the workflow (Xcode ▸ Report navigator ▸ Cloud, or App Store Connect ▸ your app ▸ **Xcode Cloud**):

- **Start conditions**: Branch Changes on `main` (and/or Tag Changes like `v*` for releases).
- **Environment**: latest released Xcode, macOS.
- **Actions**:
  - **Build** (scheme: *Pair for two*, platform: iOS) — fast feedback on every push.
  - **Archive** (scheme: *Pair for two*, distribution: **TestFlight (Internal)**) — uploads a build to
    TestFlight automatically.
- **Post-Actions**: **TestFlight Internal Testing** → add yourself as an internal tester so builds land
  on your phone via TestFlight.

## 4. Each release

- After **Versioning** (bump `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` — see the project's
  `CLAUDE.md` versioning rule) and pushing to `main`, Xcode Cloud archives and pushes to TestFlight.
- Install via the **TestFlight** app on your device; the second phone installs the same TestFlight
  build to play over Multipeer without cables.

## Notes / gotchas

- Xcode Cloud gives every Apple Developer account a monthly compute allowance — plenty for this app.
- The repo is **private**; make sure Apple's GitHub app is granted access to it during step 2.
- The app has **no server** and needs no secrets, so there's nothing to configure in the workflow's
  Environment ▸ Custom variables.
- Local Network usage (`NSLocalNetworkUsageDescription`) and Bonjour services are already in the
  Info.plist — App Store review will ask why; answer: "peer-to-peer two-player play over
  MultipeerConnectivity, no data leaves the devices."
- **Game Center**: online play uses real-time `GKMatch`. **Sandbox invites (Xcode dev builds) are
  unreliable** — this is exactly why the Archive→TestFlight workflow matters: TestFlight builds use
  *production* Game Center, where invitations are delivered reliably. Add both test accounts as
  internal TestFlight testers.
