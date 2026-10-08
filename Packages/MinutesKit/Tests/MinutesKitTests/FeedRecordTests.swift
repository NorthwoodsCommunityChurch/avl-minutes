import Foundation
import Testing
@testable import MinutesKit

private let mtime = Date(timeIntervalSince1970: 1_800_000_000)

private func parse(_ json: String, path: String) -> FeedRecord.Parsed? {
    FeedRecord.parse(Data(json.utf8), relativePath: path, fileModifiedAt: mtime)
}

@Test func mailBecomesANoteInTheMailFolder() throws {
    let p = try #require(parse(#"{"type":"mail","received":"2026-10-08T16:16:42+00:00","from":"a@x.org","to":"b@x.org","subject":"Hermes test","conversation":"c1","body":"A test email\n\nAaron"}"#, path: "mail/20261008-161658-6678.json"))
    #expect(p.metadata.id == "feed:mail/20261008-161658-6678.json")
    #expect(p.metadata.folder == "mail")
    #expect(p.metadata.account == FeedRecord.account)
    #expect(p.metadata.title == "Hermes test")
    #expect(p.metadata.modifiedAt == mtime)
    #expect(p.metadata.createdAt == Date(timeIntervalSince1970: 1_791_476_202))   // the received time
    #expect(p.body.contains("From: a@x.org"))
    #expect(p.body.contains("A test email"))
    #expect(!p.metadata.isLocked)
}

@Test func calendarEventsSayWhenAndWhatHappened() throws {
    let p = try #require(parse(#"{"type":"calendar","action":"Added","subject":"Staff meeting","start":"2026-10-09T14:00:00.0000000","end":"2026-10-09T15:00:00.0000000","location":"Room 2","organizer":"b@x.org","attendees":"a@x.org; c@x.org","id":"e1","body":"Agenda"}"#, path: "calendar/x.json"))
    #expect(p.metadata.folder == "calendar")
    #expect(p.metadata.title == "Staff meeting")
    #expect(p.body.contains("added"))
    #expect(p.body.contains("When: 2026-10-09T14:00:00"))
    #expect(p.body.contains("Where: Room 2"))
    #expect(p.body.contains("Agenda"))
}

@Test func teamsMessagesAreTitledBySenderAndHermesIsSkipped() throws {
    let p = try #require(parse(#"{"type":"teams","chat":"19:abc","from":"Kirk Smith","created":"2026-10-08T17:00:00Z","id":"m1","body":"Can you check the lobby screens before Sunday?"}"#, path: "teams/y.json"))
    #expect(p.metadata.folder == "teams")
    #expect(p.metadata.title == "Kirk Smith: Can you check the lobby screens before Sunday?")
    #expect(p.body.contains("From: Kirk Smith"))
    #expect(parse(#"{"type":"teams","from":"Hermes","body":"The answer"}"#, path: "teams/z.json") == nil)
}

@Test func teamsMessagesGroupByMessageIdSoABackfillCopyReplacesTheLiveOne() throws {
    let p = try #require(parse(#"{"type":"teams","chat":"19:abc","from":"Kirk Smith","created":"2026-10-08T17:00:00Z","id":"1791484137639","body":"hi"}"#, path: "teams/live.json"))
    #expect(p.groupKey == "teams:1791484137639")
    let noID = try #require(parse(#"{"type":"teams","chat":"19:abc","from":"Kirk Smith","created":"2026-10-08T17:00:00Z","body":"hi"}"#, path: "teams/old.json"))
    #expect(noID.groupKey == nil)
}

@Test func sentMailIsTitledByRecipient() throws {
    let p = try #require(parse(#"{"type":"mail","direction":"sent","received":"2026-10-08T20:00:00Z","from":"Aaron Larson","to":"Kirk Smith <kirk@example.org>","subject":"Lobby screens","body":"Done before Sunday."}"#, path: "mail/s.json"))
    #expect(p.metadata.title == "To Kirk Smith <kirk@example.org>: Lobby screens")
    #expect(p.body.contains("Sent by Aaron to: Kirk Smith <kirk@example.org>"))
    #expect(!p.body.hasPrefix("From:"))
}

@Test func teamsMessagesWithoutASenderAreSkipped() {
    // Bot and system messages carry no user display name; Hermes's own replies arrive this way.
    #expect(parse(#"{"type":"teams","chat":"19:abc","from":"","created":"2026-10-08T18:28:57Z","id":"m2","body":"Here is what I found."}"#, path: "teams/w.json") == nil)
    #expect(parse(#"{"type":"teams","chat":"19:abc","created":"2026-10-08T18:28:57Z","id":"m3","body":"no from field at all"}"#, path: "teams/v.json") == nil)
}

@Test func unknownOrBrokenFilesAreSkipped() {
    #expect(parse(#"{"type":"weather","body":"x"}"#, path: "mail/a.json") == nil)
    #expect(parse("not json", path: "mail/b.json") == nil)
    #expect(parse(#"{"type":"mail","subject":"no body"}"#, path: "mail/c.json")?.metadata.title == "no body")
}

@Test func missingSubjectsGetAPlaceholderTitle() throws {
    let p = try #require(parse(#"{"type":"mail","body":"hi"}"#, path: "mail/d.json"))
    #expect(p.metadata.title == "(no subject)")
}
