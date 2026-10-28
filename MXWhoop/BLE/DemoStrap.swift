import Foundation
import WhoopKit

/// A virtual WHOOP MG for the Simulator and for trying the app without a strap.
///
/// It encodes simulated physiology into real WHOOP 5/MG frames, chops them into
/// BLE-sized notifications and pushes them through a `FrameAssembler`, so the demo
/// exercises exactly the same parsing path as a real strap. It also plays the part of the
/// official WHOOP app: stored one-second summaries are "synced" every few minutes, or
/// every 61 s after a high-frequency-sync prompt, just as they would pass over a shared link.
final class DemoStrap: StrapLink {
    var onEvent: ((LinkEvent) -> Void)?

    private var sim: PhysiologySimulator
    private var timer: Timer?
    private var assembler = FrameAssembler()
    private var sequencer = CommandSequencer()
    private var realtimeHR = false
    private var imu = false
    private var optical = false
    private var ticks = 0

    // Strap memory: summaries not yet "synced by the WHOOP app".
    private var unsynced: [(time: UInt32, frame: WhoopFrame)] = []
    private var recordIndex: UInt32 = 1_593_000
    private var trimPage: UInt32 = 116_400
    private var steps: UInt16 = 4_210
    private var highFreqSync = false
    private var nextPrompt = Date.distantFuture

    // ECG
    private var ecgLive = false
    private var ecgGenerating = false
    private var ecgStartedAt = Date()
    private var ecgSequence: UInt32 = 0
    private var recentBeats: [Double] = []

    init() {
        sim = PhysiologySimulator(start: Date().timeIntervalSinceReferenceDate,
                                  restingHR: Double.random(in: 58...72), seed: UInt64.random(in: 1...UInt64.max))
    }

    /// Lie-detector demo hook: the virtual wearer reacts to a question asked now.
    func ask(deceptive: Bool) {
        sim.ask(at: sim.time, deceptive: deceptive)
    }

    func connect() {
        emit(.peripheral(name: "WHOOP MG (demo)"))
        emit(.state(.connecting("WHOOP MG (demo)")))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            self.emit(.state(.handshaking))
            self.send(CommandBody.hello)
            self.emit(.deviceInfo(key: "Model", value: "MG"))
            self.emit(.deviceInfo(key: "Firmware", value: "50.42.1.0 (simulated)"))
            self.emit(.battery(87))
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                self.emit(.state(.streaming))
                self.sim = PhysiologySimulator(start: Date().timeIntervalSinceReferenceDate,
                                               restingHR: self.sim.restingHR, seed: UInt64.random(in: 1...UInt64.max))
                self.seedMemory()
                self.timer?.invalidate()
                self.timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
            }
        }
    }

    func disconnect() {
        timer?.invalidate()
        timer = nil
        realtimeHR = false; imu = false; optical = false
        highFreqSync = false; nextPrompt = .distantFuture
        ecgLive = false; ecgGenerating = false
        emit(.state(.idle))
    }

    func send(_ request: CommandBody.Request) {
        let (seq, frame) = sequencer.frame(request)
        emit(.commandSent(label: request.label, seq: seq, frame: frame))
        let on = request.params.count >= 2 ? request.params[1] == 1 : request.params.first == 1
        var body: [UInt8] = [0x01]
        var pendingFirst = false
        var then: (() -> Void)?
        switch WhoopCommand(rawValue: request.command) {
        case .toggleRealtimeHR: realtimeHR = request.params.first == 1
        case .toggleIMUMode: imu = on
        case .toggleOpticalMode: optical = on
        case .getHello: body = helloBody()
        case .getBatteryLevel: body = UInt32(87).littleEndianBytesForDemo
        case .runHapticPatternMaverick: emit(.log("Demo strap: bzzz"))
        case .getDataRange:
            pendingFirst = true
            body = dataRangeBody()
        case .sendHistoricalData:
            then = { [weak self] in self?.servePeek() }
        case .enterHighFreqSync:
            if !highFreqSync {
                highFreqSync = true
                nextPrompt = Date().addingTimeInterval(Double(BiometricsMonitor.fastSyncInterval))
                then = { [weak self] in self?.deliverEvent(StrapEvent.highFreqSyncEnabled) }
            }
        case .exitHighFreqSync:
            if highFreqSync {
                highFreqSync = false
                nextPrompt = .distantFuture
                then = { [weak self] in self?.deliverEvent(StrapEvent.highFreqSyncDisabled) }
            }
        case .toggleECGFiltered:
            ecgLive = on
        case .toggleECGGeneration:
            let start = request.params.count >= 2 && request.params[1] >= 2
            if start && !ecgGenerating { ecgStartedAt = Date() }
            ecgGenerating = start
        default:
            break
        }
        if pendingFirst {
            let pending = SyntheticFrames.commandResponse(command: request.command, originSeq: seq, result: .pending, body: [])
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in self?.deliver(pending, .command) }
        }
        let reply = SyntheticFrames.commandResponse(command: request.command, originSeq: seq, result: .success, body: body)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            self?.deliver(reply, .command)
            then?()
        }
    }

    private func tick() {
        let s = sim.nextSecond()
        ticks += 1
        let unix = Date().timeIntervalSince1970
        if realtimeHR {
            deliver(SyntheticFrames.realtimeHR(time: UInt32(unix), bpm: s.bpm, rrMs: s.beats.map(\.v)), .data)
        }
        if imu {
            deliver(SyntheticFrames.imuR21(time: unix - 1, accel: s.accel, gyro: s.gyro), .data)
        }
        if optical {
            deliver(SyntheticFrames.opticalR26(time: UInt32(unix), samples: s.optical), .data)
        }
        if ticks % 60 == 0 {
            deliver(SyntheticFrames.event(3, time: UInt32(unix)), .event)
        }
        store(s, unix: UInt32(unix))
        recentBeats = (recentBeats + s.beats.map(\.t)).filter { $0 > s.start - 5 }
        if ecgGenerating && ecgLive { deliverECG(s, unix: UInt32(unix)) }

        // The "WHOOP app": syncs on each fast-sync prompt, otherwise every five minutes.
        if highFreqSync, Date() >= nextPrompt {
            nextPrompt = Date().addingTimeInterval(Double(BiometricsMonitor.fastSyncInterval))
            deliverEvent(StrapEvent.highFreqSyncPrompt)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.whoopAppSync() }
        } else if ticks == 8 || (!highFreqSync && ticks % 300 == 0) {
            whoopAppSync()
        }
    }

    // MARK: Strap memory

    /// Fills the last ten minutes, as if the WHOOP app last synced a while ago.
    private func seedMemory() {
        unsynced.removeAll()
        let now = Date().timeIntervalSince1970
        for back in stride(from: 600, to: 0, by: -1) {
            let t = now - Double(back)
            recordIndex += 1
            let temp = sim.skinTemperature(at: Date(timeIntervalSince1970: t).timeIntervalSinceReferenceDate)
            let f = SyntheticFrames.biometricR18(index: recordIndex, time: UInt32(t), bpm: Int(sim.restingHR), rrMs: [],
                                                 skinTempC: temp, steps: steps)
            unsynced.append((UInt32(t), f))
        }
    }

    private func store(_ s: PhysiologySimulator.Second, unix: UInt32) {
        recordIndex += 1
        if ticks % 40 < 4 { steps &+= 2 } // a few steps now and then
        let f = SyntheticFrames.biometricR18(index: recordIndex, time: unix, bpm: s.bpm, rrMs: s.beats.map(\.v),
                                             skinTempC: sim.skinTemperature(at: s.start), steps: steps,
                                             activity: ticks % 40 < 4 ? 1 : 0, bandState: 0,
                                             gravity: s.accel.first ?? SIMD3(0.05, -0.30, 0.95))
        unsynced.append((unix, f))
        if unsynced.count > 7200 { unsynced.removeFirst(unsynced.count - 7200) }
    }

    /// What passes over the shared link while the official app syncs (it acknowledges, so
    /// the records leave strap memory).
    private func whoopAppSync() {
        guard !unsynced.isEmpty else { return }
        let now = UInt32(Date().timeIntervalSince1970)
        deliver(SyntheticFrames.historyMarker(.start, time: now), .data)
        for item in unsynced { deliver(item.frame, .data) }
        trimPage &+= pages(unsynced.count)
        deliver(SyntheticFrames.historyMarker(.end, time: now, trimCursor: trimPage), .data)
        deliver(SyntheticFrames.historyMarker(.complete, time: now), .data)
        unsynced.removeAll()
    }

    /// SEND_HISTORICAL_DATA without an acknowledgement: the first chunk, then END; nothing is released.
    private func servePeek() {
        let now = UInt32(Date().timeIntervalSince1970)
        deliver(SyntheticFrames.historyMarker(.start, time: now), .data)
        for item in unsynced.prefix(30) { deliver(item.frame, .data) }
        deliver(SyntheticFrames.historyMarker(.end, time: now, trimCursor: trimPage &+ 1), .data)
    }

    private func dataRangeBody() -> [UInt8] {
        let now = UInt32(Date().timeIntervalSince1970)
        let write = trimPage &+ pages(unsynced.count)
        return SyntheticFrames.dataRangeBody(read: trimPage, write: write, trim: trimPage,
                                             estimate: UInt32(unsynced.count),
                                             oldest: unsynced.first?.time ?? now, newest: unsynced.last?.time ?? now)
    }

    private func pages(_ records: Int) -> UInt32 { UInt32((records + 29) / 30) }

    // MARK: ECG

    private func deliverECG(_ s: PhysiologySimulator.Second, unix: UInt32) {
        let elapsed = Date().timeIntervalSince(ecgStartedAt)
        let settled = elapsed > 2.5
        // One second behind, so every beat in the window is already known.
        let values = ECGSynth.samples(beats: recentBeats, start: s.start - 1, count: 100, rate: 100)
        let samples: [Int16] = settled ? values.map { Int16(clamping: Int($0.rounded())) } : Array(repeating: 0, count: 100)
        ecgSequence += 1
        let progress = UInt8(min(100, elapsed / 30 * 100))
        deliver(SyntheticFrames.ecgR17(sequence: ecgSequence, time: unix, samples: samples, quality: settled ? 3 : 0,
                                       presence: settled, progress: progress, hr: UInt8(clamping: s.bpm)), .data)
    }

    // MARK: Plumbing

    private func deliverEvent(_ number: UInt8) {
        deliver(SyntheticFrames.event(number, time: UInt32(Date().timeIntervalSince1970)), .event)
    }

    /// Splits the frame into notification-sized chunks and reassembles it, like a real link.
    private func deliver(_ frame: WhoopFrame, _ channel: LinkChannel) {
        for chunk in SyntheticFrames.chunks(frame) {
            for out in assembler.append(chunk) {
                if case .frame(let f) = out { emit(.frame(f, channel)) }
            }
        }
    }

    private func helloBody() -> [UInt8] {
        var b = [UInt8](repeating: 0, count: 107)
        b[0] = 1
        let battery = UInt32(873).littleEndianBytesForDemo
        b.replaceSubrange(1..<5, with: battery)
        let now = UInt32(Date().timeIntervalSince1970).littleEndianBytesForDemo
        b.replaceSubrange(6..<10, with: now)
        b[91] = 50; b[92] = 42; b[93] = 1
        return b
    }

    private func emit(_ e: LinkEvent) { onEvent?(e) }
}

private extension UInt32 {
    var littleEndianBytesForDemo: [UInt8] { withUnsafeBytes(of: littleEndian, Array.init) }
}
