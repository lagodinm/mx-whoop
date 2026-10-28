import XCTest
@testable import WhoopKit

/// Frames from a real WHOOP 5 PacketLogger capture taken while the official app synced
/// (dofek `packages/mobile/modules/whoop-ble/Tests/fixtures/imu-activation-capture.tsv`).
final class CapturedHistoryTests: XCTestCase {
    func testBiometricRecordFromRealStrap() throws {
        let bytes = try XCTUnwrap([UInt8](hex: "aa01740001003fb12f1280335018000b45c9690a3700410119040000000000000060e3018c3e4239ffc08ea03c9a493abfb8b61b3fe14aa93ecffe9000000000000000000026013301920ca004010c020c0000000000000000000000000000000000000000000002010097a12526000000455b9cc0000000ccebec5c"))
        let frame = try XCTUnwrap(WhoopFrame(validating: bytes), "real frame must pass both CRCs")
        guard case .biometric(let r) = WhoopParser.parse(frame) else { return XCTFail("expected R18") }
        XCTAssertEqual(r.recordIndex, 1_593_395)
        XCTAssertEqual(r.unixTime, 1_774_798_091)
        XCTAssertEqual(r.bpm, 65)
        XCTAssertEqual(r.rrIntervalsMs, [1024]) // 1049 ticks
        XCTAssertEqual(try XCTUnwrap(r.skinTempC), 32.18, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(r.auxTemp1C), 29.4, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(r.auxTemp2C), 30.7, accuracy: 0.001)
        XCTAssertEqual(r.steps, 65_231)
        XCTAssertEqual(r.activity, .still)
        XCTAssertEqual(r.bandState, .wake)
        let g = try XCTUnwrap(r.gravity)
        XCTAssertEqual(Double((g * g).sum().squareRoot()), 1.0, accuracy: 0.02)
    }

    func testDataRangeFromRealStrap() throws {
        let bytes = try XCTUnwrap([UInt8](hex: "aa014c00010032d124c322f7010100000000b2c60100b7c60100b2c6010000000000000002003e000000b5ff1d0000010020813000000b45c9690a3700000b45c9690a3700004845c9690a3700000000dd108995"))
        let frame = try XCTUnwrap(WhoopFrame(validating: bytes))
        guard case .commandResponse(let resp) = WhoopParser.parse(frame) else { return XCTFail() }
        let range = try XCTUnwrap(WhoopParser.dataRange(resp))
        XCTAssertEqual(range.trimPage, 116_402)
        XCTAssertEqual(range.writePage, 116_407)
        XCTAssertEqual(range.pagesBehind, 5)
        XCTAssertEqual(range.recordEstimate, 62)
        XCTAssertEqual(range.oldestUnsyncedTime, 1_774_798_091) // = the first R18 record above
        XCTAssertEqual(range.newestTime, 1_774_798_152)
    }

    func testHistoryEndMarkerAndEventFromRealStrap() throws {
        let end = try XCTUnwrap(WhoopFrame(validating: [UInt8](hex: "aa011c00010023d13133025145c969476135000000b3c60100000000000000006fe92a61")!))
        XCTAssertEqual(WhoopParser.parse(end), .metadata(packetType: 49, kind: HistoryMarker.end.rawValue))
        let event = try XCTUnwrap(WhoopFrame(validating: [UInt8](hex: "aa0110000100208130e022000c45c969b83e00001f3b0b16")!))
        guard case .event(let e) = WhoopParser.parse(event) else { return XCTFail() }
        XCTAssertEqual(e.name, "BLE_REALTIME_HR_OFF")
    }

    func testSyntheticBiometricRoundTrip() throws {
        let f = SyntheticFrames.biometricR18(index: 7, time: 1_700_000_000, bpm: 71, rrMs: [845], skinTempC: 33.47,
                                             auxTempC: (28.1, 31.2), steps: 1234, activity: 1, bandState: 2)
        XCTAssertEqual(f.count, 124)
        guard case .biometric(let r) = WhoopParser.parse(f) else { return XCTFail() }
        XCTAssertEqual(try XCTUnwrap(r.skinTempC), 33.47, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(r.auxTemp1C), 28.1, accuracy: 0.001)
        XCTAssertEqual(r.steps, 1234)
        XCTAssertEqual(r.activity, .walk)
        XCTAssertEqual(r.bandState, .sleep)
        XCTAssertEqual(r.rrIntervalsMs, [845])
    }

    func testSyntheticDataRangeAndMarkers() throws {
        let body = SyntheticFrames.dataRangeBody(read: 10, write: 14, trim: 10, estimate: 40,
                                                 oldest: 1_700_000_000, newest: 1_700_000_090)
        let f = SyntheticFrames.commandResponse(command: 34, originSeq: 3, result: .success, body: body)
        guard case .commandResponse(let r) = WhoopParser.parse(f) else { return XCTFail() }
        let range = try XCTUnwrap(WhoopParser.dataRange(r))
        XCTAssertEqual(range.pagesBehind, 4)
        XCTAssertEqual(range.oldestUnsyncedTime, 1_700_000_000)
        XCTAssertEqual(range.newestTime, 1_700_000_090)
        XCTAssertEqual(SyntheticFrames.historyMarker(.end, time: 1, trimCursor: 99).count, 36)
        XCTAssertEqual(WhoopParser.parse(SyntheticFrames.historyMarker(.complete, time: 1)), .metadata(packetType: 49, kind: 3))
        // PENDING replies carry no body and must not decode.
        let pending = SyntheticFrames.commandResponse(command: 34, originSeq: 3, result: .pending, body: [])
        guard case .commandResponse(let p) = WhoopParser.parse(pending) else { return XCTFail() }
        XCTAssertNil(WhoopParser.dataRange(p))
    }
}

final class ECGParserTests: XCTestCase {
    func testFilteredECGRoundTrip() throws {
        let samples: [Int16] = (0..<100).map { Int16(800 * sin(Double($0) / 5)) }
        let f = SyntheticFrames.ecgR17(sequence: 42, time: 1, samples: samples, quality: 2, presence: true, progress: 37, hr: 64)
        XCTAssertEqual(f.count, 240)
        guard case .ecg(let r) = WhoopParser.parse(f) else { return XCTFail() }
        XCTAssertTrue(r.isLive && r.isFiltered && r.presence)
        XCTAssertEqual(r.samples, samples.map { Int32($0) })
        XCTAssertEqual(r.sequence, 42)
        XCTAssertEqual(r.quality, 2)
        XCTAssertEqual(r.progress, 37)
        XCTAssertEqual(r.strapHRValue, 64)
        // The same layout replayed by a sync is not live.
        let replay = SyntheticFrames.ecgR17(sequence: 1, time: 1, samples: [1], packetType: .historicalData)
        guard case .ecg(let h) = WhoopParser.parse(replay) else { return XCTFail() }
        XCTAssertFalse(h.isLive)
    }

    func testRawECGIs18BitTwosComplementWithFlagsIgnored() {
        var body = [UInt8](repeating: 0, count: 1584 - 12)
        func put(_ bytes: [UInt8], at frameOffset: Int) {
            for (i, x) in bytes.enumerated() { body[frameOffset - 8 + i] = x }
        }
        put([PacketType.realtimeRawData.rawValue, 16], at: 8)
        put([4, 0], at: 32)               // four samples
        put([0x01, 0xFF, 0xFF], at: 34)   // 0x1FFFF → 131071
        put([0xC2, 0x00, 0x00], at: 37)   // flags 6/7 set, 0x20000 → −131072
        put([0x03, 0xFF, 0xFF], at: 40)   // 0x3FFFF → −1
        put([0x80, 0x00, 0x05], at: 43)   // flag 7 only → 5
        let f = SyntheticFrames.frame(body: body)
        XCTAssertEqual(f.count, 1584)
        guard case .ecg(let r) = WhoopParser.parse(f) else { return XCTFail() }
        XCTAssertEqual(r.samples, [131_071, -131_072, -1, 5])
        XCTAssertFalse(r.isFiltered)
    }

    func testCountAboveCapacityIsRejected() {
        var bytes = SyntheticFrames.ecgR17(sequence: 1, time: 1, samples: [1, 2, 3]).bytes
        bytes[32] = 101
        let f = SyntheticFrames.frame(body: Array(bytes[8..<236]))
        XCTAssertEqual(WhoopParser.parse(f), .other(packetType: 43, layout: 17))
    }
}

final class NewCommandTests: XCTestCase {
    func testHighFrequencySyncPayloadMatchesOfficialBuilder() {
        // Official app: allocate(5) · put(0, 2) · putShort(1, interval) · putShort(3, duration), little-endian.
        XCTAssertEqual(CommandBody.enterHighFreqSync(interval: 61, duration: 1800).params, [0x02, 0x3D, 0x00, 0x08, 0x07])
        XCTAssertEqual(CommandBody.enterHighFreqSync(interval: 10, duration: 99_999).params, [0x02, 0x3D, 0x00, 0x7F, 0x70])
        XCTAssertEqual(CommandBody.exitHighFreqSync.params, [0x00])
        XCTAssertEqual(CommandBody.enterHighFreqSync().command, 96)
    }

    func testHistoryPeekNeverAcknowledges() {
        XCTAssertEqual(CommandBody.sendHistory.command, 22)
        XCTAssertEqual(CommandBody.abortHistory.command, 20)
        XCTAssertEqual(CommandBody.dataRange.params, [0x00])
        XCTAssertNil(WhoopCommand(rawValue: 23), "the history acknowledgement must not exist in this app")
        XCTAssertNil(WhoopCommand(rawValue: 25))
        XCTAssertNil(WhoopCommand(rawValue: 33))
    }

    func testECGPayloadsMatchOfficialEnums() {
        XCTAssertEqual(CommandBody.selectWrist(.right).params, [0x01, 0x01])
        XCTAssertEqual(CommandBody.selectWrist(.left).params, [0x01, 0x02])
        XCTAssertEqual(CommandBody.ecgGeneration(true).params, [0x01, 0x02])
        XCTAssertEqual(CommandBody.ecgGeneration(false).params, [0x01, 0x01])
        XCTAssertEqual(CommandBody.ecgLiveFiltered(true).params, [0x01, 0x01])
        XCTAssertEqual(CommandBody.ecgLiveFiltered(false).params, [0x01, 0x00])
        let commands = [CommandBody.selectWrist(.left).command, CommandBody.ecgGeneration(true).command,
                        CommandBody.ecgLiveFiltered(true).command]
        XCTAssertEqual(commands, [123, 124, 139])
    }
}

final class NewAnalysisTests: XCTestCase {
    /// Beats with a 0.25 Hz (breathing) and a 0.1 Hz (baroreflex) oscillation.
    private func oscillatingBeats(seconds: Double) -> [TimedValue] {
        var beats: [TimedValue] = []
        var t = 0.0
        while t < seconds {
            let a: Double = 30 * sin(2 * Double.pi * 0.25 * t)
            let b: Double = 20 * sin(2 * Double.pi * 0.1 * t)
            let rr = 900 + a + b
            t += rr / 1000
            beats.append(TimedValue(t: t, v: rr))
        }
        return beats
    }

    func testFrequencyDomainSeparatesBands() throws {
        let f = try XCTUnwrap(HRV.frequencyDomain(oscillatingBeats(seconds: 180)))
        // Sinusoid power is A²/2: HF 450 ms², LF 200 ms², less the linear-interpolation loss.
        XCTAssertEqual(f.hf, 330, accuracy: 120)
        XCTAssertEqual(f.lf, 190, accuracy: 60)
        XCTAssertEqual(f.peakHz, 0.25, accuracy: 0.01)
        XCTAssertNil(HRV.frequencyDomain(oscillatingBeats(seconds: 60)), "needs at least 100 s")
    }

    func testStressIndexRisesWithRigidFastRhythm() throws {
        var rng = SeededRandom(seed: 9)
        let calm = (0..<120).map { _ in 900 + 40 * rng.gaussian() }
        let tense = (0..<120).map { _ in 600 + 8 * rng.gaussian() }
        let a = try XCTUnwrap(HRV.stressIndex(calm))
        let b = try XCTUnwrap(HRV.stressIndex(tense))
        XCTAssertLessThan(a, 200)
        XCTAssertGreaterThan(b, 500)
        XCTAssertNil(HRV.stressIndex(Array(calm.prefix(10))))
    }

    func testECGPeaksAtAnyPolarityAndRate() {
        for (fs, bpm, inverted) in [(100.0, 60.0, false), (100.0, 150.0, true), (128.0, 45.0, true), (250.0, 72.0, false)] {
            var beats: [Double] = []
            var t = 0.37
            var k = 0.0
            while t < 12 {
                beats.append(t)
                t += 60 / bpm * (1 + 0.04 * sin(k)); k += 1
            }
            var x = ECGSynth.samples(beats: beats, start: 0, count: Int(10 * fs), rate: fs)
            if inverted { x = x.map { -$0 } }
            let peaks = ECGAnalyzer.rPeaks(x, sampleRate: fs)
            let truth = beats.filter { $0 < 10 }
            XCTAssertEqual(peaks.count, truth.count, "fs \(fs) bpm \(bpm)")
            for p in peaks {
                let nearest = truth.map { abs($0 - Double(p) / fs) }.min() ?? 1
                XCTAssertLessThan(nearest, 0.015)
            }
            let rr = ECGAnalyzer.rrIntervals(peaks: peaks, sampleRate: fs)
            XCTAssertEqual(60_000 / (Stats.median(rr) ?? 1), bpm, accuracy: bpm * 0.06)
        }
    }

    func testEffortEstimates() {
        let p = EffortProfile(age: 35, weightKg: 75, sex: .male)
        XCTAssertEqual(p.maxHR, 183.5, accuracy: 0.01)
        XCTAssertEqual(Effort.zone(hr: 60, maxHR: p.maxHR), 0)
        XCTAssertEqual(Effort.zone(hr: 140, maxHR: p.maxHR), 3)
        XCTAssertEqual(Effort.zone(hr: 180, maxHR: p.maxHR), 5)
        // Rest is floored at 1 MET; exercise follows Keytel.
        XCTAssertEqual(Effort.kcalPerMinute(hr: 60, profile: p), 75.0 / 60, accuracy: 1e-9)
        XCTAssertEqual(Effort.kcalPerMinute(hr: 150, profile: p), 15.0, accuracy: 1)
        // 45 min at 75 % HR reserve ≈ 11, an hour at 90 % ≈ 17.
        let rest = 60.0
        let moderate = Effort.trimp(hr: rest + 0.75 * (p.maxHR - rest), restingHR: rest, profile: p, seconds: 45 * 60)
        let hard = Effort.trimp(hr: rest + 0.9 * (p.maxHR - rest), restingHR: rest, profile: p, seconds: 3600)
        XCTAssertEqual(Effort.strain(trimp: moderate), 11.5, accuracy: 1)
        XCTAssertEqual(Effort.strain(trimp: hard), 17, accuracy: 1)
        XCTAssertEqual(Effort.strain(trimp: 0), 0)
    }
}
