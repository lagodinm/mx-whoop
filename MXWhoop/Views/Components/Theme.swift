import SwiftUI

enum Theme {
    static let background = Color(red: 0.035, green: 0.04, blue: 0.05)
    static let card = Color(red: 0.09, green: 0.10, blue: 0.115)
    static let cardStroke = Color.white.opacity(0.06)
    static let accent = Color(red: 0.20, green: 0.90, blue: 0.70)
    static let heart = Color(red: 1.00, green: 0.33, blue: 0.40)
    static let truth = Color(red: 0.25, green: 0.87, blue: 0.55)
    static let lie = Color(red: 1.00, green: 0.29, blue: 0.36)
    static let warning = Color(red: 1.00, green: 0.75, blue: 0.27)
    static let motion = Color(red: 0.38, green: 0.62, blue: 1.00)
    static let muted = Color.white.opacity(0.55)

    static func mono(_ size: CGFloat = 12) -> Font { .system(size: size, design: .monospaced) }
    static func number(_ size: CGFloat) -> Font { .system(size: size, weight: .bold, design: .rounded).monospacedDigit() }
}

/// Rounded dark card used across the app.
struct Card<Content: View>: View {
    let title: String?
    let systemImage: String?
    let trailing: AnyView?
    let content: Content

    init(_ title: String? = nil, systemImage: String? = nil, trailing: AnyView? = nil,
         @ViewBuilder content: () -> Content) {
        self.title = title
        self.systemImage = systemImage
        self.trailing = trailing
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if title != nil || trailing != nil {
                HStack {
                    if let title {
                        Group {
                            if let systemImage { Label(title, systemImage: systemImage) } else { Text(title) }
                        }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.muted)
                    }
                    Spacer()
                    trailing
                }
            }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(Theme.cardStroke))
    }
}

struct MetricTile: View {
    let title: String
    let value: String
    var unit: String = ""
    var color: Color = .white
    var footnote: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(Theme.muted)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value).font(Theme.number(22)).foregroundStyle(color)
                    .contentTransition(.numericText())
                if !unit.isEmpty { Text(unit).font(.caption2).foregroundStyle(Theme.muted) }
            }
            if let footnote { Text(footnote).font(.caption2).foregroundStyle(Theme.muted) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(0.04)))
    }
}

struct StatusPill: View {
    let state: LinkState

    var color: Color {
        switch state {
        case .streaming: Theme.truth
        case .handshaking, .connecting, .scanning: Theme.warning
        case .failed, .unavailable: Theme.lie
        case .idle: Theme.muted
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
                .shadow(color: color.opacity(0.8), radius: state == .streaming ? 4 : 0)
            Text(state == .streaming ? "Live" : state.label)
                .font(.caption.weight(.medium))
                .lineLimit(1)
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(Capsule().fill(color.opacity(0.14)))
    }
}

/// Semicircular 0–100 gauge.
struct ArcGauge: View {
    let value: Double?      // 0…100
    var label: String = "Arousal"
    var size: CGFloat = 120

    var body: some View {
        let v = (value ?? 0) / 100
        ZStack {
            Arc(progress: 1).stroke(Color.white.opacity(0.08), style: StrokeStyle(lineWidth: 10, lineCap: .round))
            Arc(progress: v)
                .stroke(AngularGradient(colors: [Theme.truth, Theme.warning, Theme.lie], center: .bottom,
                                        startAngle: .degrees(180), endAngle: .degrees(360)),
                        style: StrokeStyle(lineWidth: 10, lineCap: .round))
                .animation(.easeOut(duration: 0.6), value: v)
            VStack(spacing: 0) {
                Text(value.map { "\(Int($0))" } ?? "--").font(Theme.number(size * 0.24))
                Text(label).font(.caption2).foregroundStyle(Theme.muted)
            }
            .offset(y: size * 0.08)
        }
        .frame(width: size, height: size * 0.62)
    }

    struct Arc: Shape {
        var progress: Double
        var animatableData: Double {
            get { progress }
            set { progress = newValue }
        }
        func path(in rect: CGRect) -> Path {
            var p = Path()
            let r = min(rect.width / 2, rect.height) - 6
            let c = CGPoint(x: rect.midX, y: rect.maxY - 2)
            p.addArc(center: c, radius: r, startAngle: .degrees(180),
                     endAngle: .degrees(180 + 180 * max(0, min(1, progress))), clockwise: false)
            return p
        }
    }
}

/// Countdown ring driven by wall-clock dates (render inside a TimelineView).
struct CountdownRing: View {
    let start: Date
    let end: Date
    let now: Date
    var color: Color = Theme.accent
    var size: CGFloat = 180
    var lineWidth: CGFloat = 12

    var body: some View {
        let total = max(end.timeIntervalSince(start), 0.001)
        let remaining = max(0, end.timeIntervalSince(now))
        let progress = 1 - remaining / total
        ZStack {
            Circle().stroke(Color.white.opacity(0.07), lineWidth: lineWidth)
            Circle().trim(from: 0, to: progress)
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text("\(Int(remaining.rounded(.up)))")
                .font(Theme.number(size * 0.28))
                .contentTransition(.numericText(countsDown: true))
        }
        .frame(width: size, height: size)
    }
}
