import Foundation

/// Reassembles complete frames from BLE notifications.
///
/// Large records (a 1,244-byte IMU buffer, a 2,140-byte optical block) arrive split
/// across several notifications, and a single notification may also carry the tail
/// of one frame plus the head of the next. Keep one assembler per notify
/// characteristic.
///
/// Algorithm (same as whoop-rs `framing.rs`): find 0xAA, read the declared length,
/// confirm the header CRC16 before trusting that length, wait for the full frame,
/// then emit it. A bad header means a false start byte: skip one byte and resync.
public struct FrameAssembler: Sendable {
    public enum Output: Equatable, Sendable {
        case frame(WhoopFrame)
        /// Structurally complete but failed CRC32 — surfaced for diagnostics.
        case corrupt([UInt8], WhoopFrame.Validation)
    }

    private var buffer: [UInt8] = []
    public private(set) var discardedBytes = 0

    public init() {}

    public mutating func reset() { buffer.removeAll(keepingCapacity: true) }

    public mutating func append(_ chunk: [UInt8]) -> [Output] {
        buffer += chunk
        var out: [Output] = []
        var start = 0
        scan: while true {
            // 1. Seek the start byte.
            guard let sof = buffer[start...].firstIndex(of: WhoopFrame.startByte) else {
                discardedBytes += buffer.count - start
                start = buffer.count
                break scan
            }
            discardedBytes += sof - start
            start = sof
            let available = buffer.count - start
            // 2. Need the full 8-byte header to check the CRC16.
            guard available >= WhoopFrame.headerSize else { break scan }
            let declared = Int(buffer[start + 2]) | Int(buffer[start + 3]) << 8
            let total = declared + WhoopFrame.headerSize
            let headerCRC = UInt16(buffer[start + 6]) | UInt16(buffer[start + 7]) << 8
            guard buffer[start + 1] == 0x01,
                  total >= WhoopFrame.minimumSize, total <= WhoopFrame.maximumSize,
                  Checksum.crc16Modbus(buffer[start..<(start + 6)]) == headerCRC else {
                // False start byte — resync one byte later.
                discardedBytes += 1
                start += 1
                continue scan
            }
            // 3. Wait until the whole frame has arrived.
            guard available >= total else { break scan }
            let candidate = Array(buffer[start..<(start + total)])
            if let frame = WhoopFrame(validating: candidate) {
                out.append(.frame(frame))
            } else {
                out.append(.corrupt(candidate, WhoopFrame.validate(candidate)))
            }
            start += total
        }
        if start > 0 { buffer.removeFirst(start) }
        // Guard against unbounded growth from a stream we never manage to sync on.
        if buffer.count > WhoopFrame.maximumSize * 2 {
            discardedBytes += buffer.count
            buffer.removeAll(keepingCapacity: true)
        }
        return out
    }
}
