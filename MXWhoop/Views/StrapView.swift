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
                    row("Last event", hub.lastEvent?.name)
                }

                Section("Settings") {
                    Toggle("Buzz the strap on a LIE verdict", isOn: $hub.buzzOnLie)
                }

                Section("How the connection works") {
                    Text("""
                    • The app talks to the strap's own Bluetooth service (FD4B0001), the same one the official app uses on WHOOP 5.0 and MG.
                    • The strap only accepts commands over an encrypted (bonded) link. The first time, iOS shows a pairing request; accept it.
                    • If the official WHOOP app on this iPhone is already connected, both apps share the link.
                    • If the strap is bonded to a different phone, put it in pairing mode: tap the strap until the LED flashes blue.
                    • This app only streams live data. It never syncs or deletes history, so the WHOOP app keeps working normally.
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
