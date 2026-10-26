import Foundation

// A polygraph-style "lie detector" built from what a WHOOP strap can measure.
//
// What it really measures is *physiological arousal relative to your own truthful
// answers* — the same principle as a polygraph's Comparison Question Technique.
// Arousal is not deception (nerves, embarrassment or a hard question all look the
// same), so treat verdicts as entertainment, not evidence.
//
// Signals, per question (t0 = the moment the question has been asked):
//   pre-window      [t0 − 10 s, t0)         your settled state
//   response window [t0 + 0.5 s, t0 + 14 s) cardiac response peaks ~3–8 s after a stimulus
//
// Features (response minus pre-window):
//   hrPeak          peak heart-rate rise (bpm)                 — sympathetic arousal
//   hrMean          mean heart-rate rise (bpm)
//   rrShortening    max beat-interval shortening (%)            — cardio-acceleration
//   hrvSuppression  ln RMSSD(pre) − ln RMSSD(resp)              — vagal withdrawal
//   tremor          ln change of 4–12 Hz acceleration power     — muscle tension
//   movement        ln change of wrist movement                 — fidgeting or freezing
//   pulseAmplitude  PPG amplitude drop (%)                      — peripheral vasoconstriction (experimental)

public enum LieFeature: String, CaseIterable, Codable, Sendable {
    case hrPeak, hrMean, rrShortening, hrvSuppression, tremor, movement, pulseAmplitude

    public var title: String {
        switch self {
        case .hrPeak: "Heart-rate spike"
        case .hrMean: "Heart-rate rise"
        case .rrShortening: "Beat acceleration"
        case .hrvSuppression: "HRV drop"
        case .tremor: "Micro-tremor"
        case .movement: "Movement"
        case .pulseAmplitude: "Pulse amplitude drop"
        }
    }

    /// Expected direction/strength of a deceptive response, in noise-σ units.
    /// Used as the prior before (and alongside) personal calibration.
    var priorWeight: Double {
        switch self {
        case .hrPeak: 1.0
        case .hrMean: 0.6
        case .rrShortening: 0.8
        case .hrvSuppression: 0.5
        case .tremor: 0.4
        case .movement: 0.0      // people both fidget and freeze when lying; learn it per person
        case .pulseAmplitude: 0.8
        }
    }

    /// Smallest plausible noise σ, so a suspiciously calm baseline can't blow up z-scores.
    var noiseFloor: Double {
        switch self {
        case .hrPeak: 1.5
        case .hrMean: 1.0
        case .rrShortening: 2.0
        case .hrvSuppression: 0.2
        case .tremor: 0.25
        case .movement: 0.25
        case .pulseAmplitude: 4.0
        }
    }
}

/// All signals the detector reads, on one time base (seconds).
public struct PhysioTimeline: Sendable {
    public var heartRate: [TimedValue] = []      // bpm, ~1 Hz
    public var beats: [TimedValue] = []          // R-R ms, stamped at the beat
    public var movement: [TimedValue] = []       // g, 1 Hz (MotionSummary.movement)
    public var tremor: [TimedValue] = []         // mg², 1 Hz (MotionSummary.tremor)
    public var pulseAmplitude: [TimedValue] = [] // raw optical counts, ~1 Hz

    public init() {}

    public mutating func trim(before t: Double) {
        heartRate.trim(before: t); beats.trim(before: t); movement.trim(before: t)
        tremor.trim(before: t); pulseAmplitude.trim(before: t)
    }
}

public struct LieDetectorConfig: Codable, Equatable, Sendable {
    public var preWindow: Double = 10
    public var responseStart: Double = 0.5
    public var responseEnd: Double = 14
    /// Data arrive ~1 s late (1 Hz HR packets, 1 s IMU buffers); wait this much extra.
    public var dataLatency: Double = 2
    /// Minimum calm time after a response window before the next question.
    public var settleTime: Double = 8
    public var baselineDuration: Double = 60

    public init() {}
    public var evaluationDelay: Double { responseEnd + dataLatency }
}

public struct ResponseFeatures: Codable, Equatable, Sendable {
    public var values: [LieFeature: Double] = [:]
    public var hrSamplesPre = 0
    public var hrSamplesResponse = 0
    public var beatsResponse = 0

    public init() {}
    public var isUsable: Bool { hrSamplesPre >= 4 && hrSamplesResponse >= 6 }
    public subscript(_ f: LieFeature) -> Double? { values[f] }
}

public enum LieDetector {
    public static func features(from tl: PhysioTimeline, questionAt t0: Double,
                                config c: LieDetectorConfig = .init()) -> ResponseFeatures {
        let pre = (t0 - c.preWindow, t0)
        let resp = (t0 + c.responseStart, t0 + c.responseEnd)
        var f = ResponseFeatures()

        let hrPre = tl.heartRate.values(from: pre.0, to: pre.1).filter { $0 > 25 }
        let hrResp = tl.heartRate.values(from: resp.0, to: resp.1).filter { $0 > 25 }
        f.hrSamplesPre = hrPre.count
        f.hrSamplesResponse = hrResp.count
        if hrPre.count >= 3, hrResp.count >= 3, let base = Stats.mean(hrPre), let m = Stats.mean(hrResp) {
            f.values[.hrMean] = m - base
            f.values[.hrPeak] = (Stats.movingAverage(hrResp, window: 3).max() ?? m) - base
        }

        let rrPreRaw = tl.beats.values(from: pre.0, to: pre.1)
        let rrRespRaw = tl.beats.values(from: resp.0, to: resp.1)
        f.beatsResponse = rrRespRaw.count
        let rrPre = HRV.clean(rrPreRaw).compactMap { $0 }
        let rrResp = HRV.clean(rrRespRaw).compactMap { $0 }
        if rrPre.count >= 4, rrResp.count >= 4, let base = Stats.mean(rrPre),
           let fastest = Stats.movingAverage(rrResp, window: 3).min() {
            f.values[.rrShortening] = 100 * (base - fastest) / base
        }
        if let a = HRV.metrics(rrPreRaw), let b = HRV.metrics(rrRespRaw), a.rmssd > 1, b.rmssd > 1 {
            f.values[.hrvSuppression] = log(a.rmssd) - log(b.rmssd)
        }

        if let p = Stats.mean(tl.tremor.values(from: pre.0, to: pre.1)),
           let r = Stats.mean(tl.tremor.values(from: resp.0, to: resp.1)) {
            f.values[.tremor] = log((r + 0.05) / (p + 0.05))
        }
        if let p = Stats.mean(tl.movement.values(from: pre.0, to: pre.1)),
           let r = Stats.mean(tl.movement.values(from: resp.0, to: resp.1)) {
            f.values[.movement] = log((r + 0.003) / (p + 0.003))
        }
        let ampPre = tl.pulseAmplitude.values(from: pre.0, to: pre.1)
        let ampResp = tl.pulseAmplitude.values(from: resp.0, to: resp.1)
        if ampPre.count >= 3, ampResp.count >= 3, let p = Stats.mean(ampPre), let r = Stats.mean(ampResp), p > 0 {
            f.values[.pulseAmplitude] = 100 * (p - r) / p
        }
        return f
    }

    /// Null distribution of every feature: pseudo-questions slid across a rest period
    /// where nothing was asked. This is "how much your signals wobble on their own".
    public static func noiseProfile(from tl: PhysioTimeline, restFrom start: Double, to end: Double,
                                    config c: LieDetectorConfig = .init()) -> NoiseProfile {
        var samples: [LieFeature: [Double]] = [:]
        var t0 = start + c.preWindow
        while t0 + c.responseEnd <= end {
            let f = features(from: tl, questionAt: t0, config: c)
            for (k, v) in f.values { samples[k, default: []].append(v) }
            t0 += 1
        }
        var stats: [LieFeature: FeatureStats] = [:]
        for (k, xs) in samples where xs.count >= 5 {
            stats[k] = FeatureStats(mean: Stats.mean(xs) ?? 0, sd: Stats.std(xs) ?? k.noiseFloor)
        }
        return NoiseProfile(stats: stats)
    }

    /// 0–100 live arousal gauge: the last 6 s against the 10 s before.
    public static func liveArousal(_ tl: PhysioTimeline, now: Double, noise: NoiseProfile?) -> Double? {
        var c = LieDetectorConfig()
        c.responseStart = 0; c.responseEnd = 6
        let f = features(from: tl, questionAt: now - 6, config: c)
        guard f.hrSamplesPre >= 4, f.hrSamplesResponse >= 3 else { return nil }
        let noise = noise ?? NoiseProfile(stats: [:])
        var a = 0.0, norm = 0.0
        for k in [LieFeature.hrMean, .rrShortening, .tremor] {
            guard let x = f[k] else { continue }
            a += k.priorWeight * noise.z(x, k); norm += k.priorWeight * k.priorWeight
        }
        guard norm > 0 else { return nil }
        return 100 * Stats.sigmoid(1.2 * (a / norm.squareRoot() - 1))
    }
}

public struct FeatureStats: Codable, Equatable, Sendable {
    public var mean: Double
    public var sd: Double
}

public struct NoiseProfile: Codable, Equatable, Sendable {
    public var stats: [LieFeature: FeatureStats]

    /// z-score against rest noise, with a per-feature σ floor.
    public func z(_ x: Double, _ k: LieFeature) -> Double {
        let s = stats[k]
        return (x - (s?.mean ?? 0)) / max(s?.sd ?? k.noiseFloor, k.noiseFloor)
    }
}

public struct Verdict: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case truth, lie, inconclusive }
    public struct Contribution: Codable, Equatable, Sendable {
        public let feature: LieFeature
        /// Log-odds pushed towards "lie" (positive) or "truth" (negative).
        public let logOdds: Double
        public let rawValue: Double
    }

    public let kind: Kind
    public let lieProbability: Double
    public let contributions: [Contribution]
    public let notes: [String]
    public let tier: LieModel.Tier

    /// The percentage to show next to the verdict.
    public var confidencePercent: Int {
        switch kind {
        case .lie: Int((lieProbability * 100).rounded())
        case .truth: Int(((1 - lieProbability) * 100).rounded())
        case .inconclusive: 50
        }
    }
}

/// Personal model: rest noise + labelled calibration answers.
public struct LieModel: Codable, Equatable, Sendable {
    public enum Tier: String, Codable, Sendable {
        case baselineOnly   // rest period only — generic thresholds
        case truthOnly      // compares against your truthful answers
        case calibrated     // truthful AND deliberate-lie answers — personal discriminant
    }

    public var noise: NoiseProfile
    public var truths: [ResponseFeatures] = []
    public var lies: [ResponseFeatures] = []

    public init(noise: NoiseProfile) { self.noise = noise }

    public var tier: Tier {
        let t = truths.filter(\.isUsable).count, l = lies.filter(\.isUsable).count
        return t >= 2 && l >= 2 ? .calibrated : t >= 2 ? .truthOnly : .baselineOnly
    }

    /// Correlated features (three are heart-rate views) would otherwise make the
    /// naive sum overconfident.
    static let correlationTemper = 0.55
    static let probabilityRange = 0.03...0.97

    public func verdict(for f: ResponseFeatures) -> Verdict {
        guard f.isUsable else {
            return Verdict(kind: .inconclusive, lieProbability: 0.5, contributions: [],
                           notes: ["Not enough heart-rate data in this window. Check the strap fit and that live HR is streaming."],
                           tier: tier)
        }
        var notes: [String] = []
        var parts: [Verdict.Contribution] = []

        switch tier {
        case .calibrated:
            parts = discriminant(f)
        case .truthOnly, .baselineOnly:
            parts = weightedArousal(f)
        }

        var logOdds = parts.reduce(0) { $0 + $1.logOdds }
        if let m = f[.movement], noise.z(m, .movement) > 4 {
            notes.append("You moved a lot during the answer — keep your arm still for a cleaner reading.")
            logOdds *= 0.6
        }
        if f[.rrShortening] == nil {
            notes.append("No beat-to-beat (R-R) data in this window; using heart rate only.")
        }
        if tier == .baselineOnly {
            notes.append("Not calibrated: complete calibration for personal, more accurate results.")
        }
        let p = Stats.clamp(Stats.sigmoid(logOdds), Self.probabilityRange.lowerBound, Self.probabilityRange.upperBound)
        return Verdict(kind: p >= 0.5 ? .lie : .truth, lieProbability: p,
                       contributions: parts.sorted { abs($0.logOdds) > abs($1.logOdds) },
                       notes: notes, tier: tier)
    }

    /// Diagonal linear discriminant between your truthful and deliberate-lie answers,
    /// shrunk towards the population prior because calibration sets are tiny.
    private func discriminant(_ f: ResponseFeatures) -> [Verdict.Contribution] {
        let truthSet = truths.filter(\.isUsable), lieSet = lies.filter(\.isUsable)
        var out: [Verdict.Contribution] = []
        for k in LieFeature.allCases {
            guard let x = f[k] else { continue }
            let zt = truthSet.compactMap { $0[k] }.map { noise.z($0, k) }
            let zl = lieSet.compactMap { $0[k] }.map { noise.z($0, k) }
            guard zt.count >= 2, zl.count >= 2, let mt = Stats.mean(zt), let ml = Stats.mean(zl) else { continue }
            // Pooled within-class variance, with κ pseudo-observations of the rest noise (σ = 1 in z units).
            let kappa = 2.0
            let ssTruth: Double = zt.reduce(0) { $0 + ($1 - mt) * ($1 - mt) }
            let ssLie: Double = zl.reduce(0) { $0 + ($1 - ml) * ($1 - ml) }
            let ss = ssTruth + ssLie
            let s = max(((ss + kappa) / (Double(zt.count + zl.count - 2) + kappa)).squareRoot(), 0.5)
            let observed = Stats.clamp((ml - mt) / s, -3, 3)
            // Blend the personal effect size with the prior one.
            let n = Double(min(zt.count, zl.count)), priorStrength = 1.5
            let d = (n * observed + priorStrength * 1.5 * k.priorWeight) / (n + priorStrength)
            let z = noise.z(x, k)
            let contribution = Self.correlationTemper * d * (z - (mt + ml) / 2) / s
            out.append(.init(feature: k, logOdds: Stats.clamp(contribution, -3, 3), rawValue: x))
        }
        return out
    }

    /// Prior-weighted arousal score, centred on your truthful answers when available,
    /// otherwise on rest noise with a higher bar (talking alone raises heart rate).
    private func weightedArousal(_ f: ResponseFeatures) -> [Verdict.Contribution] {
        let truthSet = truths.filter(\.isUsable)
        let useTruth = tier == .truthOnly
        let slope = useTruth ? 2.0 : 1.5
        let threshold = useTruth ? 1.0 : 2.0
        var terms: [(LieFeature, Double, Double)] = []
        for k in LieFeature.allCases where k.priorWeight > 0 {
            guard let x = f[k] else { continue }
            var e = noise.z(x, k)
            if useTruth {
                let zt = truthSet.compactMap { $0[k] }.map { noise.z($0, k) }
                if zt.count >= 2, let mt = Stats.mean(zt) {
                    let ss = zt.reduce(0) { $0 + ($1 - mt) * ($1 - mt) }
                    let s = max(((ss + 2) / (Double(zt.count - 1) + 2)).squareRoot(), 0.7)
                    e = (e - mt) / s
                }
            }
            terms.append((k, e, x))
        }
        // logit = slope·(A − threshold) with A the weighted MEAN of the eₖ: the heart
        // features are strongly correlated, so a sum would count one reaction several
        // times. Splitting the threshold by weight makes the per-feature bars add up.
        let wSum = terms.reduce(0) { $0 + $1.0.priorWeight }
        guard wSum > 0 else { return [] }
        return terms.map { k, e, x in
            let lo = slope * k.priorWeight / wSum * (Stats.clamp(e, -4, 6) - threshold)
            return .init(feature: k, logOdds: lo, rawValue: x)
        }
    }
}
