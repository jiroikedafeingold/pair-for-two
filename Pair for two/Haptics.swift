import UIKit
import CoreHaptics

// MARK: - Win Haptics (reused from Criboard)

/// Celebratory rumble for a win, scaled by skunk level.
final class WinHaptics {
    static let shared = WinHaptics()
    private var engine: CHHapticEngine?

    init() {
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else { return }
        do {
            engine = try CHHapticEngine()
            try engine?.start()
            engine?.resetHandler = { [weak self] in
                try? self?.engine?.start()
            }
            engine?.stoppedHandler = { _ in }
        } catch {
            engine = nil
        }
    }

    func play(skunk: SkunkLevel) {
        guard let engine, CHHapticEngine.capabilitiesForHardware().supportsHaptics else {
            let n = UINotificationFeedbackGenerator()
            n.notificationOccurred(.success)
            return
        }

        let (duration, ramps): (Double, [(Double, Float)])
        switch skunk {
        case .none:
            duration = 1.2
            ramps = [(0.0, 0.55), (0.6, 0.85), (1.2, 0.0)]
        case .single:
            duration = 1.8
            ramps = [(0.0, 0.7), (0.6, 0.95), (1.2, 1.0), (1.8, 0.0)]
        case .double:
            duration = 2.6
            ramps = [(0.0, 0.7), (0.5, 0.9), (1.0, 1.0), (1.8, 1.0), (2.6, 0.0)]
        }

        var events: [CHHapticEvent] = []

        let continuous = CHHapticEvent(
            eventType: .hapticContinuous,
            parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.95),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.45)
            ],
            relativeTime: 0,
            duration: duration
        )
        events.append(continuous)

        let beats: [Double]
        switch skunk {
        case .none:   beats = [0.0, 0.4, 0.9]
        case .single: beats = [0.0, 0.3, 0.6, 1.0, 1.4]
        case .double: beats = [0.0, 0.25, 0.5, 0.8, 1.1, 1.5, 1.9, 2.3]
        }
        for t in beats {
            events.append(
                CHHapticEvent(
                    eventType: .hapticTransient,
                    parameters: [
                        CHHapticEventParameter(parameterID: .hapticIntensity, value: 1.0),
                        CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.8)
                    ],
                    relativeTime: t
                )
            )
        }

        let intensityCurve = CHHapticParameterCurve(
            parameterID: .hapticIntensityControl,
            controlPoints: ramps.map { CHHapticParameterCurve.ControlPoint(relativeTime: $0.0, value: $0.1) },
            relativeTime: 0
        )

        do {
            let pattern = try CHHapticPattern(events: events, parameterCurves: [intensityCurve])
            let player = try engine.makePlayer(with: pattern)
            try engine.start()
            try player.start(atTime: CHHapticTimeImmediate)
        } catch {
            let n = UINotificationFeedbackGenerator()
            n.notificationOccurred(.success)
        }
    }
}

// MARK: - Drag Tick Haptics (reused from Criboard)

/// Per-step feedback for the points slider. Uses Core Haptics so the tick scales in strength as the
/// number climbs, stacking a deep transient at the top. Falls back to escalating UIImpact generators.
final class DragTickHaptics {
    static let shared = DragTickHaptics()

    private let supportsHaptics = CHHapticEngine.capabilitiesForHardware().supportsHaptics
    private var engine: CHHapticEngine?

    private let fallbackMedium = UIImpactFeedbackGenerator(style: .medium)
    private let fallbackHeavy = UIImpactFeedbackGenerator(style: .heavy)
    private let fallbackRigid = UIImpactFeedbackGenerator(style: .rigid)

    init() {
        guard supportsHaptics else { return }
        do {
            engine = try CHHapticEngine()
            try engine?.start()
            engine?.resetHandler = { [weak self] in try? self?.engine?.start() }
            engine?.stoppedHandler = { _ in }
        } catch {
            engine = nil
        }
    }

    func prepare() {
        fallbackMedium.prepare(); fallbackHeavy.prepare(); fallbackRigid.prepare()
        try? engine?.start()
    }

    /// - Parameter progress: 0...1 position of the value along the track.
    func tick(progress: Double) {
        let p = min(1, max(0, progress))

        guard supportsHaptics, let engine else {
            fallbackTick(p)
            return
        }

        let intensity = Float(0.85 + 0.15 * p)
        let sharpness = Float(0.4 + 0.6 * p)
        var events: [CHHapticEvent] = [
            CHHapticEvent(
                eventType: .hapticTransient,
                parameters: [
                    CHHapticEventParameter(parameterID: .hapticIntensity, value: intensity),
                    CHHapticEventParameter(parameterID: .hapticSharpness, value: sharpness)
                ],
                relativeTime: 0
            )
        ]
        if p >= 0.85 {
            events.append(
                CHHapticEvent(
                    eventType: .hapticTransient,
                    parameters: [
                        CHHapticEventParameter(parameterID: .hapticIntensity, value: 1.0),
                        CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.05)
                    ],
                    relativeTime: 0
                )
            )
            events.append(
                CHHapticEvent(
                    eventType: .hapticContinuous,
                    parameters: [
                        CHHapticEventParameter(parameterID: .hapticIntensity, value: 1.0),
                        CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.5)
                    ],
                    relativeTime: 0,
                    duration: 0.09
                )
            )
            events.append(
                CHHapticEvent(
                    eventType: .hapticTransient,
                    parameters: [
                        CHHapticEventParameter(parameterID: .hapticIntensity, value: 1.0),
                        CHHapticEventParameter(parameterID: .hapticSharpness, value: 1.0)
                    ],
                    relativeTime: 0.015
                )
            )
        }
        do {
            let pattern = try CHHapticPattern(events: events, parameters: [])
            let player = try engine.makePlayer(with: pattern)
            try player.start(atTime: CHHapticTimeImmediate)
        } catch {
            fallbackTick(p)
        }
    }

    private func fallbackTick(_ p: Double) {
        if p >= 0.85 {
            fallbackHeavy.impactOccurred(intensity: 1.0)
            fallbackRigid.impactOccurred(intensity: 1.0)
            fallbackHeavy.prepare(); fallbackRigid.prepare()
        } else if p >= 0.5 {
            fallbackHeavy.impactOccurred(intensity: CGFloat(0.85 + 0.15 * p))
            fallbackHeavy.prepare()
        } else {
            fallbackMedium.impactOccurred(intensity: CGFloat(0.85 + 0.15 * p))
            fallbackMedium.prepare()
        }
    }
}
