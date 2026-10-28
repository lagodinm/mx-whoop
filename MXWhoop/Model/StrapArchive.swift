import Foundation
import WhoopKit

/// One minute of the strap's own per-second summaries.
struct MinuteBin: Identifiable, Equatable {
    let minute: Int            // Unix minutes
    var skinTemp: Double?
    var heartRate: Double?
    var steps: Int
    /// Share of the minute's records whose strap state was SLEEP.
    var sleepShare: Double
    var id: Int { minute }
    var date: Date { Date(timeIntervalSince1970: TimeInterval(minute * 60)) }
}

/// Keeps every one-second summary record this app sees in daily CSV files
/// (Documents/StrapArchive/strap-YYYY-MM-DD.csv) and per-minute bins for charts.
/// Records reach the app whenever the WHOOP app syncs while this app is connected, including
/// in the background, so the archive fills in over the day and night.
final class StrapArchive {
    static let header = "unix_time,record_index,bpm,rr_ms,skin_temp_c,aux1_c,aux2_c,steps_counter,activity,band_state,b82_raw,alt_hr"

    private struct Accumulator {
        var tempSum = 0.0, tempN = 0, hrSum = 0.0, hrN = 0, steps = 0, sleep = 0, n = 0
    }

    private var bins: [Int: Accumulator] = [:]
    private var lastSteps: (time: UInt32, counter: UInt16)?
    private var handle: FileHandle?
    private var handleDay: String?
    private let queue = DispatchQueue(label: "strap-archive", qos: .utility)

    static var folder: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("StrapArchive")
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func file(for day: String) -> URL { folder.appendingPathComponent("strap-\(day).csv") }

    var files: [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: Self.folder, includingPropertiesForKeys: nil)) ?? []
        return urls.filter { $0.pathExtension == "csv" }.sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    // MARK: Writing

    func append(_ r: BiometricRecord) {
        addToBins(unix: r.unixTime, bpm: Double(r.bpm), skin: r.skinTempC, steps: r.steps, sleeping: r.bandState == .sleep)
        let line = Self.line(r)
        let day = Self.dayFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(r.unixTime)))
        queue.async { [weak self] in self?.write(line, day: day) }
    }

    private func write(_ line: String, day: String) {
        if handleDay != day {
            try? handle?.close()
            handle = nil
            let url = Self.file(for: day)
            try? FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: url.path) {
                try? Data((Self.header + "\n").utf8).write(to: url)
            }
            handle = try? FileHandle(forWritingTo: url)
            _ = try? handle?.seekToEnd()
            handleDay = day
        }
        handle?.write(Data((line + "\n").utf8))
    }

    private static func line(_ r: BiometricRecord) -> String {
        func c(_ v: Double?) -> String { v.map { String(format: "%.2f", $0) } ?? "" }
        let rr = r.rrIntervalsMs.map { String(Int($0)) }.joined(separator: ";")
        let activity = r.activity.map { "\($0)" } ?? ""
        return "\(r.unixTime),\(r.recordIndex),\(r.bpm),\(rr),\(c(r.skinTempC)),\(c(r.auxTemp1C)),\(c(r.auxTemp2C)),\(r.steps),\(activity),\(r.bandState),\(r.extras.spo2CandidateRaw),\(r.extras.alternateHR)"
    }

    // MARK: Bins

    private func addToBins(unix: UInt32, bpm: Double, skin: Double?, steps: UInt16, sleeping: Bool) {
        let minute = Int(unix / 60)
        var a = bins[minute] ?? Accumulator()
        a.n += 1
        if let skin { a.tempSum += skin; a.tempN += 1 }
        if bpm > 0 { a.hrSum += bpm; a.hrN += 1 }
        if sleeping { a.sleep += 1 }
        if let last = lastSteps, unix > last.time, unix - last.time < 120 {
            let delta = Int(steps &- last.counter)
            if delta < 300 { a.steps += delta }
        }
        lastSteps = (unix, steps)
        bins[minute] = a
    }

    /// Minute bins covering the last `hours` hours, oldest first.
    func recentBins(hours: Double = 24) -> [MinuteBin] {
        let cutoff = Int(Date().timeIntervalSince1970 / 60) - Int(hours * 60)
        bins = bins.filter { $0.key >= cutoff - 60 }
        let recent = bins.filter { $0.key >= cutoff }.sorted { $0.key < $1.key }
        return recent.map { item in
            let a = item.value
            return MinuteBin(minute: item.key,
                             skinTemp: a.tempN > 0 ? a.tempSum / Double(a.tempN) : nil,
                             heartRate: a.hrN > 0 ? a.hrSum / Double(a.hrN) : nil,
                             steps: a.steps,
                             sleepShare: a.n > 0 ? Double(a.sleep) / Double(a.n) : 0)
        }
    }

    /// Rebuilds the bins from today's and yesterday's files (off the main thread).
    func load(completion: @escaping () -> Void) {
        let today = Date()
        let days = [today.addingTimeInterval(-86_400), today].map { Self.dayFormatter.string(from: $0) }
        queue.async { [weak self] in
            var rows: [(UInt32, Double, Double?, UInt16, Bool)] = []
            for day in days {
                guard let text = try? String(contentsOf: Self.file(for: day), encoding: .utf8) else { continue }
                for line in text.split(separator: "\n").dropFirst() {
                    let f = line.split(separator: ",", omittingEmptySubsequences: false)
                    guard f.count >= 10, let unix = UInt32(f[0]), let bpm = Double(f[2]), let steps = UInt16(f[7]) else { continue }
                    rows.append((unix, bpm, Double(f[4]), steps, f[9] == "sleep"))
                }
            }
            rows.sort { $0.0 < $1.0 }
            DispatchQueue.main.async {
                guard let self else { return }
                let live = self.bins
                self.bins = [:]
                self.lastSteps = nil
                for r in rows { self.addToBins(unix: r.0, bpm: r.1, skin: r.2, steps: r.3, sleeping: r.4) }
                // Anything that arrived while loading is already in the files and was re-read.
                if self.bins.isEmpty { self.bins = live }
                completion()
            }
        }
    }
}
