import Foundation
import MCP
import MinutesKit

/// Read-only MCP server over the local Notes index, run by `Minutes --mcp` (for Claude Code)
/// and `HermesHelper --mcp` (for Hermes Agent).
public enum MinutesMCPServer {
    public static let instructions = """
    Search Aaron's Apple Notes, including meeting transcripts made by the Minutes app. \
    Use search_notes first, then get_note to read a result in full. \
    \(NotesTools.transcriptFolderHint) \
    current_time is the only clock available: call it before answering anything about today, now, or deadlines.
    """

    private static let dateHelp = "YYYY-MM-DD (local day) or ISO 8601. Filters on a note's last edit, or on the item's own time for mail and Teams (sent) and calendar (start) records. Pass it whenever Aaron names a day or a span (yesterday, this week, since Monday), with the date from current_time."
    private static let folderHelp = "A folder name from list_folders (case does not matter), or \"mail\", \"calendar\", \"teams\" for Aaron's email, calendar, and Teams chats, or \"notes\" for all of Aaron's own notes and transcripts together. Omit it to search everything, which is right for \"my notes on X\". An unknown name is an error, not an empty result."
    private static let untilHelp = dateHelp + " A plain date includes that whole day."
    private static let limitHelp = "Maximum results, 1-50. Default 20."

    public static let tools: [Tool] = [
        Tool(
            name: "search_notes",
            description: "Full-text search across all of Aaron's notes and meeting transcripts. Words are matched with stemming and ranked (titles weigh more); wrap words in double quotes for an exact phrase. Returns note ids, titles, folders, dates, and a snippet with matches in [brackets]. " + NotesTools.transcriptFolderHint,
            inputSchema: schema(properties: [
                "query": property("string", "Words to find, or \"an exact phrase\" in double quotes."),
                "folder": property("string", folderHelp),
                "since": property("string", dateHelp),
                "until": property("string", untilHelp),
                "limit": property("integer", limitHelp),
            ], required: ["query"])
        ),
        Tool(
            name: "list_notes",
            description: "List notes, newest first (last edit for Aaron's notes; sent time for mail and Teams; start time for calendar), optionally within one folder or date range. Use folder \"Meeting Transcripts\" to list meetings.",
            inputSchema: schema(properties: [
                "folder": property("string", folderHelp),
                "since": property("string", dateHelp),
                "until": property("string", untilHelp),
                "limit": property("integer", limitHelp),
            ])
        ),
        Tool(
            name: "get_note",
            description: "Read one note's full plain text by id (from search_notes or list_notes). Long notes come in 40,000-character pages; pass the offset the previous page gives.",
            inputSchema: schema(properties: [
                "note_id": property("string", "The note's id."),
                "offset": property("integer", "Character offset to start from. Default 0."),
            ], required: ["note_id"])
        ),
        Tool(
            name: "list_folders",
            description: "List note folders with how many notes each holds.",
            inputSchema: schema(properties: [:])
        ),
        Tool(
            name: "current_time",
            description: "The current date, time, weekday, and time zone on Aaron's Mac. Call it whenever an answer depends on today, now, or how long until something; nothing else tells you the time, so never assume it.",
            inputSchema: schema(properties: [:])
        ),
    ]

    public static func call(
        name: String,
        arguments: [String: Value]?,
        indexURL: URL,
        timeZone: TimeZone = .current,
        now: @escaping @Sendable () -> Date = { Date() },
        noIndexHint: String = "open Minutes once so it can index your notes"
    ) -> CallTool.Result {
        let args = arguments ?? [:]
        guard tools.contains(where: { $0.name == name }) else {
            return failure("Unknown tool \"\(name)\".")
        }
        if name == "current_time" { return .init(content: [.text(currentTime(timeZone: timeZone, now: now()))]) }
        guard FileManager.default.fileExists(atPath: indexURL.path) else {
            return .init(content: [.text("No notes indexed yet — \(noIndexHint).")])
        }
        do {
            let notes = NotesTools(index: try NotesIndex(url: indexURL, readOnly: true), timeZone: timeZone, now: now)
            let since = try date(args["since"], key: "since", timeZone: timeZone, until: false)
            let until = try date(args["until"], key: "until", timeZone: timeZone, until: true)
            let output: String
            switch name {
            case "search_notes":
                guard let query = args["query"]?.stringValue, !query.trimmingCharacters(in: .whitespaces).isEmpty else {
                    throw ToolError.invalidArgument("search_notes needs a non-empty \"query\".")
                }
                output = try notes.searchNotes(query: query, folder: args["folder"]?.stringValue,
                                               since: since, until: until, limit: int(args["limit"]))
            case "list_notes":
                output = try notes.listNotes(folder: args["folder"]?.stringValue, since: since, until: until, limit: int(args["limit"]))
            case "get_note":
                guard let id = args["note_id"]?.stringValue else {
                    throw ToolError.invalidArgument("get_note needs \"note_id\".")
                }
                output = try notes.getNote(id: id, offset: int(args["offset"]))
            default:
                output = try notes.listFolders()
            }
            return .init(content: [.text(output)])
        } catch let error as ToolError {
            return failure(error.description)
        } catch {
            return failure("Could not read the notes index: \(error)")
        }
    }

    public static func run(
        indexURL: URL,
        version: String,
        name: String = "minutes",
        noIndexHint: String = "open Minutes once so it can index your notes"
    ) async throws {
        let server = Server(
            name: name,
            version: version,
            instructions: instructions,
            capabilities: .init(tools: .init(listChanged: false))
        )
        await server.withMethodHandler(ListTools.self) { _ in .init(tools: tools) }
        await server.withMethodHandler(CallTool.self) { params in
            call(name: params.name, arguments: params.arguments, indexURL: indexURL, noIndexHint: noIndexHint)
        }
        try await server.start(transport: StdioTransport())
        await server.waitUntilCompleted()
    }

    /// "Thursday, October 8, 2026 at 2:32 PM CDT (America/Chicago). ISO 8601: 2026-10-08T14:32:05-05:00"
    static func currentTime(timeZone: TimeZone, now: Date) -> String {
        let day = DateFormatter()
        day.locale = Locale(identifier: "en_US_POSIX")
        day.timeZone = timeZone
        day.dateFormat = "EEEE, MMMM d, yyyy"
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.hour, .minute], from: now)
        let hour24 = parts.hour ?? 0
        let hour12 = hour24 % 12 == 0 ? 12 : hour24 % 12
        let clock = String(format: "%d:%02d %@", hour12, parts.minute ?? 0, hour24 < 12 ? "AM" : "PM")
        let iso = ISO8601DateFormatter()
        iso.timeZone = timeZone
        iso.formatOptions = [.withInternetDateTime]
        let abbreviation = timeZone.abbreviation(for: now) ?? timeZone.identifier
        return "\(day.string(from: now)) at \(clock) \(abbreviation) (\(timeZone.identifier)). ISO 8601: \(iso.string(from: now))"
    }

    private static func schema(properties: [String: Value], required: [String] = []) -> Value {
        var object: [String: Value] = ["type": .string("object"), "properties": .object(properties)]
        if !required.isEmpty { object["required"] = .array(required.map { .string($0) }) }
        return .object(object)
    }

    private static func property(_ type: String, _ description: String) -> Value {
        .object(["type": .string(type), "description": .string(description)])
    }

    private static func failure(_ message: String) -> CallTool.Result {
        .init(content: [.text(message)], isError: true)
    }

    private static func int(_ value: Value?) -> Int? {
        guard let value else { return nil }
        if let i = value.intValue { return i }
        if let d = value.doubleValue { return Int(d) }
        if let s = value.stringValue { return Int(s) }
        return nil
    }

    private static func date(_ value: Value?, key: String, timeZone: TimeZone, until: Bool) throws -> Date? {
        guard let text = value?.stringValue, !text.isEmpty else { return nil }
        let parsed = until ? DateArgument.parseUntil(text, timeZone: timeZone) : DateArgument.parseSince(text, timeZone: timeZone)
        guard let parsed else {
            throw ToolError.invalidArgument("\"\(key)\" must be YYYY-MM-DD or ISO 8601, got \"\(text)\".")
        }
        return parsed
    }
}
