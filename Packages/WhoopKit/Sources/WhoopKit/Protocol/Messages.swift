import Foundation

/// Live heart rate + beat-to-beat intervals (packet 40).
public struct RealtimeHeartRate: Equatable, Sendable {
    /// Strap clock, Unix seconds.
    public let strapTime: UInt32
    public let bpm: Int
    /// R-R intervals in milliseconds, oldest first. Often empty during motion even
    /// when `bpm` is valid — WHOOP reports them independently.
    public let rrIntervalsMs: [Double]
    /// Worn flag (WHOOP app: payload byte 18). nil when the packet is not the compact form.
    public let onWrist: Bool?
}

/// 100 Hz six-axis IMU buffer (record layout 21, ICM-45686).
public struct IMUBatch: Equatable, Sendable {
    public static let sampleRate = 100.0
    /// Strap clock: Unix seconds + 1/32768 s fraction, time of the first sample.
    public let strapTime: Double
    /// Acceleration in g (raw / 4096, the ±8 g convention used by noop/dofek).
    public let accel: [SIMD3<Float>]
    /// Angular rate in °/s (raw × 2000 / 32768).
    public let gyro: [SIMD3<Float>]
}

/// Raw optical (PPG) samples, uncalibrated ADC counts. Experimental: WHOOP does not
/// document which LED/wavelength a slot represents.
public struct OpticalWindow: Equatable, Sendable {
    public let strapTime: UInt32
    public let layout: UInt8
    public let samples: [Double]
    /// Nominal sample rate of `samples`.
    public let sampleRate: Double
}

public struct CommandResponse: Equatable, Sendable {
    public let command: UInt8
    /// Sequence number of the request this answers (frame offset 11).
    public let originSeq: UInt8
    public let resultRaw: UInt8
    public let body: [UInt8]

    public var result: CommandResult? { CommandResult(rawValue: resultRaw) }
    public var commandName: String { WhoopCommand(rawValue: command)?.name ?? "cmd \(command)" }
}

public struct StrapEvent: Equatable, Sendable {
    public let number: UInt8
    public let strapTime: UInt32

    public var name: String { StrapEvent.names[number] ?? "EVENT_\(number)" }

    public static let wristOn: UInt8 = 9
    public static let wristOff: UInt8 = 10
    public static let doubleTap: UInt8 = 14

    static let names: [UInt8: String] = [
        1: "ERROR", 3: "BATTERY_LEVEL", 7: "CHARGING_ON", 8: "CHARGING_OFF",
        9: "WRIST_ON", 10: "WRIST_OFF", 11: "BLE_CONNECTION_UP", 12: "BLE_CONNECTION_DOWN",
        13: "RTC_LOST", 14: "DOUBLE_TAP", 15: "BOOT", 16: "SET_RTC", 17: "TEMPERATURE_LEVEL",
        18: "PAIRING_MODE", 23: "BLE_BONDED", 24: "BLE_HR_PROFILE_ENABLED", 25: "BLE_HR_PROFILE_DISABLED",
        33: "BLE_REALTIME_HR_ON", 34: "BLE_REALTIME_HR_OFF", 46: "RAW_DATA_COLLECTION_ON",
        47: "RAW_DATA_COLLECTION_OFF", 60: "HAPTICS_FIRED", 100: "HAPTICS_TERMINATED",
    ]
}

/// Decoded GET_HELLO (145) final response.
public struct HelloInfo: Equatable, Sendable {
    public let revision: UInt8
    public let batteryPercent: Double
    public let strapTime: UInt32
    public let firmware: String
    public let preparationBits: UInt32
}

/// Everything the parser can produce from one frame.
public enum WhoopMessage: Equatable, Sendable {
    case realtimeHR(RealtimeHeartRate)
    case imu(IMUBatch)
    case optical(OpticalWindow)
    case commandResponse(CommandResponse)
    case event(StrapEvent)
    case consoleLog(String)
    case metadata(packetType: UInt8, kind: UInt8)
    /// A valid frame we don't decode (history records, ECG, unknown layouts…).
    case other(packetType: UInt8, layout: UInt8)
}

/// Standard Bluetooth Heart Rate Measurement (0x2A37). Works without a bond and is
/// the fallback HR/R-R source when the custom service is unavailable.
public struct StandardHeartRate: Equatable, Sendable {
    public let bpm: Int
    public let rrIntervalsMs: [Double]
    /// nil when the sensor doesn't report contact.
    public let sensorContact: Bool?

    public init?(_ d: [UInt8]) {
        guard d.count >= 2 else { return nil }
        let flags = d[0]
        var i = 1
        if flags & 0x01 != 0 {
            guard d.count >= 3 else { return nil }
            bpm = Int(d.u16(at: 1)); i = 3
        } else {
            bpm = Int(d[1]); i = 2
        }
        sensorContact = (flags & 0x04) != 0 ? (flags & 0x02) != 0 : nil
        if flags & 0x08 != 0 { i += 2 } // energy expended
        var rr: [Double] = []
        if flags & 0x10 != 0 {
            while i + 1 < d.count {
                let ticks = d.u16(at: i)
                if ticks > 0 { rr.append(Double(ticks) * 1000.0 / 1024.0) }
                i += 2
            }
        }
        rrIntervalsMs = rr
    }
}
