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
            content
                // Every screen here is a fixed landscape geometry: cards measured from the screen, a
                // rail of a set width, two players' halves sharing one display. There is nowhere for
                // larger text to reflow to, so the system's text size clipped labels and pushed
                // buttons off the bottom rather than making anything more readable. Pinning the whole
                // app to the default size is a deliberate trade — it costs Dynamic Type support, and
                // leaves VoiceOver, Zoom, Bold Text and contrast settings working as they should.
                //
                // Two mechanisms, because one doesn't reach everything: the modifier covers this
                // hierarchy from the first layout pass, and the window trait override below covers
                // what SwiftUI presents *outside* it — sheets, full-screen covers and the system's
                // own confirmation dialogs don't inherit `dynamicTypeSize` from the presenting view.
                .dynamicTypeSize(.large)
                .background(FixedTextSize())
        }
    }

    @ViewBuilder private var content: some View {
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

/// Overrides the content size category on the window, so the default text size applies to everything
/// drawn in it — including views SwiftUI presents outside the app's own hierarchy.
private struct FixedTextSize: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView { Anchor() }
    func updateUIView(_ view: UIView, context: Context) {}

    /// An empty view that exists only to reach its window once it has one.
    private final class Anchor: UIView {
        override func didMoveToWindow() {
            super.didMoveToWindow()
            window?.traitOverrides.preferredContentSizeCategory = .large
        }
    }
}

#Preview {
    RootView()
}
