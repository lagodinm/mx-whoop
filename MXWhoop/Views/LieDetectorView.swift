import SwiftUI
import WhoopKit

struct LieDetectorView: View {
    @Environment(SensorHub.self) private var hub
    @Environment(LieDetectorSession.self) private var session

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    TimelineView(.periodic(from: .now, by: 0.25)) { context in
                        phaseView(now: context.date)
                    }
                    if session.isActive { LiveStrip() }
                    if !session.history.isEmpty { HistoryCard(history: session.history) }
                    Text("For fun, not forensics. The detector measures physiological arousal — heart-rate spike, beat acceleration, HRV drop, micro-tremor — and compares it with your own truthful and deliberately false answers. Nervousness looks exactly like lying.")
                        .font(.caption2).foregroundStyle(Theme.muted)
                        .padding(.horizontal, 4)
                }
                .padding(.horizontal)
                .padding(.bottom, 24)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Theme.background)
            .navigationTitle("Lie Detector")
            .toolbar {
                if session.isActive {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Reset", role: .destructive) { session.reset() }
                    }
                }
            }
            .sensoryFeedback(.impact(weight: .medium), trigger: session.transitions)
            .sensoryFeedback(trigger: session.latest?.id) { _, _ in
                session.latest?.verdict.kind == .lie ? .error : .success
            }
        }
    }

    @ViewBuilder
    private func phaseView(now: Date) -> some View {
        switch session.phase {
        case .intro:
            IntroCard()
        case .baseline(let start, let end):
            StageCard(title: "Measuring your baseline",
                      message: "Sit still, rest your arm on a table and breathe normally. Don't talk.",
                      color: Theme.accent, start: start, end: end, now: now)
        case .calibrationSettle(let step, let until):
            let span = step == 0 ? session.config.preWindow : session.settleTime
            StageCard(title: "Calibration \(step + 1) of \(LieDetectorSession.script.count)",
                      message: "Relax… next: \(LieDetectorSession.script[step].instruction.lowercased())",
                      color: Theme.muted, start: until.addingTimeInterval(-span), end: until, now: now,
                      footer: AnyView(CalibrationDots(done: session.calibrationDone, total: LieDetectorSession.script.count)))
        case .calibrationListen(let step, let start, let until):
            let item = LieDetectorSession.script[step]
            PromptCard(instruction: item.instruction, say: item.say,
                       color: item.deceptive ? Theme.lie : Theme.truth, start: start, end: until, now: now,
                       skip: { session.skipCalibration() })
        case .ready:
            VStack(spacing: 16) {
                if let latest = session.latest { VerdictCard(result: latest) }
                AskCard()
            }
        case .listening(let start, let until):
            StageCard(title: "Answer now",
                      message: "Answer the question, then stay still while the reaction is measured.",
                      color: Theme.warning, start: start, end: until, now: now, pulsing: true)
        case .settling(let until):
            VStack(spacing: 12) {
                if let latest = session.latest { VerdictCard(result: latest) }
                Text("Next question in \(Int(max(0, until.timeIntervalSince(now)).rounded(.up))) s — let your pulse settle")
                    .font(.footnote).foregroundStyle(Theme.muted)
            }
        }
    }
}

// MARK: - Intro

private struct IntroCard: View {
    @Environment(SensorHub.self) private var hub
    @Environment(LieDetectorSession.self) private var session

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Image(systemName: "theatermasks.fill").font(.system(size: 34)).foregroundStyle(Theme.accent)
                    VStack(alignment: .leading) {
                        Text("Truth or lie?").font(.title2.bold())
                        Text("A WHOOP-powered polygraph").font(.subheadline).foregroundStyle(Theme.muted)
                    }
                }
                step(1, "Baseline", "60 s sitting still, so the app learns your normal wobble.")
                step(2, "Calibration", "Say 3 true and 3 false statements when prompted (~2.5 min). This teaches the model how *you* react when lying.")
                step(3, "Interrogation", "Someone asks you anything. Tap ASK right after the question; ~16 s later you get TRUE or LIE with a percentage.")
                Text("Tips: wear the strap snug, rest your arm, avoid talking between questions, ask yes/no questions.")
                    .font(.caption).foregroundStyle(Theme.muted)

                if let blocker = session.blocker {
                    Label(blocker, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(Theme.warning)
                    if !hub.linkState.isConnected {
                        HStack {
                            Button("Connect strap") { hub.connectStrap() }.buttonStyle(.borderedProminent)
                            Button("Demo mode") { hub.startDemo() }.buttonStyle(.bordered)
                        }
                    }
                }
                Button {
                    session.start(calibrate: true)
                } label: {
                    Text("Start session").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .disabled(session.blocker != nil)
                Button("Quick start — baseline only, no calibration") { session.start(calibrate: false) }
                    .font(.footnote)
                    .disabled(session.blocker != nil)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private func step(_ n: Int, _ title: String, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(n)").font(.headline).frame(width: 28, height: 28)
                .background(Circle().fill(Theme.accent.opacity(0.18)))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.bold())
                Text(text).font(.footnote).foregroundStyle(Theme.muted)
            }
        }
    }
}

// MARK: - Stages

private struct StageCard: View {
    let title: String
    let message: String
    let color: Color
    let start: Date
    let end: Date
    let now: Date
    var footer: AnyView?
    var pulsing = false

    var body: some View {
        Card {
            VStack(spacing: 16) {
                Text(title).font(.title3.bold())
                ZStack {
                    if pulsing {
                        Circle().stroke(color.opacity(0.25), lineWidth: 2)
                            .frame(width: 210, height: 210)
                            .scaleEffect(1 + 0.06 * sin(now.timeIntervalSinceReferenceDate * 4))
                    }
                    CountdownRing(start: start, end: end, now: now, color: color)
                }
                Text(message).font(.callout).multilineTextAlignment(.center).foregroundStyle(Theme.muted)
                if let footer { footer }
            }
            .frame(maxWidth: .infinity)
        }
    }
}

private struct PromptCard: View {
    let instruction: String
    let say: String
    let color: Color
    let start: Date
    let end: Date
    let now: Date
    let skip: () -> Void

    var body: some View {
        Card {
            VStack(spacing: 14) {
                Text(instruction.uppercased())
                    .font(.system(size: 30, weight: .black, design: .rounded))
                    .foregroundStyle(color)
                Text(say).font(.title3.weight(.semibold)).multilineTextAlignment(.center)
                CountdownRing(start: start, end: end, now: now, color: color, size: 120, lineWidth: 9)
                Text("Say it now, then stay still until the ring completes.")
                    .font(.footnote).foregroundStyle(Theme.muted)
                Button("Skip remaining calibration", action: skip).font(.footnote)
            }
            .frame(maxWidth: .infinity)
        }
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(color.opacity(0.6), lineWidth: 2))
    }
}

private struct CalibrationDots: View {
    let done: [Bool]
    let total: Int
    var body: some View {
        HStack(spacing: 8) {
            ForEach(0..<total, id: \.self) { i in
                let deceptive = LieDetectorSession.script[i].deceptive
                Circle()
                    .fill(i < done.count ? (done[i] ? (deceptive ? Theme.lie : Theme.truth) : Theme.warning) : Color.white.opacity(0.12))
                    .frame(width: 10, height: 10)
            }
        }
    }
}

// MARK: - Asking

private struct AskCard: View {
    @Environment(SensorHub.self) private var hub
    @Environment(LieDetectorSession.self) private var session

    var body: some View {
        @Bindable var session = session
        Card {
            VStack(spacing: 14) {
                TierBadge(tier: session.tier)
                TextField("Type the question (optional)", text: $session.questionText, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .submitLabel(.done)
                if hub.isDemo {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Demo: the virtual subject will…").font(.caption).foregroundStyle(Theme.muted)
                        Picker("Demo answer", selection: $session.demoAnswer) {
                            ForEach(LieDetectorSession.DemoAnswer.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented)
                    }
                }
                Button {
                    session.ask()
                } label: {
                    ZStack {
                        Circle().fill(RadialGradient(colors: [Theme.accent, Theme.accent.opacity(0.55)],
                                                     center: .center, startRadius: 4, endRadius: 80))
                        VStack(spacing: 2) {
                            Image(systemName: "questionmark").font(.system(size: 34, weight: .black))
                            Text("ASK").font(.headline.weight(.heavy))
                        }
                        .foregroundStyle(.black)
                    }
                    .frame(width: 140, height: 140)
                    .shadow(color: Theme.accent.opacity(0.5), radius: 16)
                }
                .buttonStyle(.plain)
                .disabled(!hub.hasLiveHeartRate)
                Text(hub.hasLiveHeartRate ? "Ask your question out loud, then tap ASK immediately." : "Waiting for heart rate…")
                    .font(.footnote).foregroundStyle(Theme.muted)
            }
            .frame(maxWidth: .infinity)
        }
    }
}

private struct TierBadge: View {
    let tier: LieModel.Tier?
    var body: some View {
        let (text, color): (String, Color) = switch tier {
        case .calibrated: ("Personal calibration ✓", Theme.truth)
        case .truthOnly: ("Calibrated on truthful answers only", Theme.warning)
        default: ("Uncalibrated — generic thresholds", Theme.warning)
        }
        Text(text).font(.caption.weight(.semibold)).foregroundStyle(color)
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(Capsule().fill(color.opacity(0.15)))
    }
}

// MARK: - Verdict

struct VerdictCard: View {
    let result: LieDetectorSession.QuestionResult
    @State private var appeared = false

    private var verdict: Verdict { result.verdict }
    private var color: Color {
        switch verdict.kind {
        case .lie: Theme.lie
        case .truth: Theme.truth
        case .inconclusive: Theme.warning
        }
    }
    private var word: String {
        switch verdict.kind {
        case .lie: "LIE"
        case .truth: "TRUTH"
        case .inconclusive: "NO SIGNAL"
        }
    }

    var body: some View {
        Card {
            VStack(spacing: 10) {
                Text(result.question).font(.subheadline).foregroundStyle(Theme.muted).multilineTextAlignment(.center)
                Text(word)
                    .font(.system(size: 60, weight: .black, design: .rounded))
                    .foregroundStyle(color)
                    .shadow(color: color.opacity(0.6), radius: 18)
                    .scaleEffect(appeared ? 1 : 0.6)
                    .opacity(appeared ? 1 : 0)
                if verdict.kind != .inconclusive {
                    Text("\(verdict.confidencePercent)%").font(Theme.number(40))
                    ProbabilityBar(lieProbability: verdict.lieProbability)
                }
                if let wasLie = result.demoWasLie {
                    let correct = (verdict.kind == .lie) == wasLie
                    Label("Demo subject actually \(wasLie ? "lied" : "told the truth")",
                          systemImage: correct ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .font(.footnote).foregroundStyle(correct ? Theme.truth : Theme.lie)
                }
                if !verdict.contributions.isEmpty {
                    Divider().overlay(Theme.cardStroke)
                    VStack(spacing: 8) {
                        ForEach(verdict.contributions.prefix(6), id: \.feature) { ContributionRow(c: $0) }
                    }
                }
                ForEach(verdict.notes, id: \.self) { note in
                    Label(note, systemImage: "info.circle").font(.caption2).foregroundStyle(Theme.muted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(color.opacity(0.5), lineWidth: 1.5))
        .onAppear { withAnimation(.spring(response: 0.45, dampingFraction: 0.6)) { appeared = true } }
        .id(result.id)
    }
}

private struct ProbabilityBar: View {
    let lieProbability: Double
    var body: some View {
        VStack(spacing: 4) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(LinearGradient(colors: [Theme.truth, Theme.warning, Theme.lie],
                                                  startPoint: .leading, endPoint: .trailing))
                        .frame(height: 8)
                    Circle().fill(.white).frame(width: 16, height: 16)
                        .shadow(radius: 3)
                        .offset(x: max(0, min(geo.size.width - 16, geo.size.width * lieProbability - 8)))
                }
                .frame(maxHeight: .infinity)
            }
            .frame(height: 16)
            HStack {
                Text("Truth \(Int(((1 - lieProbability) * 100).rounded()))%").foregroundStyle(Theme.truth)
                Spacer()
                Text("Lie \(Int((lieProbability * 100).rounded()))%").foregroundStyle(Theme.lie)
            }
            .font(.caption.weight(.semibold))
        }
    }
}

private struct ContributionRow: View {
    let c: Verdict.Contribution

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(c.feature.title).font(.caption.weight(.semibold))
                Text(formatted).font(.caption2).foregroundStyle(Theme.muted)
            }
            .frame(width: 130, alignment: .leading)
            GeometryReader { geo in
                let half = geo.size.width / 2
                let w = half * min(abs(c.logOdds) / 2, 1)
                ZStack(alignment: .leading) {
                    Rectangle().fill(Color.white.opacity(0.15)).frame(width: 1).offset(x: half)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(c.logOdds >= 0 ? Theme.lie : Theme.truth)
                        .frame(width: w, height: 8)
                        .offset(x: c.logOdds >= 0 ? half : half - w)
                }
                .frame(maxHeight: .infinity)
            }
            .frame(height: 14)
        }
    }

    private var formatted: String {
        let v = c.rawValue
        switch c.feature {
        case .hrPeak, .hrMean: return String(format: "%+.1f bpm", v)
        case .rrShortening: return String(format: "beats %.1f%% faster", v)
        case .hrvSuppression: return String(format: "RMSSD %+.0f%%", (exp(-v) - 1) * 100)
        case .tremor, .movement: return String(format: "×%.2f vs before", exp(v))
        case .pulseAmplitude: return String(format: "pulse %+.0f%%", -v)
        }
    }
}

// MARK: - Live strip & history

private struct LiveStrip: View {
    @Environment(SensorHub.self) private var hub
    var body: some View {
        Card {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Heart rate").font(.caption).foregroundStyle(Theme.muted)
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(hub.heartRate.map { "\($0)" } ?? "--").font(Theme.number(34))
                            .contentTransition(.numericText())
                        Text("bpm").font(.caption).foregroundStyle(Theme.muted)
                    }
                    Text("RMSSD \(fmt(hub.hrv?.rmssd)) ms · tremor \(fmt(hub.motion?.tremor, digits: 1))")
                        .font(.caption2).foregroundStyle(Theme.muted)
                }
                Spacer()
                ArcGauge(value: hub.arousal, label: "Arousal now", size: 110)
            }
        }
    }
}

private struct HistoryCard: View {
    let history: [LieDetectorSession.QuestionResult]
    var body: some View {
        Card("History", systemImage: "list.bullet") {
            ForEach(history) { r in
                HStack {
                    let isLie = r.verdict.kind == .lie
                    Text(r.verdict.kind == .inconclusive ? "?" : isLie ? "LIE" : "TRUE")
                        .font(.caption.weight(.heavy))
                        .foregroundStyle(.black)
                        .frame(width: 44)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(r.verdict.kind == .inconclusive ? Theme.warning : isLie ? Theme.lie : Theme.truth))
                    Text(r.question).font(.subheadline).lineLimit(2)
                    Spacer()
                    Text("\(r.verdict.confidencePercent)%").font(Theme.number(15))
                }
                if r.id != history.last?.id { Divider().overlay(Theme.cardStroke) }
            }
        }
    }
}
