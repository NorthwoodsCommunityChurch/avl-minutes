import AudioDeps
import MinutesKit

/// Sortformer speaker detection for one stream, fed from RAM. Keeps the last two
/// minutes of finalized "who is talking" probabilities.
final class StreamDiarizer {
    private let diarizer: SortformerDiarizer
    private(set) var activity: SpeakerActivity

    init(models: SortformerModels) {
        let config = ModelStore.diarizerConfig
        diarizer = SortformerDiarizer(config: config)
        diarizer.initialize(models: models)
        activity = SpeakerActivity(frameDuration: Double(config.frameDurationSeconds), slotCount: config.numSpeakers)
    }

    func process(_ samples: [Float]) throws {
        if let update = try diarizer.process(samples: samples, sourceSampleRate: 16_000) { absorb(update) }
    }

    func finish() throws {
        if let update = try diarizer.finalizeSession() { absorb(update) }
    }

    private func absorb(_ update: DiarizerTimelineUpdate) {
        activity.append(startFrame: update.chunkResult.startFrame, predictions: update.chunkResult.finalizedPredictions)
    }
}
