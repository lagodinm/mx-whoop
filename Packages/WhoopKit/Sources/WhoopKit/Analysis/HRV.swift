import Foundation

public struct HRVMetrics: Equatable, Sendable {
    public let beats: Int
    public let meanRR: Double      // ms
    public let meanHR: Double      // bpm, from R-R
    public let rmssd: Double       // ms — vagal (parasympathetic) tone
    public let sdnn: Double        // ms — overall variability
    public let pnn50: Double       // % of successive differences > 50 ms
    public let artifactRate: Double // fraction of rejected beats
}

public enum HRV {
    /// Marks implausible beats as nil: outside 300–2000 ms, or deviating more than
    /// 25 % from the median of the previous accepted beats (ectopics, missed detections).
    public static func clean(_ rr: [Double]) -> [Double?] {
        var out: [Double?] = []
        out.reserveCapacity(rr.count)
        var recent: [Double] = []
        for x in rr {
            guard (300...2000).contains(x) else { out.append(nil); continue }
            if recent.count >= 3, let med = Stats.median(recent), abs(x - med) > 0.25 * med {
                out.append(nil)
                continue
            }
            out.append(x)
            recent.append(x)
            if recent.count > 7 { recent.removeFirst() }
        }
        return out
    }

    /// Time-domain HRV. Successive differences only use beats that were adjacent in
    /// the original series, so a rejected beat never fabricates a large difference.
    public static func metrics(_ rr: [Double]) -> HRVMetrics? {
        let marked = clean(rr)
        let good = marked.compactMap { $0 }
        guard good.count >= 5, let meanRR = Stats.mean(good), let sdnn = Stats.std(good) else { return nil }
        var diffs: [Double] = []
        for i in 1..<marked.count {
            if let a = marked[i - 1], let b = marked[i] { diffs.append(b - a) }
        }
        guard diffs.count >= 3 else { return nil }
        let rmssd = (diffs.reduce(0) { $0 + $1 * $1 } / Double(diffs.count)).squareRoot()
        let pnn50 = 100 * Double(diffs.filter { abs($0) > 50 }.count) / Double(diffs.count)
        return HRVMetrics(beats: good.count, meanRR: meanRR, meanHR: 60_000 / meanRR, rmssd: rmssd,
                          sdnn: sdnn, pnn50: pnn50,
                          artifactRate: Double(marked.count - good.count) / Double(marked.count))
    }

    /// Breathing rate (breaths/min) from respiratory sinus arrhythmia: the R-R
    /// tachogram is resampled at 4 Hz and the dominant frequency in 0.1–0.5 Hz
    /// (6–30 breaths/min) is taken. Needs ~40 s of clean beats.
    public static func respirationRate(_ beats: [TimedValue]) -> Double? {
        let marks = HRV.clean(beats.map(\.v))
        let clean = beats.indices.filter { marks[$0] != nil }.map { beats[$0] }
        guard clean.count >= 30, let first = clean.first?.t, let last = clean.last?.t, last - first >= 40 else { return nil }
        let fs = 4.0
        let n = Int((last - first) * fs)
        var series = [Double](repeating: 0, count: n)
        var j = 0
        for i in 0..<n {
            let t = first + Double(i) / fs
            while j < clean.count - 2, clean[j + 1].t < t { j += 1 }
            let a = clean[j], b = clean[j + 1]
            let w = b.t > a.t ? Stats.clamp((t - a.t) / (b.t - a.t), 0, 1) : 0
            series[i] = a.v + (b.v - a.v) * w
        }
        let detrended = detrend(series)
        // Hann window, then a direct DFT scan of the respiratory band.
        let windowed = detrended.enumerated().map { i, x in x * (0.5 - 0.5 * cos(2 * .pi * Double(i) / Double(n - 1))) }
        var bestF = 0.0, bestP = 0.0
        var f = 0.1
        while f <= 0.5 {
            let p = power(windowed, frequency: f, sampleRate: fs)
            if p > bestP { bestP = p; bestF = f }
            f += 0.005
        }
        return bestP > 0 ? bestF * 60 : nil
    }

    /// Removes the least-squares line.
    static func detrend(_ x: [Double]) -> [Double] {
        let n = Double(x.count)
        guard x.count > 2 else { return x }
        let tMean = (n - 1) / 2
        let xMean = x.reduce(0, +) / n
        var num = 0.0, den = 0.0
        for (i, v) in x.enumerated() {
            let dt = Double(i) - tMean
            num += dt * (v - xMean); den += dt * dt
        }
        let slope = den > 0 ? num / den : 0
        return x.enumerated().map { i, v in v - xMean - slope * (Double(i) - tMean) }
    }

    /// |DFT|² at one frequency (Goertzel-equivalent), normalised by length.
    static func power(_ x: [Double], frequency f: Double, sampleRate fs: Double) -> Double {
        var re = 0.0, im = 0.0
        let w = 2 * Double.pi * f / fs
        for (i, v) in x.enumerated() {
            re += v * cos(w * Double(i)); im -= v * sin(w * Double(i))
        }
        return (re * re + im * im) / Double(x.count)
    }
}
