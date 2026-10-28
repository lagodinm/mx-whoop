import Foundation

/// Beat detection on a single-lead ECG of unknown polarity and scale (the MG's filtered
/// stream is in native units and its sample rate is undocumented).
public enum ECGAnalyzer {
    /// R-peak sample indices (Pan–Tompkins): zero-phase 5–15 Hz band-pass, slope energy
    /// over a 150 ms window, adaptive signal/noise thresholds, T-wave rejection (a candidate
    /// within 360 ms of a beat with less than half its slope) and search-back after a long
    /// gap. Each beat is placed on the largest band-passed deflection, whichever way the
    /// lead points.
    ///
    /// `expectedRR` (seconds, e.g. from the strap's PPG heart rate) widens the refractory
    /// period to 55 % of it, between 0.2 and 0.6 s, which suppresses tall T waves and noise.
    public static func rPeaks(_ x: [Double], sampleRate fs: Double, expectedRR: Double? = nil) -> [Int] {
        let n = x.count
        guard fs >= 40, n >= Int(fs * 2) else { return [] }
        let y = bandpass(x, sampleRate: fs)

        var slope = [Double](repeating: 0, count: n)
        for i in 4..<n {
            let a: Double = 2 * y[i] + y[i - 1]
            let b: Double = y[i - 3] + 2 * y[i - 4]
            slope[i] = (a - b) / 8
        }
        let w = max(1, Int(0.15 * fs))
        var energy = [Double](repeating: 0, count: n)
        var running = 0.0
        for i in 0..<n {
            running += slope[i] * slope[i]
            if i >= w { running -= slope[i - w] * slope[i - w] }
            energy[i] = running / Double(w)
        }

        var refractory = Int(0.2 * fs)
        if let rr = expectedRR, rr > 0 { refractory = Int(Stats.clamp(0.55 * rr, 0.2, 0.6) * fs) }
        let tWindow = Int(0.36 * fs)
        let learn = Array(energy.prefix(Int(2 * fs)))
        var signalLevel = 0.25 * (learn.max() ?? 0)
        var noiseLevel = 0.5 * (Stats.mean(learn) ?? 0)
        var threshold = noiseLevel + 0.25 * (signalLevel - noiseLevel)
        guard signalLevel > 0 else { return [] }

        func maxSlope(_ p: Int) -> Double {
            var m = 0.0
            for j in max(0, p - w)...p { m = max(m, abs(slope[j])) }
            return m
        }

        var qrs: [Int] = []
        var qrsSlopes: [Double] = []
        var intervals: [Int] = []
        var rejected: [Int] = []
        for p in 1..<(n - 1) where energy[p] >= energy[p - 1] && energy[p] > energy[p + 1] {
            if let last = qrs.last, p - last < refractory { continue }
            if energy[p] > threshold {
                if let last = qrs.last, let lastSlope = qrsSlopes.last, p - last < tWindow, maxSlope(p) < 0.5 * lastSlope {
                    noiseLevel = 0.125 * energy[p] + 0.875 * noiseLevel   // a T wave
                    rejected.append(p)
                } else {
                    if let last = qrs.last {
                        // Search back for a beat missed in a long gap.
                        let recent = intervals.suffix(8)
                        if !recent.isEmpty {
                            let average = Double(recent.reduce(0, +)) / Double(recent.count)
                            if Double(p - last) > 1.66 * average {
                                let missed = rejected.filter {
                                    $0 >= last + refractory && $0 <= p - refractory && energy[$0] > 0.5 * threshold
                                }
                                if let m = missed.max(by: { energy[$0] < energy[$1] }) {
                                    intervals.append(m - last)
                                    qrs.append(m)
                                    qrsSlopes.append(maxSlope(m))
                                }
                            }
                        }
                        intervals.append(p - (qrs.last ?? last))
                    }
                    qrs.append(p)
                    qrsSlopes.append(maxSlope(p))
                    signalLevel = 0.125 * energy[p] + 0.875 * signalLevel
                }
            } else {
                noiseLevel = 0.125 * energy[p] + 0.875 * noiseLevel
                rejected.append(p)
            }
            threshold = noiseLevel + 0.25 * (signalLevel - noiseLevel)
        }

        // The energy peak trails the QRS; place each beat on the largest deflection.
        var peaks: [Int] = []
        let back = w + Int(0.05 * fs)
        for p in qrs {
            var best = max(0, p - back)
            for j in best...p where abs(y[j]) > abs(y[best]) { best = j }
            if let last = peaks.last, best - last < refractory {
                if abs(y[best]) > abs(y[last]) { peaks[peaks.count - 1] = best }
            } else {
                peaks.append(best)
            }
        }
        return peaks
    }

    /// Beat-to-beat intervals (ms) between consecutive peaks.
    public static func rrIntervals(peaks: [Int], sampleRate fs: Double) -> [Double] {
        guard peaks.count >= 2 else { return [] }
        return (1..<peaks.count).map { Double(peaks[$0] - peaks[$0 - 1]) * 1000 / fs }
    }

    /// Zero-phase 5–15 Hz band-pass: second-order Butterworth high- and low-pass sections run
    /// forward and backward over an odd-reflected signal (like `filtfilt`).
    public static func bandpass(_ x: [Double], sampleRate fs: Double) -> [Double] {
        let n = x.count
        guard n > 3 else { return x }
        let pad = min(n - 1, Int(fs * 0.5))
        var padded: [Double] = []
        padded.reserveCapacity(n + 2 * pad)
        for k in stride(from: pad, through: 1, by: -1) { padded.append(2 * x[0] - x[k]) }
        padded += x
        for k in 1...max(pad, 1) where pad > 0 { padded.append(2 * x[n - 1] - x[n - 1 - k]) }
        let hp = Biquad.highPass(5, sampleRate: fs)
        let lp = Biquad.lowPass(min(15, 0.4 * fs), sampleRate: fs)
        var y = lp.run(hp.run(padded))
        y = lp.run(hp.run(y.reversed())).reversed()
        return Array(y[pad..<(pad + n)])
    }
}

/// RBJ-cookbook second-order section.
struct Biquad {
    let b0, b1, b2, a1, a2: Double

    static func lowPass(_ f0: Double, sampleRate fs: Double, q: Double = 0.7071) -> Biquad {
        let w = 2 * Double.pi * f0 / fs
        let c = cos(w), alpha = sin(w) / (2 * q), a0 = 1 + alpha
        return Biquad(b0: (1 - c) / 2 / a0, b1: (1 - c) / a0, b2: (1 - c) / 2 / a0, a1: -2 * c / a0, a2: (1 - alpha) / a0)
    }

    static func highPass(_ f0: Double, sampleRate fs: Double, q: Double = 0.7071) -> Biquad {
        let w = 2 * Double.pi * f0 / fs
        let c = cos(w), alpha = sin(w) / (2 * q), a0 = 1 + alpha
        return Biquad(b0: (1 + c) / 2 / a0, b1: -(1 + c) / a0, b2: (1 + c) / 2 / a0, a1: -2 * c / a0, a2: (1 - alpha) / a0)
    }

    func run<S: Sequence>(_ x: S) -> [Double] where S.Element == Double {
        var out: [Double] = []
        var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
        for v in x {
            let a: Double = b0 * v + b1 * x1 + b2 * x2
            let o: Double = a - a1 * y1 - a2 * y2
            x2 = x1; x1 = v; y2 = y1; y1 = o
            out.append(o)
        }
        return out
    }
}

/// Estimates the ECG sample rate, which the strap does not document.
///
/// Arrival times alone are misleading: the strap buffers up to 250 filtered values and
/// delivers them in a burst when output starts, so "samples ÷ elapsed time" reads far too
/// high for the first tens of seconds (and inflates heart rate with it). This fits a line
/// through (time, cumulative samples), using the record's own strap clock when it looks
/// like one and ignoring the startup burst, then snaps to a standard rate when close.
public struct ECGRateEstimator: Sendable {
    public enum Source: String, Sendable { case strapClock = "strap clock", arrival = "arrival times" }

    private var points: [(arrival: Double, strap: Double?, cumulative: Int)] = []
    private var total = 0
    public static let standardRates: [Double] = [50, 64, 100, 125, 128, 200, 250, 256, 500, 512]

    public init() {}

    /// Call once per record: when it arrived, its strap time (if decodable) and its sample count.
    public mutating func add(arrival: Double, strapTime: Double?, samples: Int) {
        points.append((arrival, strapTime, total))
        total += samples
    }

    public var estimate: (rate: Double, source: Source)? {
        if let r = fit(useStrapClock: true) { return (r, .strapClock) }
        if let r = fit(useStrapClock: false) { return (r, .arrival) }
        return nil
    }

    private func fit(useStrapClock: Bool) -> Double? {
        guard let first = points.first else { return nil }
        let skip = useStrapClock ? 0.0 : 1.5 // the startup burst
        var xs: [Double] = [], ys: [Double] = []
        for p in points {
            if useStrapClock {
                guard let s = p.strap else { return nil }
                xs.append(s)
            } else {
                guard p.arrival - first.arrival >= skip else { continue }
                xs.append(p.arrival)
            }
            ys.append(Double(p.cumulative))
        }
        guard xs.count >= 4, let x0 = xs.first, let x1 = xs.last, x1 - x0 >= (useStrapClock ? 2 : 4) else { return nil }
        let mx = xs.reduce(0, +) / Double(xs.count), my = ys.reduce(0, +) / Double(ys.count)
        var num = 0.0, den = 0.0
        for (x, y) in zip(xs, ys) { num += (x - mx) * (y - my); den += (x - mx) * (x - mx) }
        guard den > 0 else { return nil }
        let rate = num / den
        guard rate > 20, rate < 2000 else { return nil }
        if let snap = Self.standardRates.min(by: { abs($0 - rate) < abs($1 - rate) }), abs(snap - rate) / snap < 0.04 {
            return snap
        }
        return rate
    }
}
