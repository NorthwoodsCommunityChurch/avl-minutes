import SwiftUI

struct MinutesApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuContent(model: model)
        } label: {
            MenuBarLabel(session: model.session)
        }
        .menuBarExtraStyle(.window)

        Window("Welcome to Minutes", id: "welcome") {
            WelcomeView(model: model)
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(model.onboarded ? .suppressed : .presented)

        Settings {
            SettingsView(model: model)
        }
    }
}

/// Menu bar icon: a waveform when idle; a red record dot and the elapsed time while
/// listening (the same pattern macOS uses for screen recording).
///
/// The elapsed time comes from `MeetingSession.now`, which ticks once a second while listening.
/// Not a `TimelineView`: inside a `MenuBarExtra` label it makes the host re-render the status
/// item in a tight loop and the app hangs at 100% CPU (macOS 26.5, any schedule, any start date).
struct MenuBarLabel: View {
    let session: MeetingSession

    var body: some View {
        if session.isActive, let start = session.startedAt {
            HStack(spacing: 4) {
                Image(nsImage: Self.recordingImage)
                Text(ElapsedFormat.short(from: start, to: session.now))
                    .monospacedDigit()
            }
            .accessibilityLabel("Minutes is listening")
        } else {
            Image(systemName: "waveform")
                .accessibilityLabel("Minutes")
        }
    }

    /// Non-template so it stays red in the menu bar.
    private static let recordingImage: NSImage = {
        let configuration = NSImage.SymbolConfiguration(paletteColors: [.systemRed])
        let image = NSImage(systemSymbolName: "record.circle.fill", accessibilityDescription: "Listening")?
            .withSymbolConfiguration(configuration) ?? NSImage()
        image.isTemplate = false
        return image
    }()
}
