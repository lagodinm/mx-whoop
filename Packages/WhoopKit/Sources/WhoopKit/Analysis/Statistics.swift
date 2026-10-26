import Foundation

/// A timestamped scalar. `t` is seconds on any monotonic base (the app uses
/// `Date.timeIntervalSinceReferenceDate`).
public struct TimedValue: Equatable, Codable, Sendable {
    public var t: Double
    public var v: Double
    public init(t: Double, v: Double) { self.t = t; self.v = v }
}

public enum Stats {
    public static func mean(_ x: [Double]) -> Double? {
        x.isEmpty ? nil : x.reduce(0, +) / Double(x.count)
    }

    /// Sample standard deviation (n − 1).
    public static func std(_ x: [Double]) -> Double? {
        guard x.count >= 2, let m = mean(x) else { return nil }
        return (x.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Double(x.count - 1)).squareRoot()
    }

    public static func median(_ x: [Double]) -> Double? {
        guard !x.isEmpty else { return nil }
        let s = x.sorted()
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }

    /// Centred moving average; output has the same length as the input.
    public static func movingAverage(_ x: [Double], window: Int) -> [Double] {
        guard window > 1, x.count > 1 else { return x }
        let h = window / 2
        return x.indices.map { i in
            let lo = max(0, i - h), hi = min(x.count - 1, i + h)
            return x[lo...hi].reduce(0, +) / Double(hi - lo + 1)
        }
    }

    public static func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double { min(max(v, lo), hi) }

    public static func sigmoid(_ x: Double) -> Double { 1 / (1 + exp(-x)) }
}

extension Array where Element == TimedValue {
    /// Values with `lo <= t < hi`. Assumes ascending `t` (binary search).
    public func values(from lo: Double, to hi: Double) -> [Double] {
        slice(from: lo, to: hi).map(\.v)
    }

    public func slice(from lo: Double, to hi: Double) -> ArraySlice<TimedValue> {
        let start = firstIndex(atOrAfter: lo)
        let end = firstIndex(atOrAfter: hi)
        return start < end ? self[start..<end] : []
    }

    func firstIndex(atOrAfter t: Double) -> Int {
        var lo = 0, hi = count
        while lo < hi {
            let mid = (lo + hi) / 2
            if self[mid].t < t { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    /// Drops samples older than `t` (amortised: only when at least 256 are stale).
    public mutating func trim(before t: Double) {
        let i = firstIndex(atOrAfter: t)
        if i >= 256 || i == count { removeFirst(i) }
    }
}
