import AudioDeps
import Foundation
import MinutesKit
import OSLog

/// One audio stream from samples to labeled lines. A single task consumes every
/// event in order, so the diarizer, voice ring, queue, and resolver are only ever
/// touched from that task. Audio exists here only in RAM; the ring is wiped at the end.
final class StreamPipeline {
    enum Event {
        case audio([Float])
        case words([TimedWord])
        case finish
    }

    let source: Source
    private let continuation: AsyncStream<Event>.Continuation
    private var task: Task<Void, Never>?
    private static let logger = Logger(subsystem: "com.northwoods.Minutes", category: "StreamPipeline")

    /// `emit` runs on the main actor and is awaited, so every line is delivered
    /// before `finish()` returns.
    init(
        source: Source,
        diarizer: StreamDiarizer?,
        embedder: CampPlusEmbedder?,
        voicePrint: VoicePrint?,
        threshold: Float,
        emit: @escaping @MainActor (SlotLine, SpeakerKey) -> Void
    ) {
        self.source = source
        let (stream, continuation) = AsyncStream<Event>.makeStream()
        self.continuation = continuation
        task = Task.detached(priority: .userInitiated) {
            var queue = AttributionQueue()
            var resolver = SpeakerResolver(source: source, threshold: threshold)
            var ring: VoiceRing? = (source == .room && voicePrint != nil && embedder != nil) ? VoiceRing() : nil
            var received = 0.0
            var diarizerHealthy = diarizer != nil
            let empty = SpeakerActivity(frameDuration: Double(ModelStore.diarizerConfig.frameDurationSeconds),
                                        slotCount: ModelStore.diarizerConfig.numSpeakers)

            for await event in stream {
                var flush = false
                switch event {
                case .audio(let samples):
                    if diarizerHealthy {
                        do { try diarizer?.process(samples) } catch {
                            diarizerHealthy = false
                            Self.logger.error("Diarizer failed; continuing without speaker labels")
                        }
                    }
                    ring?.append(samples)
                    received += Double(samples.count) / 16_000
                case .words(let words):
                    queue.enqueue(words, arrivedAt: received)
                case .finish:
                    if diarizerHealthy { try? diarizer?.finish() }
                    flush = true
                }

                let activity = diarizerHealthy ? (diarizer?.activity ?? empty) : empty
                for line in queue.drain(activity: activity, now: received, flush: flush) {
                    var similarity: Float?
                    if let ring, let embedder, let voicePrint, line.end - line.start >= 1.0,
                       var audio = ring.samples(from: line.start, to: line.end) {
                        if let embedding = try? await embedder.embed(audio: audio) {
                            similarity = voicePrint.similarity(to: embedding)
                        }
                        audio.withUnsafeMutableBufferPointer { $0.update(repeating: 0) }
                    }
                    let key = resolver.resolve(slot: line.slot, similarity: similarity)
                    await emit(line, key)
                }
                if flush { break }
            }
            ring?.wipe()
        }
    }

    func audio(_ samples: [Float]) { continuation.yield(.audio(samples)) }

    func words(_ words: [TimedWord]) { continuation.yield(.words(words)) }

    /// Drains everything, waits for the last line, and wipes the voice ring.
    func finish() async {
        continuation.yield(.finish)
        continuation.finish()
        await task?.value
    }
}
