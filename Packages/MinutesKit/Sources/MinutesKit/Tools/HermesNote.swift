import Foundation

public enum HermesNoteError: Error, Equatable, CustomStringConvertible {
    case emptyText
    case unknownSection(String)
    case tooLong(Int, limit: Int)
    case duplicateTitle(String)
    case emptyTitle
    case badTitle(String)

    public var description: String {
        switch self {
        case .emptyText: "Nothing to write: text is empty."
        case .unknownSection(let s): "No section named \"\(s)\". Sections: \(HermesNote.sectionNames.joined(separator: ", "))."
        case .tooLong(let n, let limit): "That would make the note \(n) characters; the limit is \(limit). Replace a section with a shorter one, or start another note."
        case .duplicateTitle(let t): "A note titled \"\(t)\" already exists in the Hermes folder; use note_write to add to it."
        case .emptyTitle: "A note needs a title."
        case .badTitle(let t): "\"\(t)\" cannot be a note title: one line, at most \(HermesNote.maxTitleCharacters) characters, no angle brackets."
        }
    }
}

/// A note Hermes keeps in Aaron's Apple Notes (folder "Hermes"): a title line, then sections from a fixed
/// vocabulary, each a list of plain lines. Plain text is the working form (what the index stores and the model
/// reads); HTML is only for handing the note to Notes. Headings come back from Notes as bare lines, which is why
/// the section names are a fixed set rather than "## " markers.
public struct HermesNote: Sendable, Equatable {
    public static let folder = "Hermes"
    public static let indexTitle = "Hermes index"
    public static let logTitle = "Hermes log"
    public static let maxCharacters = 8_000
    public static let maxIndexCharacters = 4_000
    public static let maxTitleCharacters = 120
    public static let sectionNames = ["Summary", "Facts", "Decisions", "Open questions", "People", "Next", "Items", "Log"]

    public struct Section: Sendable, Equatable {
        public var name: String
        public var lines: [String]
        public init(name: String, lines: [String]) { self.name = name; self.lines = lines }
    }

    public enum Mode: String, Sendable, Equatable { case append, replace }

    public var title: String
    /// Lines before the first section (a one-line description, usually).
    public var preamble: [String]
    public var sections: [Section]

    public init(title: String, preamble: [String] = [], sections: [Section] = []) {
        self.title = title
        self.preamble = preamble
        self.sections = sections
    }

    /// The canonical spelling of a section name, or nil if it is not one of ours.
    public static func sectionName(_ raw: String) -> String? {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return sectionNames.first { $0.lowercased() == key }
    }

    /// Parses what Notes gives back as plain text: the title line, then lines; a line that is exactly a section
    /// name (or "## name") starts that section. Blank lines are dropped.
    public static func parse(plainText: String) -> HermesNote {
        var lines = plainText.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        while let first = lines.first, first.isEmpty { lines.removeFirst() }
        let title = lines.first ?? ""
        var note = HermesNote(title: title)
        var current: Int? = nil
        for raw in lines.dropFirst() where !raw.isEmpty {
            let candidate = raw.hasPrefix("## ") ? String(raw.dropFirst(3)) : raw
            if let name = sectionName(candidate) {
                note.sections.append(Section(name: name, lines: []))
                current = note.sections.count - 1
            } else if let i = current {
                note.sections[i].lines.append(raw)
            } else {
                note.preamble.append(raw)
            }
        }
        return note
    }

    public var plainText: String {
        var out = [title] + preamble
        for s in sections {
            out.append("")
            out.append(s.name)
            out += s.lines
        }
        return out.joined(separator: "\n")
    }

    public var characterCount: Int { plainText.count }

    /// What Notes receives: one div per line, h1 for the title, h2 for a section, a br between sections.
    public var html: String {
        var parts = ["<div><h1>\(Self.escape(title))</h1></div>"]
        parts += preamble.map { "<div>\(Self.escape($0))</div>" }
        for s in sections {
            parts.append("<div><br></div>")
            parts.append("<div><h2>\(Self.escape(s.name))</h2></div>")
            parts += s.lines.map { "<div>\(Self.escape($0))</div>" }
        }
        return parts.joined()
    }

    /// Adds `text`'s non-empty lines to `section` (created at the end if absent), or replaces the section's lines.
    /// Throws for an unknown section or empty text.
    public mutating func upsert(section rawName: String, text: String, mode: Mode) throws {
        guard let name = Self.sectionName(rawName) else { throw HermesNoteError.unknownSection(rawName) }
        let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !lines.isEmpty else { throw HermesNoteError.emptyText }
        if let i = sections.firstIndex(where: { $0.name == name }) {
            switch mode {
            case .append: sections[i].lines += lines
            case .replace: sections[i].lines = lines
            }
        } else {
            sections.append(Section(name: name, lines: lines))
        }
    }

    static func escape(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        for c in text {
            switch c {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            default: out.append(c)
            }
        }
        return out
    }
}

/// What the writer needs from Apple Notes; the apps' NotesBridge satisfies it.
public protocol NoteStore: Sendable {
    func plaintext(ids: [String]) async throws -> [String: String]
    func createNote(folder: String, html: String) async throws -> String
    func setBody(noteID: String, html: String) async throws
}

/// Ids of notes this process created, so a second write in the two minutes before the index sees them finds
/// the note instead of creating a twin.
public actor HermesNoteCache {
    private var ids: [String: String] = [:]
    public init() {}
    public func id(for title: String) -> String? { ids[title.lowercased()] }
    public func remember(_ id: String, for title: String) { ids[title.lowercased()] = id }
}

/// Creates and edits notes in the Hermes folder only. Notes elsewhere, whatever their title, are never read for
/// writing or changed: his notes stay his. The note is found through the index (plus the cache above), never by
/// listing Apple Notes over AppleScript: a second client listing every note while the index service does the same
/// hung Notes.app for minutes (2026-10-10). Only the small per-note events (read text, set body, create) go to
/// Notes. Last write wins inside the folder.
public struct HermesNoteWriter: Sendable {
    public let store: any NoteStore
    public let folder: String
    public let index: NotesIndex?
    public let cache: HermesNoteCache

    public init(store: any NoteStore, folder: String = HermesNote.folder, index: NotesIndex? = nil, cache: HermesNoteCache = HermesNoteCache()) {
        self.store = store
        self.folder = folder
        self.index = index
        self.cache = cache
    }

    /// Appends to (or replaces) one section of the note titled `title`, creating the note if it does not exist.
    /// Returns a short confirmation for the model.
    public func write(title rawTitle: String, section: String, text: String, mode: HermesNote.Mode) async throws -> String {
        let title = try Self.cleanTitle(rawTitle)
        if let existingID = try await find(title: title) {
            let body = try await store.plaintext(ids: [existingID])[existingID] ?? title
            var note = HermesNote.parse(plainText: body)
            if note.title.isEmpty { note.title = title }
            try note.upsert(section: section, text: text, mode: mode)
            try Self.checkSize(note)
            try await store.setBody(noteID: existingID, html: note.html)
            let count = note.sections.first { $0.name == HermesNote.sectionName(section) }?.lines.count ?? 0
            return "\(mode == .append ? "Added to" : "Replaced") \(HermesNote.sectionName(section) ?? section) of \"\(title)\" (\(count) lines there now, \(note.characterCount) characters in the note)."
        }
        var note = HermesNote(title: title)
        try note.upsert(section: section, text: text, mode: mode)
        try Self.checkSize(note)
        let id = try await store.createNote(folder: folder, html: note.html)
        await cache.remember(id, for: title)
        return "Created \"\(title)\" in folder \(folder) with a \(HermesNote.sectionName(section) ?? section) section (\(note.characterCount) characters)."
    }

    /// Creates a note from `body` (a description line, then section names each followed by their lines; the title
    /// comes from `title`, never from the body); refuses a title that already exists in the folder.
    public func create(title rawTitle: String, body: String) async throws -> String {
        let title = try Self.cleanTitle(rawTitle)
        if try await find(title: title) != nil { throw HermesNoteError.duplicateTitle(title) }
        let note = HermesNote.parse(plainText: title + "\n" + body)
        if note.preamble.isEmpty && note.sections.isEmpty { throw HermesNoteError.emptyText }
        try Self.checkSize(note)
        let id = try await store.createNote(folder: folder, html: note.html)
        await cache.remember(id, for: title)
        return "Created \"\(title)\" in folder \(folder) (\(note.sections.count) sections, \(note.characterCount) characters)."
    }

    /// Notes names a note after its first line and the title lands in an h1, so a title is one short line with no
    /// markup: a newline would turn the rest into body text, and angle brackets have no business in a name.
    static func cleanTitle(_ raw: String) throws -> String {
        let title = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw HermesNoteError.emptyTitle }
        guard !title.contains(where: { $0.isNewline }), title.count <= HermesNote.maxTitleCharacters,
              !title.contains("<"), !title.contains(">") else { throw HermesNoteError.badTitle(raw) }
        return title
    }

    /// The note's id: from this process's cache, else from the index (notes in `folder` only). Never from Notes.
    private func find(title: String) async throws -> String? {
        if let id = await cache.id(for: title) { return id }
        guard let index else { return nil }
        let key = title.lowercased()
        return try index.list(scope: .folder(folder), since: nil, until: nil, limit: 500)
            .first { $0.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == key }?.id
    }

    private static func checkSize(_ note: HermesNote) throws {
        let limit = note.title == HermesNote.indexTitle ? HermesNote.maxIndexCharacters : HermesNote.maxCharacters
        if note.characterCount > limit { throw HermesNoteError.tooLong(note.characterCount, limit: limit) }
    }
}
