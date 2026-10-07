import SwiftUI

struct MinutesApp: App {
    var body: some Scene {
        MenuBarExtra("Minutes", systemImage: "waveform") {
            Text("Minutes")
                .padding()
        }
        .menuBarExtraStyle(.window)
    }
}
