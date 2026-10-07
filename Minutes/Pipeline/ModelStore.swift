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
            let resolved = await SpeechTranscriber.supportedLocale(equivalentTo: Locale.current) ?? Locale(identifier: "en-US")
            let probe = SpeechTranscriber(locale: resolved, transcriptionOptions: [],
                                          reportingOptions: [.volatileResults], attributeOptions: [.audioTimeRange])
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [probe]) {
                try await request.downloadAndInstall()
            }
            analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [probe])
            locale = resolved

            state = .preparing("Downloading the speaker models")
            _ = try await SortformerModels.loadFromHuggingFace(config: Self.diarizerConfig)
            embedder = try await CampPlusEmbedder.load()

            state = .ready
            Self.logger.info("Models ready")
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
