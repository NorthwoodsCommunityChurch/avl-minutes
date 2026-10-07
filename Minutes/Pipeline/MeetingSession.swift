import AVFAudio
import Foundation
import MinutesKit
import Observation
import OSLog

/// One meeting at a time: capture → transcribe → label → Apple Notes.
/// The transcript lives in memory and is written to its note every 30 seconds and
/// at Stop. Audio is never written anywhere.
@MainActor @Observable
final class MeetingSession {
    enum Phase: Equatable {
        case idle
        case starting
        case listening
        case stopping
        case finished
    }

    private(set) var phase: Phase = .idle
    private(set) var startedAt: Date?
    private(set) var liveLines: [TranscriptLine] = []
    private(set) var volatileText: [Source: String] = [:]
    private(set) var levels: [Source: Float] = [:]
    private(set) var lastSaved: Date?
    private(set) var saveError: String?
    private(set) var startError: String?
    private(set) var captureErrors: [Source: String] = [:]
    private(set) var noteID: String?
    private(set) var document: TranscriptDocument?

    /// When false, nothing is written to Notes (used by `--transcribe-check`).
    var saveToNotes = true
    var folderName: () -> String = { "Meeting Transcripts" }
    var onFinished: (() -> Void)?

    private let models: ModelStore
    private let bridge: NotesBridge
    private var streams: [Source: ActiveStream] = [:]
    private var saveTimer: Timer?
    private var isSaving = false
    private static let saveInterval: TimeInterval = 30
    private static let logger = Logger(subsystem: "com.northwoods.Minutes", category: "MeetingSession")

    private struct ActiveStream {
        let transcriber: StreamTranscriber
        let pipeline: StreamPipeline
        let clock: StreamClock
        let stopCapture: () -> Void
    }

    /// Wall-clock offset of a stream's first buffer from the meeting start.
    final class StreamClock: @unchecked Sendable {
        private let lock = NSLock()
        private var offset: TimeInterval?
        func markFirstBuffer(meetingStart: Date) {
            lock.withLock { if offset == nil { offset = Date().timeIntervalSince(meetingStart) } }
        }
        var offsetSeconds: TimeInterval { lock.withLock { offset ?? 0 } }
    }

    init(models: ModelStore, bridge: NotesBridge) {
        self.models = models
        self.bridge = bridge
    }

    var isActive: Bool { phase == .starting || phase == .listening || phase == .stopping }

    func start(title: String, sources: Set<Source>) async {
        guard !isActive, !sources.isEmpty else { return }
        phase = .starting
        startError = nil
        saveError = nil
        captureErrors = [:]
        liveLines = []
        volatileText = [:]
        levels = [:]
        noteID = nil
        lastSaved = nil

        await models.prepare()
        guard models.isReady, let locale = models.locale, let analyzerFormat = models.analyzerFormat else {
            if case .failed(let message) = models.state { startError = message } else { startError = "Speech models aren't ready yet." }
            phase = .idle
            return
        }

        let start = Date()
        startedAt = start
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        document = TranscriptDocument(
            title: trimmed.isEmpty ? TranscriptDocument.defaultTitle(for: start, timeZone: .current) : trimmed,
            startedAt: start,
            sources: sources
        )
        let voicePrint = try? VoicePrint.load(from: VoicePrint.defaultURL())

        for source in Source.allCases where sources.contains(source) {
            Trace.step("session: making \(source.rawValue) stream")
            do {
                streams[source] = try await makeStream(source, start: start, locale: locale,
                                                       analyzerFormat: analyzerFormat, voicePrint: voicePrint)
            } catch {
                captureErrors[source] = error.localizedDescription
            }
        }
        guard !streams.isEmpty else {
            startError = captureErrors.values.first ?? "Minutes couldn't start listening."
            document = nil
            startedAt = nil
            phase = .idle
            return
        }
        document?.sources = Set(streams.keys)
        phase = .listening
        saveTimer = Timer.scheduledTimer(withTimeInterval: Self.saveInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.save() }
        }
        Task { await save() }
        Self.logger.info("Meeting started with \(self.streams.count) source(s)")
    }

    func stop() async {
        guard phase == .listening else { return }
        phase = .stopping
        saveTimer?.invalidate()
        saveTimer = nil
        for stream in streams.values { stream.stopCapture() }
        for (source, stream) in streams {
            Self.logger.info("Stopping \(source.rawValue, privacy: .public): transcriber")
            Trace.step("stop \(source.rawValue): transcriber finish")
            await stream.transcriber.finish()
            Self.logger.info("Stopping \(source.rawValue, privacy: .public): pipeline")
            Trace.step("stop \(source.rawValue): pipeline finish")
            await stream.pipeline.finish()
        }
        Self.logger.info("Streams stopped; final save")
        Trace.step("stop: streams stopped")
        streams = [:]
        levels = [:]
        volatileText = [:]
        document?.endedAt = Date()
        while isSaving { try? await Task.sleep(for: .milliseconds(100)) }   // never skip the final save
        await save()
        phase = .finished
        Self.logger.info("Meeting stopped")
        onFinished?()
    }

    /// Back to idle after the "saved" screen; keeps nothing but the note in Notes.
    func reset() {
        guard phase == .finished else { return }
        document = nil
        liveLines = []
        startedAt = nil
        phase = .idle
    }

    func plainTextForCopy() -> String? {
        document?.plainText(timeZone: .current, now: Date())
    }

    // MARK: - Streams

    private func makeStream(_ source: Source, start: Date, locale: Locale, analyzerFormat: AVAudioFormat,
                            voicePrint: VoicePrint?) async throws -> ActiveStream {
        if source == .room {
            guard await MicCapture.requestPermission() else {
                throw SessionError("Microphone access is off for Minutes. Turn it on in System Settings > Privacy & Security > Microphone.")
            }
        }
        let diarizer: StreamDiarizer?
        Trace.step("stream \(source.rawValue): loading diarizer models")
        do {
            diarizer = StreamDiarizer(models: try await models.makeDiarizerModels())
        } catch {
            diarizer = nil
            Self.logger.error("Speaker model unavailable; lines will be labeled Unknown")
        }
        Trace.step("stream \(source.rawValue): diarizer ready")
        let clock = StreamClock()
        let pipeline = StreamPipeline(
            source: source, diarizer: diarizer, embedder: models.embedder, voicePrint: voicePrint, threshold: 0.5
        ) { [weak self] line, key in
            self?.add(line, key: key, source: source, clock: clock)
        }
        let transcriber = StreamTranscriber(locale: locale, analyzerFormat: analyzerFormat)
        transcriber.onFinal = { words in pipeline.words(words) }
        transcriber.onVolatile = { text in
            Task { @MainActor [weak self] in self?.volatileText[source] = text }
        }
        transcriber.start()
        Trace.step("stream \(source.rawValue): transcriber started")

        let onBuffer: (AVAudioPCMBuffer) -> Void = { buffer in
            clock.markFirstBuffer(meetingStart: start)
            transcriber.append(buffer)
            pipeline.audio(MonoResampler.samples(buffer))
        }
        let onLevel: (Float) -> Void = { level in
            Task { @MainActor [weak self] in self?.levels[source] = level }
        }

        switch source {
        case .room:
            let mic = MicCapture()
            mic.onBuffer = onBuffer
            mic.onLevel = onLevel
            Trace.step("stream room: starting capture")
            do { try mic.start() } catch {
                await transcriber.finish()
                await pipeline.finish()
                throw SessionError("The microphone couldn't start: \(error.localizedDescription)")
            }
            return ActiveStream(transcriber: transcriber, pipeline: pipeline, clock: clock, stopCapture: { mic.stop() })
        case .call:
            let call = CallCapture()
            call.onBuffer = onBuffer
            call.onLevel = onLevel
            call.onFailure = { message in
                Task { @MainActor [weak self] in self?.captureErrors[.call] = message }
            }
            Trace.step("stream call: starting capture")
            do { try call.start() } catch {
                await transcriber.finish()
                await pipeline.finish()
                throw SessionError(error.localizedDescription)
            }
            return ActiveStream(transcriber: transcriber, pipeline: pipeline, clock: clock, stopCapture: { call.stop() })
        }
    }

    private func add(_ line: SlotLine, key: SpeakerKey, source: Source, clock: StreamClock) {
        let offset = clock.offsetSeconds
        let transcriptLine = TranscriptLine(
            startMs: Int(((offset + line.start) * 1000).rounded()),
            endMs: Int(((offset + line.end) * 1000).rounded()),
            source: source,
            speaker: key,
            text: line.text
        )
        document?.append(transcriptLine)
        liveLines.append(transcriptLine)
        liveLines.sort { $0.startMs < $1.startMs }
        if liveLines.count > 6 { liveLines.removeFirst(liveLines.count - 6) }
    }

    // MARK: - Saving to Notes

    private func save() async {
        guard saveToNotes, !isSaving, let document else { return }
        isSaving = true
        defer { isSaving = false }
        let html = document.html(timeZone: .current, now: Date())
        do {
            if let noteID {
                try await bridge.setBody(noteID: noteID, html: html)
            } else {
                noteID = try await bridge.createNote(folder: folderName(), html: html)
            }
            lastSaved = Date()
            saveError = nil
        } catch {
            saveError = error.localizedDescription
            Self.logger.error("Saving the transcript to Notes failed")
        }
    }

    #if DEBUG
    /// Sample state for the `--gallery` screenshot mode. Debug builds only.
    func loadPreview(phase: Phase, lines: [TranscriptLine], volatile: [Source: String] = [:]) {
        let start = Date().addingTimeInterval(-872)
        var document = TranscriptDocument(title: "Staff meeting", startedAt: start, sources: [.room, .call])
        for line in lines { document.append(line) }
        if phase == .finished { document.endedAt = start.addingTimeInterval(47 * 60) }
        self.document = document
        self.startedAt = start
        self.liveLines = lines
        self.volatileText = volatile
        self.levels = [.room: 0.08, .call: 0.02]
        self.lastSaved = Date().addingTimeInterval(-12)
        self.noteID = "preview"
        self.phase = phase
    }
    #endif

    struct SessionError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}
