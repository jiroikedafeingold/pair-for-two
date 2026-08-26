import SwiftUI

@main
struct PairForTwoApp: App {
#if DEBUG
    /// Only there to hold a screenshot run in landscape; it defers to the Info.plist otherwise.
    @UIApplicationDelegateAdaptor(ScreenshotOrientationDelegate.self) private var orientationDelegate
#endif

    /// The opening plays once per launch, then hands over to the menu.
    @State private var opening = true

    var body: some Scene {
        WindowGroup {
#if DEBUG
            // `-shot N` on the command line boots straight into one of the App Store screenshot
            // fixtures, so the whole matrix of shots × languages × devices can be captured with
            // simctl instead of by hand. Debug-only, like the fixtures themselves — and it skips the
            // opening, which would otherwise be in every screenshot.
            if let shot = ScreenshotStage.requested {
                ScreenshotStage(shot: shot)
            } else {
                launch
            }
#else
            launch
#endif
        }
    }

    /// The opening sits *instead of* the menu rather than over it: `RootView` puts the first-run
    /// welcome up in a `fullScreenCover`, which would appear above anything layered beside it.
    @ViewBuilder private var launch: some View {
        ZStack {
            if opening {
                OpeningView { opening = false }
                    .transition(.opacity)
            } else {
                RootView()
                    .transition(.opacity)
            }
        }
    }
}

#Preview {
    RootView()
}
