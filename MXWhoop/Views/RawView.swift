import SwiftUI
import UIKit
import WhoopKit

struct RawView: View {
    @Environment(SensorHub.self) private var hub
    @State private var filter: RawEntry.Kind?
    @State private var selected: RawEntry?

    private var entries: [RawEntry] {
        guard let filter else { return hub.rawLog }
        return hub.rawLog.filter { $0.kind == filter }
    }

    var body: some View {
        @Bindable var hub = hub
        NavigationStack {
            List {
                Section {
                    stats
                    counts
                }
                Section("Command console") { CommandConsole() }
                Section {
                    Picker("Filter", selection: $filter) {
                        Text("All").tag(RawEntry.Kind?.none)
                        ForEach(RawEntry.Kind.allCases, id: \.self) { Text($0.rawValue).tag(RawEntry.Kind?.some($0)) }
                    }
                    .pickerStyle(.segmented)
                    ForEach(entries) { entry in
                        Button { selected = entry } label: { RawRow(entry: entry) }
                            .buttonStyle(.plain)
                    }
                } header: {
                    HStack {
                        Text("Frames (newest first)")
                        Spacer()
                        Toggle("Pause", isOn: $hub.rawPaused).toggleStyle(.button).font(.caption)
                        Button("Clear") { hub.clearRaw() }.font(.caption)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle("Raw data")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { StatusPill(state: hub.linkState) } }
            .sheet(item: $selected) { FrameDetail(entry: $0) }
        }
    }

    private var stats: some View {
        HStack {
            MetricTile(title: "Frames", value: "\(hub.framesReceived)")
            MetricTile(title: "Bytes", value: ByteCountFormatter.string(fromByteCount: Int64(hub.bytesReceived), countStyle: .binary))
            MetricTile(title: "Bad CRC", value: "\(hub.corruptFrames)", color: hub.corruptFrames > 0 ? Theme.warning : .white)
        }
        .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
    }

    private var counts: some View {
        let sorted = hub.packetCounts.sorted { $0.value > $1.value }
        return VStack(alignment: .leading, spacing: 6) {
            if sorted.isEmpty {
                Text("No packets yet").font(.caption).foregroundStyle(Theme.muted)
            }
            ForEach(sorted, id: \.key) { item in
                HStack {
                    Text(item.key).font(Theme.mono(12))
                    Spacer()
                    Text("\(item.value)").font(Theme.mono(12)).foregroundStyle(Theme.accent)
                }
            }
        }
    }
}

private struct RawRow: View {
    let entry: RawEntry

    private var color: Color {
        if entry.isError { return Theme.lie }
        if entry.outgoing { return Theme.warning }
        switch entry.kind {
        case .hr: return Theme.heart
        case .imu: return Theme.motion
        case .body: return Theme.warning
        case .event: return Theme.truth
        case .command: return Theme.accent
        case .other: return Theme.muted
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(entry.channel).font(Theme.mono(10).bold()).foregroundStyle(.black)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(RoundedRectangle(cornerRadius: 4).fill(color))
                Text(entry.title).font(.caption.weight(.semibold))
                Spacer()
                Text(entry.date.formatted(.dateTime.hour().minute().second().secondFraction(.fractional(2))))
                    .font(Theme.mono(10)).foregroundStyle(Theme.muted)
            }
            Text(entry.summary).font(.caption)
            Text(Array(entry.bytes.prefix(24)).hexString + (entry.bytes.count > 24 ? " …" : ""))
                .font(Theme.mono(10)).foregroundStyle(Theme.muted).lineLimit(2)
        }
        .padding(.vertical, 2)
    }
}

private struct FrameDetail: View {
    let entry: RawEntry
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(entry.summary).font(.headline)
                    Text("\(entry.bytes.count) bytes · \(entry.outgoing ? "phone → strap" : "strap → phone, \(entry.channel)")")
                        .font(.caption).foregroundStyle(Theme.muted)
                    Text(hexDump).font(Theme.mono(11)).textSelection(.enabled)
                }
                .padding()
            }
            .background(Theme.background)
            .navigationTitle(entry.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Copy hex") { UIPasteboard.general.string = entry.bytes.hexString }
                }
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
            }
        }
    }

    /// Classic 16-bytes-per-line dump with offsets, so frame offsets in the docs are easy to find.
    private var hexDump: String {
        stride(from: 0, to: entry.bytes.count, by: 16).map { offset in
            let line = entry.bytes[offset..<min(offset + 16, entry.bytes.count)]
            return String(format: "%04d  ", offset) + Array(line).hexString
        }.joined(separator: "\n")
    }
}

private struct CommandConsole: View {
    @Environment(SensorHub.self) private var hub

    private var commands: [(String, String, CommandBody.Request)] {
        [
            ("Hello", "hand.wave", CommandBody.hello),
            ("Battery", "battery.75percent", CommandBody.getBattery),
            ("Buzz", "iphone.radiowaves.left.and.right", CommandBody.buzz(pulses: 1)),
            ("Stop buzz", "speaker.slash", CommandBody.stopHaptics),
            ("HR on", "heart", CommandBody.realtimeHR(true)),
            ("HR off", "heart.slash", CommandBody.realtimeHR(false)),
            ("Get clock", "clock", CommandBody.getClock),
            ("Wear status", "hand.raised", CommandBody.bodyLocation),
            ("Data range", "externaldrive", CommandBody.dataRange),
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 96))], spacing: 8) {
                ForEach(commands, id: \.0) { item in
                    Button {
                        hub.send(item.2)
                    } label: {
                        Label(item.0, systemImage: item.1).font(.caption).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
            }
            .disabled(hub.linkState != .streaming)
            Text("Only safe, non-persistent commands are offered. History acknowledgements, trims, read-pointer changes, reboots, firmware and pairing resets are deliberately not exposed.")
                .font(.caption2).foregroundStyle(Theme.muted)
        }
    }
}
