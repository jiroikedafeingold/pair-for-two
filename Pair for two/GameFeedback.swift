import UIKit
import CoreHaptics
import AVFoundation
import QuartzCore

/// Whether sound effects are enabled (Settings → "Sound effects"). Read at each play so turning it
/// off silences all SFX. Defaults to on.
enum SoundSetting {
    static var enabled: Bool { (UserDefaults.standard.object(forKey: "soundEnabled") as? Bool) ?? true }
}

/// Unified tactile + audio feedback for in-game actions. One call — `GameFeedback.shared.play(.cardPlay)`
/// — fires a rich Core Haptics pattern (with a graceful UIKit fallback) and a matching sound effect.
///
/// Sounds are synthesized in memory at launch (no bundled asset files), wrapped as tiny WAV buffers and
/// played through cached `AVAudioPlayer`s. The audio session is `.ambient`, so effects mix with other
/// audio and honour the ring/silent switch — appropriate for a game's SFX.
@MainActor
final class GameFeedback {
    static let shared = GameFeedback()

    /// Every discrete moment the game gives feedback for.
    enum Action {
        case cardPlay        // a card lands on the pegging pile
        case discardSelect   // toggling a card for the crib
        case discardConfirm  // sending 2 to the crib
        case cutTap          // tapping to cut for deal
        case deckLift        // the pone lifts the deck for the starter cut
        case starterReveal   // the dealer turns up the starter
        case deal            // a fresh hand is dealt
        case go              // a "go" — the other player takes 1
        case thirtyOne       // the count hits 31
        case score           // points added to a peg
        case advance         // "continue" / next step
    }

    private var engine: CHHapticEngine?
    private let supportsHaptics = CHHapticEngine.capabilitiesForHardware().supportsHaptics
    /// Pattern players built once per action and reused, so firing a haptic is a single lightweight
    /// `start()` — no per-call pattern compile/allocation, which mattered during the rapid
    /// card-by-card deal-out when counting hands.
    private var hapticPlayers: [Action: CHHapticPatternPlayer] = [:]

    // UIKit fallbacks (used when Core Haptics is unavailable).
    private let lightImpact = UIImpactFeedbackGenerator(style: .light)
    private let mediumImpact = UIImpactFeedbackGenerator(style: .medium)
    private let heavyImpact = UIImpactFeedbackGenerator(style: .heavy)
    private let rigidImpact = UIImpactFeedbackGenerator(style: .rigid)
    private let notify = UINotificationFeedbackGenerator()

    private var players: [String: AVAudioPlayer] = [:]
    private var audioReady = false

    /// When the last scoring haptic fired (monotonic clock), used to thin out rapid replay ticks.
    private var lastScoreTickAt: CFTimeInterval = 0

    // A small pool of firework players so celebration pops can overlap; driven by `playCelebration()`.
    private var celebrationPool: [AVAudioPlayer] = []
    private var celebrationTask: Task<Void, Never>?

    private init() {
        startEngine()
        buildSounds()
    }

    // MARK: Public entry point

    func play(_ action: Action) {
        playHaptic(action)
        playSound(for: action)
    }

    /// A score "tick" whose strength scales with the points: a light tap for a small move (a peg or a
    /// pair), a firmer and longer buzz for a big hand. Used by the scoring replay so each step feels
    /// proportional instead of a constant string of identical taps.
    func playScoreTick(points: Int) {
        playSound(for: .score)
        guard HapticsSetting.enabled else { return }
        let p = max(1, points)
        // Thin out the taps. During the replay small scores can land only ~0.12s apart, and even
        // discrete taps that fast blur into one constant buzz — so a small score is skipped (sound
        // only) if we buzzed very recently. Big hands always fire, so the moments that matter still
        // land with a firm tap.
        let now = CACurrentMediaTime()
        if p < 7 && now - lastScoreTickAt < 0.3 { return }
        lastScoreTickAt = now
        if supportsHaptics, let engine {
            do {
                let player = try engine.makePlayer(with: scaledScorePattern(points: p))
                try player.start(atTime: CHHapticTimeImmediate)
                return
            } catch { /* fall through to the UIKit generators */ }
        }
        switch p {
        case ...2:  lightImpact.impactOccurred(intensity: 0.55); lightImpact.prepare()
        case 3...5: mediumImpact.impactOccurred(intensity: 0.9); mediumImpact.prepare()
        default:    heavyImpact.impactOccurred(intensity: 1.0); heavyImpact.prepare()
        }
    }

    /// A single crisp tap that scales from a small score (1) to a big hand (12+): mellow and soft for
    /// a small move, hard and sharp for a big one — but always a brief tap, never a lingering rumble.
    /// (The replay fires these in quick succession, so any sustained buzz runs together into one long
    /// vibration — keeping each one transient keeps the ticks feeling discrete and proportional.)
    private func scaledScorePattern(points: Int) throws -> CHHapticPattern {
        let t = min(1.0, max(0.0, Double(points - 1) / 11.0))
        let intensity = Float(0.35 + 0.65 * t)   // soft → strong
        let sharpness = Float(0.30 + 0.65 * t)   // rounded/mellow → hard/crisp
        var events = [transient(0, intensity, sharpness)]
        // Only sizeable hands get a short firm thump for extra weight — still under 1/20th of a second,
        // so it stays a punchy tap rather than a buzz.
        if t > 0.5 {
            events.append(continuous(0.01, 0.045, intensity * 0.6, sharpness))
        }
        return try CHHapticPattern(events: events, parameters: [])
    }

    /// Fire a volley of firework pops for the win celebration (sound only). Overlapping pops play
    /// through a small pool, each with a little pitch/volume variation so they don't sound identical.
    func playCelebration() {
        guard SoundSetting.enabled, audioReady, !celebrationPool.isEmpty else { return }
        celebrationTask?.cancel()
        celebrationTask = Task { @MainActor [weak self] in
            for k in 0..<14 {
                guard let self, !Task.isCancelled else { return }
                let p = self.celebrationPool[k % self.celebrationPool.count]
                p.currentTime = 0
                p.rate = Float.random(in: 0.88...1.22)
                p.volume = Float.random(in: 0.65...1.0)
                p.play()
                try? await Task.sleep(for: .seconds(Double.random(in: 0.26...0.6)))
            }
        }
    }

    /// Warm up the generators/engine ahead of a burst of actions (called when a game screen appears).
    func prepare() {
        lightImpact.prepare(); mediumImpact.prepare(); heavyImpact.prepare(); rigidImpact.prepare()
        try? engine?.start()
        activateAudioSession()
    }

    // MARK: Haptics

    private func startEngine() {
        guard supportsHaptics else { return }
        do {
            engine = try CHHapticEngine()
            // Keep the engine running between events so we never pay a synchronous `start()` per
            // haptic — doing that on every card stalled the main thread during the counting deal-out
            // on iPhone (iPads have no haptics, so they were unaffected).
            engine?.isAutoShutdownEnabled = false
            engine?.resetHandler = { [weak self] in
                try? self?.engine?.start()
                // Players are tied to the engine instance — drop them so they rebuild after a reset.
                Task { @MainActor in self?.hapticPlayers.removeAll() }
            }
            engine?.stoppedHandler = { [weak self] reason in
                // The system stops the engine on interruptions (calls, other haptics). Bring it back
                // so haptics keep working mid-game, unless the app itself is going away.
                switch reason {
                case .applicationSuspended, .engineDestroyed: break
                default: try? self?.engine?.start()
                }
            }
            try engine?.start()
        } catch {
            engine = nil
        }
    }

    private func playHaptic(_ action: Action) {
        guard HapticsSetting.enabled else { return }
        guard supportsHaptics, engine != nil, let player = hapticPlayer(for: action) else {
            fallbackHaptic(action); return
        }
        do {
            try player.start(atTime: CHHapticTimeImmediate)
        } catch {
            fallbackHaptic(action)
        }
    }

    /// Returns the cached pattern player for `action`, building it on first use. Runs on the main
    /// actor, so the lazy build is race-free.
    private func hapticPlayer(for action: Action) -> CHHapticPatternPlayer? {
        if let player = hapticPlayers[action] { return player }
        guard let engine,
              let pattern = try? haptic(for: action),
              let player = try? engine.makePlayer(with: pattern) else { return nil }
        hapticPlayers[action] = player
        return player
    }

    private func transient(_ time: Double, _ intensity: Float, _ sharpness: Float) -> CHHapticEvent {
        CHHapticEvent(eventType: .hapticTransient, parameters: [
            CHHapticEventParameter(parameterID: .hapticIntensity, value: intensity),
            CHHapticEventParameter(parameterID: .hapticSharpness, value: sharpness)
        ], relativeTime: time)
    }

    private func continuous(_ time: Double, _ duration: Double, _ intensity: Float, _ sharpness: Float) -> CHHapticEvent {
        CHHapticEvent(eventType: .hapticContinuous, parameters: [
            CHHapticEventParameter(parameterID: .hapticIntensity, value: intensity),
            CHHapticEventParameter(parameterID: .hapticSharpness, value: sharpness)
        ], relativeTime: time, duration: duration)
    }

    private func haptic(for action: Action) throws -> CHHapticPattern {
        switch action {
        case .cardPlay:
            // A crisp "snap" as the card hits the table.
            return try CHHapticPattern(events: [
                transient(0, 0.9, 0.85),
                continuous(0, 0.045, 0.5, 0.6)
            ], parameters: [])

        case .discardSelect:
            return try CHHapticPattern(events: [transient(0, 0.55, 0.55)], parameters: [])

        case .discardConfirm:
            return try CHHapticPattern(events: [
                transient(0, 0.7, 0.6), transient(0.07, 0.85, 0.75)
            ], parameters: [])

        case .cutTap:
            // A slide then a click — cutting the deck.
            return try CHHapticPattern(events: [
                continuous(0, 0.12, 0.5, 0.3),
                transient(0.13, 0.9, 0.9)
            ], parameters: [])

        case .deckLift:
            // A rising drag as the top portion is lifted aside.
            let curve = CHHapticParameterCurve(parameterID: .hapticIntensityControl, controlPoints: [
                .init(relativeTime: 0, value: 0.2),
                .init(relativeTime: 0.18, value: 0.7),
                .init(relativeTime: 0.26, value: 0.0)
            ], relativeTime: 0)
            return try CHHapticPattern(events: [continuous(0, 0.26, 0.7, 0.35)], parameterCurves: [curve])

        case .starterReveal:
            // Turn + a satisfying thud as the starter lands face up.
            return try CHHapticPattern(events: [
                transient(0, 0.7, 0.9),
                continuous(0.02, 0.06, 0.6, 0.5),
                transient(0.11, 1.0, 0.7)
            ], parameters: [])

        case .deal:
            // A rolling riffle: several quick transients tapering off.
            var events: [CHHapticEvent] = []
            let beats: [Double] = [0, 0.05, 0.095, 0.135, 0.17, 0.205, 0.245, 0.29, 0.35, 0.42]
            for (i, t) in beats.enumerated() {
                let fade = Float(1.0 - Double(i) / Double(beats.count) * 0.5)
                events.append(transient(t, 0.5 * fade, 0.75))
            }
            return try CHHapticPattern(events: events, parameters: [])

        case .go:
            // Two firm taps — "you're on, take the point".
            return try CHHapticPattern(events: [
                transient(0, 0.9, 0.5), transient(0.14, 0.9, 0.5)
            ], parameters: [])

        case .thirtyOne:
            // A strong escalating triple with a little rumble — the biggest pegging moment.
            return try CHHapticPattern(events: [
                transient(0, 0.8, 0.6),
                transient(0.1, 0.9, 0.7),
                transient(0.2, 1.0, 0.9),
                continuous(0.2, 0.18, 0.9, 0.5)
            ], parameters: [])

        case .score:
            return try CHHapticPattern(events: [
                transient(0, 0.9, 0.7),
                continuous(0.01, 0.08, 0.7, 0.4)
            ], parameters: [])

        case .advance:
            return try CHHapticPattern(events: [transient(0, 0.7, 0.6)], parameters: [])
        }
    }

    private func fallbackHaptic(_ action: Action) {
        switch action {
        case .discardSelect: lightImpact.impactOccurred(); lightImpact.prepare()
        case .advance, .discardConfirm: mediumImpact.impactOccurred(); mediumImpact.prepare()
        case .cardPlay, .cutTap, .starterReveal: rigidImpact.impactOccurred(intensity: 0.9); rigidImpact.prepare()
        case .deckLift: mediumImpact.impactOccurred(intensity: 0.7); mediumImpact.prepare()
        case .deal: notify.notificationOccurred(.success); notify.prepare()
        case .go, .score: heavyImpact.impactOccurred(); heavyImpact.prepare()
        case .thirtyOne:
            heavyImpact.impactOccurred(intensity: 1.0); rigidImpact.impactOccurred(intensity: 1.0)
            heavyImpact.prepare(); rigidImpact.prepare()
        }
    }

    // MARK: Sound

    private func playSound(for action: Action) {
        guard SoundSetting.enabled else { return }
        guard audioReady, let player = players[soundKey(action)] else { return }
        player.currentTime = 0
        player.play()
    }

    private func soundKey(_ action: Action) -> String {
        switch action {
        case .cardPlay:                     return "click"
        case .discardSelect:                return "tick"
        case .discardConfirm:               return "click"
        case .cutTap:                       return "flip"
        case .deckLift:                     return "whoosh"
        case .starterReveal:                return "flip"
        case .deal:                         return "riffle"
        case .go:                           return "go"
        case .thirtyOne:                    return "chime"
        case .score:                        return "ding"
        case .advance:                      return "tick"
        }
    }

    private func activateAudioSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.ambient, mode: .default, options: [.mixWithOthers])
        try? session.setActive(true)
    }

    private func buildSounds() {
        activateAudioSession()
        var ok = true
        func register(_ key: String, _ samples: [Float]) {
            guard let player = try? AVAudioPlayer(data: SoundSynthesis.wav(samples)) else { ok = false; return }
            player.prepareToPlay()
            players[key] = player
        }
        // Driven by SoundSynthesis.allEffects so the app and the Android renderer can't drift
        // apart on which sounds exist or how each is parameterised.
        for effect in SoundSynthesis.allEffects where effect.key != "firework" {
            register(effect.key, effect.samples())
        }

        // Firework pool (whistle → boom → crackle), reused for the win celebration volley.
        let fireworkData = SoundSynthesis.wav(SoundSynthesis.fireworkSamples())
        celebrationPool = (0..<4).compactMap { _ -> AVAudioPlayer? in
            guard let p = try? AVAudioPlayer(data: fireworkData) else { return nil }
            p.enableRate = true
            p.prepareToPlay()
            return p
        }

        audioReady = ok
    }

}
