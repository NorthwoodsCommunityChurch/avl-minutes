import Foundation
import Testing
@testable import MinutesKit

private func tempURL() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("minutes-test-\(UUID().uuidString)").appendingPathComponent("index.db")
}

private func meta(_ id: String, _ title: String, folder: String = "Notes", modified: TimeInterval = 1_000) -> NoteMetadata {
    NoteMetadata(id: id, title: title, folder: folder, account: "iCloud",
                 createdAt: Date(timeIntervalSince1970: 10), modifiedAt: Date(timeIntervalSince1970: modified), isLocked: false)
}

@Test func searchFindsStemsPhrasesAndWeightsTitles() throws {
    let index = try NotesIndex(url: tempURL())
    try index.upsert(meta("1", "Lobby screens"), body: "Need new mounts.")
    try index.upsert(meta("2", "Budget"), body: "We decided the lobby screens can wait.")
    try index.upsert(meta("3", "Groceries"), body: "eggs, milk")
    let stems = try index.search("decide", scope: .all, since: nil, until: nil, limit: 10)
    #expect(stems.map(\.id) == ["2"])
    let ranked = try index.search("lobby screens", scope: .all, since: nil, until: nil, limit: 10)
    #expect(ranked.first?.id == "1")                    // title match outranks body match
    let phrase = try index.search("\"screens can wait\"", scope: .all, since: nil, until: nil, limit: 10)
    #expect(phrase.map(\.id) == ["2"])
    #expect(phrase.first?.snippet.contains("[screens can wait]") == true)
}

@Test func searchNeverThrowsOnOddInput() throws {
    let index = try NotesIndex(url: tempURL())
    try index.upsert(meta("1", "Q"), body: "what's next")
    for q in ["what's", "\"unclosed", "AND", "*", "NEAR(", "-x", ""] {
        _ = try index.search(q, scope: .all, since: nil, until: nil, limit: 5)
    }
}

@Test func filtersByFolderAndDate() throws {
    let index = try NotesIndex(url: tempURL())
    try index.upsert(meta("1", "A", folder: "Meeting Transcripts", modified: 1_000), body: "budget talk")
    try index.upsert(meta("2", "B", folder: "Notes", modified: 2_000), body: "budget idea")
    #expect(try index.search("budget", scope: .folder("Notes"), since: nil, until: nil, limit: 10).map(\.id) == ["2"])
    #expect(try index.search("budget", scope: .all, since: Date(timeIntervalSince1970: 1_500), until: nil, limit: 10).map(\.id) == ["2"])
    #expect(try index.search("budget", scope: .all, since: nil, until: Date(timeIntervalSince1970: 1_500), limit: 10).map(\.id) == ["1"])
    #expect(try index.list(scope: .all, since: nil, until: nil, limit: 10).map(\.id) == ["2", "1"])
    #expect(try index.folders() == [FolderCount(name: "Meeting Transcripts", count: 1), FolderCount(name: "Notes", count: 1)])
}

@Test func upsertRetagDeleteKeepFTSInSync() throws {
    let index = try NotesIndex(url: tempURL())
    try index.upsert(meta("1", "Old"), body: "alpha")
    try index.upsert(meta("1", "New", modified: 2_000), body: "beta <b>emoji 🎉</b>")
    #expect(try index.search("alpha", scope: .all, since: nil, until: nil, limit: 5).isEmpty)
    #expect(try index.note(id: "1")?.body == "beta <b>emoji 🎉</b>")
    try index.retag(meta("1", "New", folder: "Work", modified: 2_000))
    #expect(try index.note(id: "1")?.folder == "Work")
    #expect(try index.stamps()["1"] == IndexedStamp(title: "New", folder: "Work", account: "iCloud", modifiedMs: 2_000_000))
    try index.delete(ids: ["1"])
    #expect(try index.search("beta", scope: .all, since: nil, until: nil, limit: 5).isEmpty)
    #expect(try index.count() == 0)
    try index.checkIntegrity()
}

@Test func readOnlyReaderSeesWriterAndCannotWrite() throws {
    let url = tempURL()
    let writer = try NotesIndex(url: url)
    try writer.upsert(meta("1", "Shared"), body: "visible")
    try writer.setLastRefresh(Date(timeIntervalSince1970: 5_000))
    let reader = try NotesIndex(url: url, readOnly: true)
    #expect(try reader.search("visible", scope: .all, since: nil, until: nil, limit: 5).count == 1)
    #expect(try reader.lastRefresh() == Date(timeIntervalSince1970: 5_000))
    #expect(throws: (any Error).self) { try reader.upsert(meta("2", "x"), body: "y") }
}

@Test func transactionCommitsAndRollsBack() throws {
    let index = try NotesIndex(url: tempURL())
    try index.transaction { try index.upsert(meta("1", "A"), body: "one") }
    #expect(try index.count() == 1)
    struct Boom: Error {}
    #expect(throws: Boom.self) {
        try index.transaction {
            try index.upsert(meta("2", "B"), body: "two")
            throw Boom()
        }
    }
    #expect(try index.count() == 1)
}

@Test func defaultURLUsesTheAppFolder() {
    let minutes = NotesIndex.defaultURL()
    #expect(Array(minutes.pathComponents.suffix(3)) == ["Application Support", "Minutes", "notes-index.db"])
    let helper = NotesIndex.defaultURL(appFolder: "Hermes Helper")
    #expect(Array(helper.pathComponents.suffix(3)) == ["Application Support", "Hermes Helper", "notes-index.db"])
}

@Test func groupKeysLetALaterRecordReplaceEarlierOnes() throws {
    let index = try NotesIndex(url: tempURL())
    try index.upsert(meta("a", "v1", folder: "calendar"), body: "first", groupKey: "calendar:E1")
    try index.upsert(meta("b", "v2", folder: "calendar"), body: "second", groupKey: "calendar:E1")
    try index.upsert(meta("c", "other", folder: "calendar"), body: "third", groupKey: "calendar:E2")
    try index.upsert(meta("d", "plain"), body: "no group")
    #expect(try index.ids(groupKey: "calendar:E1").sorted() == ["a", "b"])
    #expect(try index.delete(groupKey: "calendar:E1", except: "b") == ["a"])
    #expect(try index.note(id: "a") == nil)
    #expect(try index.note(id: "b")?.title == "v2")
    #expect(try index.count() == 3)
}

@Test func existingIndexesGainTheGroupKeyColumn() throws {
    let url = tempURL()
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let v1 = try SQLiteConnection(path: url.path, readOnly: false)   // the schema as shipped before group keys
    try v1.exec("""
    CREATE TABLE notes (id INTEGER PRIMARY KEY, note_id TEXT NOT NULL UNIQUE, title TEXT NOT NULL, folder TEXT NOT NULL,
      account TEXT NOT NULL, created_at INTEGER NOT NULL, modified_at INTEGER NOT NULL, body TEXT NOT NULL);
    CREATE VIRTUAL TABLE notes_fts USING fts5(title, body, content='notes', content_rowid='id', tokenize='porter unicode61');
    CREATE TRIGGER notes_ai AFTER INSERT ON notes BEGIN INSERT INTO notes_fts(rowid, title, body) VALUES (new.id, new.title, new.body); END;
    CREATE TRIGGER notes_ad AFTER DELETE ON notes BEGIN INSERT INTO notes_fts(notes_fts, rowid, title, body) VALUES ('delete', old.id, old.title, old.body); END;
    CREATE TRIGGER notes_au AFTER UPDATE ON notes BEGIN INSERT INTO notes_fts(notes_fts, rowid, title, body) VALUES ('delete', old.id, old.title, old.body);
      INSERT INTO notes_fts(rowid, title, body) VALUES (new.id, new.title, new.body); END;
    CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
    INSERT INTO notes(note_id, title, folder, account, created_at, modified_at, body) VALUES ('1', 'Before', 'Notes', 'iCloud', 1, 1, 'x');
    PRAGMA user_version = 1;
    """)
    let reopened = try NotesIndex(url: url)
    #expect(try reopened.note(id: "1")?.title == "Before")
    try reopened.upsert(meta("2", "After", folder: "calendar"), body: "y", groupKey: "calendar:E9")
    #expect(try reopened.ids(groupKey: "calendar:E9") == ["2"])
}

@Test func upcomingReturnsCalendarRecordsByItemTimeSoonestFirst() throws {
    let index = try NotesIndex(url: tempURL())
    let now = Date()
    func put(_ id: String, start: TimeInterval, folder: String = "calendar", account: String = FeedRecord.account, group: String? = nil) throws {
        try index.upsert(NoteMetadata(id: id, title: id, folder: folder, account: account,
                                      createdAt: now.addingTimeInterval(start), modifiedAt: now, isLocked: false),
                         body: "Calendar event, added", groupKey: group)
    }
    try put("feed:calendar/later.json", start: 30 * 60)
    try put("feed:calendar/soon.json", start: 10 * 60, group: "calendar:A")
    try put("feed:calendar/past.json", start: -60)
    try put("feed:calendar/edge.json", start: 35 * 60)
    try put("feed:calendar/far.json", start: 2 * 3600)
    try put("feed:mail/x.json", start: 10 * 60, folder: "mail")
    try put("Notes-x", start: 10 * 60, account: "iCloud")
    let found = try index.upcoming(folder: "calendar", account: FeedRecord.account, from: now, to: now.addingTimeInterval(35 * 60))
    #expect(found.map(\.id) == ["feed:calendar/soon.json", "feed:calendar/later.json", "feed:calendar/edge.json"])
    #expect(found[0].groupKey == "calendar:A")
    #expect(found[1].groupKey == nil)
    #expect(found[0].body == "Calendar event, added")
    #expect(abs(found[0].start.timeIntervalSince(now.addingTimeInterval(10 * 60))) < 0.001)
}

@Test func ownNotesScopeAndFeedRecordsDateByItemTime() throws {
    let index = try NotesIndex(url: tempURL())
    try index.upsert(meta("own", "Atrium", folder: "Northwoods", modified: 2_000), body: "atrium speakers")
    // A backfilled email: sent long ago (created_at), file written recently (modified_at).
    try index.upsert(NoteMetadata(id: "feed:mail/a.json", title: "Re: Atrium", folder: "mail", account: FeedRecord.account,
                                  createdAt: Date(timeIntervalSince1970: 500), modifiedAt: Date(timeIntervalSince1970: 3_000), isLocked: false),
                     body: "atrium quote")
    #expect(try index.search("atrium", scope: .ownNotes, since: nil, until: nil, limit: 10).map(\.id) == ["own"])
    #expect(try index.search("atrium", scope: .folder("mail"), since: nil, until: nil, limit: 10).map(\.id) == ["feed:mail/a.json"])
    // Date filters use the item's own time for feed records, never the file time.
    #expect(try index.search("atrium", scope: .all, since: Date(timeIntervalSince1970: 1_500), until: nil, limit: 10).map(\.id) == ["own"])
    #expect(try index.search("atrium", scope: .all, since: nil, until: Date(timeIntervalSince1970: 1_500), limit: 10).map(\.id) == ["feed:mail/a.json"])
    let hits = try index.search("atrium", scope: .all, since: nil, until: nil, limit: 10)
    #expect(hits.first { $0.id == "feed:mail/a.json" }?.datedAt == Date(timeIntervalSince1970: 500))
    #expect(hits.first { $0.id == "own" }?.datedAt == Date(timeIntervalSince1970: 2_000))
    // Listing orders by that same time: the note edited at 2,000 s comes before the email sent at 500 s.
    let listed = try index.list(scope: .all, since: nil, until: nil, limit: 10)
    #expect(listed.map(\.id) == ["own", "feed:mail/a.json"])
    #expect(listed.map(\.account) == ["iCloud", FeedRecord.account])
    #expect(try index.list(scope: .ownNotes, since: nil, until: nil, limit: 10).map(\.id) == ["own"])
}
