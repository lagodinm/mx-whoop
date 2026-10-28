import Foundation

/// Beat detection on a single-lead ECG of unknown polarity and scale (the MG's filtered
/// stream is in native units and its sample rate is undocumented).
public enum ECGAnalyzer {
    /// R-peak sample indices: slope energy (Pan–Tompkins style), a ~80 ms integration
    /// window, an adaptive threshold and a 280 ms refractory period; each detection is then
    /// moved to the largest deflection nearby, whichever way the lead points.
    public static func rPeaks(_ x: [Double], sampleRate fs: Double) -> [Int] {
        let n = x.count
        guard fs >= 40, n >= Int(fs * 2) else { return [] }
        var energy = [Double](repeating: 0, count: n)
        for i in 1..<(n - 1) {
            let d = x[i + 1] - x[i - 1]
            energy[i] = d * d
        }
        let w = max(1, Int(0.08 * fs))
        var integrated = [Double](repeating: 0, count: n)
        var running = 0.0
        for i in 0..<n {
            running += energy[i]
            if i >= w { running -= energy[i - w] }
            integrated[i] = running / Double(w)
        }
        let sorted = integrated.sorted()
        let high = sorted[min(n - 1, Int(Double(n) * 0.98))]
        guard high > 0 else { return [] }
        let threshold = 0.3 * high
        let refractory = Int(0.28 * fs)
        let search = max(1, Int(0.08 * fs))
        let baseline = Stats.median(x) ?? 0

        var peaks: [Int] = []
        var i = 1
        while i < n - 1 {
            guard integrated[i] > threshold, integrated[i] >= integrated[i - 1], integrated[i] >= integrated[i + 1] else {
                i += 1
                continue
            }
            // The integrated energy peaks just after the QRS; look back for the R wave itself.
            let lo = max(0, i - w - search), hi = min(n - 1, i + search)
            var best = lo
            for j in lo...hi where abs(x[j] - baseline) > abs(x[best] - baseline) { best = j }
            if let last = peaks.last, best - last < refractory {
                if abs(x[best] - baseline) > abs(x[last] - baseline) { peaks[peaks.count - 1] = best }
            } else {
                peaks.append(best)
            }
            i += max(1, refractory / 2)
        }
        return peaks
    }

    /// Beat-to-beat intervals (ms) between consecutive peaks.
    public static func rrIntervals(peaks: [Int], sampleRate fs: Double) -> [Double] {
        guard peaks.count >= 2 else { return [] }
        return (1..<peaks.count).map { Double(peaks[$0] - peaks[$0 - 1]) * 1000 / fs }
    }
}
