import Foundation

/// One complete WHOOP 5.0 / MG "format 1" frame.
///
/// ```
/// offset  size  field
///   0      1    0xAA start of frame
///   1      1    0x01 format
///   2      2    declared length (u16 LE) = padded body + 4 (the CRC32)
///   4      2    header fields: requests 00 01, responses commonly 01 00
///   6      2    CRC16-MODBUS over bytes [0, 6)
///   8      n    body: [packet type][…], zero-padded to a multiple of 4
///  8+n     4    CRC32 over the padded body
/// ```
/// Total frame size is `declared length + 8`. All offsets used by the parsers are
/// absolute offsets into this complete frame, matching the noop/whoop-rs docs.
public struct WhoopFrame: Equatable, Sendable {
    public static let startByte: UInt8 = 0xAA
    public static let headerSize = 8
    public static let minimumSize = 13
    public static let maximumSize = 8192

    public let bytes: [UInt8]

    /// Validates the envelope; returns nil if any check fails.
    public init?(validating bytes: [UInt8]) {
        guard WhoopFrame.validate(bytes) == .ok else { return nil }
        self.bytes = bytes
    }

    public var packetTypeRaw: UInt8 { bytes[8] }
    public var packetType: PacketType? { PacketType(rawValue: bytes[8]) }
    public var count: Int { bytes.count }
    /// Exclusive end of the body, i.e. where the CRC32 trailer starts.
    public var bodyEnd: Int { bytes.count - 4 }

    public var hex: String { bytes.hexString }

    public enum Validation: Equatable, Sendable {
        case ok, tooShort, badStart, lengthMismatch, badHeaderCRC, badBodyCRC
    }

    public static func validate(_ b: [UInt8]) -> Validation {
        guard b.count >= minimumSize else { return .tooShort }
        guard b[0] == startByte else { return .badStart }
        let declared = Int(b[2]) | Int(b[3]) << 8
        guard declared + headerSize == b.count else { return .lengthMismatch }
        let headerCRC = UInt16(b[6]) | UInt16(b[7]) << 8
        guard Checksum.crc16Modbus(b[0..<6]) == headerCRC else { return .badHeaderCRC }
        let end = b.count - 4
        let bodyCRC = b.u32(at: end)
        guard Checksum.crc32(b[8..<end]) == bodyCRC else { return .badBodyCRC }
        return .ok
    }

    /// Builds a command frame: body `[packetType][seq][command][params…]`, zero-padded to 4.
    public static func command(_ command: UInt8, seq: UInt8, params: [UInt8],
                               packetType: UInt8 = PacketType.command.rawValue) -> WhoopFrame {
        var body: [UInt8] = [packetType, seq, command] + params
        while body.count % 4 != 0 { body.append(0) }
        let declared = body.count + 4
        var frame: [UInt8] = [startByte, 0x01, UInt8(declared & 0xFF), UInt8(declared >> 8), 0x00, 0x01]
        let headerCRC = Checksum.crc16Modbus(frame)
        frame += [UInt8(headerCRC & 0xFF), UInt8(headerCRC >> 8)]
        frame += body
        let bodyCRC = Checksum.crc32(body)
        frame += [UInt8(bodyCRC & 0xFF), UInt8((bodyCRC >> 8) & 0xFF),
                  UInt8((bodyCRC >> 16) & 0xFF), UInt8(bodyCRC >> 24)]
        // A frame we build is valid by construction.
        return WhoopFrame(unchecked: frame)
    }

    private init(unchecked bytes: [UInt8]) { self.bytes = bytes }
}

// MARK: - Little-endian readers

extension Array where Element == UInt8 {
    func u8(at i: Int) -> UInt8 { self[i] }
    func u16(at i: Int) -> UInt16 { UInt16(self[i]) | UInt16(self[i + 1]) << 8 }
    func i16(at i: Int) -> Int16 { Int16(bitPattern: u16(at: i)) }
    func u32(at i: Int) -> UInt32 {
        UInt32(self[i]) | UInt32(self[i + 1]) << 8 | UInt32(self[i + 2]) << 16 | UInt32(self[i + 3]) << 24
    }
    func f32(at i: Int) -> Float { Float(bitPattern: u32(at: i)) }

    /// Space-separated uppercase hex, e.g. `AA 01 08 00`.
    public var hexString: String { map { String(format: "%02X", $0) }.joined(separator: " ") }
}

extension Array where Element == UInt8 {
    /// Parses `"AA 01 08"` / `"aa0108"` into bytes; nil on malformed input.
    public init?(hex: String) {
        let clean = hex.filter { !$0.isWhitespace }
        guard clean.count % 2 == 0 else { return nil }
        var out: [UInt8] = []
        out.reserveCapacity(clean.count / 2)
        var idx = clean.startIndex
        while idx < clean.endIndex {
            let next = clean.index(idx, offsetBy: 2)
            guard let byte = UInt8(clean[idx..<next], radix: 16) else { return nil }
            out.append(byte)
            idx = next
        }
        self = out
    }
}
