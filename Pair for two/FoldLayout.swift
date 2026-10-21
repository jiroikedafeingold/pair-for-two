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

/// Reports the vertical hinge crossing the view it's attached to, or nil where there isn't one: every
/// non-foldable device, the folded Duo's outer display, and any OS before 27.1.
///
/// Inactive divisions are included. The Duo's division is inactive while the phone lies flat and
/// active once it's bent into the book pose; including both keeps the layout still as the phone
/// folds, instead of reflowing the table the moment someone props it up.
private struct FoldDivisionReader: UIViewRepresentable {
    @Binding var division: FoldDivision?

    func makeUIView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.isUserInteractionEnabled = false
        view.onChange = { division = $0 }
        return view
    }

    func updateUIView(_ view: ProbeView, context: Context) {
        view.onChange = { division = $0 }
    }

    final class ProbeView: UIView {
        var onChange: ((FoldDivision?) -> Void)?
        private var reported: FoldDivision??

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
            reported = .some(current)
            // Not inside SwiftUI's own update pass: publish on the next turn of the main actor.
            let onChange = onChange
            Task { @MainActor in onChange?(current) }
        }

        private func measure() -> FoldDivision? {
            guard window != nil else { return nil }
            if #available(iOS 27.1, *) {
                // Only a hinge running top to bottom splits this landscape layout into pages; one
                // across the middle (a portrait-held inner display) leaves the layout as it is.
                let vertical = reservedRegions(kind: .division, options: .includeInactive)
                    .map(\.frame)
                    .filter { $0.height > $0.width && $0.minX > 0 && $0.maxX < bounds.width }
                guard let frame = vertical.first else { return nil }
                return FoldDivision(minX: frame.minX, maxX: frame.maxX, containerWidth: bounds.width)
            }
            return nil
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
    @State private var insets = EdgeInsets()

    func body(content: Content) -> some View {
        let balance = horizontalSizeClass == .compact
        content
            .safeAreaPadding(.leading, balance ? max(0, insets.trailing - insets.leading) : 0)
            .safeAreaPadding(.trailing, balance ? max(0, insets.leading - insets.trailing) : 0)
            // Read outside the padding above, so this sees the device's own insets rather than the
            // ones just added — otherwise the two would chase each other.
            .onGeometryChange(for: EdgeInsets.self) { $0.safeAreaInsets } action: { insets = $0 }
    }
}

extension View {
    /// Centers content on the screen when the device's side safe areas are uneven (iPhone Duo's
    /// cover screen). See `BalancedHorizontalSafeArea`.
    func balancedHorizontalSafeArea() -> some View {
        modifier(BalancedHorizontalSafeArea())
    }

    /// Keeps `division` up to date with the hinge crossing this view, in this view's coordinates.
    func readingFoldDivision(_ division: Binding<FoldDivision?>) -> some View {
        background(FoldDivisionReader(division: division))
    }
}
