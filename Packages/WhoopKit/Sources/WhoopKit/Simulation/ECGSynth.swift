import Foundation

/// A synthetic single-lead ECG: a P-QRS-T template (sum of Gaussians, McSharry-style)
/// placed at each beat, plus slow baseline wander and optional noise. Deterministic for a
/// given seed, and it never touches the physiology simulator's random sequence.
public enum ECGSynth {
    /// `count` samples starting at `start`, at `rate` Hz, for R peaks at `beats` (same time
    /// base). Amplitude is in arbitrary native units (R ≈ `gain`). `tWave` is the T wave's
    /// (amplitude relative to R, delay after R in s); `noise` is white noise relative to R.
    public static func samples(beats: [Double], start: Double, count: Int, rate: Double, gain: Double = 1200,
                               tWave: (amplitude: Double, delay: Double) = (0.3, 0.25),
                               noise: Double = 0, wander: Double = 0.06, seed: UInt64 = 1) -> [Double] {
        // (offset from the R peak in s, amplitude, width in s)
        let waves: [(Double, Double, Double)] = [
            (-0.20, 0.12, 0.025),               // P
            (-0.03, -0.15, 0.008),              // Q
            (0.00, 1.00, 0.010),                // R
            (0.03, -0.25, 0.010),               // S
            (tWave.delay, tWave.amplitude, 0.05), // T
        ]
        var rng = SeededRandom(seed: seed)
        return (0..<count).map { i in
            let t = start + Double(i) / rate
            var v = wander * sin(2 * Double.pi * 0.3 * t)
            for b in beats where abs(t - b) < 0.6 {
                for (offset, amplitude, width) in waves {
                    let z = (t - b - offset) / width
                    v += amplitude * exp(-0.5 * z * z)
                }
            }
            if noise > 0 { v += noise * rng.gaussian() }
            return v * gain
        }
    }
}
