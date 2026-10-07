import AVFAudio
import Foundation

/// `Minutes --audio-check`: measures echo cancellation. Plays a spoken sentence
/// through the speakers and prints per-second peak levels (numbers only) for the
/// call tap, the voice-processed mic, and the raw mic. Nothing is saved.
enum AudioCheck {
    private final class Peaks: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String: Float] = [:]
        func record(_ key: String, _ level: Float) { lock.withLock { values[key] = max(values[key] ?? 0, level) } }
        func take() -> [String: Float] { lock.withLock { defer { values = [:] }; return values } }
    }

    static func run(voiceProcessing: Bool) -> Never {
        let peaks = Peaks()
        let mic = MicCapture(voiceProcessing: voiceProcessing)
        let call = CallCapture()
        mic.onLevel = { peaks.record("mic", $0) }
        call.onLevel = { peaks.record("call", $0) }
        let micOnly = CommandLine.arguments.contains("--mic-only")
        do {
            try mic.start()
        } catch {
            print("audio-check: mic start failed: \(error)")
            exit(1)
        }
        if !micOnly {
            do {
                try call.start()
            } catch {
                print("audio-check: call start failed: \(error)")
                exit(1)
            }
        }
        print("audio-check: voiceProcessing=\(voiceProcessing)  sec  call  mic   (speech plays from second 4)")
        let speaker = Process()
        speaker.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        speaker.arguments = ["This is the Minutes echo test. The call audio should not appear on the microphone. One two three four five six seven."]
        for second in 1...14 {
            if second == 4 { try? speaker.run() }
            RunLoop.main.run(until: Date().addingTimeInterval(1))
            let p = peaks.take()
            print(String(format: "audio-check: %3d  %.4f  %.4f", second, p["call"] ?? 0, p["mic"] ?? 0))
        }
        mic.stop()
        call.stop()
        exit(0)
    }
}
