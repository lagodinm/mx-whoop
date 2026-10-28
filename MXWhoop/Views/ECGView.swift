import SwiftUI
import WhoopKit

/// Experimental live ECG for WHOOP MG: calibrate, record 30 s, summarise.
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
                    if let summary = ecg.lastSummary { SummaryCard(summary: summary) }
                    Card("How to record", systemImage: "hand.point.up.left.fill") {
                        Text("""
                        1. Sit still and rest your forearm on a table.
                        2. Pick the wrist the strap is on (the same wrist as in the WHOOP app), then press Start.
                        3. Hold a fingertip of your other hand on the strap's metal clasp, without pressing hard.
                        4. The app calibrates first: the signal settles, the sample rate is measured and the beats must match the strap's optical heart rate. Then it records \(Int(ecg.recordingDuration)) s.
                        """)
                        .font(.footnote)
                        Text("Experimental. The commands are documented by the community, not by WHOOP. Amplitude is in the strap's native units. Yellow dots mark the detected heartbeats. This is not a medical ECG and can't detect any condition.")
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
        let count = Int((ecg.sampleRate ?? 128) * 4)
        let shown = Array(ecg.samples.suffix(count))
        let displayStart = ecg.totalSamples - shown.count
        let markers = ecg.peakPositions.map { $0 - displayStart }
        return Card("Live ECG · lead I", systemImage: "waveform.path.ecg") {
            ECGWaveform(samples: shown, sampleRate: ecg.sampleRate, peaks: markers)
            HStack(spacing: 10) {
                MetricTile(title: "ECG heart rate", value: ecg.phase == .calibrating ? "…" : fmt(ecg.heartRate), unit: "bpm",
                           color: Theme.heart, footnote: "from R peaks")
                MetricTile(title: "Optical HR", value: fmt(ecg.ppgHeartRate), unit: "bpm", footnote: "strap PPG")
                MetricTile(title: "Last R-R", value: fmt(ecg.rrIntervals.last), unit: "ms")
            }
            VStack(alignment: .leading, spacing: 4) {
                Label(statusText(ecg), systemImage: "dot.radiowaves.left.and.right")
                if let rate = ecg.sampleRate {
                    Text("Sample rate \(Int(rate)) Hz (\(ecg.rateSource ?? "?"))")
                }
                if ecg.recordsReceived > 0 { Text(detailText(ecg)) }
            }
            .font(.caption).foregroundStyle(Theme.muted)
        }
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
            if ecg.phase == .calibrating || ecg.phase == .starting {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: ecg.calibration) { Text("Calibrating") }
                        .tint(Theme.warning)
                    if let hint = ecg.calibrationHint {
                        Text(hint).font(.caption).foregroundStyle(Theme.muted)
                    }
                }
            }
            if ecg.phase == .recording {
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    ProgressView(value: min(1, ecg.recordingElapsed / ecg.recordingDuration)) {
                        Text("Recording · \(max(0, Int(ecg.recordingDuration - ecg.recordingElapsed))) s left")
                    }
                    .tint(Theme.heart)
                }
            }
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
            if case .failed(let why) = ecg.phase {
                Text(why).font(.caption).foregroundStyle(Theme.lie)
            }
            if hub.linkState != .streaming && !active {
                Text("Connect the strap (or Demo mode) first.").font(.caption).foregroundStyle(Theme.muted)
            }
        }
    }

    private func detailText(_ ecg: ECGSession) -> String {
        func code(_ v: UInt8?) -> String { v.map { String($0) } ?? "–" }
        let contact = ecg.presence ? "detected" : "not detected"
        return "Contact \(contact) · quality \(code(ecg.quality)) · strap progress \(code(ecg.progress)) · strap HR value \(code(ecg.strapHRValue)) · \(ecg.recordsReceived) records"
    }

    private func statusText(_ ecg: ECGSession) -> String {
        switch ecg.phase {
        case .idle: return "Idle"
        case .starting: return "Started: waiting for ECG records…"
        case .calibrating: return "Calibrating"
        case .recording: return "Recording"
        case .finished: return "Finished"
        case .failed: return "Stopped with an error"
        }
    }
}

private struct SummaryCard: View {
    let summary: ECGSession.Summary

    var body: some View {
        Card("Last recording · \(summary.date.formatted(date: .omitted, time: .shortened))", systemImage: "list.clipboard") {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                MetricTile(title: "Average", value: fmt(summary.averageHR), unit: "bpm", color: Theme.heart)
                MetricTile(title: "Range", value: "\(Int(summary.minHR))–\(Int(summary.maxHR))", unit: "bpm")
                MetricTile(title: "Beats", value: "\(summary.beats)")
                MetricTile(title: "RMSSD", value: fmt(summary.rmssd), unit: "ms", color: Theme.accent)
                MetricTile(title: "SDNN", value: fmt(summary.sdnn), unit: "ms")
                MetricTile(title: "Optical HR", value: fmt(summary.ppgHR), unit: "bpm")
            }
            Text(footer).font(.caption2).foregroundStyle(Theme.muted)
        }
    }

    private var footer: String {
        var parts = ["\(Int(summary.duration)) s at \(Int(summary.sampleRate)) Hz (\(summary.rateSource))"]
        if let v = summary.strapHRValue { parts.append("strap's own HR value \(Int(v))") }
        if let r = summary.classifierResult, let s = summary.classifierState {
            parts.append("strap classifier result \(r), state \(s) (meaning unknown)")
        }
        return parts.joined(separator: " · ") + ". RMSSD from ECG beats is more precise than from the optical sensor."
    }
}
