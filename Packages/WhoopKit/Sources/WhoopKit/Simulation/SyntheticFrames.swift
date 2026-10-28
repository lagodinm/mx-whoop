import Foundation

/// Builds strap → phone frames in the documented WHOOP 5.0 / MG layouts. Demo mode
/// pushes these through the real reassembler and parser, and tests use them as fixtures.
public enum SyntheticFrames {
    /// Wraps a body (starting with the packet type) in a format-1 envelope.
    public static func frame(body: [UInt8]) -> WhoopFrame {
        var body = body
        while body.count % 4 != 0 { body.append(0) }
        let declared = body.count + 4
        var bytes: [UInt8] = [0xAA, 0x01, UInt8(declared & 0xFF), UInt8(declared >> 8), 0x01, 0x00]
        bytes += Checksum.crc16Modbus(bytes).littleEndianBytes
        bytes += body
        bytes += Checksum.crc32(body).littleEndianBytes
        return WhoopFrame(validating: bytes)!
    }

    /// Compact packet 40 (32-byte frame): `[10] u32 time · [16] bpm · [17] count ·
    /// [18+2i] ticks (≤ 4) · [26] worn · [27] body location`.
    public static func realtimeHR(time: UInt32, bpm: Int, rrMs: [Double], onWrist: Bool = true) -> WhoopFrame {
        let rr = rrMs.suffix(4)
        var body: [UInt8] = [PacketType.realtimeData.rawValue, 0x02]
        body += time.littleEndianBytes
        body += [0x00, 0x00, UInt8(clamping: bpm), UInt8(rr.count)]
        for x in rr { body += UInt16(clamping: Int((x * 1024 / 1000).rounded())).littleEndianBytes }
        body += [UInt8](repeating: 0, count: 18 - body.count)
        body += [onWrist ? 1 : 0, 0x00]
        return frame(body: body)
    }

    /// Layout 21 IMU record, 1,244-byte frame.
    public static func imuR21(time: Double, accel: [SIMD3<Float>], gyro: [SIMD3<Float>],
                              packetType: PacketType = .realtimeRawData) -> WhoopFrame {
        var b = [UInt8](repeating: 0, count: 1244 - 12) // body = frame[8..<1240]
        func put(_ bytes: [UInt8], at frameOffset: Int) {
            for (i, x) in bytes.enumerated() { b[frameOffset - 8 + i] = x }
        }
        func raw(_ v: Float, _ scale: Float) -> [UInt8] {
            UInt16(bitPattern: Int16(clamping: Int((v * scale).rounded()))).littleEndianBytes
        }
        let seconds = UInt32(time)
        let ticks = UInt16(min(32767, (time - Double(seconds)) * 32768))
        put([packetType.rawValue, 21, 0x80], at: 8)
        put(seconds.littleEndianBytes, at: 15)
        put(ticks.littleEndianBytes, at: 19)
        put([4, 100], at: 21)
        let na = min(accel.count, 100), ng = min(gyro.count, 100)
        put(UInt16(na).littleEndianBytes, at: 24)
        put([3], at: 26)
        for i in 0..<na {
            put(raw(accel[i].x, 4096), at: 28 + 2 * i)
            put(raw(accel[i].y, 4096), at: 228 + 2 * i)
            put(raw(accel[i].z, 4096), at: 428 + 2 * i)
        }
        put([100], at: 628)
        put(UInt16(ng).littleEndianBytes, at: 630)
        put([5], at: 632)
        for i in 0..<ng {
            put(raw(gyro[i].x, 32768 / 2000), at: 640 + 2 * i)
            put(raw(gyro[i].y, 32768 / 2000), at: 840 + 2 * i)
            put(raw(gyro[i].z, 32768 / 2000), at: 1040 + 2 * i)
        }
        return frame(body: b)
    }

    /// Layout 26 compact optical window (88-byte frame): base + 24 clipped deltas.
    public static func opticalR26(time: UInt32, samples: [Double],
                                  packetType: PacketType = .realtimeRawData) -> WhoopFrame {
        var b = [UInt8](repeating: 0, count: 88 - 12)
        func put(_ bytes: [UInt8], at frameOffset: Int) {
            for (i, x) in bytes.enumerated() { b[frameOffset - 8 + i] = x }
        }
        put([packetType.rawValue, 26], at: 8)
        put(time.littleEndianBytes, at: 15)
        let s = samples.prefix(25).map { UInt32(clamping: Int($0.rounded())) }
        guard let base = s.first else { return frame(body: b) }
        put(base.littleEndianBytes, at: 23)
        var prev = Int(base)
        for i in 1..<min(s.count, 25) {
            let delta = Int16(clamping: Int(s[i]) - prev)
            put(UInt16(bitPattern: delta).littleEndianBytes, at: 27 + 2 * (i - 1))
            prev += Int(delta)
        }
        return frame(body: b)
    }

    /// Layout 18 one-second summary (124-byte frame), as replayed during a history sync.
    public static func biometricR18(index: UInt32, time: UInt32, bpm: Int, rrMs: [Double], skinTempC: Double,
                                    auxTempC: (Double, Double) = (29.4, 30.7), steps: UInt16 = 0,
                                    activity: UInt8 = 0, bandState: UInt8 = 0,
                                    gravity: SIMD3<Float> = SIMD3(0.05, -0.30, 0.95),
                                    dynamicAccelG: Float = 0.02) -> WhoopFrame {
        var b = [UInt8](repeating: 0, count: 124 - 12)
        func put(_ bytes: [UInt8], at frameOffset: Int) {
            for (i, x) in bytes.enumerated() { b[frameOffset - 8 + i] = x }
        }
        func f32(_ v: Float) -> [UInt8] { v.bitPattern.littleEndianBytes }
        func i16(_ v: Double) -> [UInt8] { UInt16(bitPattern: Int16(clamping: Int(v.rounded()))).littleEndianBytes }
        let rr = rrMs.suffix(4)
        put([PacketType.historicalData.rawValue, 18, 0x80], at: 8)
        put(index.littleEndianBytes, at: 11)
        put(time.littleEndianBytes, at: 15)
        put([UInt8(clamping: bpm), UInt8(rr.count)], at: 22)
        for (i, x) in rr.enumerated() { put(UInt16(clamping: Int((x * 1024 / 1000).rounded())).littleEndianBytes, at: 24 + 2 * i) }
        put([0x8C], at: 36)
        put(f32(dynamicAccelG), at: 41)
        put(f32(gravity.x) + f32(gravity.y) + f32(gravity.z), at: 45)
        put(steps.littleEndianBytes, at: 57)
        put([activity], at: 63)
        put(i16(auxTempC.0 * 10) + i16(auxTempC.1 * 10), at: 69)
        put(UInt16(clamping: Int((skinTempC * 100).rounded())).littleEndianBytes, at: 73)
        put([(bandState & 3) << 4], at: 81)
        return frame(body: b)
    }

    /// Layout 17 filtered ECG (240-byte frame): up to 100 i16 samples from 34.
    public static func ecgR17(sequence: UInt32, time: UInt32, samples: [Int16], quality: UInt8 = 3,
                              presence: Bool = true, progress: UInt8 = 0, hr: UInt8 = 0,
                              packetType: PacketType = .realtimeRawData) -> WhoopFrame {
        var b = [UInt8](repeating: 0, count: 240 - 12)
        func put(_ bytes: [UInt8], at frameOffset: Int) {
            for (i, x) in bytes.enumerated() { b[frameOffset - 8 + i] = x }
        }
        let s = samples.prefix(100)
        put([packetType.rawValue, 17, 0x00], at: 8)
        put(sequence.littleEndianBytes, at: 11)
        put(time.littleEndianBytes, at: 15)
        put([quality, presence ? 0x08 : 0x00, 0, presence ? 1 : 0, progress, 0, hr], at: 21)
        put(UInt16(s.count).littleEndianBytes, at: 32)
        for (i, v) in s.enumerated() { put(UInt16(bitPattern: v).littleEndianBytes, at: 34 + 2 * i) }
        return frame(body: b)
    }

    /// History stream marker (packet 49): START, END (carrying its 8-byte token) or COMPLETE.
    public static func historyMarker(_ marker: HistoryMarker, time: UInt32, trimCursor: UInt32 = 0,
                                     seq: UInt8 = 1) -> WhoopFrame {
        var body: [UInt8] = [PacketType.metadata.rawValue, seq, marker.rawValue]
        body += time.littleEndianBytes
        body += [0, 0, 0, 0, 0, 0]
        body += trimCursor.littleEndianBytes + [0, 0, 0, 0]
        return frame(body: body)
    }

    /// GET_DATA_RANGE success body (revision 1 + sixteen u32 fields).
    public static func dataRangeBody(read: UInt32, write: UInt32, trim: UInt32, capacity: UInt32 = 131_072,
                                     estimate: UInt32, oldest: UInt32, newest: UInt32) -> [UInt8] {
        var fields = [UInt32](repeating: 0, count: 16)
        fields[1] = read; fields[2] = write; fields[3] = trim; fields[5] = capacity; fields[6] = estimate
        fields[10] = oldest; fields[12] = oldest; fields[14] = newest
        return [0x01] + fields.flatMap(\.littleEndianBytes)
    }

    /// Firmware console fragment (packet 50): `[9] seq · [12] time · [18] u16 length · [20] 01 · [21…] text NUL`.
    public static func console(sequence: UInt8, time: UInt32, text: String) -> WhoopFrame {
        let bytes = Array(text.utf8.prefix(200)) + [0]
        var body: [UInt8] = [PacketType.consoleLogs.rawValue, sequence, 0x02, 0x00]
        body += time.littleEndianBytes + [0, 0]
        body += UInt16(bytes.count).littleEndianBytes + [0x01]
        body += bytes
        return frame(body: body)
    }

    public static func event(_ number: UInt8, time: UInt32) -> WhoopFrame {
        frame(body: [PacketType.event.rawValue, 0x00, number, 0x00] + time.littleEndianBytes)
    }

    public static func commandResponse(command: UInt8, originSeq: UInt8, result: CommandResult,
                                       body: [UInt8], seq: UInt8 = 1) -> WhoopFrame {
        frame(body: [PacketType.commandResponse.rawValue, seq, command, originSeq, result.rawValue] + body)
    }

    /// Splits a frame into BLE-notification-sized chunks, like the strap does.
    public static func chunks(_ frame: WhoopFrame, size: Int = 182) -> [[UInt8]] {
        stride(from: 0, to: frame.count, by: size).map { Array(frame.bytes[$0..<min($0 + size, frame.count)]) }
    }
}
