import AVFAudio
import OSLog

/// The room microphone with Apple's voice processing turned on, so sound coming out
/// of the Mac's speakers (a call) is cancelled from what the mic hears.
/// Buffers are delivered in RAM on the audio thread and never stored.
final class MicCapture {
    var onBuffer: ((AVAudioPCMBuffer) -> Void)?
    var onLevel: ((Float) -> Void)?
    /// Called on the main thread when the mic stops and can't be restarted.
    var onFailure: ((String) -> Void)?

    private let engine = AVAudioEngine()
    private let voiceProcessing: Bool
    private let resampler = MonoResampler(channelMode: .firstChannel)
    private var observer: NSObjectProtocol?
    private(set) var isRunning = false
    private static let logger = Logger(subsystem: "com.northwoods.Minutes", category: "MicCapture")

    init(voiceProcessing: Bool = true) {
        self.voiceProcessing = voiceProcessing
    }

    static func requestPermission() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }

    func start() throws {
        try configureAndStart()
        observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            self?.restartAfterConfigurationChange()
        }
    }

    func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false
    }

    private func configureAndStart() throws {
        let input = engine.inputNode
        if voiceProcessing {
            try input.setVoiceProcessingEnabled(true)
            input.voiceProcessingOtherAudioDuckingConfiguration =
                AVAudioVoiceProcessingOtherAudioDuckingConfiguration(enableAdvancedDucking: false, duckingLevel: .min)
            // Don't touch mainMixerNode here: instantiating the mixer makes the
            // voice-processing output unit fail to initialize (-10875) on macOS 26.
        }
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            self?.handle(buffer)
        }
        engine.prepare()
        try engine.start()
        isRunning = true
        Self.logger.info("Mic capture started (\(format.channelCount) ch @ \(format.sampleRate) Hz)")
    }

    private func restartAfterConfigurationChange() {
        Self.logger.info("Audio configuration changed; restarting mic")
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        do {
            try configureAndStart()
        } catch {
            isRunning = false
            Self.logger.error("Mic restart failed; trying once more")
            // Devices often settle a moment after the change notification.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                guard let self, self.observer != nil, !self.isRunning else { return }
                do {
                    try self.configureAndStart()
                } catch {
                    Self.logger.error("Mic restart failed again")
                    self.onFailure?("The microphone stopped and couldn't restart. Room lines aren't being transcribed.")
                }
            }
        }
    }

    private func handle(_ buffer: AVAudioPCMBuffer) {
        guard let mono = resampler.convert(buffer) else { return }
        onLevel?(MonoResampler.rms(mono))
        onBuffer?(mono)
    }
}
