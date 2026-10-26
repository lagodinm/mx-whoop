import SwiftUI
import WhoopKit

struct LiveView: View {
    @Environment(SensorHub.self) private var hub

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    if !hub.linkState.isConnected { ConnectCard() }
                    HeartHero()
                    Card("Heart rate · 5 min", systemImage: "heart.fill") {
                        HeartRateChart(samples: hub.timeline.heartRate)
                    }
                    variabilityCard
                    motionCard
                    opticalCard
                    RecordingCard()
                }
                .padding(.horizontal)
                .padding(.bottom, 24)
            }
            .background(Theme.background)
            .navigationTitle("MX Whoop")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { StatusPill(state: hub.linkState) } }
        }
    }

    private var variabilityCard: some View {
        Card("Heart-rate variability", systemImage: "waveform.path.ecg.rectangle") {
            RRChart(beats: hub.timeline.beats)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                MetricTile(title: "RMSSD (60 s)", value: fmt(hub.hrv?.rmssd), unit: "ms", color: Theme.accent,
                           footnote: "vagal tone")
                MetricTile(title: "SDNN", value: fmt(hub.hrv?.sdnn), unit: "ms")
                MetricTile(title: "pNN50", value: fmt(hub.hrv?.pnn50), unit: "%")
                MetricTile(title: "Breathing", value: fmt(hub.respirationRate), unit: "/min",
                           footnote: "from sinus arrhythmia")
                MetricTile(title: "Last R-R", value: fmt(hub.lastRR), unit: "ms")
                MetricTile(title: "Mean HR (R-R)", value: fmt(hub.hrv?.meanHR), unit: "bpm")
            }
        }
    }

    private var motionCard: some View {
        Card("Motion · 100 Hz IMU", systemImage: "gyroscope",
                    trailing: AnyView(Toggle("", isOn: Binding(get: { hub.imuEnabled }, set: { hub.setIMU($0) })).labelsHidden())) {
            AccelChart(points: hub.accelPreview)
            HStack(spacing: 10) {
                MetricTile(title: "Movement", value: fmt(hub.motion.map { $0.movement * 1000 }), unit: "mg", color: Theme.motion)
                MetricTile(title: "Tremor 4–12 Hz", value: fmt(hub.motion?.tremor, digits: 2), unit: "mg²")
                MetricTile(title: "Rotation", value: fmt(hub.motion?.rotation), unit: "°/s")
            }
        }
    }

    private var opticalCard: some View {
        Card("Optical (experimental)", systemImage: "light.max",
             trailing: AnyView(Toggle("", isOn: Binding(get: { hub.opticalEnabled }, set: { hub.setOptical($0) })).labelsHidden())) {
            OpticalChart(samples: hub.opticalPreview)
            Text("Asks the strap for live optical (PPG) output. Not confirmed on WHOOP 5/MG firmware — if nothing arrives, the strap only stores optical data for its own sync.")
                .font(.caption2).foregroundStyle(Theme.muted)
        }
    }
}

/// Big live heart-rate readout.
struct HeartHero: View {
    @Environment(SensorHub.self) private var hub

    var body: some View {
        Card {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(hub.heartRate.map { "\($0)" } ?? "--")
                            .font(Theme.number(64))
                            .contentTransition(.numericText())
                            .animation(.snappy, value: hub.heartRate)
                        Text("bpm").font(.title3).foregroundStyle(Theme.muted)
                    }
                    Text(hub.heartRateSource?.rawValue ?? "Waiting for heart rate")
                        .font(.caption).foregroundStyle(Theme.muted)
                    HStack(spacing: 12) {
                        if let worn = hub.onWrist {
                            Label(worn ? "On wrist" : "Off wrist", systemImage: worn ? "hand.raised.fill" : "hand.raised.slash")
                                .foregroundStyle(worn ? Theme.truth : Theme.warning)
                        }
                        if let b = hub.battery {
                            Label("\(b)%", systemImage: b > 20 ? "battery.75percent" : "battery.25percent")
                        }
                    }
                    .font(.caption)
                }
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "heart.fill")
                        .font(.system(size: 44))
                        .foregroundStyle(Theme.heart)
                        .symbolEffect(.pulse, options: .repeating, isActive: hub.hasLiveHeartRate)
                    ArcGauge(value: hub.arousal, label: "Arousal", size: 96)
                }
            }
        }
    }
}

/// Shown when no strap is connected.
struct ConnectCard: View {
    @Environment(SensorHub.self) private var hub

    var body: some View {
        Card("Connect", systemImage: "antenna.radiowaves.left.and.right") {
            Text(hub.linkState.label)
                .font(.callout)
                .foregroundStyle(failure ? Theme.lie : .primary)
            HStack {
                Button {
                    hub.connectStrap()
                } label: {
                    Label("Connect strap", systemImage: "dot.radiowaves.left.and.right").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(hub.linkState.isBusy)
                Button {
                    hub.startDemo()
                } label: {
                    Label("Demo mode", systemImage: "play.circle").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            Text("First time? Keep the strap close. iOS will ask to pair — accept it. If the strap is paired with another phone, tap it until the LED flashes blue (pairing mode).")
                .font(.caption2).foregroundStyle(Theme.muted)
        }
    }

    private var failure: Bool {
        if case .failed = hub.linkState { return true }
        return false
    }
}

struct RecordingCard: View {
    @Environment(SensorHub.self) private var hub

    var body: some View {
        let recorder = hub.recorder
        Card("Record raw data", systemImage: "record.circle") {
            HStack {
                Button {
                    recorder.isRecording ? recorder.stop() : recorder.start()
                } label: {
                    Label(recorder.isRecording ? "Stop" : "Start recording",
                          systemImage: recorder.isRecording ? "stop.fill" : "record.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(recorder.isRecording ? Theme.lie : Theme.accent)

                if !recorder.lastFiles.isEmpty && !recorder.isRecording {
                    ShareLink(items: recorder.lastFiles) {
                        Label("Export", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
            }
            if recorder.isRecording, let start = recorder.startedAt {
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    Text("Recording \(Duration.seconds(ctx.date.timeIntervalSince(start)).formatted(.time(pattern: .minuteSecond))) · \(recorder.lineCount) writes")
                        .font(Theme.mono(12)).foregroundStyle(Theme.muted)
                }
            }
            Text("CSV files: heart rate, R-R intervals, 100 Hz IMU, optical, events and a hex log of every frame. Also visible in the Files app.")
                .font(.caption2).foregroundStyle(Theme.muted)
        }
    }
}

func fmt(_ v: Double?, digits: Int = 0) -> String {
    guard let v, v.isFinite else { return "--" }
    return v.formatted(.number.precision(.fractionLength(digits)))
}
