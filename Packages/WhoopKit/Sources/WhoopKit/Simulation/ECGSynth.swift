import Foundation

/// A synthetic single-lead ECG: a P-QRS-T template (sum of Gaussians, McSharry-style)
/// placed at each beat, plus slow baseline wander. Deterministic, so it never disturbs
/// the simulator's random sequence.
public enum ECGSynth {
    /// (offset from the R peak in s, amplitude, width in s)
    private static let waves: [(Double, Double, Double)] = [
        (-0.20, 0.12, 0.025),  // P
        (-0.03, -0.15, 0.008), // Q
        (0.00, 1.00, 0.010),   // R
        (0.03, -0.25, 0.010),  // S
        (0.25, 0.30, 0.050),   // T
    ]

    /// `count` samples starting at `start`, at `rate` Hz, for R peaks at `beats` (same time base).
    /// Amplitude is in arbitrary native units (R ≈ `gain`).
    public static func samples(beats: [Double], start: Double, count: Int, rate: Double,
                               gain: Double = 1200) -> [Double] {
        (0..<count).map { i in
            let t = start + Double(i) / rate
            var v = 0.06 * sin(2 * Double.pi * 0.3 * t)
            for b in beats where abs(t - b) < 0.5 {
                for (offset, amplitude, width) in waves {
                    let z = (t - b - offset) / width
                    v += amplitude * exp(-0.5 * z * z)
                }
            }
            return v * gain
        }
    }
}
