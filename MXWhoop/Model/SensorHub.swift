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
    enum Kind: String, CaseIterable {
        case hr = "HR", imu = "IMU", body = "Body", event = "Evt", command = "Cmd", other = "Other"
    }
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
    private(set) var stressIndex: Double?
    private(set) var frequencyHRV: FrequencyHRV?

    // Effort (session totals since connect)
    var profile: EffortProfile = SensorHub.loadProfile() {
        didSet { UserDefaults.standard.set(try? JSONEncoder().encode(profile), forKey: Self.profileKey) }
    }
    private(set) var zone: Int?
    private(set) var percentOfMax: Double?
    private(set) var restingHR: Double?
    private(set) var sessionKcal: Double = 0
    private(set) var sessionStrain: Double = 0

    /// Skin temperature, steps and strap state from the strap's stored summary records.
    let biometrics = BiometricsMonitor()
    /// Experimental live ECG (WHOOP MG).
    let ecg = ECGSession()
    /// Read-only settings, alarms, battery pack, clock.
    let internals = StrapInternals()

    // The official app, seen from here: the strap's replies to *its* commands reach every
    // subscribed app, so we can tell when it syncs, acknowledges or uses a sensor.
    struct ForeignCommand: Identifiable {
        let id: Int
        let date: Date
        let name: String
        let result: String
    }
    private(set) var foreignLog: [ForeignCommand] = []
    private(set) var foreignCounts: [String: Int] = [:]
    private(set) var whoopAppLastSeen: Date?
    /// The WHOOP app holds a sensor session (raw, IMU/optical saving or ECG companion) that a
    /// STOP_RAW_DATA from us would clear.
    private(set) var whoopAppUsesSensors = false
    /// Reassembled firmware console lines, oldest first.
    private(set) var consoleLines: [String] = []
    var whoopAppPresent: Bool { whoopAppLastSeen != nil || biometrics.syncByOthersSeen }

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
    @ObservationIgnored private var tickCount = 0
    @ObservationIgnored private var sessionTrimp = 0.0
    @ObservationIgnored private var sentCommands: [(command: UInt8, seq: UInt8, at: Double)] = []
    @ObservationIgnored private var foreignCounter = 0
    @ObservationIgnored private var consolePartial = ""

    static let timelineSpan: Double = 15 * 60
    static let rawLogLimit = 400
    private static let profileKey = "effortProfile"

    init() {
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        biometrics.send = { [weak self] in self?.send($0) }
        biometrics.log = { [weak self] in self?.addLog($0) }
        biometrics.recorder = recorder
        ecg.send = { [weak self] in self?.send($0) }
        ecg.log = { [weak self] in self?.addLog($0) }
        ecg.recorder = recorder
        internals.send = { [weak self] in self?.send($0) }
    }

    private static func loadProfile() -> EffortProfile {
        guard let data = UserDefaults.standard.data(forKey: profileKey),
              let p = try? JSONDecoder().decode(EffortProfile.self, from: data) else { return EffortProfile() }
        return p
    }

    /// Foreground/background: fast sync only runs while the app is on screen.
    func setAppActive(_ active: Bool) { biometrics.setAppActive(active) }

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
            ecg.stop()
            biometrics.willDisconnect()
            if imuEnabled || opticalEnabled { stopRawCollectionIfOurs() }
            if imuEnabled { send(CommandBody.imuStream(false)) }
            if opticalEnabled { send(CommandBody.opticalStream(false)) }
            // Live HR is one switch shared by every app; leave it for the WHOOP app if it's around.
            if whoopAppPresent {
                addLog("Leaving live HR on: the WHOOP app is connected too")
            } else {
                send(CommandBody.realtimeHR(false))
            }
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
        stressIndex = nil; frequencyHRV = nil
        timeline = PhysioTimeline()
        resetEffort()
        biometrics.reset()
        internals.reset()
        foreignLog = []; foreignCounts = [:]; whoopAppLastSeen = nil; whoopAppUsesSensors = false
        sentCommands = []; consoleLines = []; consolePartial = ""
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
            if !opticalEnabled { stopRawCollectionIfOurs() }
            send(CommandBody.imuStream(false))
            motion = nil; accelPreview = []
        }
    }

    /// STOP_RAW_DATA clears *every* app's raw and per-sensor session requests on the strap
    /// (noop: "a later raw stop can clear collection requested earlier by another session
    /// control"). If the WHOOP app is using a sensor session (e.g. Strength Trainer), leave
    /// it running; our own request then just expires.
    private func stopRawCollectionIfOurs() {
        if whoopAppUsesSensors {
            addLog("Not sending STOP_RAW_DATA: the WHOOP app is using a sensor session")
        } else {
            send(CommandBody.rawData(false))
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
            if !imuEnabled { stopRawCollectionIfOurs() }
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
            if previous == .streaming && s != .streaming {
                biometrics.linkLost()
                ecg.linkLost()
            }
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
            sentCommands.append((frame.bytes[10], seq, now))
            if sentCommands.count > 96 { sentCommands.removeFirst(sentCommands.count - 96) }
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
        ecg.sessionStarted()
        biometrics.sessionStarted()
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
        case .biometric(let record):
            biometrics.ingest(record)
        case .ecg(let record):
            ecg.ingest(record)
        case .commandResponse(let r):
            if let hello = WhoopParser.hello(r) {
                firmware = hello.firmware
                if hello.batteryPercent > 0 { battery = Int(hello.batteryPercent.rounded()) }
            }
            if let b = WhoopParser.batteryPercent(r) { battery = b }
            let ours = isOurs(r)
            if !ours { noteForeign(r) }
            biometrics.handleResponse(r, ours: ours)
            internals.handle(r, ours: ours)
            if ours { ecg.handle(r) }
        case .consoleLog(let fragment):
            ingestConsole(fragment)
        case .event(let e):
            lastEvent = e
            if e.number == StrapEvent.wristOn { onWrist = true }
            if e.number == StrapEvent.wristOff { onWrist = false }
            biometrics.handleEvent(e)
            recorder.event(e.name)
        case .metadata(let type, let kind):
            if type == PacketType.metadata.rawValue || type == PacketType.puffinMetadata.rawValue {
                biometrics.handleMarker(kind)
            }
        case .other:
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
        tickCount += 1
        timeline.trim(before: t - Self.timelineSpan)
        if !timeline.beats.isEmpty {
            hrv = HRV.metrics(timeline.beats.values(from: t - 60, to: t + 1))
            respirationRate = HRV.respirationRate(Array(timeline.beats.slice(from: t - 64, to: t + 1)))
            stressIndex = HRV.stressIndex(timeline.beats.values(from: t - 120, to: t + 1))
            if tickCount % 5 == 0 {
                frequencyHRV = HRV.frequencyDomain(Array(timeline.beats.slice(from: t - 180, to: t + 1)))
            }
        } else {
            hrv = nil; respirationRate = nil; stressIndex = nil; frequencyHRV = nil
        }
        arousal = LieDetector.liveArousal(timeline, now: t, noise: noiseProfile)
        updateEffort(t)
        biometrics.whoopAppLastSeen = whoopAppLastSeen
        biometrics.tick()
        ecg.ppgHeartRate = hasLiveHeartRate ? heartRate.map { Double($0) } : nil
        ecg.tick()
        if heartRate != nil, t - lastHRAt > 5 { heartRate = nil }
        // Live HR stopped (e.g. the WHOOP app turned it off): re-arm, at most every 10 s.
        if linkState == .streaming, t - lastWhoopHRAt > 10, t - lastRealtimeArm > 10 {
            lastRealtimeArm = t
            addLog("No live HR for 10 s — re-arming TOGGLE_REALTIME_HR")
            send(CommandBody.realtimeHR(true))
        }
    }

    // MARK: The WHOOP app, observed

    /// A response answers our command when we sent that command number with that sequence
    /// number recently. Anything else answers another app on the same link.
    private func isOurs(_ r: CommandResponse) -> Bool {
        let t = now
        sentCommands.removeAll { t - $0.at > 30 }
        return sentCommands.contains { $0.command == r.command && $0.seq == r.originSeq }
    }

    private func noteForeign(_ r: CommandResponse) {
        guard r.result != .pending else { return }
        whoopAppLastSeen = Date()
        let name = r.commandName
        foreignCounts[name, default: 0] += 1
        foreignCounter += 1
        let result = r.result.map { "\($0)" } ?? "result \(r.resultRaw)"
        foreignLog.insert(ForeignCommand(id: foreignCounter, date: Date(), name: name, result: result), at: 0)
        if foreignLog.count > 150 { foreignLog.removeLast() }
        // Sensor sessions that a STOP_RAW_DATA from us would clear.
        switch WhoopCommandNumber(rawValue: r.command) {
        case .startRaw, .imuSaving, .opticalSaving, .ecgGeneration:
            if r.result == .success { whoopAppUsesSensors = true }
        case .stopRaw:
            whoopAppUsesSensors = false
        case nil:
            break
        }
    }

    private enum WhoopCommandNumber: UInt8 {
        case startRaw = 81, stopRaw = 82, imuSaving = 105, opticalSaving = 107, ecgGeneration = 124
    }

    private func ingestConsole(_ c: ConsoleFragment) {
        consolePartial += c.text
        var parts = consolePartial.components(separatedBy: "\n")
        consolePartial = parts.removeLast()
        if consolePartial.count > 600 { parts.append(consolePartial); consolePartial = "" }
        let lines = parts.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !lines.isEmpty else { return }
        consoleLines += lines
        if consoleLines.count > 400 { consoleLines.removeFirst(consoleLines.count - 400) }
    }

    // MARK: Effort

    private func updateEffort(_ t: Double) {
        // Resting HR: the lowest one-minute mean seen this session.
        let lastMinute = timeline.heartRate.values(from: t - 60, to: t + 1)
        if lastMinute.count >= 45, let m = Stats.mean(lastMinute) { restingHR = min(restingHR ?? m, m) }
        guard hasLiveHeartRate, let bpm = heartRate else {
            zone = nil; percentOfMax = nil
            return
        }
        let hr = Double(bpm)
        zone = Effort.zone(hr: hr, maxHR: profile.maxHR)
        percentOfMax = 100 * hr / profile.maxHR
        sessionKcal += Effort.kcalPerMinute(hr: hr, profile: profile) / 60
        sessionTrimp += Effort.trimp(hr: hr, restingHR: restingHR ?? 60, profile: profile, seconds: 1)
        sessionStrain = Effort.strain(trimp: sessionTrimp)
    }

    private func resetEffort() {
        zone = nil; percentOfMax = nil; restingHR = nil
        sessionKcal = 0; sessionStrain = 0; sessionTrimp = 0
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
        case .biometric(let r):
            let temp = r.skinTempC.map { String(format: "%.2f °C", $0) } ?? "no temp"
            let at = Date(timeIntervalSince1970: TimeInterval(r.unixTime)).formatted(date: .omitted, time: .standard)
            return ("R18 SUMMARY", "#\(r.recordIndex) at \(at) · \(temp) · HR \(r.bpm) · steps \(r.steps)", .body)
        case .ecg(let e):
            let source = e.isLive ? "live" : "history"
            return ("R\(e.layout) ECG", "\(e.samples.count) samples (\(source)) · quality \(e.quality) · progress \(e.progress)", .body)
        case .commandResponse(let r):
            let result = r.result.map { "\($0)".uppercased() } ?? "result \(r.resultRaw)"
            return ("RESPONSE", "\(r.commandName) #\(r.originSeq) · \(result) · \(r.body.count) B", .command)
        case .event(let e):
            return ("EVENT", e.name, .event)
        case .consoleLog(let c):
            return ("CONSOLE", "#\(c.sequence) " + String(c.text.prefix(120)), .other)
        case .metadata(_, let kind):
            let marker = HistoryMarker(rawValue: kind).map { "HISTORY_\("\($0)".uppercased())" } ?? "kind \(kind)"
            return ("METADATA", "\(typeName) \(marker)", .body)
        case .other(_, let layout):
            return (typeName, "layout \(layout) · \(f.count) B", .other)
        }
    }
}
