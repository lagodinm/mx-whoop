import Foundation

/// GATT identifiers for the WHOOP 5.0 / MG ("Maverick/Goose") family.
///
/// Kept as plain strings so this package never imports CoreBluetooth; the app
/// turns them into `CBUUID`s.
///
/// Sources: dofek `docs/whoop-ble-protocol.md`, noop `PROTOCOL_WHOOP5.md`,
/// whoop-rs `src/protocol/gatt.rs`, and the decompiled WHOOP Android app.
public enum WhoopGATT {
    /// Custom WHOOP 5.0 / MG service.
    public static let service = "FD4B0001-CCE1-4033-93CE-002D5875F58A"
    /// Phone → strap command frames (write with response).
    public static let commandWrite = "FD4B0002-CCE1-4033-93CE-002D5875F58A"
    /// Strap → phone command responses.
    public static let commandNotify = "FD4B0003-CCE1-4033-93CE-002D5875F58A"
    /// Strap → phone events (wrist on/off, double tap, battery…).
    public static let eventNotify = "FD4B0004-CCE1-4033-93CE-002D5875F58A"
    /// Strap → phone data (realtime HR, raw IMU, history). Frames can span notifications.
    public static let dataNotify = "FD4B0005-CCE1-4033-93CE-002D5875F58A"
    /// Strap → phone Memfault diagnostics.
    public static let memfaultNotify = "FD4B0007-CCE1-4033-93CE-002D5875F58A"

    public static let notifyCharacteristics = [commandNotify, eventNotify, dataNotify, memfaultNotify]

    /// Older generations, used only so the scanner can recognise (and reject) them.
    public static let whoop4Service = "61080001-8D6D-82B8-614A-1C8CB0F8DCC6"

    // Standard Bluetooth SIG services the strap also exposes.
    public static let heartRateService = "180D"
    /// Heart Rate Measurement: HR + R-R at ~1 Hz. Readable without a bond.
    public static let heartRateMeasurement = "2A37"
    public static let batteryService = "180F"
    public static let batteryLevel = "2A19"
    public static let deviceInfoService = "180A"
    public static let modelNumber = "2A24"
    public static let serialNumber = "2A25"
    public static let firmwareRevision = "2A26"
    public static let hardwareRevision = "2A27"
    public static let manufacturerName = "2A29"
}

/// WHOOP 5.0 vs MG. MG carries the ECG-capable clasp; the wire protocol is shared.
public enum WhoopVariant: String, Sendable {
    case mg = "WHOOP MG"
    case whoop5 = "WHOOP 5.0"
    case unknown = "WHOOP (unidentified)"

    /// Device Information heuristics from noop `PROTOCOL_WHOOP5.md`. Not a universal rule:
    /// an unrecognised serial does not prove the strap lacks MG hardware.
    public static func resolve(model: String?, serial: String?, hardwareRevision: String?) -> WhoopVariant {
        if model?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() == "MG" { return .mg }
        let isMGSerial = serial?.uppercased().hasPrefix("5AM") == true
        let is50Signal = serial?.uppercased().hasPrefix("5AG") == true
            || hardwareRevision?.uppercased().contains("WG50") == true
        if isMGSerial && !is50Signal { return .mg }
        if is50Signal && !isMGSerial { return .whoop5 }
        return .unknown
    }
}
