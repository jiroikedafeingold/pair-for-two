import SwiftUI
import UIKit

/// Where a foldable's hinge crosses a view, in that view's own coordinates.
///
/// iPhone Duo's inner display has a hinge strip down the middle. iOS 27.1 reports it as a reserved
/// region of kind `.division`: "a region where an element should divide into two separate regions".
/// The screens that care lay themselves out like a book around it — content on the left page,
/// controls on the right, the hinge in the gutter — so nothing that has to be touched sits across
/// it when the phone is half-folded.
///
/// Read from the system rather than inferred. The previous version guessed from "regular size
/// classes on a phone", which Apple advises against and which assumed the hinge was centered.
struct FoldDivision: Equatable {
    /// The hinge's leading and trailing edges, including the margin the system asks interactive
    /// content to keep.
    var minX: CGFloat
    var maxX: CGFloat
    /// Width of the view the division was measured in, so a layout can size its right-hand page.
    var containerWidth: CGFloat

    var width: CGFloat { maxX - minX }
    /// Room left of the hinge, and right of it.
    var leadingPage: CGFloat { minX }
    var trailingPage: CGFloat { containerWidth - maxX }
}

/// Whether this is a phone at all. With the app locked to landscape on every other iPhone, a phone
/// whose screen is taller than wide, or regular in height, can only be the open iPhone Duo — which is
/// how the Duo-only layouts tell themselves apart from an iPad in the same shape. (A device check,
/// deliberately: those layouts must leave every other device exactly as it was.)
@MainActor
var isPhoneHardware: Bool { UIDevice.current.userInterfaceIdiom == .phone }

/// Where a hinge running side to side crosses a view (the open Duo held upright), in that view's
/// coordinates: the top page ends at `minY` and the bottom page starts at `maxY`.
struct FoldBand: Equatable {
    var minY: CGFloat
    var maxY: CGFloat
}

/// Reports the vertical hinge crossing the view it's attached to, or nil where there isn't one: every
/// non-foldable device, the folded Duo's outer display, and any OS before 27.1.
///
/// Inactive divisions are included. The Duo's division is inactive while the phone lies flat and
/// active once it's bent into the book pose; including both keeps the layout still as the phone
/// folds, instead of reflowing the table the moment someone props it up.
private struct FoldDivisionReader: UIViewRepresentable {
    @Binding var division: FoldDivision?
    /// The hinge when it runs *across* the view instead — the open Duo held upright. Optional, so a
    /// screen that has no portrait arrangement doesn't have to ask.
    var across: Binding<FoldBand?>?

    func makeUIView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.isUserInteractionEnabled = false
        updateUIView(view, context: context)
        return view
    }

    func updateUIView(_ view: ProbeView, context: Context) {
        let across = across
        view.onChange = { vertical, horizontal in
            division = vertical
            across?.wrappedValue = horizontal
        }
    }

    final class ProbeView: UIView {
        var onChange: ((FoldDivision?, FoldBand?) -> Void)?
        private var reported: Measurement?

        private struct Measurement: Equatable {
            var vertical: FoldDivision?
            var horizontal: FoldBand?
        }

        // Bounds change on every fold, unfold and rotation, each of which lays the view out again.
        override func layoutSubviews() {
            super.layoutSubviews()
            report()
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            report()
        }

        private func report() {
            let current = measure()
            if let reported, reported == current { return }
            reported = current
            // Not inside SwiftUI's own update pass: publish on the next turn of the main actor.
            let onChange = onChange
            Task { @MainActor in onChange?(current.vertical, current.horizontal) }
        }

        private func measure() -> Measurement {
            guard window != nil else { return Measurement() }
            if #available(iOS 27.1, *) {
                let frames = reservedRegions(kind: .division, options: .includeInactive).map(\.frame)
                // Top to bottom: the open Duo in landscape, pages left and right.
                let vertical = frames.first { $0.height > $0.width && $0.minX > 0 && $0.maxX < bounds.width }
                // Side to side: the open Duo held upright, pages above and below.
                let horizontal = frames.first { $0.width > $0.height && $0.minY > 0 && $0.maxY < bounds.height }
                return Measurement(
                    vertical: vertical.map { FoldDivision(minX: $0.minX, maxX: $0.maxX, containerWidth: bounds.width) },
                    horizontal: horizontal.map { FoldBand(minY: $0.minY, maxY: $0.maxY) })
            }
            return Measurement()
        }
    }
}

/// Evens out the left and right safe areas, so a layout centered in the safe area is centered on the
/// screen.
///
/// The iPhone Duo's cover screen puts its camera in one corner, and in landscape that becomes an
/// 84-point safe area on one side and none on the other — every screen sat visibly to one side. This
/// pads the smaller side up to match the larger. Backgrounds that ignore the safe area still run edge
/// to edge; only the content moves.
///
/// Compact width only: that is the cover screen, and ordinary iPhones in landscape, whose two sides
/// are already equal. The open Duo's inner display has a status bar down one side, and matching it
/// would throw away 68 points of a screen the game uses all of.
private struct BalancedHorizontalSafeArea: ViewModifier {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    /// The window's own left and right insets. Read from UIKit, not from SwiftUI's geometry: the
    /// padding below changes the safe area SwiftUI reports, so measuring there read the padding back,
    /// removed it, and the two chased each other forever — a white screen at full CPU.
    @State private var insets = WindowSideInsets()

    func body(content: Content) -> some View {
        let balance = horizontalSizeClass == .compact
        content
            .safeAreaPadding(.leading, balance ? max(0, insets.right - insets.left) : 0)
            .safeAreaPadding(.trailing, balance ? max(0, insets.left - insets.right) : 0)
            .environment(\.balancedContentWidth,
                         balance && insets.width > 0 ? insets.width - 2 * max(insets.left, insets.right) : nil)
            .environment(\.windowSize, CGSize(width: insets.width, height: insets.height))
            // Spanning the whole window, so its own insets change whenever the window's do. Inside
            // the safe area it heard nothing when the cover screen turned from one landscape to the
            // other — same size, and the camera's inset just changing sides — and kept centering
            // for the old side.
            .background(WindowInsetsReader(insets: $insets).ignoresSafeArea())
    }
}

/// The device's side insets, as SwiftUI's leading and trailing: left and right on screen, swapped in a
/// right-to-left layout so the padding still lands opposite the camera.
private struct WindowSideInsets: Equatable {
    var left: CGFloat = 0
    var right: CGFloat = 0
    /// The window's size, so the room between the balanced insets can be passed on.
    var width: CGFloat = 0
    var height: CGFloat = 0
}

extension EnvironmentValues {
    /// The width between the evened-out side safe areas, from the window itself. A view inside can't
    /// trust its own proposal for this: content that overflows widens the views around it. Nil where
    /// the sides aren't balanced (regular width).
    @Entry var balancedContentWidth: CGFloat? = nil
    /// The window's own size (zero until it's measured). Like `balancedContentWidth`, read from the
    /// window rather than a view's proposal, which overflowing content can inflate.
    @Entry var windowSize: CGSize = .zero
}

/// Reports the window's left and right safe-area insets, which come from the device and the system
/// bars alone and so can't be moved by the padding they drive.
private struct WindowInsetsReader: UIViewRepresentable {
    @Binding var insets: WindowSideInsets

    func makeUIView(context: Context) -> Probe {
        let view = Probe()
        view.isUserInteractionEnabled = false
        view.onChange = { insets = $0 }
        return view
    }

    func updateUIView(_ view: Probe, context: Context) {
        view.onChange = { insets = $0 }
    }

    final class Probe: UIView {
        var onChange: ((WindowSideInsets) -> Void)?
        private var reported: WindowSideInsets?

        override func didMoveToWindow() { super.didMoveToWindow(); report() }
        override func layoutSubviews() { super.layoutSubviews(); report() }
        override func safeAreaInsetsDidChange() { super.safeAreaInsetsDidChange(); report() }

        private func report() {
            guard let window else { return }
            var current = WindowSideInsets(left: window.safeAreaInsets.left, right: window.safeAreaInsets.right,
                                           width: window.bounds.width, height: window.bounds.height)
            // Mirrored layout flips SwiftUI's leading/trailing; keep leading = the left padding.
            if effectiveUserInterfaceLayoutDirection == .rightToLeft { swap(&current.left, &current.right) }
            guard current != reported else { return }
            reported = current
            let onChange = onChange
            Task { @MainActor in onChange?(current) }
        }
    }
}

extension View {
    /// Centers content on the screen when the device's side safe areas are uneven (iPhone Duo's
    /// cover screen). See `BalancedHorizontalSafeArea`.
    func balancedHorizontalSafeArea() -> some View {
        modifier(BalancedHorizontalSafeArea())
    }

    /// Keeps `division` up to date with the hinge crossing this view, in this view's coordinates.
    func readingFoldDivision(_ division: Binding<FoldDivision?>, across: Binding<FoldBand?>? = nil) -> some View {
        background(FoldDivisionReader(division: division, across: across))
    }
}
