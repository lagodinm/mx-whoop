import SwiftUI

@main
struct MXWhoopApp: App {
    @State private var hub: SensorHub
    @State private var lieDetector: LieDetectorSession

    init() {
        let hub = SensorHub()
        _hub = State(initialValue: hub)
        _lieDetector = State(initialValue: LieDetectorSession(hub: hub))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(hub)
                .environment(lieDetector)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
        }
    }
}

struct RootView: View {
    var body: some View {
        TabView {
            LiveView()
                .tabItem { Label("Live", systemImage: "waveform.path.ecg") }
            LieDetectorView()
                .tabItem { Label("Lie Detector", systemImage: "questionmark.bubble") }
            RawView()
                .tabItem { Label("Raw", systemImage: "chevron.left.forwardslash.chevron.right") }
            StrapView()
                .tabItem { Label("Strap", systemImage: "sensor.tag.radiowaves.forward") }
        }
    }
}
