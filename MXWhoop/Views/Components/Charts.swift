import Charts
import SwiftUI
import WhoopKit

private func date(_ t: Double) -> Date { Date(timeIntervalSinceReferenceDate: t) }

/// Heart rate over the last few minutes.
struct HeartRateChart: View {
    let samples: [TimedValue]
    var window: Double = 300

    var body: some View {
        let now = Date().timeIntervalSinceReferenceDate
        let points = samples.slice(from: now - window, to: now + 1)
        let low = (points.map(\.v).min() ?? 0) - 3
        Chart(points, id: \.t) { p in
            AreaMark(x: .value("Time", date(p.t)), yStart: .value("Low", low), yEnd: .value("BPM", p.v))
                .foregroundStyle(LinearGradient(colors: [Theme.heart.opacity(0.35), .clear], startPoint: .top, endPoint: .bottom))
                .interpolationMethod(.catmullRom)
            LineMark(x: .value("Time", date(p.t)), y: .value("BPM", p.v))
                .foregroundStyle(Theme.heart)
                .lineStyle(StrokeStyle(lineWidth: 2))
                .interpolationMethod(.catmullRom)
        }
        .chartYScale(domain: .automatic(includesZero: false))
        .chartXScale(domain: date(now - window)...date(now))
        .chartXAxis { AxisMarks(values: .automatic(desiredCount: 4)) }
        .overlay { if points.isEmpty { EmptyChartLabel(text: "No heart-rate data yet") } }
        .frame(height: 150)
    }
}

/// Beat-to-beat (R-R) tachogram.
struct RRChart: View {
    let beats: [TimedValue]
    var window: Double = 120

    var body: some View {
        let now = Date().timeIntervalSinceReferenceDate
        let points = beats.slice(from: now - window, to: now + 1)
        Chart(points, id: \.t) { p in
            LineMark(x: .value("Time", date(p.t)), y: .value("R-R (ms)", p.v))
                .foregroundStyle(Theme.accent.opacity(0.6))
                .interpolationMethod(.monotone)
            PointMark(x: .value("Time", date(p.t)), y: .value("R-R (ms)", p.v))
                .foregroundStyle(Theme.accent)
                .symbolSize(10)
        }
        .chartYScale(domain: .automatic(includesZero: false))
        .chartXScale(domain: date(now - window)...date(now))
        .chartXAxis { AxisMarks(values: .automatic(desiredCount: 4)) }
        .overlay { if points.isEmpty { EmptyChartLabel(text: "No R-R intervals yet") } }
        .frame(height: 130)
    }
}

/// Last few seconds of 3-axis acceleration (decimated to 25 Hz).
struct AccelChart: View {
    let points: [AccelPoint]

    var body: some View {
        Chart {
            ForEach(points) { p in
                LineMark(x: .value("Time", p.date), y: .value("g", p.x), series: .value("Axis", "X"))
                    .foregroundStyle(by: .value("Axis", "X"))
                LineMark(x: .value("Time", p.date), y: .value("g", p.y), series: .value("Axis", "Y"))
                    .foregroundStyle(by: .value("Axis", "Y"))
                LineMark(x: .value("Time", p.date), y: .value("g", p.z), series: .value("Axis", "Z"))
                    .foregroundStyle(by: .value("Axis", "Z"))
            }
        }
        .chartForegroundStyleScale(["X": Theme.heart, "Y": Theme.truth, "Z": Theme.motion])
        .chartXAxis(.hidden)
        .chartLegend(position: .top, alignment: .trailing)
        .overlay { if points.isEmpty { EmptyChartLabel(text: "Turn on Raw IMU to stream 100 Hz motion") } }
        .frame(height: 130)
    }
}

/// Raw optical samples (uncalibrated).
struct OpticalChart: View {
    let samples: [Double]

    var body: some View {
        Chart(Array(samples.enumerated()), id: \.offset) { item in
            LineMark(x: .value("Sample", item.offset), y: .value("Raw", item.element))
                .foregroundStyle(Theme.warning)
                .interpolationMethod(.catmullRom)
        }
        .chartYScale(domain: .automatic(includesZero: false))
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .overlay { if samples.isEmpty { EmptyChartLabel(text: "No optical packets (experimental on WHOOP 5/MG)") } }
        .frame(height: 90)
    }
}

/// Skin temperature by measurement time (points arrive in bursts, whenever a sync runs).
struct TemperatureChart: View {
    let points: [TimedValue]

    var body: some View {
        Chart(points, id: \.t) { p in
            LineMark(x: .value("Time", date(p.t)), y: .value("°C", p.v))
                .foregroundStyle(Theme.warning)
                .interpolationMethod(.monotone)
            if points.count < 30 {
                PointMark(x: .value("Time", date(p.t)), y: .value("°C", p.v))
                    .foregroundStyle(Theme.warning)
                    .symbolSize(12)
            }
        }
        .chartYScale(domain: .automatic(includesZero: false))
        .chartXAxis { AxisMarks(values: .automatic(desiredCount: 4)) }
        .overlay { if points.isEmpty { EmptyChartLabel(text: "Waiting for the first stored records (WHOOP app sync or “Read strap memory”)") } }
        .frame(height: 110)
    }
}

/// Live ECG trace on a paper-like grid. Native units, auto-scaled to the window.
struct ECGWaveform: View {
    let samples: [Double]
    var sampleRate: Double?
    /// Indices into `samples` of detected R peaks, drawn as dots so detection is visible.
    var peaks: [Int] = []

    var body: some View {
        Canvas { ctx, size in
            let seconds = sampleRate.map { Double(samples.count) / $0 } ?? 4
            let minor: CGFloat = size.width / CGFloat(max(seconds, 1) * 5) // 0.2 s squares
            if minor > 2 {
                var grid = Path()
                var x: CGFloat = 0
                while x <= size.width {
                    grid.move(to: CGPoint(x: x, y: 0)); grid.addLine(to: CGPoint(x: x, y: size.height)); x += minor
                }
                var y: CGFloat = 0
                while y <= size.height {
                    grid.move(to: CGPoint(x: 0, y: y)); grid.addLine(to: CGPoint(x: size.width, y: y)); y += minor
                }
                ctx.stroke(grid, with: .color(Theme.heart.opacity(0.12)), lineWidth: 0.5)
            }

            guard samples.count > 1 else { return }
            let sorted = samples.sorted()
            let lo = sorted[Int(Double(sorted.count - 1) * 0.005)]
            let hi = sorted[Int(Double(sorted.count - 1) * 0.995)]
            let span = max(hi - lo, 1)
            func point(_ i: Int) -> CGPoint {
                let px = size.width * CGFloat(i) / CGFloat(samples.count - 1)
                let norm = min(max((samples[i] - lo) / span, -0.05), 1.05)
                return CGPoint(x: px, y: size.height * (0.92 - 0.84 * CGFloat(norm)))
            }
            var trace = Path()
            trace.move(to: point(0))
            for i in 1..<samples.count { trace.addLine(to: point(i)) }
            ctx.stroke(trace, with: .color(Theme.heart), lineWidth: 1.6)
            for i in peaks where i >= 0 && i < samples.count {
                let p = point(i)
                ctx.fill(Path(ellipseIn: CGRect(x: p.x - 3.5, y: p.y - 3.5, width: 7, height: 7)), with: .color(Theme.warning))
            }
        }
        .frame(height: 190)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.black.opacity(0.35)))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay { if samples.isEmpty { EmptyChartLabel(text: "Press Start, then hold a finger on the clasp") } }
    }
}

struct EmptyChartLabel: View {
    let text: String
    var body: some View {
        Text(text).font(.caption).foregroundStyle(Theme.muted).multilineTextAlignment(.center)
    }
}
