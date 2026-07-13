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

        // A long, relentless celebration: two overlapping continuous rumbles (deep + sharp buzz),
        // a dense accelerating fusillade of full-strength taps with crackle, and a big finale barrage.
        // Bigger skunk → longer and crazier.
        let duration: Double
        let burstCount: Int
        switch skunk {
        case .none:   duration = 4.0; burstCount = 46
        case .single: duration = 5.5; burstCount = 72
        case .double: duration = 7.0; burstCount = 100
        }

        var events: [CHHapticEvent] = []

        // Two continuous layers across the whole celebration: a deep body rumble + a sharp buzz on top.
        events.append(CHHapticEvent(
            eventType: .hapticContinuous,
            parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: 1.0),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.25)
            ],
            relativeTime: 0, duration: duration))
        events.append(CHHapticEvent(
            eventType: .hapticContinuous,
            parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.8),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.85)
            ],
            relativeTime: 0, duration: duration))

        // Dense accelerating fusillade of near-max taps; every few adds a crackle double-tap.
        var t = 0.0
        for i in 0..<burstCount {
            let frac = Double(i) / Double(burstCount)
            t += max(0.035, 0.13 - 0.09 * frac)
            if t > duration - 0.4 { break }
            events.append(CHHapticEvent(
                eventType: .hapticTransient,
                parameters: [
                    CHHapticEventParameter(parameterID: .hapticIntensity, value: Float(min(1.0, 0.85 + 0.2 * frac))),
                    CHHapticEventParameter(parameterID: .hapticSharpness, value: Float((i % 3 == 0) ? 0.95 : 0.45 + 0.45 * frac))
                ],
                relativeTime: t))
            if i % 5 == 0 {   // crackle
                events.append(CHHapticEvent(
                    eventType: .hapticTransient,
                    parameters: [
                        CHHapticEventParameter(parameterID: .hapticIntensity, value: 1.0),
                        CHHapticEventParameter(parameterID: .hapticSharpness, value: 1.0)
                    ],
                    relativeTime: t + 0.02))
            }
        }

        // Finale: a barrage of huge booms + a final swell.
        let finale = max(0, duration - 0.5)
        for dt in [0.0, 0.07, 0.14, 0.22, 0.31, 0.42] {
            events.append(CHHapticEvent(
                eventType: .hapticTransient,
                parameters: [
                    CHHapticEventParameter(parameterID: .hapticIntensity, value: 1.0),
                    CHHapticEventParameter(parameterID: .hapticSharpness, value: dt >= 0.31 ? 0.95 : 0.55)
                ],
                relativeTime: finale + dt))
        }
        events.append(CHHapticEvent(
            eventType: .hapticContinuous,
            parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: 1.0),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.6)
            ],
            relativeTime: finale, duration: 0.55))

        // Intensity curve: swell in fast and stay high, peaking at the finale.
        let intensityCurve = CHHapticParameterCurve(
            parameterID: .hapticIntensityControl,
            controlPoints: [
                .init(relativeTime: 0, value: 0.7),
                .init(relativeTime: duration * 0.2, value: 1.0),
                .init(relativeTime: duration * 0.6, value: 0.9),
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
