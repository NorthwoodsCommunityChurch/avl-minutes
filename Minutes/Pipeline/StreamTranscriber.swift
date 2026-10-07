import AVFAudio
import CoreMedia
import MinutesKit
import OSLog
import Speech

/// Apple SpeechAnalyzer for one audio stream. Single use: one per stream per meeting.
/// Reports in-progress text for the live view and finished words with their times.
final class StreamTranscriber {
    var onVolatile: ((String) -> Void)?
    var onFinal: (([TimedWord]) -> Void)?

    private let locale: Locale
    private let analyzerFormat: AVAudioFormat
    private var analyzer: SpeechAnalyzer?
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private var analyzeTask: Task<Void, Never>?
    private var converter: AVAudioConverter?
    private static let logger = Logger(subsystem: "com.northwoods.Minutes", category: "StreamTranscriber")

    init(locale: Locale, analyzerFormat: AVAudioFormat) {
        self.locale = locale
        self.analyzerFormat = analyzerFormat
    }

    func start() {
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [],
                                            reportingOptions: [.volatileResults], attributeOptions: [.audioTimeRange])
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzer = analyzer
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        self.continuation = continuation
        Trace.step("transcriber: analyzer format \(analyzerFormat.commonFormat.rawValue) \(analyzerFormat.sampleRate) Hz \(analyzerFormat.channelCount) ch")
        if analyzerFormat != MonoResampler.canonicalFormat {
            converter = AVAudioConverter(from: MonoResampler.canonicalFormat, to: analyzerFormat)
        }

        resultsTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    guard let self else { return }
                    if result.isFinal {
                        let words = Self.words(from: result.text)
                        Trace.step(String(format: "transcriber: final %.2f–%.2f s, %d words",
                                          result.range.start.seconds, result.range.end.seconds, words.count))
                        if !words.isEmpty { self.onFinal?(words) }
                    } else {
                        self.onVolatile?(String(result.text.characters))
                    }
                }
            } catch {
                Self.logger.error("Transcriber results ended with an error")
            }
        }
        analyzeTask = Task {
            do {
                _ = try await analyzer.analyzeSequence(stream)
            } catch {
                Self.logger.error("Analyzer stopped with an error")
            }
        }
    }

    private var fedFrames = 0

    /// Feeds one canonical (16 kHz mono Float32) buffer. Called on the audio thread.
    func append(_ buffer: AVAudioPCMBuffer) {
        guard let continuation else { return }
        if Trace.enabled {
            fedFrames += Int(buffer.frameLength)
            if fedFrames % 160_000 < Int(buffer.frameLength) { Trace.step("transcriber: fed \(fedFrames / 16_000) s") }
        }
        guard let converter else {
            continuation.yield(AnalyzerInput(buffer: buffer))
            return
        }
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * analyzerFormat.sampleRate / buffer.format.sampleRate) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: analyzerFormat, frameCapacity: capacity) else { return }
        var consumed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        if error == nil, out.frameLength > 0 { continuation.yield(AnalyzerInput(buffer: out)) }
    }

    /// Ends input and waits until every final result has been delivered.
    func finish() async {
        continuation?.finish()
        continuation = nil
        Trace.step("transcriber: finalize")
        if let analyzer { try? await analyzer.finalizeAndFinishThroughEndOfInput() }
        Trace.step("transcriber: waiting for results")
        // SpeechTranscriber occasionally never ends its results stream after
        // finalizing (seen ~1 in 6 runs on macOS 26.5). Wait up to 5 s, then move on.
        if let resultsTask, await !Self.finishes(resultsTask, within: 5) {
            Self.logger.error("Transcriber results did not end; cancelling")
            Trace.step("transcriber: results timed out")
            resultsTask.cancel()
        }
        Trace.step("transcriber: done")
        analyzeTask?.cancel()
        analyzer = nil
        onVolatile?("")
    }

    /// True if `task` completes within `seconds`. Never waits on the loser.
    private static func finishes(_ task: Task<Void, Never>, within seconds: Double) async -> Bool {
        final class Once: @unchecked Sendable {
            private let lock = NSLock()
            private var fired = false
            func claim() -> Bool { lock.withLock { defer { fired = true }; return !fired } }
        }
        let once = Once()
        return await withCheckedContinuation { continuation in
            Task {
                await task.value
                if once.claim() { continuation.resume(returning: true) }
            }
            Task {
                try? await Task.sleep(for: .seconds(seconds))
                if once.claim() { continuation.resume(returning: false) }
            }
        }
    }

    /// Splits a final result into timed words. Runs without a time range (spaces,
    /// punctuation) attach to the neighboring word so the text reads unchanged.
    static func words(from text: AttributedString) -> [TimedWord] {
        var words: [TimedWord] = []
        var pendingPrefix = ""
        for run in text.runs {
            let piece = String(text[run.range].characters)
            if let range = run[AttributeScopes.SpeechAttributes.TimeRangeAttribute.self] {
                words.append(TimedWord(text: pendingPrefix + piece, start: range.start.seconds, end: range.end.seconds))
                pendingPrefix = ""
            } else if !words.isEmpty {
                words[words.count - 1].text += piece
            } else {
                pendingPrefix += piece
            }
        }
        return words
    }
}
