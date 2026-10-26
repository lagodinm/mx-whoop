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
        case .realtimeRawData, .historicalData:
            switch layout {
            case 21: if let imu = imuR21(b, end: end) { return .imu(imu) }
            case 26: if let o = opticalR26(b, end: end) { return .optical(o) }
            case 20: if let o = opticalR20(b, end: end) { return .optical(o) }
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
            return .consoleLog(printableASCII(b[9..<end]))
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

    // MARK: Command response bodies

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

    static func printableASCII(_ bytes: ArraySlice<UInt8>) -> String {
        String(decoding: bytes.map { (0x20...0x7E).contains($0) || $0 == 0x0A ? $0 : 0x20 }, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
