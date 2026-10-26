import Foundation
import Observation
import WhoopKit

/// One point of the decimated accelerometer preview.
struct AccelPoint: Identifiable {
    let id: Int
    let date: Date
    let x: Double, y: Double, z: Double
}

/// One line of the Raw tab.
struct RawEntry: Identifiable {
    enum Kind: String, CaseIterable { case hr = "HR", imu = "IMU", event = "Events", command = "Cmd", other = "Other" }
    let id: Int
    let date: Date
    let channel: String
    let title: String
    let summary: String
    let bytes: [UInt8]
    let kind: Kind
    let outgoing: Bool
    let isError: Bool
}

/// The app's single source of truth: owns the strap link, decodes frames, keeps the
/// rolling physiological timeline and derives live analytics once per second.
/// Everything runs on the main thread (CoreBluetooth is created with `queue: .main`).
@Observable
final class SensorHub {
    enum Source { case strap, demo }
    enum HRSource: String { case whoop = "WHOOP live stream", standard = "BLE heart-rate profile" }

    // Connection
    private(set) var source: Source = .strap
    private(set) var linkState: LinkState = .idle
    private(set) var deviceName: String?
    private(set) var deviceInfo: [String: String] = [:]
    private(set) var firmware: String?
    private(set) var battery: Int?
    private(set) var onWrist: Bool?
    private(set) var connectionLog: [String] = []
    var variant: WhoopVariant {
        WhoopVariant.resolve(model: deviceInfo["Model"], serial: deviceInfo["Serial"], hardwareRevision: deviceInfo["Hardware"])
    }
    var isDemo: Bool { source == .demo && linkState.isConnected }

    // Live values
    private(set) var heartRate: Int?
    private(set) var heartRateSource: HRSource?
    private(set) var lastRR: Double?
    private(set) var hrv: HRVMetrics?
    private(set) var respirationRate: Double?
    private(set) var motion: MotionSummary?
    private(set) var arousal: Double?
    private(set) var accelPreview: [AccelPoint] = []
    private(set) var opticalPreview: [Double] = []
    private(set) var timeline = PhysioTimeline()

    // Streams & settings
    private(set) var imuEnabled = false
    private(set) var opticalEnabled = false
    var buzzOnLie = true

    // Raw
    private(set) var rawLog: [RawEntry] = []
    private(set) var packetCounts: [String: Int] = [:]
    private(set) var framesReceived = 0
    private(set) var bytesReceived = 0
    private(set) var corruptFrames = 0
    private(set) var lastEvent: StrapEvent?
    var rawPaused = false

    let recorder = Recorder()

    /// Rest-noise profile from the lie detector's baseline; sharpens the live arousal gauge.
    @ObservationIgnored var noiseProfile: NoiseProfile?

    @ObservationIgnored private var link: StrapLink?
    /// Created on first Connect, so the Bluetooth permission prompt appears only when needed.
    @ObservationIgnored private var ble: WhoopBLEClient?
    @ObservationIgnored private var demo: DemoStrap?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var lastHRAt: Double = 0
    @ObservationIgnored private var lastWhoopHRAt: Double = 0
    @ObservationIgnored private var lastRealtimeArm: Double = 0
    @ObservationIgnored private var rawCounter = 0
    @ObservationIgnored private var accelCounter = 0

    static let timelineSpan: Double = 15 * 60
    static let rawLogLimit = 400

    init() {
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
    }

    var now: Double { Date().timeIntervalSinceReferenceDate }

    /// True when heart rate has arrived within the last few seconds.
    var hasLiveHeartRate: Bool { heartRate != nil && now - lastHRAt < 4 }

    // MARK: Connection control

    func connectStrap() {
        let client = ble ?? WhoopBLEClient()
        ble = client
        switchLink(to: client, source: .strap)
        client.connect()
    }

    func startDemo() {
        let d = DemoStrap()
        demo = d
        switchLink(to: d, source: .demo)
        d.connect()
    }

    func disconnect() {
        if linkState == .streaming {
            if imuEnabled || opticalEnabled { send(CommandBody.rawData(false)) }
            if imuEnabled { send(CommandBody.imuStream(false)) }
            if opticalEnabled { send(CommandBody.opticalStream(false)) }
            send(CommandBody.realtimeHR(false))
        }
        let current = link
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { current?.disconnect() }
        heartRate = nil
    }

    private func switchLink(to newLink: StrapLink, source: Source) {
        if let link, link !== newLink { link.onEvent = nil; link.disconnect() }
        link = newLink
        self.source = source
        deviceInfo = [:]; firmware = nil; battery = nil; onWrist = nil; deviceName = nil
        heartRate = nil; hrv = nil; motion = nil; accelPreview = []; opticalPreview = []
        timeline = PhysioTimeline()
        newLink.onEvent = { [weak self] event in self?.handle(event) }
    }

    func send(_ request: CommandBody.Request) { link?.send(request) }

    func buzz(pulses: Int = 1) { send(CommandBody.buzz(pulses: pulses)) }

    /// Lie-detector demo hook.
    func demoAsk(deceptive: Bool) { demo?.ask(deceptive: deceptive) }

    /// Raw 100 Hz IMU. START_RAW_DATA must precede the IMU transport toggle on 5/MG.
    func setIMU(_ on: Bool) {
        guard on != imuEnabled else { return }
        imuEnabled = on
        guard linkState == .streaming else { return }
        if on {
            send(CommandBody.rawData(true)); send(CommandBody.imuStream(true))
        } else {
            if !opticalEnabled { send(CommandBody.rawData(false)) }
            send(CommandBody.imuStream(false))
            motion = nil; accelPreview = []
        }
    }

    /// Live optical transport (experimental on 5/MG).
    func setOptical(_ on: Bool) {
        guard on != opticalEnabled else { return }
        opticalEnabled = on
        guard linkState == .streaming else { return }
        if on {
            send(CommandBody.rawData(true)); send(CommandBody.opticalStream(true))
        } else {
            if !imuEnabled { send(CommandBody.rawData(false)) }
            send(CommandBody.opticalStream(false))
            opticalPreview = []
        }
    }

    // MARK: Event handling

    private func handle(_ event: LinkEvent) {
        switch event {
        case .state(let s):
            let previous = linkState
            linkState = s
            if s != previous { addLog(s.label) }
            if s == .streaming && previous != .streaming { sessionStarted() }
            if !s.isConnected { heartRate = nil }
        case .frame(let f, let ch):
            handleFrame(f, channel: ch)
        case .corruptFrame(let raw, let why, let ch):
            corruptFrames += 1
            addRaw(channel: ch.rawValue, title: "CORRUPT", summary: "\(why) · \(raw.count) B", bytes: raw,
                   kind: .other, outgoing: false, isError: true)
        case .standardHR(let m):
            count("2A37 HEART_RATE")
            // The WHOOP stream is authoritative whenever it is flowing.
            if now - lastWhoopHRAt > 3 { ingestHeartRate(bpm: m.bpm, rr: m.rrIntervalsMs, source: .standard) }
        case .battery(let b):
            battery = b
        case .deviceInfo(let key, let value):
            deviceInfo[key] = value
            if key == "Firmware", firmware == nil { firmware = value }
        case .peripheral(let name):
            deviceName = name
        case .commandSent(let label, let seq, let frame):
            addRaw(channel: "→", title: label, summary: "seq \(seq) · \(frame.count) B", bytes: frame.bytes,
                   kind: .command, outgoing: true, isError: false)
            recorder.log(frame: frame, channel: "TX")
        case .log(let line):
            addLog(line)
        }
    }

    private func sessionStarted() {
        send(CommandBody.realtimeHR(true))
        lastRealtimeArm = now
        lastWhoopHRAt = now // give the stream a grace period before the watchdog re-arms
        if imuEnabled { send(CommandBody.rawData(true)); send(CommandBody.imuStream(true)) }
        if opticalEnabled { send(CommandBody.rawData(true)); send(CommandBody.opticalStream(true)) }
    }

    private func handleFrame(_ f: WhoopFrame, channel: LinkChannel) {
        framesReceived += 1
        bytesReceived += f.count
        recorder.log(frame: f, channel: channel.rawValue)
        let message = WhoopParser.parse(f)
        let (title, summary, kind) = describe(message, frame: f)
        count(title)

        switch message {
        case .realtimeHR(let hr):
            lastWhoopHRAt = now
            if let worn = hr.onWrist { onWrist = worn }
            ingestHeartRate(bpm: hr.bpm, rr: hr.rrIntervalsMs, source: .whoop)
        case .imu(let batch):
            ingestIMU(batch)
        case .optical(let window):
            ingestOptical(window)
        case .commandResponse(let r):
            if let hello = WhoopParser.hello(r) {
                firmware = hello.firmware
                if hello.batteryPercent > 0 { battery = Int(hello.batteryPercent.rounded()) }
            }
            if let b = WhoopParser.batteryPercent(r) { battery = b }
        case .event(let e):
            lastEvent = e
            if e.number == StrapEvent.wristOn { onWrist = true }
            if e.number == StrapEvent.wristOff { onWrist = false }
            recorder.event(e.name)
        case .consoleLog, .metadata, .other:
            break
        }
        addRaw(channel: channel.rawValue, title: title, summary: summary, bytes: f.bytes,
               kind: kind, outgoing: false, isError: false)
    }

    private func ingestHeartRate(bpm: Int, rr: [Double], source: HRSource) {
        let t = now
        if bpm > 0 {
            heartRate = bpm
            heartRateSource = source
            lastHRAt = t
            timeline.heartRate.append(TimedValue(t: t, v: Double(bpm)))
            recorder.heartRate(bpm, source: source.rawValue)
        }
        guard !rr.isEmpty else { return }
        // The newest interval ends now; walk backwards to stamp earlier beats.
        var beatTime = t
        var stamped: [TimedValue] = []
        for interval in rr.reversed() {
            stamped.append(TimedValue(t: beatTime, v: interval))
            beatTime -= interval / 1000
        }
        let lastBeat = timeline.beats.last?.t ?? -.infinity
        for beat in stamped.reversed() where beat.t > lastBeat + 0.2 {
            timeline.beats.append(beat)
            recorder.rr(beat.v)
        }
        lastRR = rr.last
    }

    private func ingestIMU(_ batch: IMUBatch) {
        let t = now
        if let m = MotionAnalyzer.summarize(accel: batch.accel, gyro: batch.gyro) {
            motion = m
            timeline.movement.append(TimedValue(t: t, v: m.movement))
            timeline.tremor.append(TimedValue(t: t, v: m.tremor))
        }
        let start = Date().addingTimeInterval(-Double(batch.accel.count) / IMUBatch.sampleRate)
        var points = accelPreview
        for i in stride(from: 0, to: batch.accel.count, by: 4) {
            let a = batch.accel[i]
            accelCounter += 1
            points.append(AccelPoint(id: accelCounter, date: start.addingTimeInterval(Double(i) / IMUBatch.sampleRate),
                                     x: Double(a.x), y: Double(a.y), z: Double(a.z)))
        }
        accelPreview = Array(points.suffix(100))
        recorder.imu(batch)
    }

    private func ingestOptical(_ window: OpticalWindow) {
        guard let hi = window.samples.max(), let lo = window.samples.min() else { return }
        timeline.pulseAmplitude.append(TimedValue(t: now, v: hi - lo))
        opticalPreview = Array((opticalPreview + window.samples).suffix(150))
        recorder.optical(window.samples)
    }

    /// Once per second: trim history, recompute HRV / breathing / arousal, run the watchdog.
    private func tick() {
        let t = now
        timeline.trim(before: t - Self.timelineSpan)
        if !timeline.beats.isEmpty {
            hrv = HRV.metrics(timeline.beats.values(from: t - 60, to: t + 1))
            respirationRate = HRV.respirationRate(Array(timeline.beats.slice(from: t - 64, to: t + 1)))
        } else {
            hrv = nil; respirationRate = nil
        }
        arousal = LieDetector.liveArousal(timeline, now: t, noise: noiseProfile)
        if heartRate != nil, t - lastHRAt > 5 { heartRate = nil }
        // Live HR stopped (e.g. the WHOOP app turned it off): re-arm, at most every 10 s.
        if linkState == .streaming, t - lastWhoopHRAt > 10, t - lastRealtimeArm > 10 {
            lastRealtimeArm = t
            addLog("No live HR for 10 s — re-arming TOGGLE_REALTIME_HR")
            send(CommandBody.realtimeHR(true))
        }
    }

    // MARK: Raw log

    func clearRaw() {
        rawLog.removeAll(); packetCounts.removeAll()
        framesReceived = 0; bytesReceived = 0; corruptFrames = 0
    }

    private func count(_ key: String) { packetCounts[key, default: 0] += 1 }

    private func addRaw(channel: String, title: String, summary: String, bytes: [UInt8],
                        kind: RawEntry.Kind, outgoing: Bool, isError: Bool) {
        guard !rawPaused else { return }
        rawCounter += 1
        rawLog.insert(RawEntry(id: rawCounter, date: Date(), channel: channel, title: title, summary: summary,
                               bytes: bytes, kind: kind, outgoing: outgoing, isError: isError), at: 0)
        if rawLog.count > Self.rawLogLimit { rawLog.removeLast(rawLog.count - Self.rawLogLimit) }
    }

    private func addLog(_ line: String) {
        let stamp = Date().formatted(date: .omitted, time: .standard)
        connectionLog.insert("\(stamp)  \(line)", at: 0)
        if connectionLog.count > 80 { connectionLog.removeLast() }
    }

    private func describe(_ m: WhoopMessage, frame f: WhoopFrame) -> (String, String, RawEntry.Kind) {
        let typeName = f.packetType?.name ?? String(format: "TYPE 0x%02X", f.packetTypeRaw)
        switch m {
        case .realtimeHR(let hr):
            let rr = hr.rrIntervalsMs.isEmpty ? "no R-R" : "R-R " + hr.rrIntervalsMs.map { "\(Int($0))" }.joined(separator: ", ") + " ms"
            let worn = hr.onWrist.map { $0 ? " · worn" : " · off wrist" } ?? ""
            return ("REALTIME_DATA", "HR \(hr.bpm) bpm · \(rr)\(worn)", .hr)
        case .imu(let b):
            let g = b.accel.first.map { String(format: "%.2f %.2f %.2f g", $0.x, $0.y, $0.z) } ?? ""
            return ("R21 IMU", "\(b.accel.count) acc + \(b.gyro.count) gyro · \(g)", .imu)
        case .optical(let o):
            return ("R\(o.layout) OPTICAL", "\(o.samples.count) samples", .imu)
        case .commandResponse(let r):
            let result = r.result.map { "\($0)".uppercased() } ?? "result \(r.resultRaw)"
            return ("RESPONSE", "\(r.commandName) #\(r.originSeq) · \(result) · \(r.body.count) B", .command)
        case .event(let e):
            return ("EVENT", e.name, .event)
        case .consoleLog(let text):
            return ("CONSOLE", String(text.prefix(120)), .other)
        case .metadata(_, let kind):
            return ("METADATA", "\(typeName) kind \(kind)", .other)
        case .other(let type, let layout):
            let note = (layout == 16 || layout == 17) && type == PacketType.realtimeRawData.rawValue ? " (ECG)" : ""
            return (typeName, "layout \(layout)\(note) · \(f.count) B", .other)
        }
    }
}
