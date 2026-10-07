#if DEBUG
import MinutesKit
import SwiftUI

/// `Minutes --gallery` (debug builds): every popover state plus Welcome and Settings in
/// one window, with sample data, for design review screenshots.
enum Gallery {
    @MainActor static func run() -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let ready = AppModel()
        let listening = AppModel()
        let saved = AppModel()
        let lines = [
            TranscriptLine(startMs: 840_000, endMs: 843_000, source: .call, speaker: .call(1), text: "Can you send me the quote for the mounts?"),
            TranscriptLine(startMs: 846_000, endMs: 849_000, source: .room, speaker: .room(1), text: "I think the lobby screens can wait until spring."),
            TranscriptLine(startMs: 851_000, endMs: 855_000, source: .room, speaker: .me, text: "Agreed. I'll approve it once the quote comes in on Friday."),
        ]
        listening.session.loadPreview(phase: .listening, lines: lines, volatile: [.call: "Great, I'll get that over to you by"])
        saved.session.loadPreview(phase: .finished, lines: lines)

        let content = HStack(alignment: .top, spacing: 28) {
            VStack(alignment: .leading, spacing: 28) {
                card("Ready") { MenuContent(model: ready) }
                card("Saved") { MenuContent(model: saved) }
            }
            card("Listening") { MenuContent(model: listening) }
            card("Welcome") { WelcomeView(model: ready) }
            card("Settings") { SettingsView(model: ready) }
        }
        .padding(28)
        .background(.background)

        let window = PassivePanel(contentRect: NSRect(x: 0, y: 0, width: 1900, height: 1000),
                                  styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false)
        window.title = "Minutes gallery"
        window.contentView = NSHostingView(rootView: content)
        // Off-screen and never activated: it doesn't cover the user's work, and
        // `screencapture -l <id>` grabs only this window.
        window.setFrameOrigin(NSPoint(x: -6000, y: 0))
        window.orderFrontRegardless()
        FileHandle.standardError.write(Data("GALLERY_WINDOW=\(window.windowNumber)\n".utf8))
        app.run()
        exit(0)
    }

    /// Never becomes key or main, so it can't take the user's keystrokes.
    private final class PassivePanel: NSPanel {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }

    @MainActor private static func card(_ title: String, @ViewBuilder _ view: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            view()
                .background(.regularMaterial, in: .rect(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.separator))
        }
    }
}
#endif
