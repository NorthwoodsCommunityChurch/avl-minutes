import Foundation
import Testing
@testable import MinutesKit

private let chicago = TimeZone(identifier: "America/Chicago")!
private let now = Date(timeIntervalSince1970: 1_791_230_000)   // Mon Oct 5 2026, 2:53 PM CDT

private func makeTools(refreshedAgo: TimeInterval? = 60, pageSize: Int = 40_000) throws -> (NotesTools, NotesIndex) {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("tools-\(UUID().uuidString)/i.db")
    let index = try NotesIndex(url: url)
    if let ago = refreshedAgo { try index.setLastRefresh(now.addingTimeInterval(-ago)) }
    let fixedNow = now
    return (NotesTools(index: index, timeZone: chicago, now: { fixedNow }, pageSize: pageSize), index)
}

private func meta(_ id: String, _ title: String, folder: String = "Notes") -> NoteMetadata {
    NoteMetadata(id: id, title: title, folder: folder, account: "iCloud",
                 createdAt: now.addingTimeInterval(-7200), modifiedAt: now.addingTimeInterval(-3600), isLocked: false)
}

@Test func searchOutputListsHitsWithFreshness() throws {
    let (tools, index) = try makeTools()
    try index.upsert(meta("x-1", "Staff meeting", folder: "Meeting Transcripts"), body: "[00:01:00] Me: the lobby screens are late")
    let out = try tools.searchNotes(query: "lobby", folder: nil, since: nil, until: nil, limit: nil)
    #expect(out.hasPrefix("Notes index updated 1 min ago."))
    #expect(out.contains("1 note matches \"lobby\":"))
    #expect(out.contains("1. \"Staff meeting\" — Meeting Transcripts — modified Mon Oct 5, 2026 1:53 PM"))
    #expect(out.contains("id: x-1"))
    #expect(out.contains("[lobby]"))
}

@Test func emptyAndStaleStatesAreExplicit() throws {
    let (tools, _) = try makeTools(refreshedAgo: 3 * 3600)
    let out = try tools.searchNotes(query: "nothing", folder: nil, since: nil, until: nil, limit: nil)
    #expect(out.contains("updated 3 hours ago. It may be out of date — Minutes might not be running."))
    #expect(out.contains("No notes match \"nothing\"."))
    let (fresh, _) = try makeTools(refreshedAgo: nil)
    #expect(try fresh.listFolders().hasPrefix("No notes indexed yet — open Minutes once so it can index your notes."))
}

@Test func getNotePagesLongNotes() throws {
    let (tools, index) = try makeTools(pageSize: 10)
    try index.upsert(meta("n", "Long"), body: "0123456789abcdefghij-end")
    let first = try tools.getNote(id: "n", offset: nil)
    #expect(first.contains("\"Long\""))
    #expect(first.contains("0123456789"))
    #expect(first.contains("[More text remains — call get_note with offset: 10]"))
    let last = try tools.getNote(id: "n", offset: 20)
    #expect(last.contains("-end") && !last.contains("More text remains"))
    #expect(throws: ToolError.notFound("No note with id \"missing\" in the index.")) { try tools.getNote(id: "missing", offset: nil) }
    #expect(throws: ToolError.self) { try tools.getNote(id: "n", offset: 999) }
}

@Test func listsAndFolders() throws {
    let (tools, index) = try makeTools()
    try index.upsert(meta("a", "A", folder: "Work"), body: "12345")
    let list = try tools.listNotes(folder: nil, since: nil, until: nil, limit: 5)
    #expect(list.contains("1. \"A\" — Work — modified Mon Oct 5, 2026 1:53 PM · created Mon Oct 5, 2026 12:53 PM · 5 characters"))
    #expect(try tools.listFolders().contains("- Work (1 note)"))
}

@Test func dateArgumentsUseLocalDays() throws {
    let since = try #require(DateArgument.parseSince("2026-10-05", timeZone: chicago))
    let until = try #require(DateArgument.parseUntil("2026-10-05", timeZone: chicago))
    #expect(until.timeIntervalSince(since) == 86_400)
    #expect(DateArgument.parseSince("10/05/2026", timeZone: chicago) == nil)
    #expect(DateArgument.parseSince("2026-10-05T14:00:00-05:00", timeZone: chicago) == Date(timeIntervalSince1970: 1_791_226_800))
}
