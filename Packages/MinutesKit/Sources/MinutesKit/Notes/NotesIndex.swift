import Foundation

/// Local full-text index of Apple Notes text. The app writes it; `Minutes --mcp` reads it.
public final class NotesIndex: @unchecked Sendable {
    private let db: SQLiteConnection
    private let lock = NSLock()
    private let ownerKey = "MinutesKit.NotesIndex.transaction"
    public let isReadOnly: Bool

    public static func defaultURL() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Minutes", isDirectory: true)
            .appendingPathComponent("notes-index.db")
    }

    public init(url: URL, readOnly: Bool = false) throws {
        if !readOnly {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        db = try SQLiteConnection(path: url.path, readOnly: readOnly)
        isReadOnly = readOnly
        if !readOnly {
            try db.exec("PRAGMA journal_mode=WAL")
            try migrate()
        }
    }

    private func migrate() throws {
        var version: Int64 = 0
        try db.query("PRAGMA user_version") { version = $0.int(0) }
        guard version < 1 else { return }
        try db.exec("""
        BEGIN;
        CREATE TABLE notes (
          id INTEGER PRIMARY KEY,
          note_id TEXT NOT NULL UNIQUE,
          title TEXT NOT NULL,
          folder TEXT NOT NULL,
          account TEXT NOT NULL,
          created_at INTEGER NOT NULL,
          modified_at INTEGER NOT NULL,
          body TEXT NOT NULL
        );
        CREATE INDEX notes_modified ON notes(modified_at);
        CREATE VIRTUAL TABLE notes_fts USING fts5(
          title, body, content='notes', content_rowid='id', tokenize='porter unicode61'
        );
        CREATE TRIGGER notes_ai AFTER INSERT ON notes BEGIN
          INSERT INTO notes_fts(rowid, title, body) VALUES (new.id, new.title, new.body);
        END;
        CREATE TRIGGER notes_ad AFTER DELETE ON notes BEGIN
          INSERT INTO notes_fts(notes_fts, rowid, title, body) VALUES ('delete', old.id, old.title, old.body);
        END;
        CREATE TRIGGER notes_au AFTER UPDATE ON notes BEGIN
          INSERT INTO notes_fts(notes_fts, rowid, title, body) VALUES ('delete', old.id, old.title, old.body);
          INSERT INTO notes_fts(rowid, title, body) VALUES (new.id, new.title, new.body);
        END;
        CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
        PRAGMA user_version = 1;
        COMMIT;
        """)
    }

    // MARK: Transactions

    /// Runs `body` in one write transaction. Index calls inside `body` reuse the
    /// held lock. `body` must not suspend (no `await`).
    public func transaction(_ body: () throws -> Void) throws {
        lock.lock()
        defer { lock.unlock() }
        Thread.current.threadDictionary[ownerKey] = ObjectIdentifier(self)
        defer { Thread.current.threadDictionary.removeObject(forKey: ownerKey) }
        try db.exec("BEGIN IMMEDIATE")
        do {
            try body()
            try db.exec("COMMIT")
        } catch {
            try? db.exec("ROLLBACK")
            throw error
        }
    }

    /// Takes the lock unless this thread is already inside `transaction`.
    private func serialized<T>(_ body: () throws -> T) rethrows -> T {
        if Thread.current.threadDictionary[ownerKey] as? ObjectIdentifier == ObjectIdentifier(self) {
            return try body()
        }
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    // MARK: Writes

    public func upsert(_ note: NoteMetadata, body: String) throws {
        try serialized {
            try db.query("""
            INSERT INTO notes(note_id, title, folder, account, created_at, modified_at, body)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
            ON CONFLICT(note_id) DO UPDATE SET
              title = excluded.title, folder = excluded.folder, account = excluded.account,
              created_at = excluded.created_at, modified_at = excluded.modified_at, body = excluded.body
            """, [.text(note.id), .text(note.title), .text(note.folder), .text(note.account),
                  .int(milliseconds(note.createdAt)), .int(milliseconds(note.modifiedAt)), .text(body)])
        }
    }

    public func retag(_ note: NoteMetadata) throws {
        try serialized {
            try db.query("UPDATE notes SET title = ?1, folder = ?2, account = ?3 WHERE note_id = ?4",
                         [.text(note.title), .text(note.folder), .text(note.account), .text(note.id)])
        }
    }

    public func delete(ids: [String]) throws {
        try serialized {
            for id in ids { try db.query("DELETE FROM notes WHERE note_id = ?1", [.text(id)]) }
        }
    }

    public func setLastRefresh(_ date: Date) throws {
        try serialized {
            try db.query("""
            INSERT INTO meta(key, value) VALUES('last_refresh', ?1)
            ON CONFLICT(key) DO UPDATE SET value = excluded.value
            """, [.text(String(milliseconds(date)))])
        }
    }

    // MARK: Reads

    public func stamps() throws -> [String: IndexedStamp] {
        try serialized {
            var out: [String: IndexedStamp] = [:]
            try db.query("SELECT note_id, title, folder, account, modified_at FROM notes") { r in
                out[r.text(0)] = IndexedStamp(title: r.text(1), folder: r.text(2), account: r.text(3), modifiedMs: r.int(4))
            }
            return out
        }
    }

    public func search(_ query: String, folder: String?, since: Date?, until: Date?, limit: Int) throws -> [NoteSearchHit] {
        guard let match = FTSQuery.make(from: query) else { return [] }
        return try serialized {
            var hits: [NoteSearchHit] = []
            try db.query("""
            SELECT n.note_id, n.title, n.folder, n.modified_at,
                   snippet(notes_fts, 1, '[', ']', ' … ', 30)
            FROM notes_fts JOIN notes n ON n.id = notes_fts.rowid
            WHERE notes_fts MATCH ?1
              AND (?2 IS NULL OR n.folder = ?2)
              AND (?3 IS NULL OR n.modified_at >= ?3)
              AND (?4 IS NULL OR n.modified_at < ?4)
            ORDER BY bm25(notes_fts, 3.0, 1.0)
            LIMIT ?5
            """, [.text(match), Self.optional(folder), Self.optional(since), Self.optional(until), .int(Int64(limit))]) { r in
                hits.append(NoteSearchHit(id: r.text(0), title: r.text(1), folder: r.text(2),
                                          modifiedAt: date(milliseconds: r.int(3)), snippet: r.text(4)))
            }
            return hits
        }
    }

    public func list(folder: String?, since: Date?, until: Date?, limit: Int) throws -> [NoteSummary] {
        try serialized {
            var out: [NoteSummary] = []
            try db.query("""
            SELECT note_id, title, folder, created_at, modified_at, length(body) FROM notes
            WHERE (?1 IS NULL OR folder = ?1)
              AND (?2 IS NULL OR modified_at >= ?2)
              AND (?3 IS NULL OR modified_at < ?3)
            ORDER BY modified_at DESC LIMIT ?4
            """, [Self.optional(folder), Self.optional(since), Self.optional(until), .int(Int64(limit))]) { r in
                out.append(NoteSummary(id: r.text(0), title: r.text(1), folder: r.text(2),
                                       createdAt: date(milliseconds: r.int(3)), modifiedAt: date(milliseconds: r.int(4)),
                                       length: Int(r.int(5))))
            }
            return out
        }
    }

    public func note(id: String) throws -> IndexedNote? {
        try serialized {
            var found: IndexedNote?
            try db.query("""
            SELECT note_id, title, folder, account, created_at, modified_at, body FROM notes WHERE note_id = ?1
            """, [.text(id)]) { r in
                found = IndexedNote(id: r.text(0), title: r.text(1), folder: r.text(2), account: r.text(3),
                                    createdAt: date(milliseconds: r.int(4)), modifiedAt: date(milliseconds: r.int(5)),
                                    body: r.text(6))
            }
            return found
        }
    }

    public func folders() throws -> [FolderCount] {
        try serialized {
            var out: [FolderCount] = []
            try db.query("SELECT folder, count(*) FROM notes GROUP BY folder ORDER BY folder COLLATE NOCASE") { r in
                out.append(FolderCount(name: r.text(0), count: Int(r.int(1))))
            }
            return out
        }
    }

    public func count() throws -> Int {
        try serialized {
            var n = 0
            try db.query("SELECT count(*) FROM notes") { n = Int($0.int(0)) }
            return n
        }
    }

    public func lastRefresh() throws -> Date? {
        try serialized {
            var value: Date?
            try db.query("SELECT value FROM meta WHERE key = 'last_refresh'") { r in
                if let ms = Int64(r.text(0)) { value = date(milliseconds: ms) }
            }
            return value
        }
    }

    func checkIntegrity() throws {
        try serialized { try db.exec("INSERT INTO notes_fts(notes_fts) VALUES('integrity-check')") }
    }

    private static func optional(_ text: String?) -> SQLValue { text.map { .text($0) } ?? .null }
    private static func optional(_ date: Date?) -> SQLValue { date.map { .int(milliseconds($0)) } ?? .null }
}
