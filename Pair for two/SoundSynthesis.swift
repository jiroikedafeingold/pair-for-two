import Foundation

/// The game's sound effects, synthesized from scratch — no bundled audio assets.
///
/// Extracted verbatim from `GameFeedback` so it depends on Foundation alone. `GameFeedback` imports
/// UIKit and Core Haptics, which confines it to iOS; this file compiles anywhere, which is what lets
/// `tools/render-sounds.sh` build these exact functions into a command-line renderer and emit the
/// WAVs the **Android** app ships (PLAN.md §5.1). Android has no equivalent of synthesizing at
/// launch, so it plays pre-rendered files — and rendering them from this code rather than from a
/// re-implementation is the only way the two apps provably sound the same.
///
/// Everything here is deterministic: the noise source is a fixed-seed LCG, so a given function
/// always produces byte-identical output. That is what makes the committed WAVs diffable — a change
/// to any of these curves shows up as a changed file rather than as a sound nobody notices drifted.
nonisolated enum SoundSynthesis {

    static let sampleRate = 44_100

    /// Deterministic white noise so the effects sound identical every run.
    struct Noise {
        var state: UInt64 = 0x2545_F491_4F6C_DD1D
        mutating func next() -> Float {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Float(Int32(truncatingIfNeeded: state >> 32)) / Float(Int32.max)
        }
    }

    // MARK: - Effects

    static func clickSamples(decay: Float, level: Float, tone: Float) -> [Float] {
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

    static func flipSamples() -> [Float] {
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

    static func whooshSamples() -> [Float] {
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

    static func riffleSamples() -> [Float] {
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

    static func dingSamples(freq: Float, secondFreq: Float, duration: Double) -> [Float] {
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
    static func chimeSamples() -> [Float] {
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
    static func goSamples() -> [Float] {
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

    /// A single firework: a short rising whistle, a low boom, then a tail of crackling sparks.
    static func fireworkSamples() -> [Float] {
        let n = Int(Double(sampleRate) * 0.75)
        var noise = Noise()
        var out = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let t = Float(i) / Float(sampleRate)
            var s: Float = 0
            // Rising whistle (launch).
            if t < 0.24 {
                let f = 700 + 2600 * (t / 0.24)
                let env = (t < 0.02 ? t / 0.02 : 1) * (1 - t / 0.24) * 0.16
                s += sinf(2 * .pi * f * t) * env
            }
            // Low boom (the burst).
            if t >= 0.22 && t < 0.5 {
                let bt = t - 0.22
                let env = expf(-bt * 15) * 0.9
                s += (sinf(2 * .pi * 85 * t) * 0.7 + noise.next() * 0.5) * env
            }
            // Crackling sparks tapering off.
            if t >= 0.28 {
                let ct = t - 0.28
                let pop = expf(-ct.truncatingRemainder(dividingBy: 0.05) * 90)
                s += noise.next() * pop * 0.28 * expf(-ct * 3.5)
            }
            out[i] = max(-1, min(1, s))
        }
        return out
    }

    // MARK: - The named effect set
    //
    // The single list of what exists, so the app and the Android renderer can never disagree about
    // which sounds there are or how each is parameterised.

    /// Every effect, by the key `GameFeedback.soundKey(_:)` maps actions onto.
    static let allEffects: [(key: String, samples: () -> [Float])] = [
        ("click",    { clickSamples(decay: 130, level: 0.9, tone: 2200) }),
        ("tick",     { clickSamples(decay: 260, level: 0.4, tone: 3000) }),
        ("flip",     flipSamples),
        ("whoosh",   whooshSamples),
        ("riffle",   riffleSamples),
        ("ding",     { dingSamples(freq: 1046, secondFreq: 1568, duration: 0.32) }),
        ("chime",    chimeSamples),
        ("go",       goSamples),
        ("firework", fireworkSamples),
    ]

    // MARK: - WAV

    /// Wrap mono Float samples (−1…1) as a 16-bit PCM WAV.
    static func wav(_ samples: [Float]) -> Data {
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
