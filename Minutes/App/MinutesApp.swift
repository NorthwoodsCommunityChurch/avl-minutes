import SwiftUI

struct MinutesApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        MenuBarExtra("Minutes", systemImage: "waveform") {
            VStack(alignment: .leading, spacing: 8) {
                if let error = model.startupError {
                    Text(error).foregroundStyle(.red)
                }
                if let indexer = model.indexer {
                    Text("Notes indexed: \(indexer.noteCount)")
                    Text(indexer.lastRefresh.map { "Last refresh: \($0.formatted(date: .omitted, time: .standard))" } ?? "Not refreshed yet")
                    if let error = indexer.lastError { Text(error).foregroundStyle(.red) }
                    Button(indexer.isRefreshing ? "Refreshing…" : "Refresh now") {
                        Task { await indexer.refreshNow() }
                    }
                    .disabled(indexer.isRefreshing)
                }
                Divider()
                Button("Quit Minutes") { NSApplication.shared.terminate(nil) }
            }
            .padding()
            .frame(width: 280, alignment: .leading)
        }
        .menuBarExtraStyle(.window)
    }
}
