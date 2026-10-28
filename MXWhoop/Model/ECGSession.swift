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
@Observable
final class ECGSession {
    enum Phase: Equatable {
        case idle
        case starting
        case recording
        case failed(String)

        var isActive: Bool { self == .starting || self == .recording }
    }

    private(set) var phase: Phase = .idle
    /// Recent filtered samples in native units (oldest first), up to ~12 s.
    private(set) var samples: [Double] = []
    /// Estimated from arrival times; the strap does not document it.
    private(set) var sampleRate: Double?
    private(set) var heartRate: Double?
    private(set) var rrIntervals: [Double] = []
    private(set) var quality: UInt8?
    private(set) var presence = false
    private(set) var progress: UInt8?
    private(set) var strapHRValue: UInt8?
    private(set) var recordsReceived = 0
    private(set) var startedAt: Date?
    private(set) var lastRecordAt: Date?

    var wrist: CommandBody.Wrist {
        didSet { UserDefaults.standard.set(Int(wrist.rawValue), forKey: Self.wristKey) }
    }
    var maxDuration: Double = 60

    @ObservationIgnored var send: ((CommandBody.Request) -> Void)?
    @ObservationIgnored var log: ((String) -> Void)?
    @ObservationIgnored var recorder: Recorder?
    @ObservationIgnored private var firstRecordAt: Date?
    @ObservationIgnored private var samplesSinceFirst = 0
    @ObservationIgnored private var firstRecordCount = 0

    private static let wristKey = "ecgWrist"
    private static let cleanupKey = "ecgCleanupPending"
    static let bufferSeconds: Double = 12

    init() {
        let stored = UserDefaults.standard.integer(forKey: Self.wristKey)
        wrist = CommandBody.Wrist(rawValue: UInt8(clamping: stored)) ?? .left
    }

    var elapsed: TimeInterval { startedAt.map { Date().timeIntervalSince($0) } ?? 0 }

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
        phase = .idle
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

    func handle(_ r: CommandResponse) {
        guard phase == .starting || phase == .recording, let result = r.result,
              result == .failure || result == .unsupported else { return }
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
        if phase == .starting { phase = .recording }
        recordsReceived += 1
        lastRecordAt = now
        quality = r.quality
        presence = r.presence
        progress = r.progress
        strapHRValue = r.strapHRValue

        if firstRecordAt == nil {
            firstRecordAt = now
            firstRecordCount = r.samples.count
        } else {
            samplesSinceFirst += r.samples.count
            if let first = firstRecordAt, now.timeIntervalSince(first) >= 3 {
                sampleRate = (Double(samplesSinceFirst) / now.timeIntervalSince(first)).rounded()
            }
        }
        let values = r.samples.map { Double($0) }
        let capacity = Int((sampleRate ?? 250) * Self.bufferSeconds)
        samples = Array((samples + values).suffix(capacity))
        recorder?.ecg(values, sampleRate: sampleRate ?? Double(firstRecordCount))
    }

    /// Once per second.
    func tick() {
        guard phase.isActive else { return }
        if elapsed >= maxDuration { stop(); return }
        guard let fs = sampleRate, samples.count >= Int(fs * 4) else { return }
        let window = Array(samples.suffix(Int(fs * 8)))
        let peaks = ECGAnalyzer.rPeaks(window, sampleRate: fs)
        let rr = ECGAnalyzer.rrIntervals(peaks: peaks, sampleRate: fs).filter { (300...2000).contains($0) }
        rrIntervals = rr
        heartRate = rr.count >= 2 ? Stats.median(rr).map { 60_000 / $0 } : nil
    }

    // MARK: Private

    private func sendStopSequence() {
        send?(CommandBody.ecgGeneration(false))
        send?(CommandBody.ecgLiveFiltered(false))
        UserDefaults.standard.set(false, forKey: Self.cleanupKey)
    }

    private func resetSignal() {
        samples = []; sampleRate = nil; heartRate = nil; rrIntervals = []
        quality = nil; presence = false; progress = nil; strapHRValue = nil
        recordsReceived = 0; lastRecordAt = nil
        firstRecordAt = nil; samplesSinceFirst = 0; firstRecordCount = 0
    }
}
