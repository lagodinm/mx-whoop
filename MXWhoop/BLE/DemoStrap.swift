import Foundation
import WhoopKit

/// A virtual WHOOP MG for the Simulator and for trying the app without a strap.
///
/// It encodes simulated physiology into real WHOOP 5/MG frames, chops them into
/// BLE-sized notifications and pushes them through a `FrameAssembler`, so the demo
/// exercises exactly the same parsing path as a real strap.
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
                self.timer?.invalidate()
                self.timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
            }
        }
    }

    func disconnect() {
        timer?.invalidate()
        timer = nil
        realtimeHR = false; imu = false; optical = false
        emit(.state(.idle))
    }

    func send(_ request: CommandBody.Request) {
        let (seq, frame) = sequencer.frame(request)
        emit(.commandSent(label: request.label, seq: seq, frame: frame))
        let on = request.params.count >= 2 ? request.params[1] == 1 : request.params.first == 1
        var body: [UInt8] = [0x01]
        switch WhoopCommand(rawValue: request.command) {
        case .toggleRealtimeHR: realtimeHR = request.params.first == 1
        case .toggleIMUMode: imu = on
        case .toggleOpticalMode: optical = on
        case .getHello: body = helloBody()
        case .getBatteryLevel: body = UInt32(87).littleEndianBytesForDemo
        case .runHapticPatternMaverick: emit(.log("Demo strap: bzzz"))
        default: break
        }
        let reply = SyntheticFrames.commandResponse(command: request.command, originSeq: seq, result: .success, body: body)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.deliver(reply, .command) }
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
