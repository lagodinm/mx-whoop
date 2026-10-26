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

struct EmptyChartLabel: View {
    let text: String
    var body: some View {
        Text(text).font(.caption).foregroundStyle(Theme.muted).multilineTextAlignment(.center)
    }
}
