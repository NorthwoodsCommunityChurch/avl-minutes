import Foundation

public enum HermesNoteError: Error, Equatable, CustomStringConvertible {
    case emptyText
    case unknownSection(String)
    case tooLong(Int, limit: Int)
    case duplicateTitle(String)
    case emptyTitle

    public var description: String {
        switch self {
        case .emptyText: "Nothing to write: text is empty."
        case .unknownSection(let s): "No section named \"\(s)\". Sections: \(HermesNote.sectionNames.joined(separator: ", "))."
        case .tooLong(let n, let limit): "That would make the note \(n) characters; the limit is \(limit). Replace a section with a shorter one, or start another note."
        case .duplicateTitle(let t): "A note titled \"\(t)\" already exists in the Hermes folder; use note_write to add to it."
        case .emptyTitle: "A note needs a title."
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
    func listMetadata() async throws -> [NoteMetadata]
    func plaintext(ids: [String]) async throws -> [String: String]
    func createNote(folder: String, html: String) async throws -> String
    func setBody(noteID: String, html: String) async throws
}

/// Creates and edits notes in the Hermes folder only. Notes elsewhere, whatever their title, are never read for
/// writing or changed: his notes stay his. Last write wins inside the folder (a re-list before every write would
/// cost seconds; Aaron and Hermes editing the same note in the same minute is accepted).
public struct HermesNoteWriter: Sendable {
    public let store: any NoteStore
    public let folder: String

    public init(store: any NoteStore, folder: String = HermesNote.folder) {
        self.store = store
        self.folder = folder
    }

    /// Appends to (or replaces) one section of the note titled `title`, creating the note if it does not exist.
    /// Returns a short confirmation for the model.
    public func write(title rawTitle: String, section: String, text: String, mode: HermesNote.Mode) async throws -> String {
        let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw HermesNoteError.emptyTitle }
        if let existing = try await find(title: title) {
            let body = try await store.plaintext(ids: [existing.id])[existing.id] ?? existing.title
            var note = HermesNote.parse(plainText: body)
            if note.title.isEmpty { note.title = title }
            try note.upsert(section: section, text: text, mode: mode)
            try Self.checkSize(note)
            try await store.setBody(noteID: existing.id, html: note.html)
            let count = note.sections.first { $0.name == HermesNote.sectionName(section) }?.lines.count ?? 0
            return "\(mode == .append ? "Added to" : "Replaced") \(HermesNote.sectionName(section) ?? section) of \"\(title)\" (\(count) lines there now, \(note.characterCount) characters in the note)."
        }
        var note = HermesNote(title: title)
        try note.upsert(section: section, text: text, mode: mode)
        try Self.checkSize(note)
        _ = try await store.createNote(folder: folder, html: note.html)
        return "Created \"\(title)\" in folder \(folder) with a \(HermesNote.sectionName(section) ?? section) section (\(note.characterCount) characters)."
    }

    /// Creates a note from `body` (a description line, then section names each followed by their lines; the title
    /// comes from `title`, never from the body); refuses a title that already exists in the folder.
    public func create(title rawTitle: String, body: String) async throws -> String {
        let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw HermesNoteError.emptyTitle }
        if try await find(title: title) != nil { throw HermesNoteError.duplicateTitle(title) }
        let note = HermesNote.parse(plainText: title + "\n" + body)
        if note.preamble.isEmpty && note.sections.isEmpty { throw HermesNoteError.emptyText }
        try Self.checkSize(note)
        _ = try await store.createNote(folder: folder, html: note.html)
        return "Created \"\(title)\" in folder \(folder) (\(note.sections.count) sections, \(note.characterCount) characters)."
    }

    private func find(title: String) async throws -> NoteMetadata? {
        let key = title.lowercased()
        return try await store.listMetadata().first { $0.folder == folder && $0.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == key }
    }

    private static func checkSize(_ note: HermesNote) throws {
        let limit = note.title == HermesNote.indexTitle ? HermesNote.maxIndexCharacters : HermesNote.maxCharacters
        if note.characterCount > limit { throw HermesNoteError.tooLong(note.characterCount, limit: limit) }
    }
}
