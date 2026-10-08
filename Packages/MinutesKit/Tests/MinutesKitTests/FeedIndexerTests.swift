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
    #expect(first == FeedIndexer.Result(indexed: 1, removed: 0, skipped: 1, total: 1))
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
