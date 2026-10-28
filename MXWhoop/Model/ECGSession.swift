import Foundation
import Observation
import WhoopKit

/// Experimental live ECG on WHOOP MG (the clasp is the second electrode).
///
/// Sequence from noop `PROTOCOL_ECG.md`, payloads from the official app's command builders:
/// select wrist → enable live filtered output → start generation; to finish, stop generation
/// and disable the output. Start is not idempotent, so it is never resent on reconnect;
/// instead a "cleanup pending" flag makes the next connection send the stop sequence if
/// the app was closed mid-recording.
///
/// Like the official app, a session first **calibrates** (front end settles, sample rate is
/// established, beats become regular and agree with the strap's optical heart rate), then
/// **records** for 30 s and ends with a summary.
@Observable
final class ECGSession {
    enum Phase: Equatable {
        case idle
        case starting
        case calibrating
        case recording
        case finished
        case failed(String)

        var isActive: Bool { self == .starting || self == .calibrating || self == .recording }
    }

    struct Summary: Equatable {
        let date: Date
        let duration: Double
        let beats: Int
        let averageHR: Double
        let minHR: Double
        let maxHR: Double
        let rmssd: Double?
        let sdnn: Double?
        let ppgHR: Double?
        let strapHRValue: Double?
        let sampleRate: Double
        let rateSource: String
        let classifierResult: UInt8?
        let classifierState: UInt8?
    }

    private(set) var phase: Phase = .idle
    /// Recent filtered samples in native units (oldest first), up to ~12 s.
    private(set) var samples: [Double] = []
    /// Samples received this session; `samples.last` is sample number `totalSamples − 1`.
    private(set) var totalSamples = 0
    /// Absolute sample numbers of the R peaks found in the latest analysis window.
    private(set) var peakPositions: [Int] = []
    private(set) var sampleRate: Double?
    private(set) var rateSource: String?
    private(set) var heartRate: Double?
    private(set) var rrIntervals: [Double] = []
    /// 0…1 while calibrating.
    private(set) var calibration: Double = 0
    private(set) var calibrationHint: String?
    private(set) var quality: UInt8?
    private(set) var presence = false
    private(set) var progress: UInt8?
    private(set) var strapHRValue: UInt8?
    private(set) var classifierResult: UInt8?
    private(set) var classifierState: UInt8?
    private(set) var recordsReceived = 0
    private(set) var startedAt: Date?
    private(set) var recordingStartedAt: Date?
    private(set) var lastSummary: Summary?

    /// The strap's own optical heart rate, fed by the hub once per second.
    var ppgHeartRate: Double?
    var wrist: CommandBody.Wrist {
        didSet { UserDefaults.standard.set(Int(wrist.rawValue), forKey: Self.wristKey) }
    }
    let recordingDuration: Double = 30
    static let maxSessionLength: Double = 90

    @ObservationIgnored var send: ((CommandBody.Request) -> Void)?
    @ObservationIgnored var log: ((String) -> Void)?
    @ObservationIgnored var recorder: Recorder?
    @ObservationIgnored private var estimator = ECGRateEstimator()
    @ObservationIgnored private var firstSignalAt: Date?
    @ObservationIgnored private var lastCountedPeak: Int?
    @ObservationIgnored private var sessionRR: [Double] = []
    @ObservationIgnored private var strapHRs: [Double] = []

    private static let wristKey = "ecgWrist"
    private static let cleanupKey = "ecgCleanupPending"
    private static let rateKey = "ecgSampleRate"
    static let bufferSeconds: Double = 12

    init() {
        let stored = UserDefaults.standard.integer(forKey: Self.wristKey)
        wrist = CommandBody.Wrist(rawValue: UInt8(clamping: stored)) ?? .left
    }

    var elapsed: TimeInterval { startedAt.map { Date().timeIntervalSince($0) } ?? 0 }
    var recordingElapsed: TimeInterval { recordingStartedAt.map { Date().timeIntervalSince($0) } ?? 0 }

    // MARK: Control

    func start() {
        guard !phase.isActive else { return }
        resetSignal()
        phase = .starting
        startedAt = Date()
        UserDefaults.standard.set(true, forKey: Self.cleanupKey)
        send?(CommandBody.selectWrist(wrist))
        send?(CommandBody.ecgLiveFiltered(true))
        send?(CommandBody.ecgGeneration(true))
        log?("ECG: start requested (\(wrist.name.lowercased()) wrist)")
    }

    func stop() {
        guard phase.isActive else { return }
        sendStopSequence()
        if phase == .recording, recordingElapsed >= 10 {
            finish()
        } else {
            phase = .idle
        }
        log?("ECG: stopped after \(Int(elapsed)) s, \(recordsReceived) records")
    }

    // MARK: Hub callbacks

    /// On every new connection: finish a session an earlier run left behind.
    func sessionStarted() {
        guard UserDefaults.standard.bool(forKey: Self.cleanupKey) else { return }
        log?("ECG: a previous session was not closed — sending the stop sequence")
        sendStopSequence()
    }

    func linkLost() {
        // The flag stays set, so the next connection cleans up.
        if phase.isActive { phase = .failed("Connection lost during the recording.") }
    }

    /// Only responses to this app's own commands are passed in.
    func handle(_ r: CommandResponse) {
        guard phase.isActive, let result = r.result, result == .failure || result == .unsupported else { return }
        let ecgCommands: [UInt8] = [WhoopCommand.selectWrist.rawValue, WhoopCommand.toggleECGGeneration.rawValue,
                                    WhoopCommand.toggleECGFiltered.rawValue]
        guard ecgCommands.contains(r.command) else { return }
        sendStopSequence()
        let hint = result == .unsupported ? " This strap doesn't support ECG (it needs a WHOOP MG)." : ""
        phase = .failed("The strap refused \(r.commandName) (result \(r.resultRaw)).\(hint)")
    }

    func ingest(_ r: ECGRecord) {
        guard r.isLive, r.isFiltered, phase.isActive else { return }
        let now = Date()
        if phase == .starting { phase = .calibrating }
        recordsReceived += 1
        quality = r.quality
        presence = r.presence
        progress = r.progress
        strapHRValue = r.strapHRValue
        classifierResult = r.classifierResult
        classifierState = r.classifierState
        if phase == .recording, r.strapHRValue > 0 { strapHRs.append(Double(r.strapHRValue)) }

        estimator.add(arrival: now.timeIntervalSinceReferenceDate, strapTime: strapClock(r, now: now), samples: r.samples.count)
        if let e = estimator.estimate {
            sampleRate = e.rate
            rateSource = e.source.rawValue
        } else if sampleRate == nil, let learned = UserDefaults.standard.object(forKey: Self.rateKey) as? Double {
            sampleRate = learned
            rateSource = "learned earlier"
        }

        let values = r.samples.map { Double($0) }
        if firstSignalAt == nil, values.contains(where: { $0 != 0 }) { firstSignalAt = now }
        totalSamples += values.count
        let capacity = Int((sampleRate ?? 128) * Self.bufferSeconds)
        samples = Array((samples + values).suffix(capacity))
        recorder?.ecg(values, sampleRate: sampleRate ?? 128)
    }

    /// Once per second.
    func tick() {
        guard phase.isActive else { return }
        if elapsed >= Self.maxSessionLength {
            sendStopSequence()
            if phase == .recording { finish() } else {
                phase = .failed("No clean ECG within \(Int(Self.maxSessionLength)) s. Keep the finger still on the clasp, without pressing hard.")
            }
            return
        }
        analyze()
        switch phase {
        case .calibrating: updateCalibration()
        case .recording:
            if recordingElapsed >= recordingDuration {
                sendStopSequence()
                finish()
            }
        default: break
        }
    }

    // MARK: Analysis

    private func analyze() {
        guard let fs = sampleRate, samples.count >= Int(fs * 3) else { return }
        let window = Array(samples.suffix(Int(fs * 8)))
        let windowStart = totalSamples - window.count
        let expected = ppgHeartRate.map { 60 / $0 }
        let peaks = ECGAnalyzer.rPeaks(window, sampleRate: fs, expectedRR: expected).map { $0 + windowStart }
        peakPositions = peaks
        let rr = ECGAnalyzer.rrIntervals(peaks: peaks, sampleRate: fs).filter { (300...2000).contains($0) }
        rrIntervals = rr
        heartRate = rr.count >= 3 ? Stats.median(rr).map { 60_000 / $0 } : nil

        guard phase == .recording else { return }
        // Count each interval once across overlapping windows. Peaks in the last 0.5 s can
        // still move, and a re-detected beat may shift by a sample or two.
        let tolerance = max(2, Int(fs * 0.02))
        for (a, b) in zip(peaks, peaks.dropFirst()) where b < totalSamples - Int(fs * 0.5) {
            if let last = lastCountedPeak, b <= last + tolerance { continue }
            // If the window lost the beat we counted last, (a, b) spans a gap: skip it.
            let contiguous = lastCountedPeak.map { abs(a - $0) <= tolerance || a > $0 } ?? true
            if contiguous {
                let interval = Double(b - a) * 1000 / fs
                if (300...2000).contains(interval) { sessionRR.append(interval) }
            }
            lastCountedPeak = b
        }
    }

    private func updateCalibration() {
        let now = Date()
        guard let signalStart = firstSignalAt else {
            calibration = 0
            calibrationHint = recordsReceived == 0 ? "Waiting for the strap…" : "Touch the clasp with a fingertip of your other hand."
            return
        }
        let settle = min(1, now.timeIntervalSince(signalStart) / 6)
        let regular: Bool = {
            guard rrIntervals.count >= 4, let mean = Stats.mean(rrIntervals), let sd = Stats.std(rrIntervals) else { return false }
            return sd / mean < 0.2
        }()
        let agrees: Bool = {
            guard let ecg = heartRate else { return false }
            guard let ppg = ppgHeartRate else { return true }
            return abs(ecg - ppg) / ppg < 0.2
        }()
        let rateKnown = sampleRate != nil
        calibration = 0.5 * settle + (rateKnown ? 0.2 : 0) + (regular ? 0.15 : 0) + (agrees ? 0.15 : 0)
        if !rateKnown {
            calibrationHint = "Measuring the strap's sample rate…"
        } else if !presence && now.timeIntervalSince(signalStart) > 8 {
            calibrationHint = "The strap doesn't detect contact yet. Rest a fingertip on the clasp."
        } else if !regular {
            calibrationHint = "Hold still; waiting for a steady rhythm…"
        } else if !agrees {
            calibrationHint = "ECG and optical heart rate disagree. Keep still for a few seconds…"
        } else {
            calibrationHint = nil
        }
        if settle >= 1, rateKnown, regular, agrees {
            phase = .recording
            recordingStartedAt = now
            calibration = 1
            lastCountedPeak = peakPositions.last
            log?("ECG: calibrated at \(Int(sampleRate ?? 0)) Hz (\(rateSource ?? "?")) — recording \(Int(recordingDuration)) s")
        }
    }

    private func finish() {
        let fs = sampleRate ?? 0
        let hrs = sessionRR.map { 60_000 / $0 }
        let metrics = HRV.metrics(sessionRR)
        if let mean = Stats.mean(hrs), let lo = hrs.min(), let hi = hrs.max() {
            lastSummary = Summary(date: Date(), duration: recordingElapsed, beats: sessionRR.count + 1,
                                  averageHR: metrics?.meanHR ?? mean, minHR: lo, maxHR: hi,
                                  rmssd: metrics?.rmssd, sdnn: metrics?.sdnn, ppgHR: ppgHeartRate,
                                  strapHRValue: Stats.median(strapHRs), sampleRate: fs, rateSource: rateSource ?? "?",
                                  classifierResult: classifierResult, classifierState: classifierState)
        }
        // Remember a measured rate so the next session can start from it.
        if let source = rateSource, source != "learned earlier", fs > 0 {
            UserDefaults.standard.set(fs, forKey: Self.rateKey)
        }
        phase = .finished
    }

    /// The record's timestamp, when its first word is plausibly Unix seconds (±2 days of now).
    private func strapClock(_ r: ECGRecord, now: Date) -> Double? {
        let main = Double(r.timestampMain)
        guard abs(main - now.timeIntervalSince1970) < 172_800 else { return nil }
        return main + Double(r.timestampExtra) / 32768
    }

    private func sendStopSequence() {
        send?(CommandBody.ecgGeneration(false))
        send?(CommandBody.ecgLiveFiltered(false))
        UserDefaults.standard.set(false, forKey: Self.cleanupKey)
    }

    private func resetSignal() {
        samples = []; totalSamples = 0; peakPositions = []
        sampleRate = nil; rateSource = nil; heartRate = nil; rrIntervals = []
        calibration = 0; calibrationHint = nil
        quality = nil; presence = false; progress = nil; strapHRValue = nil
        classifierResult = nil; classifierState = nil
        recordsReceived = 0; recordingStartedAt = nil
        estimator = ECGRateEstimator()
        firstSignalAt = nil; lastCountedPeak = nil; sessionRR = []; strapHRs = []
    }
}
