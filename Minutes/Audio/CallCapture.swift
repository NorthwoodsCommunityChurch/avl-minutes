import AVFAudio
import CoreAudio
import OSLog

/// Everything the Mac plays (Teams, Zoom, browser calls), captured with a Core Audio
/// process tap and read in RAM. Minutes' own process is excluded. A watchdog rebuilds
/// the tap if it goes silent while other apps are clearly playing (a known macOS bug).
final class CallCapture {
    var onBuffer: ((AVAudioPCMBuffer) -> Void)?
    var onLevel: ((Float) -> Void)?
    var onFailure: ((String) -> Void)?

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var engine: AVAudioEngine?
    private let resampler = MonoResampler(channelMode: .sumAll)
    private var watchdog: Timer?
    private let lastSound = LastSound()
    private var lastRebuild = Date.distantPast
    private static let logger = Logger(subsystem: "com.northwoods.Minutes", category: "CallCapture")

    /// Timestamp of the last non-silent buffer, written on the audio thread.
    private final class LastSound: @unchecked Sendable {
        private let lock = NSLock()
        private var value = Date()
        func touch() { lock.withLock { value = Date() } }
        func get() -> Date { lock.withLock { value } }
    }

    var isRunning: Bool { engine?.isRunning == true }

    func start() throws {
        try build()
        watchdog = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.checkForSilentTap()
        }
    }

    func stop() {
        watchdog?.invalidate()
        watchdog = nil
        tearDown()
    }

    private func build() throws {
        var excluded: [AudioObjectID] = []
        if let me = CoreAudioProcesses.objectID(forPID: ProcessInfo.processInfo.processIdentifier) {
            excluded.append(me)
        }
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: excluded)
        description.name = "Minutes call audio"
        // muteBehavior stays at its default (unmuted): the call still plays normally.

        var newTap = AudioObjectID(kAudioObjectUnknown)
        let tapStatus = AudioHardwareCreateProcessTap(description, &newTap)
        guard tapStatus == noErr, newTap != kAudioObjectUnknown else {
            throw CaptureError.tapFailed(tapStatus)
        }
        tapID = newTap

        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Minutes call audio",
            kAudioAggregateDeviceUIDKey: "com.northwoods.Minutes.tap." + description.uuid.uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [
                [kAudioSubTapUIDKey: description.uuid.uuidString, kAudioSubTapDriftCompensationKey: true],
            ],
        ]
        var newAggregate = AudioObjectID(kAudioObjectUnknown)
        let aggregateStatus = AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &newAggregate)
        guard aggregateStatus == noErr, newAggregate != kAudioObjectUnknown else {
            tearDown()
            throw CaptureError.aggregateFailed(aggregateStatus)
        }
        aggregateID = newAggregate

        let engine = AVAudioEngine()
        do {
            try engine.inputNode.auAudioUnit.setDeviceID(aggregateID)
        } catch {
            tearDown()
            throw error
        }
        let format = engine.inputNode.outputFormat(forBus: 0)
        engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            self?.handle(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            engine.inputNode.removeTap(onBus: 0)
            tearDown()
            throw error
        }
        self.engine = engine
        lastSound.touch()
        Self.logger.info("Call capture started (\(format.channelCount) ch @ \(format.sampleRate) Hz)")
    }

    private func tearDown() {
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        engine = nil
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    private func handle(_ buffer: AVAudioPCMBuffer) {
        guard let mono = resampler.convert(buffer) else { return }
        let level = MonoResampler.rms(mono)
        if level > 1e-6 { lastSound.touch() }
        onLevel?(level)
        onBuffer?(mono)
    }

    private func checkForSilentTap() {
        let silentFor = Date().timeIntervalSince(lastSound.get())
        guard silentFor > 10, Date().timeIntervalSince(lastRebuild) > 30,
              CoreAudioProcesses.anyOtherProcessOutputting() else { return }
        Self.logger.info("Call tap silent while audio is playing; rebuilding")
        lastRebuild = Date()
        tearDown()
        do {
            try build()
        } catch {
            onFailure?("Call audio stopped and couldn't restart.")
        }
    }

    enum CaptureError: LocalizedError {
        case tapFailed(OSStatus)
        case aggregateFailed(OSStatus)

        var errorDescription: String? {
            switch self {
            case .tapFailed: "Minutes couldn't listen to call audio. Allow it in System Settings > Privacy & Security > Screen & System Audio Recording."
            case .aggregateFailed(let status): "Call audio setup failed (\(status))."
            }
        }
    }
}
