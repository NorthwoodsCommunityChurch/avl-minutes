import Foundation
import MinutesKit
import OSLog

/// What the app asks the Notes helper to do. Sent as JSON on the helper's stdin.
enum NotesRequest: Codable {
    case list
    case plaintext(ids: [String])
    case create(folder: String, html: String)
    case setBody(noteID: String, html: String)
    case show(noteID: String)

    /// How long the helper may take. Listing every note can be slow; a transcript write
    /// usually takes a few seconds even for long meetings.
    var timeout: Duration {
        switch self {
        case .list, .plaintext: .seconds(180)
        case .create: .seconds(90)
        case .setBody: .seconds(60)
        case .show: .seconds(20)
        }
    }
}

/// The helper's JSON reply on stdout.
enum NotesReply: Codable {
    case notes([NoteMetadata])
    case texts([String: String])
    case created(id: String)
    case done
    case failed(NotesBridgeError)
}

/// The app's way to reach Apple Notes. Each call runs this app's binary with `--notes-helper` as a
/// child process, so slow Notes scripting never blocks the menu bar, and transcript
/// text moves over a pipe (never argv or a temp file).
struct NotesBridge: Sendable {
    private static let logger = Logger(subsystem: AppIdentity.bundleID, category: "NotesBridge")

    func listMetadata() async throws -> [NoteMetadata] {
        guard case .notes(let notes) = try await send(.list) else { throw NotesBridgeError.badOutput }
        return notes
    }

    func plaintext(ids: [String]) async throws -> [String: String] {
        guard case .texts(let texts) = try await send(.plaintext(ids: ids)) else { throw NotesBridgeError.badOutput }
        return texts
    }

    func createNote(folder: String, html: String) async throws -> String {
        guard case .created(let id) = try await send(.create(folder: folder, html: html)) else { throw NotesBridgeError.badOutput }
        return id
    }

    func showNote(noteID: String) async throws {
        guard case .done = try await send(.show(noteID: noteID)) else { throw NotesBridgeError.badOutput }
    }

    func setBody(noteID: String, html: String) async throws {
        guard case .done = try await send(.setBody(noteID: noteID, html: html)) else { throw NotesBridgeError.badOutput }
    }

    private func send(_ request: NotesRequest) async throws -> NotesReply {
        let input = try JSONEncoder().encode(request)
        guard let executable = Bundle.main.executableURL else { throw NotesBridgeError.badOutput }
        let output: Data
        do {
            output = try await ChildProcess.run(executable: executable, arguments: ["--notes-helper"],
                                                stdin: input, timeout: request.timeout)
        } catch ChildProcess.Failure.timedOut {
            Self.logger.error("Notes helper timed out")
            throw NotesBridgeError.timedOut
        }
        let reply: NotesReply
        do {
            reply = try JSONDecoder().decode(NotesReply.self, from: output)
        } catch {
            Self.logger.error("Notes helper returned unreadable output")
            throw NotesBridgeError.badOutput
        }
        if case .failed(let error) = reply { throw error }
        return reply
    }
}

/// `--notes-helper` mode (Minutes and Hermes Helper): reads one NotesRequest from stdin, runs it with
/// NSAppleScript on this process's main thread, writes one NotesReply, exits.
enum NotesHelper {
    @MainActor
    static func run() -> Never {
        let input = FileHandle.standardInput.readDataToEndOfFile()
        let runner = NotesScriptRunner()
        let reply: NotesReply
        do {
            switch try JSONDecoder().decode(NotesRequest.self, from: input) {
            case .list:
                reply = .notes(try runner.listMetadata())
            case .plaintext(let ids):
                reply = .texts(try runner.plaintext(ids: ids))
            case .create(let folder, let html):
                reply = .created(id: try runner.createNote(folder: folder, html: html))
            case .setBody(let noteID, let html):
                try runner.setBody(noteID: noteID, html: html)
                reply = .done
            case .show(let noteID):
                try runner.showNote(noteID: noteID)
                reply = .done
            }
        } catch let error as NotesBridgeError {
            reply = .failed(error)
        } catch {
            reply = .failed(.scriptFailed(error.localizedDescription))
        }
        let data = (try? JSONEncoder().encode(reply)) ?? Data()
        FileHandle.standardOutput.write(data)
        exit(0)
    }
}
