import AudioDeps
import AVFAudio
import Observation
import OSLog
import Speech

/// Downloads and holds the on-device models: Apple's speech model, the Sortformer
/// speaker model, and the CAM++ voice model. Model files are not audio.
@MainActor @Observable
final class ModelStore {
    enum State: Equatable {
        case idle
        case preparing(String)
        case ready
        case failed(String)
    }

    static let diarizerConfig = SortformerConfig.balancedV2_1

    private(set) var state: State = .idle
    private(set) var locale: Locale?
    private(set) var analyzerFormat: AVAudioFormat?
    private(set) var embedder: CampPlusEmbedder?
    private static let logger = Logger(subsystem: "com.northwoods.Minutes", category: "ModelStore")

    var isReady: Bool { state == .ready }

    func prepare() async {
        switch state {
        case .ready, .preparing: return
        default: break
        }
        do {
            state = .preparing("Downloading the speech model")
            Self.logger.notice("prepare: locale"); Trace.step("prepare: locale")
            let resolved = await SpeechTranscriber.supportedLocale(equivalentTo: Locale.current) ?? Locale(identifier: "en-US")
            let probe = SpeechTranscriber(locale: resolved, transcriptionOptions: [],
                                          reportingOptions: [.volatileResults], attributeOptions: [.audioTimeRange])
            Self.logger.notice("prepare: asset request"); Trace.step("prepare: asset request")
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [probe]) {
                Self.logger.notice("prepare: installing speech asset"); Trace.step("prepare: installing speech asset")
                try await request.downloadAndInstall()
            }
            Self.logger.notice("prepare: analyzer format"); Trace.step("prepare: analyzer format")
            analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [probe])
            locale = resolved

            state = .preparing("Downloading the speaker models")
            Self.logger.notice("prepare: sortformer"); Trace.step("prepare: sortformer")
            _ = try await SortformerModels.loadFromHuggingFace(config: Self.diarizerConfig)
            Self.logger.notice("prepare: cam++"); Trace.step("prepare: cam++")
            embedder = try await CampPlusEmbedder.load()

            state = .ready
            Self.logger.notice("prepare: models ready"); Trace.step("prepare: models ready")
        } catch let error as ModelError {
            state = .failed(error.message)
        } catch {
            Self.logger.error("Model preparation failed")
            state = .failed("Minutes couldn't download its speech models. Check the internet connection and try again. (\(error.localizedDescription))")
        }
    }

    /// A fresh diarizer model instance per stream (loads from the local cache).
    func makeDiarizerModels() async throws -> SortformerModels {
        try await SortformerModels.loadFromHuggingFace(config: Self.diarizerConfig)
    }

    struct ModelError: Error {
        let message: String
        init(_ message: String) { self.message = message }
    }
}
