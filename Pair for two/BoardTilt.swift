import CoreMotion
import SwiftUI

/// Reads which player the device is tipped toward, so the board's shared score can turn to them.
///
/// The board normally lies flat between two players and the score alternates on a timer, because when
/// it's flat there's no way to tell who is looking. Picking it up settles that: to read a screen you
/// tilt it so it faces you, which raises the edge *away* from you and lowers the edge nearest you —
/// the same geometry as a propped-up laptop lid. So the sign of gravity along the screen's vertical
/// axis says which side of the table is reading, and that beats the timer for as long as it's held.
///
/// Only the accelerometer is used (via device motion, for its gravity/user-acceleration split), which
/// needs no permission and no usage description.
@MainActor
@Observable
final class BoardTiltReader {

    /// The side the device is currently tipped toward, or nil while it's flat enough to belong to
    /// neither player.
    private(set) var facing: BoardSide?

    /// How far past flat the device has to be tipped before it counts as held by one player, and the
    /// smaller angle it has to come back within before it's shared again. The gap is hysteresis: a
    /// device propped at exactly the threshold would otherwise flap between the two.
    private static let claimAngle = 22.0    // degrees off flat
    private static let releaseAngle = 12.0

    /// Ten samples a second is plenty for "which way is it leaning" and costs nothing; the score's own
    /// turn animation takes 0.55s anyway.
    private static let sampleInterval = 1.0 / 10.0

    private let motion = CMMotionManager()
    private let queue = OperationQueue()

    init() {
        queue.name = "board-tilt"
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInitiated
    }

    /// Begin watching, unless the device has no motion hardware (or it's already running).
    func start() {
        guard motion.isDeviceMotionAvailable, !motion.isDeviceMotionActive else { return }
        motion.deviceMotionUpdateInterval = Self.sampleInterval
        motion.startDeviceMotionUpdates(to: queue) { [weak self] sample, _ in
            guard let sample else { return }
            // Only these three doubles cross to the main actor: CMDeviceMotion itself is a class, and
            // the interface orientation the reading has to be interpreted against can only be read
            // over there anyway.
            let (x, y, z) = (sample.gravity.x, sample.gravity.y, sample.gravity.z)
            Task { @MainActor [weak self] in self?.update(gravity: (x, y, z)) }
        }
    }

    func stop() {
        motion.stopDeviceMotionUpdates()
        facing = nil
    }

    /// Resolve a gravity reading into the side that's reading the screen.
    private func update(gravity: (x: Double, y: Double, z: Double)) {
        let alongScreenUp = Self.componentAlongScreenUp(gravity: gravity, orientation: Self.interfaceOrientation)
        facing = Self.side(forGravityAlongScreenUp: alongScreenUp, current: facing)
    }

    /// The decision itself, kept static and pure so it can be reasoned about (and checked) without a
    /// device: `alongScreenUp` is gravity's component along the direction the interface calls "up".
    ///
    /// Negative means the top of the screen is the raised edge, which is how a screen looks when the
    /// player it faces is on the *bottom* edge — the near player, whose half is drawn the normal way
    /// up. Positive is the mirror image: the far player, whose half is drawn rotated 180°, holds it
    /// with the screen's bottom edge raised, because that's "up" as they read it.
    static func side(forGravityAlongScreenUp alongScreenUp: Double, current: BoardSide?) -> BoardSide? {
        let claim = sin(claimAngle * .pi / 180)
        let release = sin(releaseAngle * .pi / 180)
        // A side already holding it keeps it until the device comes back near flat.
        if let current, abs(alongScreenUp) > release {
            let stillTheirs = current == .bottom ? alongScreenUp < 0 : alongScreenUp > 0
            if stillTheirs { return current }
        }
        if alongScreenUp <= -claim { return .bottom }
        if alongScreenUp >= claim { return .top }
        return nil
    }

    /// Gravity is reported in the device's own frame — x across the short edge, y along the long edge
    /// toward the camera, z out of the glass — so which of those the interface currently calls "up"
    /// depends on how the UI is rotated.
    ///
    /// The landscape signs follow from the pair of definitions that trip everyone up: interface
    /// `landscapeRight` is device orientation `landscapeLeft` (home edge to the right), which puts the
    /// device's +x axis pointing at the sky. Hence +x is screen-up there, and -x in the mirror case.
    static func componentAlongScreenUp(gravity: (x: Double, y: Double, z: Double),
                                       orientation: UIInterfaceOrientation) -> Double {
        switch orientation {
        case .portrait:           return gravity.y
        case .portraitUpsideDown: return -gravity.y
        case .landscapeLeft:      return -gravity.x
        case .landscapeRight:     return gravity.x
        default:                  return gravity.y
        }
    }

    private static var interfaceOrientation: UIInterfaceOrientation {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?.interfaceOrientation ?? .portrait
    }
}
