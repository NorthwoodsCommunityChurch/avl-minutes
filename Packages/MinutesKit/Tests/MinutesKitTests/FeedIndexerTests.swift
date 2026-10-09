import Foundation
import Testing
@testable import MinutesKit

private func tempDir() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("feed-test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func write(_ text: String, to url: URL, modified: Date? = nil) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: url)
    if let modified { try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path) }
}

@Test func feedRefreshIndexesRemovesAndLeavesNotesAlone() throws {
    let folder = try tempDir()
    let index = try NotesIndex(url: tempDir().appendingPathComponent("index.db"))
    try index.upsert(NoteMetadata(id: "n1", title: "A real note", folder: "Notes", account: "iCloud", createdAt: .init(), modifiedAt: .init(), isLocked: false), body: "lobby screens")
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    try write(#"{"type":"mail","subject":"Hermes test","body":"first version"}"#, to: folder.appendingPathComponent("mail/a.json"), modified: t0)
    try write(#"{"type":"teams","from":"Hermes","body":"skip me"}"#, to: folder.appendingPathComponent("teams/b.json"), modified: t0)
    try write("# readme", to: folder.appendingPathComponent("README.md"))
    try write(#"{"type":"mail","subject":"hidden"}"#, to: folder.appendingPathComponent("calendar/.hidden.json"))

    let feed = FeedIndexer(folder: folder, index: index)
    let first = try feed.refresh()
    #expect((first.indexed, first.removed, first.skipped, first.total, first.unreadable) == (1, 0, 1, 1, 0))
    #expect(first.records.map(\.path) == ["mail/a.json"])
    #expect(try index.count() == 2)
    #expect(try index.note(id: "feed:mail/a.json")?.title == "Hermes test")
    #expect(try index.search("first", folder: "mail", since: nil, until: nil, limit: 5).count == 1)

    // Unchanged files are not re-read; a changed file is.
    #expect(try feed.refresh() == FeedIndexer.Result(indexed: 0, removed: 0, skipped: 0, total: 1))
    try write(#"{"type":"mail","subject":"Hermes test 2","body":"second version"}"#, to: folder.appendingPathComponent("mail/a.json"), modified: t0.addingTimeInterval(60))
    #expect(try feed.refresh().indexed == 1)
    #expect(try index.note(id: "feed:mail/a.json")?.title == "Hermes test 2")

    // A removed file leaves the index; the real note is untouched throughout.
    try FileManager.default.removeItem(at: folder.appendingPathComponent("mail/a.json"))
    #expect(try feed.refresh() == FeedIndexer.Result(indexed: 0, removed: 1, skipped: 0, total: 0))
    #expect(try index.count() == 1)
    #expect(try index.note(id: "n1")?.title == "A real note")
}

@Test func feedStampsAreSeparableFromNotes() throws {
    let index = try NotesIndex(url: tempDir().appendingPathComponent("index.db"))
    try index.upsert(NoteMetadata(id: "n1", title: "N", folder: "Notes", account: "iCloud", createdAt: .init(), modifiedAt: .init(), isLocked: false), body: "")
    try index.upsert(NoteMetadata(id: "feed:mail/a.json", title: "M", folder: "mail", account: FeedRecord.account, createdAt: .init(), modifiedAt: .init(), isLocked: false), body: "")
    let all = try index.stamps()
    #expect(FeedRecord.notesOnly(all).keys.sorted() == ["n1"])
    #expect(FeedRecord.feedOnly(all).keys.sorted() == ["feed:mail/a.json"])
}

@Test func laterFilesForTheSameCalendarEventReplaceEarlierOnes() throws {
    let folder = try tempDir()
    let index = try NotesIndex(url: tempDir().appendingPathComponent("index.db"))
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    let event = #""id":"AAMk-event-1""#
    try write(#"{"type":"calendar","action":"added","subject":"New Event","start":"2026-10-08T17:00:00.0000000","#  + event + "}", to: folder.appendingPathComponent("calendar/20261008-163338-1572.json"), modified: t0)
    try write(#"{"type":"calendar","action":"added","subject":"New Event","start":"2026-10-08T17:00:00.0000000","#  + event + "}", to: folder.appendingPathComponent("calendar/20261008-163339-1637.json"), modified: t0.addingTimeInterval(1))
    try write(#"{"type":"calendar","action":"updated","subject":"Hermes Test","start":"2026-10-08T17:00:00.0000000","#  + event + "}", to: folder.appendingPathComponent("calendar/20261008-163346-8239.json"), modified: t0.addingTimeInterval(8))
    try write(#"{"type":"calendar","action":"added","subject":"Other event","start":"2026-10-09T17:00:00.0000000","id":"AAMk-event-2"}"#, to: folder.appendingPathComponent("calendar/20261008-170000-1111.json"), modified: t0.addingTimeInterval(60))
    let feed = FeedIndexer(folder: folder, index: index, timeZone: TimeZone(identifier: "America/Chicago")!)
    let r = try feed.refresh()
    #expect(r.total == 2)
    let titles = try index.list(folder: "calendar", since: nil, until: nil, limit: 10).map(\.title).sorted()
    #expect(titles == ["Hermes Test — Thu Oct 8, 2026 12:00 PM", "Other event — Fri Oct 9, 2026 12:00 PM"])
    #expect(try index.note(id: "feed:calendar/20261008-163346-8239.json")?.title == "Hermes Test — Thu Oct 8, 2026 12:00 PM")
    #expect(try index.note(id: "feed:calendar/20261008-163338-1572.json") == nil)

    // A later update to event 1 (next pass) replaces the survivor too, and nothing comes back.
    try write(#"{"type":"calendar","action":"updated","subject":"Hermes Test (moved)","start":"2026-10-08T18:00:00.0000000","#  + event + "}", to: folder.appendingPathComponent("calendar/20261008-180000-2222.json"), modified: t0.addingTimeInterval(120))
    #expect(try feed.refresh().total == 2)
    #expect(try index.list(folder: "calendar", since: nil, until: nil, limit: 10).map(\.title).sorted() == ["Hermes Test (moved) — Thu Oct 8, 2026 1:00 PM", "Other event — Fri Oct 9, 2026 12:00 PM"])
    #expect(try feed.refresh() == FeedIndexer.Result(indexed: 0, removed: 0, skipped: 0, total: 2))
}

@Test func feedRecordsCarryAGroupKeyForDuplicates() throws {
    let p = try #require(FeedRecord.parse(Data(#"{"type":"calendar","subject":"S","id":"E1"}"#.utf8), relativePath: "calendar/a.json", fileModifiedAt: .init()))
    #expect(p.groupKey == "calendar:E1")
    let m = try #require(FeedRecord.parse(Data(#"{"type":"mail","subject":"S"}"#.utf8), relativePath: "mail/a.json", fileModifiedAt: .init()))
    #expect(m.groupKey == nil)
}

@Test func mailAndCalendarAreIndexedBeforeTeamsAndAPassIsCapped() throws {
    let folder = try tempDir()
    let index = try NotesIndex(url: tempDir().appendingPathComponent("index.db"))
    let old = Date().addingTimeInterval(-3600)
    for n in 0..<5 {
        let json = "{\"type\":\"teams\",\"chat\":\"c\",\"from\":\"Kirk\",\"created\":\"2026-10-08T10:00:00Z\",\"id\":\"t\(n)\",\"body\":\"chat \(n)\"}"
        try write(json, to: folder.appendingPathComponent("teams/t\(n).json"), modified: old)
    }
    try write(#"{"type":"mail","received":"2026-10-08T20:58:26Z","from":"brian@example.org","subject":"Atrium","body":"drawings"}"#, to: folder.appendingPathComponent("mail/brian.json"), modified: Date())
    try write(#"{"type":"calendar","action":"updated","subject":"Sync","start":"2026-10-09T19:00:00Z","end":"2026-10-09T19:40:00Z","id":"e1","body":"x"}"#, to: folder.appendingPathComponent("calendar/e1.json"), modified: Date())
    let feed = FeedIndexer(folder: folder, index: index, maxPerPass: 4)
    let first = try feed.refresh()
    #expect(first.indexed == 4)
    #expect(first.capped == true)
    #expect(first.records.prefix(2).map(\.folder).sorted() == ["calendar", "mail"])   // mail and calendar before any chat history
    #expect(first.records.dropFirst(2).allSatisfy { $0.folder == "teams" })
    let second = try feed.refresh()
    #expect(second.indexed == 3)
    #expect(second.capped == false)
    #expect(try feed.count() == 7)
}

@Test func aNewRecordFormatReindexesEveryFeedFile() throws {
    let folder = try tempDir()
    let index = try NotesIndex(url: tempDir().appendingPathComponent("index.db"))
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    try write(#"{"type":"mail","subject":"Old format","body":"x"}"#, to: folder.appendingPathComponent("mail/a.json"), modified: t0)
    let feed = FeedIndexer(folder: folder, index: index)
    #expect(try feed.refresh().indexed == 1)
    #expect(try feed.refresh().indexed == 0)                       // unchanged file, nothing to do
    try index.setMeta("feed_format", "0")                            // pretend the index was built by an older helper
    let again = FeedIndexer(folder: folder, index: index)
    #expect(try again.refresh().indexed == 1)                        // re-read with the current format
    #expect(try index.meta("feed_format") == String(FeedRecord.formatVersion))
    #expect(try again.refresh().indexed == 0)
}

@Test func aRewriteWithNoRealChangeIsMarkedUnchanged() throws {
    // Outlook re-sends every occurrence of a series, word for word, whenever the series is touched (edit-3, 2026-10-09:
    // nine identical copies of each Weekend Tech Rehearsal in 90 minutes). Only a real change is news.
    let folder = try tempDir()
    let index = try NotesIndex(url: tempDir().appendingPathComponent("index.db"))
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    let same = #"{"type":"calendar","action":"updated","subject":"Rehearsal","start":"2026-10-16T21:15:00.0000000","id":"E1"}"#
    try write(same, to: folder.appendingPathComponent("calendar/a.json"), modified: t0)
    try write(same, to: folder.appendingPathComponent("calendar/b.json"), modified: t0.addingTimeInterval(1))
    let feed = FeedIndexer(folder: folder, index: index)
    let first = try feed.refresh()
    #expect(first.records.map(\.unchanged) == [false, true])

    try write(same, to: folder.appendingPathComponent("calendar/c.json"), modified: t0.addingTimeInterval(60))
    #expect(try feed.refresh().records.map(\.unchanged) == [true])
    try write(same.replacingOccurrences(of: "21:15", with: "22:15"), to: folder.appendingPathComponent("calendar/d.json"), modified: t0.addingTimeInterval(120))
    #expect(try feed.refresh().records.map(\.unchanged) == [false])
}
