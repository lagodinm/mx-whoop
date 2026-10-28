import SwiftUI
import WhoopKit

/// Experimental live ECG for WHOOP MG.
struct ECGView: View {
    @Environment(SensorHub.self) private var hub

    var body: some View {
        let ecg = hub.ecg
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    if hub.variant == .whoop5 {
                        Card("WHOOP 5.0 detected", systemImage: "exclamationmark.triangle.fill") {
                            Text("ECG needs the WHOOP MG's conductive clasp. On a WHOOP 5.0 the strap will most likely refuse the commands; nothing else is affected.")
                                .font(.footnote).foregroundStyle(Theme.muted)
                        }
                    }
                    traceCard(ecg)
                    controlCard(ecg)
                    Card("How to record", systemImage: "hand.point.up.left.fill") {
                        Text("""
                        1. Sit still and rest your forearm on a table.
                        2. Pick the wrist the strap is on, then press Start.
                        3. Hold a fingertip of your other hand on the strap's metal clasp, without pressing hard.
                        4. The trace settles after a few seconds. Recording stops by itself after \(Int(ecg.maxDuration)) s.
                        """)
                        .font(.footnote)
                        Text("Experimental: the commands are documented by the community but not confirmed on real hardware. Amplitude is in the strap's native units and the sample rate is estimated from arrival times. This is not a medical ECG and can't detect any condition.")
                            .font(.caption2).foregroundStyle(Theme.muted)
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 24)
            }
            .background(Theme.background)
            .navigationTitle("ECG")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { StatusPill(state: hub.linkState) } }
        }
    }

    private func traceCard(_ ecg: ECGSession) -> some View {
        let shown = Array(ecg.samples.suffix(Int((ecg.sampleRate ?? 100) * 4)))
        return Card("Live ECG · lead I", systemImage: "waveform.path.ecg") {
            ECGWaveform(samples: shown, sampleRate: ecg.sampleRate)
            HStack(spacing: 10) {
                MetricTile(title: "Heart rate", value: fmt(ecg.heartRate), unit: "bpm", color: Theme.heart,
                           footnote: "from R peaks")
                MetricTile(title: "Last R-R", value: fmt(ecg.rrIntervals.last), unit: "ms")
                MetricTile(title: "Rate", value: fmt(ecg.sampleRate), unit: "Hz", footnote: "estimated")
            }
            VStack(alignment: .leading, spacing: 4) {
                Label(statusText(ecg), systemImage: "dot.radiowaves.left.and.right")
                if ecg.recordsReceived > 0 { Text(detailText(ecg)) }
            }
            .font(.caption).foregroundStyle(Theme.muted)
        }
    }

    private func detailText(_ ecg: ECGSession) -> String {
        func code(_ v: UInt8?) -> String { v.map { String($0) } ?? "–" }
        let contact = ecg.presence ? "detected" : "not detected"
        return "Contact: \(contact) · quality \(code(ecg.quality)) · progress \(code(ecg.progress)) · strap HR value \(code(ecg.strapHRValue)) · \(ecg.recordsReceived) records"
    }

    private func controlCard(_ session: ECGSession) -> some View {
        @Bindable var ecg = session
        let active = ecg.phase.isActive
        return Card("Recording", systemImage: "record.circle") {
            Picker("Strap is on", selection: $ecg.wrist) {
                ForEach(CommandBody.Wrist.allCases, id: \.self) { Text("\($0.name) wrist").tag($0) }
            }
            .pickerStyle(.segmented)
            .disabled(active)
            Button {
                active ? ecg.stop() : ecg.start()
            } label: {
                Label(active ? "Stop" : "Start ECG", systemImage: active ? "stop.fill" : "play.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .tint(active ? Theme.lie : Theme.heart)
            .disabled(!active && hub.linkState != .streaming)
            if active {
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    Text("\(max(0, Int(ecg.maxDuration - ecg.elapsed))) s left")
                        .font(Theme.mono(12)).foregroundStyle(Theme.muted)
                }
            }
            if case .failed(let why) = ecg.phase {
                Text(why).font(.caption).foregroundStyle(Theme.lie)
            }
            if hub.linkState != .streaming && !active {
                Text("Connect the strap (or Demo mode) first.").font(.caption).foregroundStyle(Theme.muted)
            }
        }
    }

    private func statusText(_ ecg: ECGSession) -> String {
        switch ecg.phase {
        case .idle: return ecg.recordsReceived > 0 ? "Stopped" : "Idle"
        case .starting: return "Started: waiting for ECG records…"
        case .recording: return "Recording"
        case .failed: return "Stopped with an error"
        }
    }
}
