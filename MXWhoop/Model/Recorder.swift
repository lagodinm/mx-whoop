import Foundation
import Observation
import WhoopKit

/// Writes everything that streams in to CSV files under Documents/Recordings/<date>/,
/// visible in the Files app and shareable from the Live tab.
@Observable
final class Recorder {
    private(set) var isRecording = false
    private(set) var startedAt: Date?
    private(set) var lastFiles: [URL] = []
    private(set) var lineCount = 0

    @ObservationIgnored private var handles: [String: FileHandle] = [:]
    @ObservationIgnored private var directory: URL?

    private static let headers: [String: String] = [
        "heart_rate.csv": "unix_time,bpm,source",
        "rr_intervals.csv": "unix_time,rr_ms",
        "imu.csv": "unix_time,ax_g,ay_g,az_g,gx_dps,gy_dps,gz_dps",
        "optical.csv": "unix_time,raw",
        "events.csv": "unix_time,event",
        "frames.log": "unix_time channel hex",
    ]

    static var recordingsFolder: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Recordings")
    }

    func start() {
        guard !isRecording else { return }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let dir = Self.recordingsFolder.appendingPathComponent(formatter.string(from: Date()))
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for (name, header) in Self.headers {
                let url = dir.appendingPathComponent(name)
                try Data((header + "\n").utf8).write(to: url)
                let handle = try FileHandle(forWritingTo: url)
                try handle.seekToEnd()
                handles[name] = handle
            }
            directory = dir
            startedAt = Date()
            lineCount = 0
            isRecording = true
        } catch {
            handles.values.forEach { try? $0.close() }
            handles.removeAll()
        }
    }

    func stop() {
        guard isRecording else { return }
        handles.values.forEach { try? $0.close() }
        handles.removeAll()
        isRecording = false
        if let directory {
            lastFiles = Self.headers.keys.sorted().map { directory.appendingPathComponent($0) }
        }
    }

    // MARK: Writers (no-ops unless recording)

    func heartRate(_ bpm: Int, source: String) { write("heart_rate.csv", "\(unix()),\(bpm),\(source)") }
    func rr(_ ms: Double) { write("rr_intervals.csv", "\(unix()),\(Int(ms.rounded()))") }
    func event(_ name: String) { write("events.csv", "\(unix()),\(name)") }

    func imu(_ b: IMUBatch) {
        guard isRecording else { return }
        let end = Date().timeIntervalSince1970
        let n = max(b.accel.count, b.gyro.count)
        var lines = ""
        for i in 0..<n {
            let t = end - Double(n - 1 - i) / IMUBatch.sampleRate
            let a = i < b.accel.count ? b.accel[i] : SIMD3<Float>(repeating: .nan)
            let g = i < b.gyro.count ? b.gyro[i] : SIMD3<Float>(repeating: .nan)
            lines += String(format: "%.3f,%.4f,%.4f,%.4f,%.2f,%.2f,%.2f\n", t, a.x, a.y, a.z, g.x, g.y, g.z)
        }
        append("imu.csv", lines)
    }

    func optical(_ samples: [Double]) {
        guard isRecording, !samples.isEmpty else { return }
        let end = Date().timeIntervalSince1970
        let step = 1.0 / Double(samples.count)
        let lines = samples.enumerated().map { i, v in
            String(format: "%.3f,%.0f", end - Double(samples.count - 1 - i) * step, v)
        }.joined(separator: "\n")
        append("optical.csv", lines + "\n")
    }

    func log(frame: WhoopFrame, channel: String) {
        write("frames.log", "\(unix()) \(channel) \(frame.bytes.map { String(format: "%02x", $0) }.joined())")
    }

    private func unix() -> String { String(format: "%.3f", Date().timeIntervalSince1970) }

    private func write(_ file: String, _ line: String) {
        guard isRecording else { return }
        append(file, line + "\n")
    }

    private func append(_ file: String, _ text: String) {
        handles[file]?.write(Data(text.utf8))
        lineCount += 1
    }
}
