import Foundation
import Observation
import WhoopKit

/// Read-only look inside the strap: its named settings and feature flags, the haptic alarm
/// slots the WHOOP app scheduled, the MG battery pack, clock drift and gyro mode.
///
/// Every command used here is a read. Settings are looked up **by name** (121/128), never
/// through the enumeration commands, whose shared cursor the official app also uses.
@Observable
final class StrapInternals {
    private(set) var values: [String: ConfigValue] = [:]   // keyed by ConfigCatalog.Entry.id
    private(set) var alarms: [UInt8: AlarmSlot] = [:]
    private(set) var batteryPack: BatteryPackInfo?
    /// Strap clock minus iPhone clock, seconds (includes ~0.1 s of radio latency).
    private(set) var clockOffset: Double?
    private(set) var gyroMode: UInt8?
    private(set) var lastRead: Date?
    private(set) var pending = 0

    @ObservationIgnored var send: ((CommandBody.Request) -> Void)?

    static func valueKey(_ key: String, featureFlag: Bool) -> String { (featureFlag ? "ff:" : "cfg:") + key }

    func readAll() {
        values = [:]; alarms = [:]
        var requests: [CommandBody.Request] = ConfigCatalog.all.map { CommandBody.readConfig($0.key, featureFlag: $0.isFeatureFlag) }
        requests += (1...6).map { CommandBody.alarm(slot: UInt8($0)) }
        requests += [CommandBody.batteryPack, CommandBody.getClock, CommandBody.gyroMode]
        pending = requests.count
        lastRead = Date()
        requests.forEach { send?($0) }
    }

    func reset() {
        values = [:]; alarms = [:]; batteryPack = nil; clockOffset = nil; gyroMode = nil; lastRead = nil; pending = 0
    }

    /// Any response, ours or the WHOOP app's: a read is a read.
    func handle(_ r: CommandResponse, ours: Bool) {
        let mine: Set<UInt8> = [WhoopCommand.getDeviceConfigValue.rawValue, WhoopCommand.getFeatureFlagValue.rawValue,
                                WhoopCommand.getAlarmTime.rawValue, WhoopCommand.getBatteryPackInfo.rawValue,
                                WhoopCommand.getClock.rawValue, WhoopCommand.getGyroMode.rawValue]
        guard mine.contains(r.command), r.result != .pending else { return }
        if ours, pending > 0 { pending -= 1 }
        if let v = WhoopParser.configValue(r) {
            values[Self.valueKey(v.key, featureFlag: v.isFeatureFlag)] = v
        } else if let a = WhoopParser.alarm(r) {
            alarms[a.id] = a
        } else if let p = WhoopParser.batteryPack(r) {
            batteryPack = p
        } else if let t = WhoopParser.clock(r) {
            clockOffset = t - Date().timeIntervalSince1970
        } else if let g = WhoopParser.gyroMode(r) {
            gyroMode = g
        }
    }
}
