import UIKit
import CoreHaptics

// MARK: - Global haptics toggle

/// Whether haptics are enabled (Settings → "Haptics"). Read at each call site so turning it off
/// silences every vibration — play, win, and slider ticks alike. Defaults to on.
enum HapticsSetting {
    static var enabled: Bool { (UserDefaults.standard.object(forKey: "hapticsEnabled") as? Bool) ?? true }
}

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
        guard HapticsSetting.enabled else { return }
        guard let engine, CHHapticEngine.capabilitiesForHardware().supportsHaptics else {
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            UIImpactFeedbackGenerator(style: .heavy).impactOccurred(intensity: 1.0)
            return
        }

        // A long, escalating celebration: a swelling rumble + an accelerating fusillade of strong
        // taps + a finale of big booms. Bigger skunk → longer and crazier.
        let duration: Double
        let burstCount: Int
        switch skunk {
        case .none:   duration = 2.2; burstCount = 18
        case .single: duration = 3.0; burstCount = 28
        case .double: duration = 4.2; burstCount = 42
        }

        var events: [CHHapticEvent] = []

        // Base rumble across the whole celebration.
        events.append(CHHapticEvent(
            eventType: .hapticContinuous,
            parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: 1.0),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.35)
            ],
            relativeTime: 0, duration: duration))

        // Accelerating fusillade of transients (spacing shrinks toward the end).
        var t = 0.0
        for i in 0..<burstCount {
            let frac = Double(i) / Double(burstCount)
            t += max(0.05, 0.16 - 0.09 * frac)
            if t > duration - 0.35 { break }
            events.append(CHHapticEvent(
                eventType: .hapticTransient,
                parameters: [
                    CHHapticEventParameter(parameterID: .hapticIntensity, value: Float(0.7 + 0.3 * frac)),
                    CHHapticEventParameter(parameterID: .hapticSharpness, value: Float((i % 4 == 0) ? 0.95 : 0.4 + 0.5 * frac))
                ],
                relativeTime: t))
        }

        // Finale: a cluster of huge booms + a final swell.
        let finale = max(0, duration - 0.3)
        for (k, dt) in [0.0, 0.08, 0.17].enumerated() {
            events.append(CHHapticEvent(
                eventType: .hapticTransient,
                parameters: [
                    CHHapticEventParameter(parameterID: .hapticIntensity, value: 1.0),
                    CHHapticEventParameter(parameterID: .hapticSharpness, value: k == 2 ? 0.95 : 0.5)
                ],
                relativeTime: finale + dt))
        }
        events.append(CHHapticEvent(
            eventType: .hapticContinuous,
            parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: 1.0),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.6)
            ],
            relativeTime: finale, duration: 0.4))

        // Intensity curve: swell in, pulse, then peak at the finale.
        let intensityCurve = CHHapticParameterCurve(
            parameterID: .hapticIntensityControl,
            controlPoints: [
                .init(relativeTime: 0, value: 0.5),
                .init(relativeTime: duration * 0.3, value: 0.95),
                .init(relativeTime: duration * 0.6, value: 0.7),
                .init(relativeTime: duration * 0.85, value: 1.0),
                .init(relativeTime: duration, value: 0.0)
            ],
            relativeTime: 0)

        do {
            let pattern = try CHHapticPattern(events: events, parameterCurves: [intensityCurve])
            let player = try engine.makePlayer(with: pattern)
            try engine.start()
            try player.start(atTime: CHHapticTimeImmediate)
        } catch {
            UINotificationFeedbackGenerator().notificationOccurred(.success)
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
        guard HapticsSetting.enabled else { return }
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
