import SwiftUI

@main
struct PairForTwoApp: App {
#if DEBUG
    /// Only there to hold a screenshot run in landscape; it defers to the Info.plist otherwise.
    @UIApplicationDelegateAdaptor(ScreenshotOrientationDelegate.self) private var orientationDelegate
#endif

    var body: some Scene {
        WindowGroup {
#if DEBUG
            // `-shot N` on the command line boots straight into one of the App Store screenshot
            // fixtures, so the whole matrix of shots × languages × devices can be captured with
            // simctl instead of by hand. Debug-only, like the fixtures themselves.
            if let shot = ScreenshotStage.requested {
                ScreenshotStage(shot: shot)
            } else {
                RootView()
            }
#else
            RootView()
#endif
        }
    }
}

#Preview {
    RootView()
}
