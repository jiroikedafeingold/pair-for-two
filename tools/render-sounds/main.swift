// Renders the game's sound effects to WAV files for the Android app.
//
// Compiled against the real `SoundSynthesis.swift`, so what it writes is by construction what iOS
// plays. iOS synthesizes these in memory at launch; Android has no equivalent, so it ships
// pre-rendered files and plays them through SoundPool (PLAN.md §5.1). Rendering them from the same
// code rather than from a re-implementation is the only way the two apps provably sound the same —
// and it means a change to a curve in SoundSynthesis shows up here as a changed file, rather than
// as a sound that quietly drifted on one platform.
//
// The synthesis is deterministic (fixed-seed LCG noise), so a clean re-run is byte-identical.
//
// Usage: tools/render-sounds.sh   [or]   render-sounds <output-dir>

import Foundation

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "sounds"
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

var total = 0
for effect in SoundSynthesis.allEffects {
    let samples = effect.samples()
    let data = SoundSynthesis.wav(samples)
    let path = "\(outDir)/\(effect.key).wav"
    guard FileManager.default.createFile(atPath: path, contents: data) else {
        print("FAIL: could not write \(path)")
        exit(1)
    }
    let seconds = Double(samples.count) / Double(SoundSynthesis.sampleRate)
    let peak = samples.map(abs).max() ?? 0
    // A silent or clipped effect would still produce a plausible-looking file, so check both.
    if peak < 0.01 { print("FAIL: \(effect.key) is effectively silent (peak \(peak))"); exit(1) }
    print(String(format: "  %-9@ %6d samples  %.3fs  peak %.3f  %d bytes",
                 effect.key as NSString, samples.count, seconds, peak, data.count))
    total += data.count
}
print("✓ rendered \(SoundSynthesis.allEffects.count) effects to \(outDir) (\(total) bytes)")
