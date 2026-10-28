import Foundation

/// Decodes validated WHOOP 5.0 / MG frames. All offsets are absolute frame offsets
/// (packet type at 8), per noop `PROTOCOL_SENSORS.md` / whoop-rs `parse/`.
public enum WhoopParser {
    public static func parse(_ frame: WhoopFrame) -> WhoopMessage {
        let b = frame.bytes
        let end = frame.bodyEnd
        let type = frame.packetTypeRaw
        let layout = b[9]

        switch PacketType(rawValue: type) {
        case .realtimeData:
            if let hr = realtimeHR(b, end: end) { return .realtimeHR(hr) }
        case .realtimeRawData:
            switch layout {
            case 21: if let imu = imuR21(b, end: end) { return .imu(imu) }
            case 26: if let o = opticalR26(b, end: end) { return .optical(o) }
            case 20: if let o = opticalR20(b, end: end) { return .optical(o) }
            case 16, 17: if let e = ecg(b, live: true) { return .ecg(e) }
            default: break
            }
        case .historicalData:
            // Stored records replayed by a sync, usually the official app's. Old IMU and
            // optical windows must never be mixed into the live timeline, so only the
            // one-second summary (and ECG, flagged as not live) is decoded.
            switch layout {
            case 18: if let r = biometricR18(b) { return .biometric(r) }
            case 16, 17: if let e = ecg(b, live: false) { return .ecg(e) }
            default: break
            }
        case .commandResponse, .puffinCommandResponse:
            if end >= 13 {
                return .commandResponse(CommandResponse(command: b[10], originSeq: b[11], resultRaw: b[12],
                                                        body: Array(b[13..<end])))
            }
        case .event, .puffinEvents:
            if end >= 16 { return .event(StrapEvent(number: b[10], strapTime: b.u32(at: 12))) }
        case .consoleLogs:
            if let c = console(b, end: end) { return .consoleLog(c) }
        case .metadata, .puffinMetadata:
            if end >= 11 { return .metadata(packetType: type, kind: b[10]) }
        default:
            break
        }
        return .other(packetType: type, layout: layout)
    }

    // MARK: Packet 40 — live HR / R-R

    /// `[10] u32 unix s · [14] u16 subsec · [16] bpm · [17] rr count · [18+2i] rr ticks (1/1024 s)
    ///  · [26] worn · [27] body location` — the compact form is a 32-byte frame with room
    /// for four intervals (the official app reads bpm at 16 and the worn flag at 26).
    static func realtimeHR(_ b: [UInt8], end: Int) -> RealtimeHeartRate? {
        guard end >= 18 else { return nil }
        let isCompact = end == 28
        let count = isCompact ? min(Int(b[17]), 4) : Int(b[17])
        var rr: [Double] = []
        var i = 0
        while i < count, 18 + 2 * i + 2 <= end {
            let ticks = Int(b.u16(at: 18 + 2 * i))
            // Rounded integer ms, exactly as specified: (ticks*1000 + 512) / 1024.
            if ticks > 0 { rr.append(Double((ticks * 1000 + 512) / 1024)) }
            i += 1
        }
        return RealtimeHeartRate(strapTime: b.u32(at: 10), bpm: Int(b[16]), rrIntervalsMs: rr,
                                 onWrist: isCompact ? b[26] != 0 : nil)
    }

    // MARK: Layout 21 — six-axis IMU (1,244-byte frame)

    static func imuR21(_ b: [UInt8], end: Int) -> IMUBatch? {
        guard b.count >= 1244, end >= 1240 else { return nil }
        let accelCount = min(Int(b.u16(at: 24)), 100)
        let gyroCount = min(Int(b.u16(at: 630)), 100)
        let time = Double(b.u32(at: 15)) + Double(b.u16(at: 19)) / 32768.0
        let aScale: Float = 1.0 / 4096.0
        let gScale: Float = 2000.0 / 32768.0
        var accel: [SIMD3<Float>] = []
        accel.reserveCapacity(accelCount)
        for i in 0..<accelCount {
            accel.append(SIMD3(Float(b.i16(at: 28 + 2 * i)), Float(b.i16(at: 228 + 2 * i)),
                               Float(b.i16(at: 428 + 2 * i))) * aScale)
        }
        var gyro: [SIMD3<Float>] = []
        gyro.reserveCapacity(gyroCount)
        for i in 0..<gyroCount {
            gyro.append(SIMD3(Float(b.i16(at: 640 + 2 * i)), Float(b.i16(at: 840 + 2 * i)),
                              Float(b.i16(at: 1040 + 2 * i))) * gScale)
        }
        return IMUBatch(strapTime: time, accel: accel, gyro: gyro)
    }

    // MARK: Layout 26 — compact optical window (88-byte frame)

    /// Base code u32 at 23, then 24 clipped i16 adjacent deltas at 27+2i → 25 samples (~1 s).
    static func opticalR26(_ b: [UInt8], end: Int) -> OpticalWindow? {
        guard b.count >= 88, end >= 75 else { return nil }
        var value = Double(b.u32(at: 23))
        var samples = [value]
        for i in 0..<24 {
            value += Double(b.i16(at: 27 + 2 * i))
            samples.append(value)
        }
        return OpticalWindow(strapTime: b.u32(at: 15), layout: 26, samples: samples, sampleRate: 25)
    }

    // MARK: Layout 20 — optical blocks (2,140-byte frame)

    /// Five 422-byte blocks; each has a per-slot count (≤ 50) and two i32 sample slots.
    /// We surface slot A of the first populated block. Wavelength identity is unknown.
    static func opticalR20(_ b: [UInt8], end: Int) -> OpticalWindow? {
        guard b.count >= 2140, end >= 2136 else { return nil }
        for base in [26, 448, 870, 1292, 1714] {
            let count = Int(b[base])
            guard count > 0, count <= 50 else { continue }
            let samples = (0..<count).map { Double(Int32(bitPattern: b.u32(at: base + 21 + 4 * $0))) }
            return OpticalWindow(strapTime: b.u32(at: 15), layout: 20, samples: samples, sampleRate: Double(count))
        }
        return nil
    }

    // MARK: Layout 18 — one-second biometric summary (124-byte frame, history only)

    /// `[11] u32 index · [15] u32 unix s · [22] bpm · [23] rr count · [24+2i] rr ticks ·
    /// [36] quality · [41] f32 dynamic g · [45/49/53] f32 gravity · [57] u16 steps ·
    /// [63] activity · [69/71] i16 aux °C×10 · [73] u16 skin °C×100 · [81] state bits`.
    static func biometricR18(_ b: [UInt8]) -> BiometricRecord? {
        // A record of another size is a different layout, not this one with fields missing.
        guard b.count == 124 else { return nil }
        let count = min(Int(b[23]), 4)
        var rr: [Double] = []
        for i in 0..<count {
            let ticks = Int(b.u16(at: 24 + 2 * i))
            if ticks > 0 { rr.append(Double((ticks * 1000 + 512) / 1024)) }
        }
        let skin = Double(b.u16(at: 73)) / 100
        let aux1 = Double(b.i16(at: 69)) / 10
        let aux2 = Double(b.i16(at: 71)) / 10
        let dynamic = Double(b.f32(at: 41))
        let gx = b.f32(at: 45), gy = b.f32(at: 49), gz = b.f32(at: 53)
        let gravityValid = gx.isFinite && gy.isFinite && gz.isFinite
        return BiometricRecord(
            recordIndex: b.u32(at: 11), unixTime: b.u32(at: 15), bpm: Int(b[22]), rrIntervalsMs: rr,
            skinTempC: (5...45).contains(skin) ? skin : nil,
            auxTemp1C: (0...60).contains(aux1) ? aux1 : nil,
            auxTemp2C: (0...60).contains(aux2) ? aux2 : nil,
            dynamicAccelG: dynamic.isFinite && (0...8).contains(dynamic) ? dynamic : nil,
            gravity: gravityValid ? SIMD3(gx, gy, gz) : nil,
            steps: b.u16(at: 57),
            activity: BiometricRecord.Activity(rawValue: b[63]),
            bandState: BiometricRecord.BandState(rawValue: (b[81] >> 4) & 3) ?? .wake,
            qualityFlags: b[36],
            extras: BiometricRecord.Extras(alternateHR: b[37], cadenceRaw: b[59], stateBits: b[81],
                                           spo2CandidateRaw: b[82], opticalBaseline: [b[106], b[107]],
                                           opticalAmplitude: [b[108], b[109]]))
    }

    // MARK: Packet 50 — firmware console

    /// `[9] sequence · [12] u32 strap time · [18] u16 text length · [21…] text`, checked
    /// against a real capture. Lines continue across frames; reassemble by concatenation.
    static func console(_ b: [UInt8], end: Int) -> ConsoleFragment? {
        guard end > 21 else { return nil }
        let declared = Int(b.u16(at: 18))
        let stop = declared > 0 ? min(end, 21 + declared) : end
        // Each fragment ends in a NUL that is not part of the text.
        let text = printableASCII(b[21..<stop].prefix { $0 != 0 }, trimming: false)
        return ConsoleFragment(sequence: b[9], strapTime: b.u32(at: 12), text: text)
    }

    // MARK: Layouts 16/17 — MG ECG

    /// Shared header: `[11] u32 sequence · [21] quality · [22] state bits · [23] classifier result ·
    /// [24] classifier state · [25] progress · [27] HR value · [32] u16 sample count`.
    /// R17 (240 B): 100 i16 slots from 34. R16 (1,584 B): 500 three-byte slots from 34, an
    /// 18-bit two's-complement value in the low bits (bits 6–7 of the first byte are flags).
    static func ecg(_ b: [UInt8], live: Bool) -> ECGRecord? {
        let layout = b[9]
        let filtered = layout == 17
        let (size, capacity, width) = filtered ? (240, 100, 2) : (1584, 500, 3)
        guard b.count == size else { return nil }
        let declared = Int(b.u16(at: 32))
        // A count above the fixed capacity is an anomaly, not something to truncate.
        guard declared <= capacity else { return nil }
        var samples: [Int32] = []
        samples.reserveCapacity(declared)
        for i in 0..<declared {
            let o = 34 + i * width
            if filtered {
                samples.append(Int32(b.i16(at: o)))
            } else {
                let raw = Int32(b[o] & 0x03) << 16 | Int32(b[o + 1]) << 8 | Int32(b[o + 2])
                samples.append(raw >= 131_072 ? raw - 262_144 : raw)
            }
        }
        return ECGRecord(layout: layout, isLive: live, sequence: b.u32(at: 11), timestampMain: b.u32(at: 15),
                         timestampExtra: b.u16(at: 19), quality: b[21],
                         statusBits: b[22], classifierResult: b[23], classifierState: b[24],
                         progress: b[25], strapHRValue: b[27], samples: samples)
    }

    // MARK: Command response bodies

    /// GET_DATA_RANGE final body: revision 1 then u32 fields — read page at 5, write page at
    /// 9, trim page at 13, capacity at 21, record estimate at 25, and clock pairs for the
    /// trim-side page at 41 and the last-written page at 57 (noop `PROTOCOL_TRANSPORT.md`).
    public static func dataRange(_ r: CommandResponse) -> DataRange? {
        guard r.command == WhoopCommand.getDataRange.rawValue, r.result == .success, r.body.count >= 65,
              r.body[0] == 1 else { return nil }
        let b = r.body
        // Failed page reads come back as all-ones; anything outside 2020–2100 is not a time.
        func clock(_ offset: Int) -> UInt32? {
            let v = b.u32(at: offset)
            return (1_577_836_800...4_102_444_800).contains(v) ? v : nil
        }
        return DataRange(readPage: b.u32(at: 5), writePage: b.u32(at: 9), trimPage: b.u32(at: 13),
                         capacity: b.u32(at: 21), recordEstimate: b.u32(at: 25),
                         oldestUnsyncedTime: clock(41), newestTime: clock(57))
    }

    /// GET_HELLO final body (107 or 111 bytes). Returns nil for the zero-filled PENDING reply.
    public static func hello(_ r: CommandResponse) -> HelloInfo? {
        guard r.command == WhoopCommand.getHello.rawValue, r.result == .success, r.body.count >= 107 else { return nil }
        let body = r.body
        let fw = "\(body[91]).\(body[92]).\(body[93]).\(body.u32(at: 94))"
        return HelloInfo(revision: body[0], batteryPercent: Double(body.u32(at: 1)) / 10.0,
                         strapTime: body.u32(at: 6), firmware: fw, preparationBits: body.u32(at: 103))
    }

    /// GET_BATTERY_LEVEL final body: u32 whole percent.
    public static func batteryPercent(_ r: CommandResponse) -> Int? {
        guard r.command == WhoopCommand.getBatteryLevel.rawValue, r.result == .success, r.body.count >= 4 else { return nil }
        let v = Int(r.body.u32(at: 0))
        return (0...100).contains(v) ? v : nil
    }

    /// GET_DEVICE_CONFIG_VALUE (121) / GET_FF_VALUE (128): `[0] rev · [1…32] key · [33…64] value`, NUL-terminated.
    public static func configValue(_ r: CommandResponse) -> ConfigValue? {
        let isFlag = r.command == WhoopCommand.getFeatureFlagValue.rawValue
        guard isFlag || r.command == WhoopCommand.getDeviceConfigValue.rawValue,
              r.result == .success, r.body.count >= 65 else { return nil }
        func field(_ range: Range<Int>) -> String {
            let bytes = r.body[range].prefix { $0 != 0 }
            return printableASCII(bytes)
        }
        let key = field(1..<33)
        guard !key.isEmpty else { return nil }
        return ConfigValue(key: key, value: field(33..<65), isFeatureFlag: isFlag)
    }

    /// GET_ALARM_TIME (67) revision 4: `[1] id · [2] u32 seconds · [18] repeats · [19] duration · [20] crescendo`.
    public static func alarm(_ r: CommandResponse) -> AlarmSlot? {
        guard r.command == WhoopCommand.getAlarmTime.rawValue, r.result == .success,
              r.body.count >= 21, r.body[0] == 4 else { return nil }
        let t = r.body.u32(at: 2)
        return AlarmSlot(id: r.body[1], time: t > 1_577_836_800 ? t : nil, repeats: r.body[18],
                         duration: r.body[19], crescendo: r.body[20] == 1)
    }

    /// GET_BATTERY_PACK_INFO (151): `[0] rev · [1] presence · [24] u16 charge`. The identifier
    /// and serial blocks (2–23) are deliberately not read.
    public static func batteryPack(_ r: CommandResponse) -> BatteryPackInfo? {
        guard r.command == WhoopCommand.getBatteryPackInfo.rawValue, r.result == .success,
              r.body.count >= 26, r.body[0] == 1 else { return nil }
        return BatteryPackInfo(present: r.body[1] != 0, chargeRaw: r.body.u16(at: 24))
    }

    /// GET_CLOCK (147): `[0] rev · [1] u32 seconds · [5] u16 ticks (1/32768 s)`. Zero means no valid time.
    public static func clock(_ r: CommandResponse) -> Double? {
        guard r.command == WhoopCommand.getClock.rawValue, r.result == .success, r.body.count >= 7 else { return nil }
        let seconds = r.body.u32(at: 1)
        guard seconds > 1_577_836_800 else { return nil }
        return Double(seconds) + Double(r.body.u16(at: 5)) / 32768
    }

    /// GET_GYRO_MODE (152): `[0] rev · [1] mode`.
    public static func gyroMode(_ r: CommandResponse) -> UInt8? {
        guard r.command == WhoopCommand.getGyroMode.rawValue, r.result == .success, r.body.count >= 2 else { return nil }
        return r.body[1]
    }

    static func printableASCII<C: Collection>(_ bytes: C, trimming: Bool = true) -> String where C.Element == UInt8 {
        let s = String(decoding: bytes.map { (0x20...0x7E).contains($0) || $0 == 0x0A ? $0 : 0x20 }, as: UTF8.self)
        return trimming ? s.trimmingCharacters(in: .whitespacesAndNewlines) : s
    }
}
