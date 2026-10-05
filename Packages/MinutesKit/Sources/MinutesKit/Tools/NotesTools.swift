import Foundation

public enum ToolError: Error, Equatable, CustomStringConvertible {
    case notFound(String)
    case invalidArgument(String)

    public var description: String {
        switch self {
        case .notFound(let m), .invalidArgument(let m): m
        }
    }
}

/// Formats index contents as plain text for Claude.
public struct NotesTools: Sendable {
    public static let transcriptFolderHint = """
    Notes in the "Meeting Transcripts" folder are automatic speech-recognition transcripts \
    made by Minutes: expect misheard words, and treat speaker labels as approximate. \
    "Me" is Aaron; "Speaker n" are people in the room; "Caller n" are people on a call. \
    All other folders are Aaron's own notes.
    """

    public let index: NotesIndex
    public let timeZone: TimeZone
    public let now: @Sendable () -> Date
    public let pageSize: Int

    public init(index: NotesIndex, timeZone: TimeZone = .current, now: @escaping @Sendable () -> Date = { Date() }, pageSize: Int = 40_000) {
        self.index = index
        self.timeZone = timeZone
        self.now = now
        self.pageSize = pageSize
    }

    public func searchNotes(query: String, folder: String?, since: Date?, until: Date?, limit: Int?) throws -> String {
        let hits = try index.search(query, folder: folder, since: since, until: until, limit: clamp(limit))
        var out = [try freshness(), ""]
        guard !hits.isEmpty else {
            out.append("No notes match \"\(query)\".")
            return out.joined(separator: "\n")
        }
        out.append("\(hits.count) \(hits.count == 1 ? "note matches" : "notes match") \"\(query)\":")
        for (i, hit) in hits.enumerated() {
            out.append("")
            out.append("\(i + 1). \"\(hit.title)\" — \(hit.folder) — modified \(format(hit.modifiedAt))")
            out.append("   id: \(hit.id)")
            out.append("   \(hit.snippet.replacingOccurrences(of: "\n", with: " "))")
        }
        return out.joined(separator: "\n")
    }

    public func listNotes(folder: String?, since: Date?, until: Date?, limit: Int?) throws -> String {
        let notes = try index.list(folder: folder, since: since, until: until, limit: clamp(limit))
        var out = [try freshness(), ""]
        guard !notes.isEmpty else {
            out.append("No notes found.")
            return out.joined(separator: "\n")
        }
        out.append("\(notes.count) \(notes.count == 1 ? "note" : "notes"), most recently modified first:")
        for (i, n) in notes.enumerated() {
            out.append("")
            out.append("\(i + 1). \"\(n.title)\" — \(n.folder) — modified \(format(n.modifiedAt)) · created \(format(n.createdAt)) · \(n.length) characters")
            out.append("   id: \(n.id)")
        }
        return out.joined(separator: "\n")
    }

    public func getNote(id: String, offset: Int?) throws -> String {
        guard let note = try index.note(id: id) else {
            throw ToolError.notFound("No note with id \"\(id)\" in the index.")
        }
        let body = note.body
        let length = body.count
        let start = offset ?? 0
        guard start >= 0, start <= length else {
            throw ToolError.invalidArgument("offset \(start) is past the end of this note (\(length) characters).")
        }
        let lo = body.index(body.startIndex, offsetBy: start)
        let hi = body.index(lo, offsetBy: pageSize, limitedBy: body.endIndex) ?? body.endIndex
        var out = [
            try freshness(),
            "",
            "\"\(note.title)\"",
            "Folder: \(note.folder) · created \(format(note.createdAt)) · modified \(format(note.modifiedAt))",
            "id: \(note.id)",
            "",
            String(body[lo..<hi]),
        ]
        if hi < body.endIndex {
            out.append("")
            out.append("[More text remains — call get_note with offset: \(start + body.distance(from: lo, to: hi))]")
        }
        return out.joined(separator: "\n")
    }

    public func listFolders() throws -> String {
        let folders = try index.folders()
        var out = [try freshness(), ""]
        guard !folders.isEmpty else { return out.joined(separator: "\n") }
        out.append("Folders:")
        for f in folders { out.append("- \(f.name) (\(f.count) \(f.count == 1 ? "note" : "notes"))") }
        return out.joined(separator: "\n")
    }

    func freshness() throws -> String {
        guard let refreshed = try index.lastRefresh() else {
            return "No notes indexed yet — open Minutes once so it can index your notes."
        }
        let age = max(0, now().timeIntervalSince(refreshed))
        let text: String
        switch age {
        case ..<60: text = "just now"
        case ..<3600: text = "\(Int(age / 60)) min ago"
        default:
            let hours = Int(age / 3600)
            text = "\(hours) \(hours == 1 ? "hour" : "hours") ago"
        }
        var line = "Notes index updated \(text)."
        if age > 15 * 60 { line += " It may be out of date — Minutes might not be running." }
        return line
    }

    private func clamp(_ limit: Int?) -> Int { min(max(limit ?? 20, 1), 50) }

    private func format(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "EEE MMM d, yyyy h:mm a"
        return f.string(from: date)
    }
}
