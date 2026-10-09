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

@Test func folderNamesResolveLooselyAndUnknownOnesAreErrors() throws {
    let (tools, index) = try makeTools()
    try index.upsert(meta("a", "Atrium", folder: "Northwoods"), body: "atrium speakers")
    try index.upsert(meta("t", "Meeting — Thu Oct 8", folder: "Meeting Transcripts"), body: "[00:00:01] Me: atrium walls")
    try index.upsert(NoteMetadata(id: "feed:mail/a.json", title: "Re: Atrium", folder: "mail", account: FeedRecord.account,
                                  createdAt: now.addingTimeInterval(-86_400), modifiedAt: now.addingTimeInterval(-60), isLocked: false),
                     body: "atrium quote")
    // Case does not matter for a real folder name.
    #expect(try tools.searchNotes(query: "atrium", folder: "northwoods", since: nil, until: nil, limit: nil).contains("1 note matches"))
    // "notes" means all of Aaron's own notes and transcripts, never the feed.
    let own = try tools.searchNotes(query: "atrium", folder: "notes", since: nil, until: nil, limit: nil)
    #expect(own.contains("2 notes match") && own.contains("Northwoods") && own.contains("Meeting Transcripts") && !own.contains("mail"))
    // Common aliases land on the folder they mean.
    #expect(try tools.searchNotes(query: "atrium", folder: "transcripts", since: nil, until: nil, limit: nil).contains("Meeting Transcripts"))
    #expect(try tools.searchNotes(query: "atrium", folder: "email", since: nil, until: nil, limit: nil).contains("— mail —"))
    // An unknown folder is an error that names the real ones, never a silent "no notes match".
    let message = "No folder named \"Nope\". Folders: mail, Meeting Transcripts, Northwoods. Omit folder to search everything, or pass \"notes\" for Aaron's own notes and transcripts."
    #expect(throws: ToolError.invalidArgument(message)) {
        try tools.searchNotes(query: "atrium", folder: "Nope", since: nil, until: nil, limit: nil)
    }
    #expect(throws: ToolError.invalidArgument(message)) { try tools.listNotes(folder: "Nope", since: nil, until: nil, limit: nil) }
    #expect(try tools.listNotes(folder: " ", since: nil, until: nil, limit: nil).contains("3 notes"))
}

@Test func feedHitsShowTheItemTimeNotTheFileTime() throws {
    let (tools, index) = try makeTools()
    let sent = now.addingTimeInterval(-30 * 86_400)   // Sat Sep 5 2026, 2:53 PM CDT
    try index.upsert(NoteMetadata(id: "feed:mail/a.json", title: "To danny@hg.com: Dante", folder: "mail", account: FeedRecord.account,
                                  createdAt: sent, modifiedAt: now.addingTimeInterval(-60), isLocked: false), body: "clocking")
    try index.upsert(NoteMetadata(id: "feed:calendar/b.json", title: "Atrium — Fri Oct 9", folder: "calendar", account: FeedRecord.account,
                                  createdAt: now.addingTimeInterval(3_600), modifiedAt: now.addingTimeInterval(-60), isLocked: false), body: "clocking review")
    let out = try tools.searchNotes(query: "clocking", folder: nil, since: nil, until: nil, limit: nil)
    #expect(out.contains("\"To danny@hg.com: Dante\" — mail — sent Sat Sep 5, 2026 2:53 PM"))
    #expect(out.contains("\"Atrium — Fri Oct 9\" — calendar — starts Mon Oct 5, 2026 3:53 PM"))
    let list = try tools.listNotes(folder: "mail", since: nil, until: nil, limit: nil)
    #expect(list.contains("1. \"To danny@hg.com: Dante\" — mail — sent Sat Sep 5, 2026 2:53 PM · 8 characters"))
    // "since" means sent or start time for feed records: a month-old email is not "since yesterday".
    #expect(try tools.searchNotes(query: "clocking", folder: nil, since: now.addingTimeInterval(-86_400), until: nil, limit: nil).contains("1 note matches"))
}

@Test func aCutListSaysHowManyWereLeftOut() throws {
    let (tools, index) = try makeTools()
    for i in 1...6 { try index.upsert(meta("n\(i)", "Atrium \(i)"), body: "atrium item \(i)") }
    let cut = try tools.searchNotes(query: "atrium", folder: nil, since: nil, until: nil, limit: 4)
    #expect(cut.contains("4 of 6 notes match \"atrium\" (most relevant first; the rest are not shown — narrow with since, until, or folder, or raise limit up to 50):"))
    #expect(cut.components(separatedBy: "\n   id: ").count == 5)
    let whole = try tools.searchNotes(query: "atrium", folder: nil, since: nil, until: nil, limit: 10)
    #expect(whole.contains("6 notes match \"atrium\":"))
    #expect(try index.searchCount("atrium", scope: .ownNotes, since: nil, until: nil) == 6)
}
