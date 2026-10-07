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
        if analyzerFormat != MonoResampler.canonicalFormat {
            converter = AVAudioConverter(from: MonoResampler.canonicalFormat, to: analyzerFormat)
        }

        resultsTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    guard let self else { return }
                    if result.isFinal {
                        let words = Self.words(from: result.text)
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

    /// Feeds one canonical (16 kHz mono Float32) buffer. Called on the audio thread.
    func append(_ buffer: AVAudioPCMBuffer) {
        guard let continuation else { return }
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
        if let analyzer { try? await analyzer.finalizeAndFinishThroughEndOfInput() }
        await resultsTask?.value
        analyzeTask?.cancel()
        analyzer = nil
        onVolatile?("")
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
