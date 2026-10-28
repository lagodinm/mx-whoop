import SwiftUI
import WhoopKit

/// Read-only settings, feature flags, alarms, battery pack and clock.
struct StrapInternalsView: View {
    @Environment(SensorHub.self) private var hub

    var body: some View {
        let internals = hub.internals
        List {
            Section {
                Button {
                    internals.readAll()
                } label: {
                    Label(internals.lastRead == nil ? "Read from strap" : "Read again", systemImage: "arrow.down.doc")
                }
                .disabled(hub.linkState != .streaming)
                if internals.pending > 0 {
                    HStack { ProgressView(); Text("Waiting for \(internals.pending) replies…").foregroundStyle(Theme.muted) }
                }
            } footer: {
                Text("Every request here is a read. Settings are looked up by name, so the enumeration cursor the WHOOP app uses is never touched. Nothing is written to the strap.")
            }

            Section("Strap") {
                LabeledContent("Clock vs iPhone", value: internals.clockOffset.map { String(format: "%+.2f s", $0) } ?? "—")
                LabeledContent("Gyroscope mode", value: internals.gyroMode.map { $0 == 1 ? "enabled (1)" : "\($0)" } ?? "—")
                LabeledContent("Battery pack", value: batteryPackText(internals.batteryPack))
            }

            Section {
                let set = internals.alarms.values.filter { $0.time != nil }.sorted { $0.id < $1.id }
                if internals.lastRead == nil {
                    Text("Not read yet").foregroundStyle(Theme.muted)
                } else if set.isEmpty {
                    Text("No alarm scheduled on the strap").foregroundStyle(Theme.muted)
                }
                ForEach(set, id: \.id) { a in
                    LabeledContent("Slot \(a.id)") {
                        VStack(alignment: .trailing) {
                            Text(Date(timeIntervalSince1970: TimeInterval(a.time ?? 0)).formatted(date: .abbreviated, time: .shortened))
                            Text("repeats \(a.repeats) · duration \(a.duration)\(a.crescendo ? " · crescendo" : "")")
                                .font(.caption2).foregroundStyle(Theme.muted)
                        }
                    }
                }
            } header: {
                Text("Haptic alarms on the strap")
            } footer: {
                Text("WHOOP's smart/haptic alarm lives on the strap as a one-shot slot; the WHOOP app re-arms it.")
            }

            configSection("Device settings", ConfigCatalog.deviceKeys, internals)
            configSection("Feature flags", ConfigCatalog.featureFlags, internals)
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .navigationTitle("Strap internals")
    }

    private func configSection(_ title: String, _ entries: [ConfigCatalog.Entry], _ internals: StrapInternals) -> some View {
        Section {
            ForEach(entries) { e in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(e.key).font(Theme.mono(12))
                        Spacer()
                        Text(valueText(internals.values[e.id], read: internals.lastRead != nil))
                            .font(Theme.mono(13).bold())
                            .foregroundStyle(Theme.accent)
                    }
                    Text(e.note).font(.caption2).foregroundStyle(Theme.muted)
                }
            }
        } header: {
            Text(title)
        } footer: {
            Text("Tri-state values: 1 usually means on, 2 off, 0 unset (meaning varies per key). Notes come from community research; unknown means unknown.")
        }
    }

    private func valueText(_ v: ConfigValue?, read: Bool) -> String {
        guard let v else { return read ? "n/a" : "—" }
        return v.value.isEmpty ? "(empty)" : v.value
    }

    private func batteryPackText(_ p: BatteryPackInfo?) -> String {
        guard let p else { return "—" }
        guard p.present else { return "not attached" }
        return String(format: "attached · charge %.1f (raw %d)", Double(p.chargeRaw) / 10, p.chargeRaw)
    }
}

/// What the official app did on the shared link, seen through the strap's replies.
struct WhoopAppActivityView: View {
    @Environment(SensorHub.self) private var hub

    var body: some View {
        List {
            Section {
                ForEach(hub.foreignCounts.sorted { $0.value > $1.value }, id: \.key) { item in
                    LabeledContent(item.key) { Text("\(item.value)").font(Theme.mono(13)) }
                }
                if hub.foreignCounts.isEmpty { Text("Nothing seen yet").foregroundStyle(Theme.muted) }
            } header: {
                Text("Commands answered for the WHOOP app")
            } footer: {
                Text("HISTORICAL_DATA_RESULT is the WHOOP app acknowledging chunks it has stored. Only it ever sends this, which is why its data stays complete.")
            }
            Section("Latest") {
                ForEach(hub.foreignLog.prefix(80)) { c in
                    HStack {
                        Text(c.name).font(Theme.mono(12))
                        Spacer()
                        Text(c.result).font(.caption2).foregroundStyle(Theme.muted)
                        Text(c.date.formatted(date: .omitted, time: .standard)).font(Theme.mono(10)).foregroundStyle(Theme.muted)
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .navigationTitle("WHOOP app activity")
    }
}

/// The strap firmware's own log, reassembled from console records.
struct FirmwareConsoleView: View {
    @Environment(SensorHub.self) private var hub

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 3) {
                if hub.consoleLines.isEmpty {
                    Text("No console output yet. The strap sends log lines mostly while the WHOOP app syncs.")
                        .font(.footnote).foregroundStyle(Theme.muted)
                }
                ForEach(Array(hub.consoleLines.enumerated().reversed()), id: \.offset) { item in
                    Text(item.element).font(Theme.mono(11)).textSelection(.enabled)
                }
            }
            .padding()
        }
        .background(Theme.background)
        .navigationTitle("Firmware console")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                ShareLink(item: hub.consoleLines.joined(separator: "\n")) { Image(systemName: "square.and.arrow.up") }
            }
        }
    }
}
