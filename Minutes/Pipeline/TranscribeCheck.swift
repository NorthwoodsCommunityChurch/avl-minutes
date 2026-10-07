import Foundation
import MinutesKit

/// `Minutes --transcribe-check`: plays two synthetic voices taking turns through the
/// Mac's output, transcribes them from the call tap, and prints the labeled lines.
/// Writes nothing to Notes or disk unless `--save` is passed (`--both` adds the room mic).
enum TranscribeCheck {
    /// Unbuffered so progress shows even if the run hangs.
    static func print(_ text: String) {
        FileHandle.standardError.write(Data((text + "\n").utf8))
    }

    static func run() -> Never {
        MainActor.assumeIsolated {
            Task { @MainActor in
                let models = ModelStore()
                print("transcribe-check: preparing models…")
                await models.prepare()
                guard models.isReady else {
                    print("transcribe-check: models not ready: \(models.state)")
                    exit(1)
                }
                let session = MeetingSession(models: models, bridge: NotesBridge())
                let arguments = CommandLine.arguments
                session.saveToNotes = arguments.contains("--save")
                let sources: Set<Source> = arguments.contains("--both") ? [.room, .call] : [.call]
                let began = Date()
                await session.start(title: "Minutes transcribe check - safe to delete", sources: sources)
                guard session.phase == .listening else {
                    print("transcribe-check: start failed: \(session.startError ?? "unknown")")
                    exit(1)
                }
                print(String(format: "transcribe-check: listening after %.1f s", Date().timeIntervalSince(began)))
                let turns: [(String, String)] = [
                    ("Samantha", "Good morning everyone. Let's start with the lobby screens. They need new mounts before Sunday."),
                    ("Daniel", "I can order the mounts today. The budget for that is about four hundred dollars."),
                    ("Samantha", "Great, please send me the quote by Friday so I can approve it."),
                ]
                for (voice, text) in turns {
                    let say = Process()
                    say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
                    say.arguments = ["-v", voice, text]
                    try? say.run()
                    while say.isRunning { try? await Task.sleep(for: .milliseconds(200)) }
                    try? await Task.sleep(for: .milliseconds(700))
                }
                try? await Task.sleep(for: .seconds(3))
                let stopAt = Date()
                await session.stop()
                print(String(format: "transcribe-check: stop took %.1f s", Date().timeIntervalSince(stopAt)))
                if let id = session.noteID {
                    print("transcribe-check: saved note \(id) (last save error: \(session.saveError ?? "none"))")
                }
                for (source, message) in session.captureErrors {
                    print("transcribe-check: \(source) error: \(message)")
                }
                for line in session.document?.lines ?? [] {
                    print("transcribe-check: [\(TranscriptDocument.timestamp(ms: line.startMs))] \(line.speaker.displayName): \(line.text)")
                }
                exit(0)
            }
        }
        RunLoop.main.run()
        exit(0)
    }
}
