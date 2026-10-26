import Foundation

/// Checksums used by the WHOOP 5.0 / MG "format 1" envelope.
public enum Checksum {
    /// CRC-16/MODBUS: reflected polynomial 0xA001, init 0xFFFF, no final XOR.
    /// Covers frame bytes `[0, 6)`.
    public static func crc16Modbus<C: Collection>(_ bytes: C) -> UInt16 where C.Element == UInt8 {
        var crc: UInt16 = 0xFFFF
        for byte in bytes {
            crc ^= UInt16(byte)
            for _ in 0..<8 {
                crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xA001 : crc >> 1
            }
        }
        return crc
    }

    /// Standard IEEE 802.3 / zlib CRC-32 (reflected 0xEDB88320, init and final XOR 0xFFFFFFFF).
    /// Covers the padded body, frame bytes `[8, end - 4)`.
    public static func crc32<C: Collection>(_ bytes: C) -> UInt32 where C.Element == UInt8 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in bytes {
            crc = crc32Table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }

    private static let crc32Table: [UInt32] = (0..<256).map { index in
        var c = UInt32(index)
        for _ in 0..<8 {
            c = (c & 1) != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1
        }
        return c
    }
}
