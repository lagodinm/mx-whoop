import Foundation

/// Packet type at frame offset 8.
public enum PacketType: UInt8, CaseIterable, Sendable {
    case command = 0x23              // 35  phone → strap
    case commandResponse = 0x24      // 36
    case puffinCommand = 0x25        // 37
    case puffinCommandResponse = 0x26 // 38
    case realtimeData = 0x28         // 40  live HR + R-R (~1 Hz)
    case realtimeRawData = 0x2B      // 43  live raw sensor record (R21 IMU, R16/R17 ECG…)
    case historicalData = 0x2F       // 47
    case event = 0x30                // 48
    case metadata = 0x31             // 49
    case consoleLogs = 0x32          // 50
    case realtimeIMU = 0x33          // 51
    case historicalIMU = 0x34        // 52
    case relativePuffinEvents = 0x35 // 53
    case puffinEvents = 0x36         // 54
    case batteryPackConsoleLogs = 0x37 // 55
    case puffinMetadata = 0x38       // 56

    public var name: String {
        switch self {
        case .command: "COMMAND"
        case .commandResponse: "COMMAND_RESPONSE"
        case .puffinCommand: "PUFFIN_COMMAND"
        case .puffinCommandResponse: "PUFFIN_COMMAND_RESPONSE"
        case .realtimeData: "REALTIME_DATA"
        case .realtimeRawData: "REALTIME_RAW_DATA"
        case .historicalData: "HISTORICAL_DATA"
        case .event: "EVENT"
        case .metadata: "METADATA"
        case .consoleLogs: "CONSOLE_LOGS"
        case .realtimeIMU: "REALTIME_IMU"
        case .historicalIMU: "HISTORICAL_IMU"
        case .relativePuffinEvents: "RELATIVE_PUFFIN_EVENTS"
        case .puffinEvents: "PUFFIN_EVENTS"
        case .batteryPackConsoleLogs: "BATTERY_PACK_CONSOLE_LOGS"
        case .puffinMetadata: "PUFFIN_METADATA"
        }
    }
}

/// Command numbers at frame offset 10 (WHOOP 5.0 / MG, firmware 50.4x).
///
/// Only commands this app actually sends, plus a few useful for labelling
/// responses. History offload (22/23) is intentionally absent: acknowledging
/// history chunks lets the strap trim data the official WHOOP app has not yet
/// synced. Destructive commands (FORGET_BONDS 15, FORCE_TRIM 25, REBOOT 29,
/// firmware/certificate 142–159) are never sent.
public enum WhoopCommand: UInt8, Sendable {
    case linkValid = 1
    case toggleRealtimeHR = 3
    case runHapticPatternMaverick = 19     // 0x13: the buzz opcode on 5/MG
    case getBatteryLevel = 26
    case getDataRange = 34
    case startRawData = 81
    case stopRawData = 82
    case getBodyLocationAndStatus = 84
    case toggleIMUModeHistorical = 105
    case toggleIMUMode = 106              // live IMU transport
    case enableOpticalData = 107          // optical *session saving* on 5/MG
    case toggleOpticalMode = 108          // live optical transport
    case stopHaptics = 122
    case getHello = 145
    case setClock = 146
    case getClock = 147
    case getBatteryPackInfo = 151

    public var name: String { String(describing: self) }
}

/// Result byte at frame offset 12 of a command response.
public enum CommandResult: UInt8, Sendable {
    case failure = 0, success = 1, pending = 2, unsupported = 3
}

/// Ready-to-frame command bodies. Byte layouts come from hardware-verified sources
/// (noop / whoop-rs); comments note where something is still experimental.
public enum CommandBody {
    public struct Request: Sendable {
        public let command: UInt8
        public let params: [UInt8]
        public let label: String
    }

    /// GET_HELLO revision 1. With seq 1 this is byte-identical to the canonical
    /// `AA 01 08 00 00 01 E6 71 23 01 91 01 36 3E 5C 8D` client hello. Writing it
    /// *with response* is what makes iOS pair with the strap the first time.
    public static let hello = Request(command: WhoopCommand.getHello.rawValue, params: [0x01], label: "GET_HELLO")

    /// Live HR + R-R stream (packet 40). Hardware-confirmed on 5/MG.
    public static func realtimeHR(_ on: Bool) -> Request {
        Request(command: WhoopCommand.toggleRealtimeHR.rawValue, params: [on ? 1 : 0],
                label: "TOGGLE_REALTIME_HR \(on ? "on" : "off")")
    }

    /// Raw production start/stop (revision 1). Must precede the IMU/optical transport toggles.
    public static func rawData(_ on: Bool) -> Request {
        Request(command: on ? WhoopCommand.startRawData.rawValue : WhoopCommand.stopRawData.rawValue,
                params: [0x01], label: on ? "START_RAW_DATA" : "STOP_RAW_DATA")
    }

    /// Live IMU transport, revision-1 boolean `[1, state]`. The official app sends
    /// `[1, 1, 0, 0, 0]`, which pads to the identical frame.
    public static func imuStream(_ on: Bool) -> Request {
        Request(command: WhoopCommand.toggleIMUMode.rawValue, params: [0x01, on ? 1 : 0],
                label: "TOGGLE_IMU_MODE \(on ? "on" : "off")")
    }

    /// Live optical transport, revision-1 boolean. EXPERIMENTAL: the command is
    /// documented but live optical output on 5/MG is not hardware-confirmed.
    public static func opticalStream(_ on: Bool) -> Request {
        Request(command: WhoopCommand.toggleOpticalMode.rawValue, params: [0x01, on ? 1 : 0],
                label: "TOGGLE_OPTICAL_MODE \(on ? "on" : "off")")
    }

    /// Notification buzz: `[rev 1][8 waveform effects][loop ctrl u16 = 0][repeats after first]`.
    /// Hardware-confirmed on 5/MG (noop #926): the last byte counts *extra* pulses.
    public static func buzz(pulses: Int = 1) -> Request {
        let repeats = UInt8(min(max(pulses, 1), 8) - 1)
        return Request(command: WhoopCommand.runHapticPatternMaverick.rawValue,
                       params: [0x01, 47, 152, 0, 0, 0, 0, 0, 0, 0x00, 0x00, repeats],
                       label: "BUZZ ×\(pulses)")
    }

    public static let stopHaptics = Request(command: WhoopCommand.stopHaptics.rawValue, params: [0x01], label: "STOP_HAPTICS")

    /// SET_CLOCK (146) revision 1: Unix seconds u32 + fractional ticks u16 (1/32768 s).
    public static func setClock(_ date: Date = Date()) -> Request {
        let t = date.timeIntervalSince1970
        let seconds = UInt32(t)
        let ticks = UInt16(min(32767, max(0, (t - Double(seconds)) * 32768)))
        return Request(command: WhoopCommand.setClock.rawValue,
                       params: [0x01] + seconds.littleEndianBytes + ticks.littleEndianBytes,
                       label: "SET_CLOCK")
    }

    public static let getClock = Request(command: WhoopCommand.getClock.rawValue, params: [0x01], label: "GET_CLOCK")
    public static let getBattery = Request(command: WhoopCommand.getBatteryLevel.rawValue, params: [0x00], label: "GET_BATTERY_LEVEL")
    public static let bodyLocation = Request(command: WhoopCommand.getBodyLocationAndStatus.rawValue, params: [0x01], label: "GET_BODY_LOCATION")
}

extension UInt32 {
    var littleEndianBytes: [UInt8] { [UInt8(self & 0xFF), UInt8((self >> 8) & 0xFF), UInt8((self >> 16) & 0xFF), UInt8(self >> 24)] }
}

extension UInt16 {
    var littleEndianBytes: [UInt8] { [UInt8(self & 0xFF), UInt8(self >> 8)] }
}

/// Hands out 8-bit sequence numbers and frames requests.
public struct CommandSequencer: Sendable {
    private var seq: UInt8 = 0
    public init() {}

    public mutating func frame(_ request: CommandBody.Request) -> (seq: UInt8, frame: WhoopFrame) {
        seq = seq &+ 1
        if seq == 0 { seq = 1 }
        return (seq, WhoopFrame.command(request.command, seq: seq, params: request.params))
    }
}
