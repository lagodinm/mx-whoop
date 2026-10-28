import Foundation

/// The named settings WHOOP 5/MG firmware 50.42.1.0 accepts for lookup (noop
/// `PROTOCOL_CONFIGURATION.md`). This app only *reads* them (commands 121/128); it never
/// writes settings. Notes say what is known, and say so when it isn't.
public enum ConfigCatalog {
    public struct Entry: Identifiable, Sendable {
        public let key: String
        public let isFeatureFlag: Bool
        public let note: String
        public var id: String { (isFeatureFlag ? "ff:" : "cfg:") + key }
    }

    public static let deviceKeys: [Entry] = [
        .init(key: "sigproc_wear_detect", isFeatureFlag: false, note: "Wear-detection setting (tri-state)."),
        .init(key: "enable_rfid", isFeatureFlag: false, note: "RFID setting; effect and polarity unknown."),
        .init(key: "max_collection_backlog", isFeatureFlag: false,
              note: "Collection capacity % (tenths) above which continuous collection is switched off."),
        .init(key: "cont_collection_mode", isFeatureFlag: false,
              note: "Continuous collection: 0 none, 1 optical + IMU."),
        .init(key: "whoop_live_hr_in_adv_ind_pkt", isFeatureFlag: false,
              note: "1 = live HR in the Bluetooth advertisement (HR broadcast preference)."),
        .init(key: "whoop_live_2_hrm_devices", isFeatureFlag: false,
              note: "1 = prefer two heart-rate-monitor connections."),
        .init(key: "enable_raw_data_w_ecg", isFeatureFlag: false,
              note: "Companion raw optical/IMU during ECG: 0/1 = on, 2 = off."),
        .init(key: "dorset_detection_period_min", isFeatureFlag: false,
              note: "Detection period; 0 falls back to 5. Units not established."),
    ]

    public static let featureFlags: [Entry] = [
        .init(key: "enable_r22_packets", isFeatureFlag: true, note: "History layout 22 (queued optical) master: 1 permits."),
        .init(key: "enable_r22_v2_packets", isFeatureFlag: true, note: "R22 version 2 preference."),
        .init(key: "enable_r22_v3_packets", isFeatureFlag: true, note: "R22 version 3 preference."),
        .init(key: "enable_r22_v4_packets", isFeatureFlag: true, note: "R22 version 4 preference."),
        .init(key: "enable_r22_v5_packets", isFeatureFlag: true, note: "R22 version 5 preference."),
        .init(key: "enable_r22_v6_packets", isFeatureFlag: true, note: "R22 version 6 preference."),
        .init(key: "enable_r22_v8_packets", isFeatureFlag: true, note: "R22 version 8 preference (semantics unresolved)."),
        .init(key: "enable_r22_v9_packets", isFeatureFlag: true, note: "R22 version 9 preference."),
        .init(key: "make_hrfm_visible", isFeatureFlag: true, note: "Unresolved."),
        .init(key: "disable_pip_r26_packets", isFeatureFlag: true,
              note: "Inverse: 1 removes compact optical records (layout 26) from history."),
        .init(key: "wear_detect_bias", isFeatureFlag: true, note: "Wear-detection processing; 1 = on."),
        .init(key: "hr_ch_switching", isFeatureFlag: true, note: "Enables alternate HR-channel selection (R18 bits 4/5)."),
        .init(key: "ir_hw_switching", isFeatureFlag: true, note: "Infrared hardware switching; 1 = on."),
        .init(key: "enable_passive_strap_fit_gen5", isFeatureFlag: true, note: "Passive strap-fit detection."),
        .init(key: "dorset_inhibit_wpt", isFeatureFlag: true, note: "Unresolved (wireless power?)."),
        .init(key: "enable_frizzle_burst_mode", isFeatureFlag: true, note: "Unresolved processing mode; 1 = on."),
        .init(key: "ir_1x_enable", isFeatureFlag: true, note: "Infrared 1× mode; 1 = on."),
        .init(key: "enable_rocky_again", isFeatureFlag: true, note: "Changing it re-initialises processing. Unresolved."),
        .init(key: "project_drawbridge", isFeatureFlag: true, note: "Conditional gate around buffered submission. Unresolved."),
        .init(key: "wear_detect_fast_event", isFeatureFlag: true, note: "Faster wear events; 1 = on."),
    ]

    public static var all: [Entry] { deviceKeys + featureFlags }
}
