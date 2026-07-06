import SwiftUI
import GameKit

/// Identifiable box so a `GKMatchmakerViewController` can drive a SwiftUI `.sheet(item:)`.
struct MatchmakerContext: Identifiable {
    let id = UUID()
    let controller: GKMatchmakerViewController
}

/// Hosts Game Center's own matchmaking UI (invite a friend / accept an invitation) inside SwiftUI.
/// GameKit hands us a `GKMatchmakerViewController`, so this thin `UIViewControllerRepresentable` is
/// the one place UIKit is unavoidable. It reports the ready `GKMatch`, a cancel, or an error back up.
struct MatchmakerView: UIViewControllerRepresentable {
    let controller: GKMatchmakerViewController
    var onMatch: (GKMatch) -> Void
    var onCancel: () -> Void
    var onError: (Error) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> GKMatchmakerViewController {
        controller.matchmakerDelegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ viewController: GKMatchmakerViewController, context: Context) {}

    final class Coordinator: NSObject, GKMatchmakerViewControllerDelegate {
        private let parent: MatchmakerView
        init(_ parent: MatchmakerView) { self.parent = parent }

        func matchmakerViewControllerWasCancelled(_ viewController: GKMatchmakerViewController) {
            parent.onCancel()
        }

        func matchmakerViewController(_ viewController: GKMatchmakerViewController,
                                      didFailWithError error: Error) {
            parent.onError(error)
        }

        func matchmakerViewController(_ viewController: GKMatchmakerViewController,
                                      didFind match: GKMatch) {
            parent.onMatch(match)
        }
    }
}
