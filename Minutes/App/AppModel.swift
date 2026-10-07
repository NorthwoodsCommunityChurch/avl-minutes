import AVFAudio
import Foundation
import MinutesKit
import Observation
import ServiceManagement

/// Long-lived app services and user settings, created once at launch.
@MainActor @Observable
final class AppModel {
    let bridge = NotesBridge()
    let models = ModelStore()
    let trainer = VoiceTrainer()
    let updater = Updater()
    let session: MeetingSession
    let indexer: NotesIndexer?
    let startupError: String?

    var meetingTitle = ""
    private(set) var claudeStatus: ClaudeConnector.Status?
    private(set) var claudeError: String?
    private(set) var hasVoicePrint = false
    private(set) var microphoneAllowed = AVAudioApplication.shared.recordPermission == .granted
    private(set) var callAudioChecked = false
    private(set) var callAudioError: String?
    private(set) var openError: String?

    // MARK: Settings (UserDefaults-backed so they persist)

    var useRoom: Bool {
        didSet { defaults.set(useRoom, forKey: "useRoom") }
    }
    var useCall: Bool {
        didSet { defaults.set(useCall, forKey: "useCall") }
    }
    var remindOnStart: Bool {
        didSet { defaults.set(remindOnStart, forKey: "remindOnStart") }
    }
    var transcriptFolder: String {
        didSet { defaults.set(transcriptFolder, forKey: "transcriptFolder") }
    }
    var onboarded: Bool {
        didSet { defaults.set(onboarded, forKey: "onboarded") }
    }
    var openAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                openError = "Minutes couldn't change the login setting: \(error.localizedDescription)"
            }
            loginSettingVersion += 1
        }
    }
    /// Bumped to make SwiftUI re-read `openAtLogin` (SMAppService isn't observable).
    private(set) var loginSettingVersion = 0

    private let defaults = UserDefaults.standard

    init() {
        defaults.register(defaults: [
            "useRoom": true, "useCall": true, "remindOnStart": true,
            "transcriptFolder": "Meeting Transcripts", "onboarded": false,
        ])
        useRoom = defaults.bool(forKey: "useRoom")
        useCall = defaults.bool(forKey: "useCall")
        remindOnStart = defaults.bool(forKey: "remindOnStart")
        transcriptFolder = defaults.string(forKey: "transcriptFolder") ?? "Meeting Transcripts"
        onboarded = defaults.bool(forKey: "onboarded")
        session = MeetingSession(models: models, bridge: bridge)

        do {
            let index = try NotesIndex(url: NotesIndex.defaultURL())
            indexer = NotesIndexer(index: index, bridge: bridge)
            startupError = nil
        } catch {
            indexer = nil
            startupError = "Minutes couldn't open its notes index: \(error.localizedDescription)"
        }

        session.folderName = { [weak self] in
            let name = self?.transcriptFolder.trimmingCharacters(in: .whitespaces) ?? ""
            return name.isEmpty ? "Meeting Transcripts" : name
        }
        session.onFinished = { [weak self] in
            Task { await self?.indexer?.refreshNow() }
        }

        refreshVoicePrint()
        // Turn on "open at login" once, and only for the installed copy — never for a
        // build running from DerivedData or a diagnostic mode.
        if Self.isInstalledCopy, CommandLine.arguments.count == 1, !defaults.bool(forKey: "loginItemOffered") {
            defaults.set(true, forKey: "loginItemOffered")
            try? SMAppService.mainApp.register()
        }
        indexer?.start()
        if !CommandLine.arguments.contains("--gallery") {
            updater.start(isBusy: { [weak self] in
                guard let session = self?.session else { return false }
                return session.isActive || session.hasUnsavedTranscript
            })
        }
        Task {
            await models.prepare()
            await refreshClaudeStatus()
        }
    }

    static var isInstalledCopy: Bool { Bundle.main.bundlePath.hasPrefix("/Applications/") }

    // MARK: Readiness

    var notesReady: Bool { indexer?.lastRefresh != nil && indexer?.lastError == nil }

    /// Meetings need the speech models, a source, and Notes permission. They don't wait
    /// on the notes index: a slow or failed refresh only affects Claude's search.
    var canStart: Bool { setupProblem == nil }

    /// What's missing before Start can work, in plain words (nil when ready).
    var setupProblem: String? {
        if case .failed(let message) = models.state { return message }
        if !models.isReady { return "Getting speech models ready…" }
        if indexer?.permissionDenied == true { return NotesBridgeError.permissionDenied.localizedDescription }
        if useRoom && !microphoneAllowed { return "Minutes needs microphone access." }
        if !useRoom && !useCall { return "Turn on at least one source." }
        return nil
    }

    // MARK: Actions

    func startMeeting() async {
        let sources: Set<Source> = Set([useRoom ? .room : nil, useCall ? .call : nil].compactMap { $0 })
        await session.start(title: meetingTitle, sources: sources)
        if session.phase == .listening { meetingTitle = "" }
    }

    func stopMeeting() async {
        await session.stop()
    }

    func openSavedNote() async {
        guard let id = session.noteID else { return }
        do {
            try await bridge.showNote(noteID: id)
            openError = nil
        } catch {
            openError = error.localizedDescription
        }
    }

    func requestMicrophone() async {
        microphoneAllowed = await MicCapture.requestPermission()
    }

    /// Creates and removes a call-audio tap so macOS asks for permission up front.
    func checkCallAudio() {
        let probe = CallCapture()
        do {
            try probe.start()
            probe.stop()
            callAudioChecked = true
            callAudioError = nil
        } catch {
            callAudioError = error.localizedDescription
        }
    }

    func refreshVoicePrint() {
        hasVoicePrint = (try? VoicePrint.load(from: VoicePrint.defaultURL())) != nil
    }

    func deleteVoicePrint() {
        try? FileManager.default.removeItem(at: VoicePrint.defaultURL())
        refreshVoicePrint()
    }

    func refreshClaudeStatus() async {
        claudeStatus = await ClaudeConnector.status()
    }

    func connectClaude() async {
        do {
            try await ClaudeConnector.connect()
            claudeError = nil
        } catch {
            claudeError = error.localizedDescription
        }
        await refreshClaudeStatus()
    }
}
