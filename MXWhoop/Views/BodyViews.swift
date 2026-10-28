import Charts
import SwiftUI
import WhoopKit

/// Skin temperature and the rest of the strap's own one-second summary.
struct SkinTempCard: View {
    @Environment(SensorHub.self) private var hub

    var body: some View {
        @Bindable var bio = hub.biometrics
        Card("Skin temperature", systemImage: "thermometer.medium",
             trailing: AnyView(SourceBadge(source: bio.skinTemp?.source))) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(bio.skinTemp.map { String(format: "%.2f", $0.celsius) } ?? "--")
                    .font(Theme.number(48))
                    .foregroundStyle(Theme.warning)
                    .contentTransition(.numericText())
                    .animation(.snappy, value: bio.skinTemp?.celsius)
                Text("°C").font(.title3).foregroundStyle(Theme.muted)
                Spacer()
                if let r = bio.skinTemp {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(String(format: "%.1f °F", r.celsius * 9 / 5 + 32)).font(.callout)
                        Text("measured \(r.measuredAt, style: .relative) ago")
                            .font(.caption2).foregroundStyle(Theme.muted)
                    }
                }
            }
            TemperatureChart(points: bio.series)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                MetricTile(title: "Aux 1", value: fmt(bio.auxTemps.0, digits: 1), unit: "°C")
                MetricTile(title: "Aux 2", value: fmt(bio.auxTemps.1, digits: 1), unit: "°C")
                MetricTile(title: "Steps", value: bio.stepsSeen.map { "+\($0)" } ?? "--")
                MetricTile(title: "Activity", value: activityText(bio.latest?.activity))
                MetricTile(title: "Strap state", value: stateText(bio.latest?.bandState))
                MetricTile(title: "Records", value: "\(bio.recordsSeen)")
            }
            SyncStatus(bio: bio)
            Toggle(isOn: $bio.fastSyncWanted) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Fast sync").font(.callout)
                    Text("While this app is open, the strap prompts the WHOOP app to sync every minute.")
                        .font(.caption2).foregroundStyle(Theme.muted)
                }
            }
            PeekRow(bio: bio, connected: hub.linkState == .streaming)
            Text("WHOOP measures skin temperature every second but only stores it; there is no live command for it. MX Whoop reads those stored records as they pass over the shared Bluetooth link when the WHOOP app on this iPhone syncs. It never acknowledges history, so nothing is deleted and the WHOOP app keeps all its data. Aux 1/2 are extra thermal channels in the same record; their sensors are not documented.")
                .font(.caption2).foregroundStyle(Theme.muted)
        }
    }

    private func activityText(_ a: BiometricRecord.Activity?) -> String {
        guard let a else { return "--" }
        switch a {
        case .still: return "Still"
        case .walk: return "Walk"
        case .run: return "Run"
        }
    }

    private func stateText(_ s: BiometricRecord.BandState?) -> String {
        guard let s else { return "--" }
        switch s {
        case .wake: return "Awake"
        case .still: return "Still"
        case .sleep: return "Sleep"
        case .up: return "Up"
        }
    }
}

private struct SourceBadge: View {
    let source: BiometricsMonitor.Source?

    var body: some View {
        if let source {
            Text(source == .sync ? "via sync" : "from memory")
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Capsule().fill(Theme.warning.opacity(0.18)))
        }
    }
}

private struct SyncStatus: View {
    let bio: BiometricsMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let last = bio.lastSyncTraffic {
                Label { Text("Last sync traffic \(last, style: .relative) ago") } icon: {
                    Image(systemName: "arrow.triangle.2.circlepath")
                }
            } else {
                Label("No WHOOP sync seen yet. Is the WHOOP app installed and connected?",
                      systemImage: "arrow.triangle.2.circlepath")
            }
            if let range = bio.dataRange {
                let oldest = range.oldestUnsyncedTime.map {
                    " · oldest from " + Date(timeIntervalSince1970: TimeInterval($0)).formatted(date: .omitted, time: .shortened)
                } ?? ""
                Label("Strap memory: \(range.pagesBehind) pages (~\(range.recordEstimate) records) not yet synced\(oldest)",
                      systemImage: "externaldrive")
            }
            Label(fastSyncText, systemImage: "bolt.horizontal")
        }
        .font(.caption)
        .foregroundStyle(Theme.muted)
    }

    private var fastSyncText: String {
        switch bio.fastSync {
        case .off: "Fast sync off"
        case .requested: "Asking the strap for fast sync…"
        case .on(let ours): ours ? "Fast sync on: prompts every \(BiometricsMonitor.fastSyncInterval) s"
            : "Fast sync on (session started by the WHOOP app)"
        case .refused: "This strap's firmware refused fast sync"
        }
    }
}

private struct PeekRow: View {
    let bio: BiometricsMonitor
    let connected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                bio.readStrapMemory()
            } label: {
                Label("Read strap memory now", systemImage: "memorychip").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(!connected || bio.peek == .reading)
            switch bio.peek {
            case .idle:
                EmptyView()
            case .reading:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Reading the oldest unsynced chunk…")
                }
                .font(.caption).foregroundStyle(Theme.muted)
            case .done(let records):
                Text(records > 0
                     ? "Read \(records) records from strap memory. Nothing was acknowledged or deleted."
                     : "The first unsynced chunk had no summary records. Nothing was acknowledged or deleted.")
                    .font(.caption).foregroundStyle(Theme.muted)
            case .unavailable(let why):
                Text(why).font(.caption).foregroundStyle(Theme.warning)
            }
        }
    }
}

/// Session effort from heart rate and the profile in the Strap tab.
struct EffortCard: View {
    @Environment(SensorHub.self) private var hub

    var body: some View {
        Card("Effort · this session", systemImage: "flame.fill") {
            ZoneBar(zone: hub.zone)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                MetricTile(title: "Zone", value: zoneText, unit: hub.percentOfMax.map { "\(Int($0))% max" } ?? "",
                           color: ZoneBar.color(hub.zone ?? 0))
                MetricTile(title: "Strain (est.)", value: fmt(hub.sessionStrain, digits: 1), unit: "/ 21", color: Theme.motion)
                MetricTile(title: "Calories", value: fmt(hub.sessionKcal), unit: "kcal")
                MetricTile(title: "Resting HR", value: fmt(hub.restingHR), unit: "bpm", footnote: "lowest 1-min mean")
            }
            Text("Profile: \(hub.profile.age) y · \(Int(hub.profile.weightKg)) kg · max HR \(Int(hub.profile.maxHR)) (edit in the Strap tab). Calories use Keytel's HR formula; strain is Banister TRIMP on a 0–21 scale. Both are estimates, not WHOOP's algorithms.")
                .font(.caption2).foregroundStyle(Theme.muted)
        }
    }

    private var zoneText: String {
        guard let z = hub.zone else { return "--" }
        return z == 0 ? "Rest" : "Z\(z)"
    }
}

struct ZoneBar: View {
    let zone: Int?

    static func color(_ z: Int) -> Color {
        switch z {
        case 1: Theme.motion
        case 2: Theme.accent
        case 3: Theme.truth
        case 4: Theme.warning
        case 5: Theme.lie
        default: Theme.muted
        }
    }

    var body: some View {
        HStack(spacing: 4) {
            ForEach(1...5, id: \.self) { z in
                RoundedRectangle(cornerRadius: 4)
                    .fill(Self.color(z).opacity(zone == z ? 1 : 0.22))
                    .frame(height: zone == z ? 14 : 8)
                    .overlay {
                        if zone == z { Text("\(z)").font(.system(size: 10, weight: .bold)).foregroundStyle(.black) }
                    }
            }
        }
        .animation(.snappy, value: zone)
    }
}
