import XCTest
@testable import WhoopKit

final class FrameTests: XCTestCase {
    func testClientHelloIsByteExact() {
        // The canonical WHOOP 5/MG client hello (noop DeviceFamily.whoop5ClientHello, whoop-rs gatt.rs).
        let frame = WhoopFrame.command(CommandBody.hello.command, seq: 1, params: CommandBody.hello.params)
        XCTAssertEqual(frame.hex, "AA 01 08 00 00 01 E6 71 23 01 91 01 36 3E 5C 8D")
    }

    func testMatchesOfficialAppImuToggleCapture() {
        // PacketLogger capture of the WHOOP app's TOGGLE_IMU_MODE (dofek whoop-ble-protocol.md).
        let frame = WhoopFrame.command(WhoopCommand.toggleIMUMode.rawValue, seq: 0xF1, params: CommandBody.imuStream(true).params)
        XCTAssertEqual(frame.hex, "AA 01 0C 00 00 01 E7 41 23 F1 6A 01 01 00 00 00 58 E9 61 FC")
    }

    func testOtherCommandFrames() {
        XCTAssertEqual(WhoopFrame.command(3, seq: 1, params: CommandBody.realtimeHR(true).params).hex,
                       "AA 01 08 00 00 01 E6 71 23 01 03 01 AE D6 2B CE")
        XCTAssertEqual(WhoopFrame.command(0x13, seq: 4, params: CommandBody.buzz(pulses: 1).params).hex,
                       "AA 01 14 00 00 01 E1 E1 23 04 13 01 2F 98 00 00 00 00 00 00 00 00 00 00 13 75 04 96")
        let clock = CommandBody.setClock(Date(timeIntervalSince1970: 1_760_230_751))
        XCTAssertEqual(WhoopFrame.command(clock.command, seq: 3, params: clock.params).hex,
                       "AA 01 10 00 00 01 E0 D1 23 03 92 01 5F FD EA 68 00 00 00 00 EA 5B 8F C8")
    }

    func testValidationRejectsCorruption() {
        var bytes = [UInt8](hex: "AA 01 08 00 00 01 E6 71 23 01 91 01 36 3E 5C 8D")!
        XCTAssertEqual(WhoopFrame.validate(bytes), .ok)
        bytes[11] ^= 0x01
        XCTAssertEqual(WhoopFrame.validate(bytes), .badBodyCRC)
        bytes[11] ^= 0x01
        bytes[3] = 0x01
        XCTAssertEqual(WhoopFrame.validate(bytes), .lengthMismatch)
    }

    func testSequencerWrapsAndSkipsZero() {
        var s = CommandSequencer()
        var last: UInt8 = 0
        for _ in 0..<300 { last = s.frame(CommandBody.hello).seq; XCTAssertNotEqual(last, 0) }
        XCTAssertEqual(last, 45) // 300 sends: 1…255 then 1…45
    }
}

final class AssemblerTests: XCTestCase {
    func testReassemblesFragmentedAndConcatenatedFrames() {
        let a = SyntheticFrames.realtimeHR(time: 1_700_000_000, bpm: 64, rrMs: [937.5])
        let imu = SyntheticFrames.imuR21(time: 1_700_000_000.5,
                                         accel: Array(repeating: SIMD3(0, 0, 1), count: 100),
                                         gyro: Array(repeating: SIMD3(0, 0, 0), count: 100))
        let b = SyntheticFrames.event(StrapEvent.doubleTap, time: 1_700_000_001)
        var stream = [UInt8](hex: "00 13 AA 37")! + a.bytes + imu.bytes + b.bytes // garbage incl. a false 0xAA
        var asm = FrameAssembler()
        var out: [WhoopFrame] = []
        while !stream.isEmpty {
            let n = min(stream.count, 61)
            for o in asm.append(Array(stream.prefix(n))) { if case .frame(let f) = o { out.append(f) } }
            stream.removeFirst(n)
        }
        XCTAssertEqual(out, [a, imu, b])
        XCTAssertEqual(asm.discardedBytes, 4)
    }

    func testCorruptBodyIsReportedNotEmitted() {
        var bytes = SyntheticFrames.realtimeHR(time: 1, bpm: 60, rrMs: []).bytes
        bytes[16] ^= 0xFF // flip bpm without fixing the CRC32
        var asm = FrameAssembler()
        guard case .corrupt(_, let why)? = asm.append(bytes).first else { return XCTFail("expected corrupt") }
        XCTAssertEqual(why, .badBodyCRC)
    }
}

final class ParserTests: XCTestCase {
    func testRealtimeHeartRate() {
        // 1024 ticks = exactly one second; 937.5 ms encodes as 960 ticks.
        let f = SyntheticFrames.realtimeHR(time: 1_700_000_123, bpm: 61, rrMs: [1000, 937.5])
        guard case .realtimeHR(let hr) = WhoopParser.parse(f) else { return XCTFail() }
        XCTAssertEqual(hr.bpm, 61)
        XCTAssertEqual(hr.strapTime, 1_700_000_123)
        XCTAssertEqual(hr.rrIntervalsMs, [1000, 938]) // (960*1000+512)/1024 = 938
        XCTAssertEqual(f.count, 32)
        XCTAssertEqual(hr.onWrist, true)
        guard case .realtimeHR(let off) = WhoopParser.parse(SyntheticFrames.realtimeHR(time: 1, bpm: 0, rrMs: [], onWrist: false))
        else { return XCTFail() }
        XCTAssertEqual(off.onWrist, false)
    }

    func testRealtimeHeartRateWithoutIntervals() {
        guard case .realtimeHR(let hr) = WhoopParser.parse(SyntheticFrames.realtimeHR(time: 5, bpm: 72, rrMs: [])) else { return XCTFail() }
        XCTAssertEqual(hr.bpm, 72)
        XCTAssertTrue(hr.rrIntervalsMs.isEmpty)
    }

    func testIMURoundTrip() {
        let accel = (0..<100).map { SIMD3<Float>(Float($0) / 1000, -0.5, 1) }
        let gyro = (0..<80).map { SIMD3<Float>(Float($0), 0, -250) }
        let f = SyntheticFrames.imuR21(time: 1_700_000_000.25, accel: accel, gyro: gyro)
        XCTAssertEqual(f.count, 1244)
        guard case .imu(let imu) = WhoopParser.parse(f) else { return XCTFail() }
        XCTAssertEqual(imu.accel.count, 100)
        XCTAssertEqual(imu.gyro.count, 80)
        XCTAssertEqual(imu.strapTime, 1_700_000_000.25, accuracy: 1.0 / 32768)
        XCTAssertEqual(imu.accel[50].x, 0.05, accuracy: 1.0 / 4096)
        XCTAssertEqual(imu.accel[50].z, 1, accuracy: 1.0 / 4096)
        XCTAssertEqual(imu.gyro[79].z, -250, accuracy: 0.1)
    }

    func testOpticalR26RoundTrip() {
        let samples = (0..<25).map { 100_000 + 500 * sin(Double($0) / 3) }
        guard case .optical(let o) = WhoopParser.parse(SyntheticFrames.opticalR26(time: 9, samples: samples)) else { return XCTFail() }
        XCTAssertEqual(o.samples.count, 25)
        for (a, b) in zip(o.samples, samples) { XCTAssertEqual(a, b, accuracy: 1) }
    }

    func testEventAndCommandResponse() {
        guard case .event(let e) = WhoopParser.parse(SyntheticFrames.event(StrapEvent.wristOff, time: 77)) else { return XCTFail() }
        XCTAssertEqual(e.name, "WRIST_OFF")
        XCTAssertEqual(e.strapTime, 77)

        var body = [UInt8](repeating: 0, count: 107)
        body[0] = 1
        body.replaceSubrange(1..<5, with: UInt32(873).littleEndianBytes) // 87.3 %
        body[91] = 50; body[92] = 42; body[93] = 1
        let f = SyntheticFrames.commandResponse(command: 145, originSeq: 1, result: .success, body: body)
        guard case .commandResponse(let r) = WhoopParser.parse(f), let hello = WhoopParser.hello(r) else { return XCTFail() }
        XCTAssertEqual(r.originSeq, 1)
        XCTAssertEqual(hello.firmware, "50.42.1.0")
        XCTAssertEqual(hello.batteryPercent, 87.3, accuracy: 0.001)
    }

    func testStandardHeartRateMeasurement() {
        // flags 0x16: uint8 HR, contact supported + detected, R-R present.
        let m = StandardHeartRate([0x16, 70, 0x00, 0x04, 0xC0, 0x03])
        XCTAssertEqual(m?.bpm, 70)
        XCTAssertEqual(m?.sensorContact, true)
        XCTAssertEqual(m?.rrIntervalsMs, [1000, 937.5])
    }

    func testVariantResolution() {
        XCTAssertEqual(WhoopVariant.resolve(model: "MG", serial: nil, hardwareRevision: nil), .mg)
        XCTAssertEqual(WhoopVariant.resolve(model: nil, serial: "5AM123", hardwareRevision: nil), .mg)
        XCTAssertEqual(WhoopVariant.resolve(model: nil, serial: "5AG123", hardwareRevision: nil), .whoop5)
        XCTAssertEqual(WhoopVariant.resolve(model: nil, serial: "5AM1", hardwareRevision: "WG50"), .unknown)
    }
}
