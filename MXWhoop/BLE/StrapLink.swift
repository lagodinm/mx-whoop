import Foundation
import WhoopKit

/// Connection lifecycle, as shown in the UI.
enum LinkState: Equatable {
    case unavailable(String)   // Bluetooth off / unauthorised / unsupported
    case idle
    case scanning
    case connecting(String)
    /// Connected; GET_HELLO written. iOS shows its pairing prompt here the first time.
    case handshaking
    case streaming
    case failed(String)

    var label: String {
        switch self {
        case .unavailable(let why): why
        case .idle: "Not connected"
        case .scanning: "Searching for strap…"
        case .connecting(let name): "Connecting to \(name)…"
        case .handshaking: "Securing link (pairing)…"
        case .streaming: "Streaming"
        case .failed(let why): why
        }
    }

    var isConnected: Bool { self == .handshaking || self == .streaming }
    var isBusy: Bool {
        switch self {
        case .scanning, .connecting, .handshaking: true
        default: false
        }
    }
}

/// Which notify characteristic a frame arrived on.
enum LinkChannel: String {
    case command = "CMD", event = "EVT", data = "DATA", memfault = "MFLT", demo = "DEMO"
}

enum LinkEvent {
    case state(LinkState)
    case frame(WhoopFrame, LinkChannel)
    case corruptFrame([UInt8], WhoopFrame.Validation, LinkChannel)
    case standardHR(StandardHeartRate)
    case battery(Int)
    case deviceInfo(key: String, value: String)
    case peripheral(name: String)
    case commandSent(label: String, seq: UInt8, frame: WhoopFrame)
    case log(String)
}

/// A source of strap frames: the real Bluetooth client or the demo simulator.
protocol StrapLink: AnyObject {
    var onEvent: ((LinkEvent) -> Void)? { get set }
    func connect()
    func disconnect()
    func send(_ request: CommandBody.Request)
}
