import Carbon
import Foundation
import MinutesKit
import OSLog

enum NotesBridgeError: LocalizedError, Codable, Equatable {
    case permissionDenied
    case scriptFailed(String)
    case badOutput
    case timedOut

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            "\(AppIdentity.name) isn't allowed to use Notes. Turn it on in System Settings > Privacy & Security > Automation."
        case .scriptFailed(let message):
            "Notes didn't respond: \(message)"
        case .badOutput:
            "Notes sent back something \(AppIdentity.name) couldn't read."
        case .timedOut:
            "Notes didn't respond in time."
        }
    }
}

/// Runs the Notes AppleScript handlers with NSAppleScript. NSAppleScript must stay on
/// the main thread, and a large write takes seconds, so only the short-lived
/// `--notes-helper` child process uses this (see NotesBridge). Values travel as
/// Apple event descriptors, never as script text.
@MainActor
final class NotesScriptRunner {
    private static let logger = Logger(subsystem: AppIdentity.bundleID, category: "NotesScriptRunner")
    private var compiled: NSAppleScript?

    func listMetadata() throws -> [NoteMetadata] {
        let result = try call("listNotes")
        var notes: [String: NoteMetadata] = [:]
        for folderIndex in stride(from: 1, through: result.numberOfItems, by: 1) {
            guard let row = result.atIndex(folderIndex), row.numberOfItems == 7,
                  let account = row.atIndex(1)?.stringValue,
                  let folder = row.atIndex(2)?.stringValue,
                  let ids = row.atIndex(3), let names = row.atIndex(4),
                  let created = row.atIndex(5), let modified = row.atIndex(6), let locked = row.atIndex(7)
            else { throw NotesBridgeError.badOutput }
            for i in stride(from: 1, through: ids.numberOfItems, by: 1) {
                guard let id = ids.atIndex(i)?.stringValue,
                      let createdAt = created.atIndex(i)?.dateValue,
                      let modifiedAt = modified.atIndex(i)?.dateValue
                else { continue }
                notes[id] = NoteMetadata(
                    id: id,
                    title: names.atIndex(i)?.stringValue ?? "",
                    folder: folder,
                    account: account,
                    createdAt: createdAt,
                    modifiedAt: modifiedAt,
                    isLocked: locked.atIndex(i)?.booleanValue ?? true
                )
            }
        }
        return Array(notes.values)
    }

    /// Plain text for each readable note; locked or missing notes are left out.
    func plaintext(ids: [String]) throws -> [String: String] {
        let list = NSAppleEventDescriptor.list()
        for (i, id) in ids.enumerated() { list.insert(NSAppleEventDescriptor(string: id), at: i + 1) }
        let result = try call("plaintextOf", list)
        var out: [String: String] = [:]
        for i in stride(from: 1, through: result.numberOfItems, by: 1) {
            guard let pair = result.atIndex(i), let id = pair.atIndex(1)?.stringValue else { continue }
            out[id] = pair.atIndex(2)?.stringValue ?? ""
        }
        return out
    }

    func createNote(folder: String, html: String) throws -> String {
        let result = try call("createNote", NSAppleEventDescriptor(string: folder), NSAppleEventDescriptor(string: html))
        guard let id = result.stringValue else { throw NotesBridgeError.badOutput }
        return id
    }

    func showNote(noteID: String) throws {
        _ = try call("showNote", NSAppleEventDescriptor(string: noteID))
    }

    func setBody(noteID: String, html: String) throws {
        _ = try call("setBody", NSAppleEventDescriptor(string: noteID), NSAppleEventDescriptor(string: html))
    }

    // MARK: - AppleScript plumbing

    private func script() throws -> NSAppleScript {
        if let compiled { return compiled }
        guard let script = NSAppleScript(source: NotesScriptSource.text) else { throw NotesBridgeError.badOutput }
        var error: NSDictionary?
        guard script.compileAndReturnError(&error) else {
            throw NotesBridgeError.scriptFailed(error?[NSAppleScript.errorMessage] as? String ?? "could not compile")
        }
        compiled = script
        return script
    }

    private func call(_ handler: String, _ arguments: NSAppleEventDescriptor...) throws -> NSAppleEventDescriptor {
        let event = NSAppleEventDescriptor(
            eventClass: AEEventClass(kASAppleScriptSuite),
            eventID: AEEventID(kASSubroutineEvent),
            targetDescriptor: .currentProcess(),
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )
        event.setDescriptor(NSAppleEventDescriptor(string: handler.lowercased()), forKeyword: AEKeyword(keyASSubroutineName))
        let parameters = NSAppleEventDescriptor.list()
        for (i, argument) in arguments.enumerated() { parameters.insert(argument, at: i + 1) }
        event.setParam(parameters, forKeyword: AEKeyword(keyDirectObject))

        var error: NSDictionary?
        let result = try script().executeAppleEvent(event, error: &error)
        if let error {
            let number = error[NSAppleScript.errorNumber] as? Int ?? 0
            let message = error[NSAppleScript.errorMessage] as? String ?? "unknown error"
            Self.logger.error("Notes script \(handler, privacy: .public) failed: \(number)")
            if number == -1743 || number == -10004 { throw NotesBridgeError.permissionDenied }
            throw NotesBridgeError.scriptFailed(message)
        }
        return result
    }
}
