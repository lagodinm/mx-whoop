import XCTest
@testable import WhoopKit

final class HRVTests: XCTestCase {
    func testTimeDomainMetrics() {
        let rr: [Double] = [800, 810, 790, 820, 800, 805, 795]
        let m = HRV.metrics(rr)!
        // diffs 10, -20, 30, -20, 5, -10 → squares sum to 1925 → RMSSD = sqrt(1925/6)
        XCTAssertEqual(m.rmssd, (1925.0 / 6).squareRoot(), accuracy: 1e-9)
        XCTAssertEqual(m.meanRR, 802.857, accuracy: 0.001)
        XCTAssertEqual(m.pnn50, 0)
    }

    func testArtifactDoesNotFabricateLargeDifferences() {
        let rr: [Double] = [800, 805, 810, 400, 805, 800, 810, 805]
        let m = HRV.metrics(rr)!
        XCTAssertLessThan(m.rmssd, 15)
        XCTAssertEqual(m.artifactRate, 1.0 / 8, accuracy: 1e-9)
    }

    func testRespirationFromSinusArrhythmia() {
        var sim = PhysiologySimulator(restingHR: 62, seed: 7)
        sim.breathingRate = 12
        var beats: [TimedValue] = []
        for _ in 0..<64 { beats += sim.nextSecond().beats }
        let rate = HRV.respirationRate(beats)
        XCTAssertNotNil(rate)
        XCTAssertEqual(rate ?? 0, 12, accuracy: 1.5)
    }
}

final class MotionTests: XCTestCase {
    func testTremorRisesWithArousal() {
        var sim = PhysiologySimulator(seed: 3)
        let calm = sim.nextSecond()
        sim.ask(at: sim.time, deceptive: true)
        sim.ask(at: sim.time, deceptive: true)
        for _ in 0..<3 { _ = sim.nextSecond() }
        let tense = sim.nextSecond()
        let a = MotionAnalyzer.summarize(accel: calm.accel, gyro: calm.gyro)!
        let b = MotionAnalyzer.summarize(accel: tense.accel, gyro: tense.gyro)!
        XCTAssertGreaterThan(b.tremor, a.tremor * 2)
        XCTAssertEqual(Double(a.gravity.z), 0.95, accuracy: 0.01)
    }
}

final class LieDetectorTests: XCTestCase {
    /// Feeds simulator output into a timeline exactly like the app's SensorHub does.
    struct Rig {
        var sim: PhysiologySimulator
        var tl = PhysioTimeline()
        init(seed: UInt64) { sim = PhysiologySimulator(restingHR: 60 + Double(seed % 20), seed: seed) }

        mutating func advance(_ seconds: Int) {
            for _ in 0..<seconds {
                let s = sim.nextSecond()
                let arrival = s.start + 1
                tl.heartRate.append(TimedValue(t: arrival, v: Double(s.bpm)))
                tl.beats += s.beats
                if let m = MotionAnalyzer.summarize(accel: s.accel, gyro: s.gyro) {
                    tl.movement.append(TimedValue(t: arrival, v: m.movement))
                    tl.tremor.append(TimedValue(t: arrival, v: m.tremor))
                }
                tl.pulseAmplitude.append(TimedValue(t: arrival, v: (s.optical.max() ?? 0) - (s.optical.min() ?? 0)))
            }
        }

        mutating func question(deceptive: Bool) -> ResponseFeatures {
            advance(10)
            let t0 = sim.time
            sim.ask(at: t0, deceptive: deceptive)
            advance(16)
            return LieDetector.features(from: tl, questionAt: t0)
        }
    }

    func testCalibratedModelSeparatesTruthFromLies() {
        var correct = 0, total = 0
        var pLie: [Double] = [], pTruth: [Double] = []
        for seed in UInt64(1)...6 {
            var rig = Rig(seed: seed)
            rig.advance(60)
            var model = LieModel(noise: LieDetector.noiseProfile(from: rig.tl, restFrom: 0, to: 60))
            for _ in 0..<3 {
                model.truths.append(rig.question(deceptive: false))
                model.lies.append(rig.question(deceptive: true))
            }
            XCTAssertEqual(model.tier, .calibrated)
            var coin = SeededRandom(seed: seed &* 31)
            for _ in 0..<10 {
                let deceptive = coin.uniform() < 0.5
                let v = model.verdict(for: rig.question(deceptive: deceptive))
                XCTAssertNotEqual(v.kind, .inconclusive)
                total += 1
                if (v.kind == .lie) == deceptive { correct += 1 }
                if deceptive { pLie.append(v.lieProbability) } else { pTruth.append(v.lieProbability) }
            }
        }
        let accuracy = Double(correct) / Double(total)
        XCTAssertGreaterThan(accuracy, 0.7, "accuracy \(accuracy)")
        XCTAssertGreaterThan(Stats.mean(pLie)! - Stats.mean(pTruth)!, 0.3)
    }

    func testRestOnlyIsNotParanoid() {
        // With no question asked, the baseline-only model should mostly say "truth".
        var rig = Rig(seed: 11)
        rig.advance(60)
        let model = LieModel(noise: LieDetector.noiseProfile(from: rig.tl, restFrom: 0, to: 60))
        rig.advance(60)
        var lies = 0
        for k in 0..<15 { // pseudo-questions whose windows stay inside the recorded 60–120 s
            let f = LieDetector.features(from: rig.tl, questionAt: 72 + Double(k) * 2)
            if model.verdict(for: f).kind == .lie { lies += 1 }
        }
        XCTAssertLessThan(lies, 4)
    }

    func testMissingDataIsInconclusive() {
        let model = LieModel(noise: NoiseProfile(stats: [:]))
        XCTAssertEqual(model.verdict(for: ResponseFeatures()).kind, .inconclusive)
    }
}
