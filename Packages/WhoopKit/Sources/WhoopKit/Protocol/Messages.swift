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
    /// Repeats every interval while high-frequency sync is on; the official app answers
    /// each one with a sync.
    public static let highFreqSyncPrompt: UInt8 = 96
    public static let highFreqSyncEnabled: UInt8 = 97
    public static let highFreqSyncDisabled: UInt8 = 98

    static let names: [UInt8: String] = [
        1: "ERROR", 3: "BATTERY_LEVEL", 7: "CHARGING_ON", 8: "CHARGING_OFF",
        9: "WRIST_ON", 10: "WRIST_OFF", 11: "BLE_CONNECTION_UP", 12: "BLE_CONNECTION_DOWN",
        13: "RTC_LOST", 14: "DOUBLE_TAP", 15: "BOOT", 16: "SET_RTC", 17: "TEMPERATURE_LEVEL",
        18: "PAIRING_MODE", 23: "BLE_BONDED", 24: "BLE_HR_PROFILE_ENABLED", 25: "BLE_HR_PROFILE_DISABLED",
        33: "BLE_REALTIME_HR_ON", 34: "BLE_REALTIME_HR_OFF", 46: "RAW_DATA_COLLECTION_ON",
        47: "RAW_DATA_COLLECTION_OFF", 60: "HAPTICS_FIRED", 63: "EXTENDED_BATTERY_INFORMATION",
        96: "HIGH_FREQ_SYNC_PROMPT", 97: "HIGH_FREQ_SYNC_ENABLED", 98: "HIGH_FREQ_SYNC_DISABLED",
        100: "HAPTICS_TERMINATED",
    ]
}

/// The strap's own one-second summary: history record layout 18, a 124-byte frame.
///
/// WHOOP 5/MG firmware writes its skin-temperature reading (AS6221 sensor), hardware step
/// counter and motion/rest state only here. These records reach the phone during a history
/// sync; there is no live command that returns the temperature. Offsets follow noop
/// `PROTOCOL_SENSORS.md` (R18) and were checked against a real WHOOP 5 capture.
public struct BiometricRecord: Equatable, Sendable {
    public enum Activity: UInt8, Sendable { case still = 0, walk = 1, run = 2 }
    /// Band motion/rest classifier, `(byte 81 >> 4) & 3`. Not a sleep-stage label.
    public enum BandState: UInt8, Sendable { case wake = 0, still = 1, sleep = 2, up = 3 }

    public let recordIndex: UInt32
    /// When the strap measured it: Unix seconds on the strap clock.
    public let unixTime: UInt32
    public let bpm: Int
    public let rrIntervalsMs: [Double]
    /// Skin temperature in °C (`u16 / 100` at 73); nil outside 5–45 °C.
    public let skinTempC: Double?
    /// Auxiliary thermal channels (`i16 / 10` °C at 69 and 71); nil outside 0–60 °C.
    /// Which physical sensors feed them is not established.
    public let auxTemp1C: Double?
    public let auxTemp2C: Double?
    /// Gravity-removed acceleration magnitude, g.
    public let dynamicAccelG: Double?
    public let gravity: SIMD3<Float>?
    /// Cumulative hardware step counter. Wraps at 65 536; not a daily total.
    public let steps: UInt16
    /// nil when the strap reports any other class (0xFF).
    public let activity: Activity?
    public let bandState: BandState
    public let qualityFlags: UInt8
}

/// One MG ECG record: layout 17 (filtered, i16) or 16 (raw, 18-bit). Amplitude is in the
/// strap's native units and the sample rate is undocumented, so the app estimates it from
/// arrival times. Offsets: noop `PROTOCOL_ECG.md`, whoop-rs `parse/records.rs`.
public struct ECGRecord: Equatable, Sendable {
    public let layout: UInt8
    /// Packet 43 (live) rather than 47 (replayed by a sync).
    public let isLive: Bool
    public let sequence: UInt32
    /// Byte 21; observed 0–3, vocabulary unresolved.
    public let quality: UInt8
    /// Byte 22: classifier-state transition bits, bit 3 = presence.
    public let statusBits: UInt8
    public let classifierResult: UInt8
    public let classifierState: UInt8
    /// Byte 25, percentage-like session progress.
    public let progress: UInt8
    /// Byte 27, an HR-related classifier value.
    public let strapHRValue: UInt8
    public let samples: [Int32]

    public var isFiltered: Bool { layout == 17 }
    /// The strap's presence indication (finger on the electrode, as far as is known).
    public var presence: Bool { statusBits & 0x08 != 0 }
}

/// GET_DATA_RANGE (34) final body: positions in the strap's history ring and page clocks.
public struct DataRange: Equatable, Sendable {
    public let readPage: UInt32
    public let writePage: UInt32
    /// Everything before this page has been acknowledged by a sync.
    public let trimPage: UInt32
    public let capacity: UInt32
    /// The strap's own estimate of records not yet synced.
    public let recordEstimate: UInt32
    /// Clock of the oldest record not yet acknowledged (Unix s), when the strap reports a valid one.
    public let oldestUnsyncedTime: UInt32?
    /// Clock of the newest written page (Unix s).
    public let newestTime: UInt32?

    /// Pages written but not yet acknowledged by any sync.
    public var pagesBehind: UInt32 {
        writePage >= trimPage ? writePage - trimPage : writePage &+ capacity &- trimPage
    }
}

/// History stream markers (packet 49, kind at frame offset 10).
public enum HistoryMarker: UInt8, Sendable {
    case start = 1, end = 2, complete = 3
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
    /// A stored one-second summary passing by during a history sync.
    case biometric(BiometricRecord)
    case ecg(ECGRecord)
    case commandResponse(CommandResponse)
    case event(StrapEvent)
    case consoleLog(String)
    case metadata(packetType: UInt8, kind: UInt8)
    /// A valid frame we don't decode (other history layouts, unknown types…).
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
