import SwiftUI
import UIKit

/// iPhone Duo, unfolded. Its inner display is the first iPhone screen to report regular size
/// classes in both directions, and a 40-point hinge strip down its middle takes no touches while the
/// phone lies flat — so interactive controls have to keep clear of the center. The screens lay
/// themselves out like a book there: the table on the left page, the controls on the right, the
/// hinge in the gutter. Folded, the outer display is an ordinary small phone and needs nothing.
///
/// iOS 27.1 adds a reserved-region API that reports the hinge exactly; this project is on the 27.0
/// SDK, where the only signal is "an iPhone with iPad-like size classes". Apple advises against
/// branching on the idiom, and so does this project's own style guide — this is the one exception,
/// kept to a single predicate so it can be swapped for the real API when the SDK moves. Verified
/// so far only against stand-in previews at the published geometry (951 × 669 points); Xcode 27.1's
/// simulator is the real test.
enum FoldLayout {
    /// The hinge strip's width in points, centered on the inner display.
    static let hingeWidth: CGFloat = 40

    /// Whether a layout with these size classes is on the open iPhone Duo's inner display.
    @MainActor
    static func isInnerDisplay(horizontal: UserInterfaceSizeClass?, vertical: UserInterfaceSizeClass?) -> Bool {
        horizontal == .regular && vertical == .regular && UIDevice.current.userInterfaceIdiom == .phone
    }
}
