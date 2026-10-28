import SwiftUI
import WhoopKit

struct StrapView: View {
    @Environment(SensorHub.self) private var hub

    var body: some View {
        @Bindable var hub = hub
        NavigationStack {
            List {
                Section {
                    HStack {
                        Image(systemName: "sensor.tag.radiowaves.forward.fill")
                            .font(.system(size: 30)).foregroundStyle(Theme.accent)
                        VStack(alignment: .leading) {
                            Text(hub.deviceName ?? "No strap").font(.headline)
                            Text(hub.linkState.label).font(.caption).foregroundStyle(Theme.muted)
                        }
                        Spacer()
                        StatusPill(state: hub.linkState)
                    }
                    if hub.linkState.isConnected || hub.linkState.isBusy {
                        Button(role: .destructive) { hub.disconnect() } label: { Label("Disconnect", systemImage: "xmark.circle") }
                    } else {
                        Button { hub.connectStrap() } label: { Label("Connect WHOOP strap", systemImage: "dot.radiowaves.left.and.right") }
                        Button { hub.startDemo() } label: { Label("Start demo strap", systemImage: "play.circle") }
                    }
                }

                Section("Device") {
                    row("Hardware", hub.deviceInfo.isEmpty ? "—" : hub.variant.rawValue)
                    row("Model", hub.deviceInfo["Model"])
                    row("Serial", hub.deviceInfo["Serial"])
                    row("Firmware", hub.firmware)
                    row("Hardware rev.", hub.deviceInfo["Hardware"])
                    row("Battery", hub.battery.map { "\($0) %" })
                    row("Worn", hub.onWrist.map { $0 ? "Yes" : "No" })
                    row("Skin temperature", hub.biometrics.skinTemp.map { String(format: "%.2f °C", $0.celsius) })
                    row("Last event", hub.lastEvent?.name)
                }

                Section {
                    DataSafetyRows()
                    NavigationLink { WhoopAppActivityView() } label: {
                        Label("WHOOP app activity", systemImage: "arrow.left.arrow.right")
                    }
                } header: {
                    Text("Your WHOOP data")
                } footer: {
                    Text("The strap deletes stored data only after receiving HISTORICAL_DATA_RESULT, the acknowledgement that follows a sync. MX Whoop has no code path that can send it (a unit test enforces this). It reads copies of what passes over the link.")
                }

                Section("Explore") {
                    NavigationLink { StrapInternalsView() } label: {
                        Label("Strap internals: settings, flags, alarms", systemImage: "cpu")
                    }
                    NavigationLink { FirmwareConsoleView() } label: {
                        Label("Firmware console (\(hub.consoleLines.count) lines)", systemImage: "terminal")
                    }
                }

                Section("Settings") {
                    Toggle("Buzz the strap on a LIE verdict", isOn: $hub.buzzOnLie)
                    Toggle(isOn: Binding(get: { hub.biometrics.fastSyncWanted }, set: { hub.biometrics.fastSyncWanted = $0 })) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Fast sync for skin temperature")
                            Text("While MX Whoop is open, the strap prompts the WHOOP app to sync every minute (WHOOP's own high-frequency sync). Turns itself off when you leave the app.")
                                .font(.caption2).foregroundStyle(Theme.muted)
                        }
                    }
                }

                Section {
                    Stepper("Age: \(hub.profile.age)", value: $hub.profile.age, in: 12...95)
                    Stepper("Weight: \(Int(hub.profile.weightKg)) kg", value: $hub.profile.weightKg, in: 30...200, step: 1)
                    Picker("Sex", selection: $hub.profile.sex) {
                        Text("Male").tag(EffortProfile.Sex.male)
                        Text("Female").tag(EffortProfile.Sex.female)
                    }
                    LabeledContent("Estimated max HR", value: "\(Int(hub.profile.maxHR)) bpm")
                } header: {
                    Text("Your profile")
                } footer: {
                    Text("Used for heart-rate zones, calories and the strain estimate on the Live tab. Stored on this iPhone only.")
                }

                Section("How the connection works") {
                    Text("""
                    • The app talks to the strap's own Bluetooth service (FD4B0001), the same one the official app uses on WHOOP 5.0 and MG.
                    • The strap only accepts commands over an encrypted (bonded) link. The first time, iOS shows a pairing request; accept it.
                    • If the official WHOOP app on this iPhone is already connected, both apps share the link, and records from its syncs reach this app too. That is where skin temperature comes from.
                    • If the strap is bonded to a different phone, put it in pairing mode: tap the strap until the LED flashes blue.
                    • This app never acknowledges history. "Read strap memory" only looks, and the strap keeps everything for the WHOOP app.
                    """)
                    .font(.footnote)
                    .foregroundStyle(Theme.muted)
                }

                Section("Connection log") {
                    if hub.connectionLog.isEmpty {
                        Text("Nothing yet").foregroundStyle(Theme.muted)
                    }
                    ForEach(Array(hub.connectionLog.prefix(40).enumerated()), id: \.offset) { item in
                        Text(item.element).font(Theme.mono(11))
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle("Strap")
        }
    }

    private func row(_ title: String, _ value: String?) -> some View {
        LabeledContent(title, value: value ?? "—")
    }
}

/// Live evidence that the WHOOP app keeps syncing and acknowledging its own data.
private struct DataSafetyRows: View {
    @Environment(SensorHub.self) private var hub

    var body: some View {
        let acks = hub.foreignCounts["HISTORICAL_DATA_RESULT"] ?? 0
        let syncs = hub.foreignCounts["SEND_HISTORICAL_DATA"] ?? 0
        LabeledContent("History acknowledged by MX Whoop", value: "never")
        LabeledContent("WHOOP app syncs seen", value: hub.whoopAppPresent ? "\(syncs) syncs · \(acks) chunks acked" : "none yet")
        if let range = hub.biometrics.dataRange {
            LabeledContent("Waiting on strap for WHOOP", value: "\(range.pagesBehind) pages")
        }
        if hub.whoopAppUsesSensors {
            Label("The WHOOP app is using a sensor session; MX Whoop won't stop it.", systemImage: "hand.raised")
                .font(.caption).foregroundStyle(Theme.warning)
        }
    }
}
