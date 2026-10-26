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
