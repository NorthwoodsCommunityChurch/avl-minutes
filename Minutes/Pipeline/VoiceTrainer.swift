import AudioDeps
import AVFAudio
import Foundation
import MinutesKit
import Observation
import OSLog

/// One-time voice training. Holds up to 45 s of mic audio in RAM, turns it into a
/// voiceprint (192 numbers), saves only the voiceprint, and zeroes the audio.
@MainActor @Observable
final class VoiceTrainer {
    enum State: Equatable {
        case idle
        case listening
        case processing
        case saved
        case failed(String)
    }

    static let requiredSpeech: Double = 20
    static let maxDuration: Double = 45
    private static let blockRMSForSpeech: Float = 0.03

    private(set) var state: State = .idle
    private(set) var speechSeconds: Double = 0
    private(set) var level: Float = 0

    private var mic: MicCapture?
    private var models: ModelStore?
    private let buffer = SampleBuffer()
    private var startedAt: Date?
    private static let logger = Logger(subsystem: "com.northwoods.Minutes", category: "VoiceTrainer")

    /// RAM-only sample store shared with the audio thread. Its storage is reserved up
    /// front so appends never reallocate (which would leave old audio in freed memory).
    final class SampleBuffer: @unchecked Sendable {
        private static let capacity = 16_000 * 50   // 50 s at 16 kHz, above the 45 s cap
        private let lock = NSLock()
        private var samples: [Float] = []

        init() { samples.reserveCapacity(Self.capacity) }

        func append(_ more: [Float]) {
            lock.withLock { samples += more.prefix(max(0, Self.capacity - samples.count)) }
        }
        var count: Int { lock.withLock { samples.count } }

        /// Hands over the samples without copying them. The caller zeroes them when done.
        func take() -> [Float] {
            lock.withLock {
                let taken = samples
                samples = []
                samples.reserveCapacity(Self.capacity)
                return taken
            }
        }

        /// Zeroes the samples in place, then empties the buffer.
        func wipe() {
            lock.withLock {
                samples.withUnsafeMutableBufferPointer { $0.update(repeating: 0) }
                samples.removeAll(keepingCapacity: true)
            }
        }
    }

    /// Back to the start screen (after a save or a failure) so the user can train again.
    func reset() {
        guard state != .listening, state != .processing else { return }
        state = .idle
        speechSeconds = 0
        level = 0
    }

    func start(models: ModelStore) async {
        guard state != .listening, state != .processing else { return }
        speechSeconds = 0
        buffer.wipe()
        await models.prepare()
        guard models.embedder != nil else {
            state = .failed("The voice model isn't ready. Check the internet connection and try again.")
            return
        }
        guard await MicCapture.requestPermission() else {
            state = .failed("Microphone access is off for Minutes. Turn it on in System Settings > Privacy & Security > Microphone.")
            return
        }
        let mic = MicCapture()
        mic.onBuffer = { [buffer] audio in
            buffer.append(MonoResampler.samples(audio))
            let level = MonoResampler.rms(audio)
            let seconds = Double(audio.frameLength) / audio.format.sampleRate
            Task { @MainActor [weak self] in self?.record(level: level, seconds: seconds) }
        }
        do {
            try mic.start()
        } catch {
            state = .failed("The microphone couldn't start: \(error.localizedDescription)")
            return
        }
        self.mic = mic
        self.models = models
        startedAt = Date()
        state = .listening
    }

    func cancel() {
        mic?.stop()
        mic = nil
        buffer.wipe()
        state = .idle
    }

    private func record(level: Float, seconds: Double) {
        guard state == .listening else { return }
        self.level = level
        if level > Self.blockRMSForSpeech { speechSeconds += seconds }
        let elapsed = Date().timeIntervalSince(startedAt ?? Date())
        if speechSeconds >= Self.requiredSpeech || elapsed >= Self.maxDuration {
            Task { await finish() }
        }
    }

    /// Stops listening and builds the voiceprint from what was heard.
    func finish() async {
        guard state == .listening, let mic else { return }
        mic.stop()
        self.mic = nil
        state = .processing
        var audio = buffer.take()
        defer { audio.withUnsafeMutableBufferPointer { $0.update(repeating: 0) } }
        guard let embedder = models?.embedder else {
            state = .failed("The voice model isn't ready.")
            return
        }
        let window = 48_000, step = 24_000
        var embeddings: [[Float]] = []
        var start = 0
        while start + window <= audio.count {
            var slice = Array(audio[start..<start + window])
            if Self.speechFraction(slice) >= 0.6, let embedding = try? await embedder.embed(audio: slice) {
                embeddings.append(embedding)
            }
            slice.withUnsafeMutableBufferPointer { $0.update(repeating: 0) }
            start += step
        }
        guard embeddings.count >= 3, let print = VoicePrint.make(from: embeddings) else {
            state = .failed("Minutes couldn't hear enough of your voice. Try again somewhere quieter, reading at a normal volume.")
            return
        }
        do {
            try print.save(to: VoicePrint.defaultURL())
            state = .saved
            Self.logger.info("Voiceprint saved from \(embeddings.count) windows")
        } catch {
            state = .failed("Minutes couldn't save your voiceprint: \(error.localizedDescription)")
        }
    }

    private static func speechFraction(_ samples: [Float]) -> Double {
        let block = 1_600   // 100 ms at 16 kHz
        var speech = 0, total = 0
        var i = 0
        while i + block <= samples.count {
            var sum: Float = 0
            for j in i..<i + block { sum += samples[j] * samples[j] }
            if (sum / Float(block)).squareRoot() > blockRMSForSpeech { speech += 1 }
            total += 1
            i += block
        }
        return total == 0 ? 0 : Double(speech) / Double(total)
    }
}
