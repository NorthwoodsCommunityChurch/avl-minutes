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
    let stems = try index.search("decide", folder: nil, since: nil, until: nil, limit: 10)
    #expect(stems.map(\.id) == ["2"])
    let ranked = try index.search("lobby screens", folder: nil, since: nil, until: nil, limit: 10)
    #expect(ranked.first?.id == "1")                    // title match outranks body match
    let phrase = try index.search("\"screens can wait\"", folder: nil, since: nil, until: nil, limit: 10)
    #expect(phrase.map(\.id) == ["2"])
    #expect(phrase.first?.snippet.contains("[screens can wait]") == true)
}

@Test func searchNeverThrowsOnOddInput() throws {
    let index = try NotesIndex(url: tempURL())
    try index.upsert(meta("1", "Q"), body: "what's next")
    for q in ["what's", "\"unclosed", "AND", "*", "NEAR(", "-x", ""] {
        _ = try index.search(q, folder: nil, since: nil, until: nil, limit: 5)
    }
}

@Test func filtersByFolderAndDate() throws {
    let index = try NotesIndex(url: tempURL())
    try index.upsert(meta("1", "A", folder: "Meeting Transcripts", modified: 1_000), body: "budget talk")
    try index.upsert(meta("2", "B", folder: "Notes", modified: 2_000), body: "budget idea")
    #expect(try index.search("budget", folder: "Notes", since: nil, until: nil, limit: 10).map(\.id) == ["2"])
    #expect(try index.search("budget", folder: nil, since: Date(timeIntervalSince1970: 1_500), until: nil, limit: 10).map(\.id) == ["2"])
    #expect(try index.search("budget", folder: nil, since: nil, until: Date(timeIntervalSince1970: 1_500), limit: 10).map(\.id) == ["1"])
    #expect(try index.list(folder: nil, since: nil, until: nil, limit: 10).map(\.id) == ["2", "1"])
    #expect(try index.folders() == [FolderCount(name: "Meeting Transcripts", count: 1), FolderCount(name: "Notes", count: 1)])
}

@Test func upsertRetagDeleteKeepFTSInSync() throws {
    let index = try NotesIndex(url: tempURL())
    try index.upsert(meta("1", "Old"), body: "alpha")
    try index.upsert(meta("1", "New", modified: 2_000), body: "beta <b>emoji 🎉</b>")
    #expect(try index.search("alpha", folder: nil, since: nil, until: nil, limit: 5).isEmpty)
    #expect(try index.note(id: "1")?.body == "beta <b>emoji 🎉</b>")
    try index.retag(meta("1", "New", folder: "Work", modified: 2_000))
    #expect(try index.note(id: "1")?.folder == "Work")
    #expect(try index.stamps()["1"] == IndexedStamp(title: "New", folder: "Work", account: "iCloud", modifiedMs: 2_000_000))
    try index.delete(ids: ["1"])
    #expect(try index.search("beta", folder: nil, since: nil, until: nil, limit: 5).isEmpty)
    #expect(try index.count() == 0)
    try index.checkIntegrity()
}

@Test func readOnlyReaderSeesWriterAndCannotWrite() throws {
    let url = tempURL()
    let writer = try NotesIndex(url: url)
    try writer.upsert(meta("1", "Shared"), body: "visible")
    try writer.setLastRefresh(Date(timeIntervalSince1970: 5_000))
    let reader = try NotesIndex(url: url, readOnly: true)
    #expect(try reader.search("visible", folder: nil, since: nil, until: nil, limit: 5).count == 1)
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
