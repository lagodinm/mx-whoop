import Foundation

/// Deterministic SplitMix64 generator, so demo sessions and tests are reproducible.
public struct SeededRandom: RandomNumberGenerator, Sendable {
    private var state: UInt64
    public init(seed: UInt64) { state = seed }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    public mutating func uniform() -> Double { Double(next() >> 11) / Double(1 << 53) }

    /// Standard normal (Box–Muller).
    public mutating func gaussian() -> Double {
        let u = max(uniform(), 1e-12), v = uniform()
        return (-2 * log(u)).squareRoot() * cos(2 * .pi * v)
    }
}

/// A synthetic wearer: heart beats with respiratory sinus arrhythmia, a resting wrist
/// with physiological tremor, and a pulse wave — plus an "arousal" response whenever a
/// question is asked (bigger for deliberate lies). Used by Demo mode and tests.
public struct PhysiologySimulator: Sendable {
    public struct Second: Sendable {
        public let start: Double
        public let bpm: Int
        public let beats: [TimedValue]
        public let accel: [SIMD3<Float>]
        public let gyro: [SIMD3<Float>]
        /// 25 Hz pulse-wave samples (raw optical counts).
        public let optical: [Double]
    }

    public var restingHR: Double
    public var breathingRate: Double = 14 // breaths/min
    public private(set) var time: Double
    private var nextBeat: Double
    private var recentRR: [Double] = []
    private var rng: SeededRandom
    private var stimuli: [(t: Double, peak: Double)] = []
    private var pulsePhase = 0.0

    public init(start: Double = 0, restingHR: Double = 66, seed: UInt64 = 42) {
        self.time = start
        self.nextBeat = start
        self.restingHR = restingHR
        self.rng = SeededRandom(seed: seed)
    }

    /// Registers a question asked at `t`. A lie gets a large arousal response; telling
    /// the truth still gets a small one (speaking and being questioned are arousing).
    public mutating func ask(at t: Double, deceptive: Bool) {
        let peak = deceptive ? 0.8 + 0.25 * rng.gaussian() : 0.25 + 0.12 * rng.gaussian()
        stimuli.append((t, max(0.05, peak)))
    }

    /// 0…~1.5. Each stimulus: rises over ~3 s, decays over ~10 s.
    public func arousal(at t: Double) -> Double {
        stimuli.reduce(0) { sum, s in
            let x = t - s.t
            guard x > 0 else { return sum }
            return sum + s.peak * (1 - exp(-x / 2)) * exp(-x / 9) / 0.56
        }
    }

    private func isSpeaking(at t: Double) -> Bool {
        stimuli.contains { t - $0.t > 0.3 && t - $0.t < 3.5 }
    }

    public mutating func nextSecond() -> Second {
        let start = time, end = time + 1
        // Heart.
        var beats: [TimedValue] = []
        while nextBeat < end {
            let t = nextBeat
            let a = arousal(at: t)
            let hr = restingHR + 14 * a + 2 * sin(2 * .pi * 0.03 * t)
            let rsa = 45 * (1 - 0.6 * min(a, 1)) * sin(2 * .pi * breathingRate / 60 * t)
            let mayer = 15 * sin(2 * .pi * 0.1 * t + 1)
            let rr = Stats.clamp(60_000 / hr + rsa + mayer + 8 * rng.gaussian(), 350, 1800)
            beats.append(TimedValue(t: t, v: rr))
            recentRR.append(rr)
            if recentRR.count > 4 { recentRR.removeFirst() }
            nextBeat += rr / 1000
        }
        let bpm = Int((60_000 / (Stats.mean(recentRR) ?? 60_000 / restingHR)).rounded())

        // Wrist.
        let gravity = SIMD3<Float>(0.05, -0.30, 0.95)
        var accel: [SIMD3<Float>] = [], gyro: [SIMD3<Float>] = []
        accel.reserveCapacity(100); gyro.reserveCapacity(100)
        for i in 0..<100 {
            let t = start + Double(i) / 100
            let a = arousal(at: t)
            let tremorAmp = 0.002 + 0.006 * min(a, 1.5)
            let speech = isSpeaking(at: t) ? 0.012 : 0
            var v = gravity
            v.x += Float(tremorAmp * sin(2 * .pi * 9 * t) + (0.0025 + speech) * rng.gaussian())
            v.y += Float((0.0025 + speech) * rng.gaussian())
            v.z += Float((0.0025 + speech) * rng.gaussian())
            accel.append(v)
            let g = 0.4 + (speech > 0 ? 3 : 0)
            gyro.append(SIMD3(Float(g * rng.gaussian()), Float(g * rng.gaussian()), Float(g * rng.gaussian())))
        }

        // Pulse wave: amplitude shrinks with arousal (vasoconstriction).
        var optical: [Double] = []
        for i in 0..<25 {
            let t = start + Double(i) / 25
            let a = arousal(at: t)
            pulsePhase += Double(bpm) / 60 / 25
            let phase = pulsePhase.truncatingRemainder(dividingBy: 1)
            let shape = exp(-pow((phase - 0.2) / 0.08, 2)) + 0.35 * exp(-pow((phase - 0.5) / 0.1, 2))
            optical.append(120_000 + 2500 * (1 - 0.35 * min(a, 1.2)) * shape + 40 * rng.gaussian())
        }
        time = end
        return Second(start: start, bpm: bpm, beats: beats, accel: accel, gyro: gyro, optical: optical)
    }
}
