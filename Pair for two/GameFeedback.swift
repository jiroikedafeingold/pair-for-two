import UIKit
import CoreHaptics
import AVFoundation

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

    // UIKit fallbacks (used when Core Haptics is unavailable).
    private let lightImpact = UIImpactFeedbackGenerator(style: .light)
    private let mediumImpact = UIImpactFeedbackGenerator(style: .medium)
    private let heavyImpact = UIImpactFeedbackGenerator(style: .heavy)
    private let rigidImpact = UIImpactFeedbackGenerator(style: .rigid)
    private let notify = UINotificationFeedbackGenerator()

    private var players: [String: AVAudioPlayer] = [:]
    private var audioReady = false

    private init() {
        startEngine()
        buildSounds()
    }

    // MARK: Public entry point

    func play(_ action: Action) {
        playHaptic(action)
        playSound(for: action)
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
            try engine?.start()
            engine?.resetHandler = { [weak self] in try? self?.engine?.start() }
            engine?.stoppedHandler = { _ in }
        } catch {
            engine = nil
        }
    }

    private func playHaptic(_ action: Action) {
        guard supportsHaptics, let engine else { fallbackHaptic(action); return }
        do {
            let pattern = try haptic(for: action)
            let player = try engine.makePlayer(with: pattern)
            try engine.start()
            try player.start(atTime: CHHapticTimeImmediate)
        } catch {
            fallbackHaptic(action)
        }
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
            guard let player = try? AVAudioPlayer(data: wav(samples)) else { ok = false; return }
            player.prepareToPlay()
            players[key] = player
        }
        register("click", clickSamples(decay: 130, level: 0.9, tone: 2200))
        register("tick", clickSamples(decay: 260, level: 0.4, tone: 3000))
        register("flip", flipSamples())
        register("whoosh", whooshSamples())
        register("riffle", riffleSamples())
        register("ding", dingSamples(freq: 1046, secondFreq: 1568, duration: 0.32))
        register("chime", chimeSamples())
        register("go", goSamples())
        audioReady = ok
    }

    // MARK: Sound synthesis

    private let sampleRate = 44_100

    /// Deterministic white noise so the effects sound identical every run.
    private struct Noise {
        var state: UInt64 = 0x2545_F491_4F6C_DD1D
        mutating func next() -> Float {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Float(Int32(truncatingIfNeeded: state >> 32)) / Float(Int32.max)
        }
    }

    private func clickSamples(decay: Float, level: Float, tone: Float) -> [Float] {
        let n = Int(Double(sampleRate) * 0.05)
        var noise = Noise()
        var out = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let t = Float(i) / Float(sampleRate)
            let env = expf(-t * decay)
            let body = noise.next() * 0.7 + sinf(2 * .pi * tone * t) * 0.3
            out[i] = body * env * level
        }
        return out
    }

    private func flipSamples() -> [Float] {
        let n = Int(Double(sampleRate) * 0.14)
        var noise = Noise()
        var out = [Float](repeating: 0, count: n)
        var lp: Float = 0
        for i in 0..<n {
            let t = Float(i) / Float(sampleRate)
            // Two-part envelope: a soft riffle then a sharper snap as it lands.
            let env = t < 0.05 ? (t / 0.05) * 0.5 : expf(-(t - 0.05) * 55) * 0.9
            lp += (noise.next() - lp) * 0.5   // one-pole lowpass to soften the noise
            out[i] = lp * env
        }
        return out
    }

    private func whooshSamples() -> [Float] {
        let n = Int(Double(sampleRate) * 0.28)
        var noise = Noise()
        var out = [Float](repeating: 0, count: n)
        var lp: Float = 0
        for i in 0..<n {
            let t = Float(i) / Float(sampleRate)
            let env = sinf(.pi * min(1, t / 0.28)) * 0.6   // smooth rise and fall
            lp += (noise.next() - lp) * 0.12               // heavier lowpass → airy "whoosh"
            out[i] = lp * env
        }
        return out
    }

    private func riffleSamples() -> [Float] {
        let n = Int(Double(sampleRate) * 0.5)
        var noise = Noise()
        var out = [Float](repeating: 0, count: n)
        // ~11 quick clicks (cards falling), slightly accelerating then easing.
        let clicks: [Float] = [0, 0.05, 0.095, 0.135, 0.17, 0.205, 0.245, 0.29, 0.34, 0.4, 0.46]
        for (idx, start) in clicks.enumerated() {
            let s0 = Int(start * Float(sampleRate))
            let clickLen = Int(0.02 * Double(sampleRate))
            let fade = 1.0 - Float(idx) / Float(clicks.count) * 0.4
            for j in 0..<clickLen where s0 + j < n {
                let t = Float(j) / Float(sampleRate)
                out[s0 + j] += noise.next() * expf(-t * 300) * 0.5 * fade
            }
        }
        return out
    }

    private func dingSamples(freq: Float, secondFreq: Float, duration: Double) -> [Float] {
        let n = Int(Double(sampleRate) * duration)
        var out = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let t = Float(i) / Float(sampleRate)
            let env = expf(-t * 9)
            out[i] = (sinf(2 * .pi * freq * t) * 0.6 + sinf(2 * .pi * secondFreq * t) * 0.35) * env * 0.7
        }
        return out
    }

    /// A bright three-note rising arpeggio for hitting 31.
    private func chimeSamples() -> [Float] {
        let notes: [Float] = [784, 988, 1319]   // G5 · B5 · E6
        let step = 0.09
        let n = Int(Double(sampleRate) * (step * Double(notes.count) + 0.25))
        var out = [Float](repeating: 0, count: n)
        for (idx, f) in notes.enumerated() {
            let start = Int(Double(idx) * step * Double(sampleRate))
            for j in 0..<(n - start) {
                let t = Float(j) / Float(sampleRate)
                let env = expf(-t * 7)
                out[start + j] += sinf(2 * .pi * f * t) * env * 0.4
            }
        }
        return out
    }

    /// Two firm mid notes for a "go".
    private func goSamples() -> [Float] {
        let n = Int(Double(sampleRate) * 0.3)
        var out = [Float](repeating: 0, count: n)
        let hits: [(Double, Float)] = [(0, 660), (0.13, 660)]
        for (start, f) in hits {
            let s0 = Int(start * Double(sampleRate))
            for j in 0..<(n - s0) {
                let t = Float(j) / Float(sampleRate)
                let env = expf(-t * 16)
                out[s0 + j] += sinf(2 * .pi * f * t) * env * 0.5
            }
        }
        return out
    }

    /// Wrap mono Float samples (−1…1) as a 16-bit PCM WAV in memory.
    private func wav(_ samples: [Float]) -> Data {
        var pcm = [Int16](); pcm.reserveCapacity(samples.count)
        for s in samples { pcm.append(Int16(max(-1, min(1, s)) * 32_767)) }
        let dataSize = pcm.count * 2
        var d = Data()
        func str(_ s: String) { d.append(contentsOf: Array(s.utf8)) }
        func u32(_ v: UInt32) { var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        str("RIFF"); u32(UInt32(36 + dataSize)); str("WAVE")
        str("fmt "); u32(16); u16(1); u16(1)
        u32(UInt32(sampleRate)); u32(UInt32(sampleRate * 2)); u16(2); u16(16)
        str("data"); u32(UInt32(dataSize))
        pcm.withUnsafeBufferPointer { d.append(contentsOf: UnsafeRawBufferPointer($0)) }
        return d
    }
}
