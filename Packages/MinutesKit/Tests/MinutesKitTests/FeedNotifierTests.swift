import Foundation
import Testing
@testable import MinutesKit

private func record(_ folder: String, _ title: String, body: String, age: TimeInterval, now: Date,
                    itemAge: TimeInterval? = nil, name: String = UUID().uuidString) -> FeedIndexer.IndexedRecord {
    FeedIndexer.IndexedRecord(path: "\(folder)/\(name).json", folder: folder, title: title, body: body,
                              groupKey: nil, modifiedAt: now.addingTimeInterval(-age), createdAt: now.addingTimeInterval(-(itemAge ?? age)))
}

@Test func calendarChangesSentMailAndNoAutomatedMailQualify() {
    let now = Date()
    let records = [
        record("calendar", "Sync", body: "Calendar event, updated\nWhen: 2026-10-15T19:00:00 to 2026-10-15T19:40:00", age: 60, now: now),
        record("calendar", "Gone", body: "Calendar event, deleted\nWhen: x", age: 60, now: now),
        record("calendar", "Later", body: "Calendar event, added\nWhen: \(ISO8601DateFormatter().string(from: now.addingTimeInterval(3 * 3600))) to x", age: 60, now: now),
        record("calendar", "Far", body: "Calendar event, added\nWhen: \(ISO8601DateFormatter().string(from: now.addingTimeInterval(10 * 86400))) to x", age: 60, now: now),
        record("calendar", "Backfilled", body: "Calendar event, backfill\nWhen: x", age: 60, now: now),
        record("mail", "To Kirk: Screens", body: "Sent by Aaron to: Kirk\nSent: x", age: 60, now: now),
        record("mail", "Alert", body: "From: Enterprise.Manager-noreply@reflect.qsc.com\nTo: Aaron", age: 60, now: now),
    ]
    let picked = FeedNotifier.select(records, now: now).map(\.title)
    #expect(picked == ["Sync", "Gone", "Later", "To Kirk: Screens"])
}

@Test func oldFilesNeverTriggerSoBackfillsAndRestartsStayQuiet() {
    let now = Date()
    let old = record("calendar", "Old change", body: "Calendar event, updated", age: 90 * 60, now: now)
    let fresh = record("calendar", "New change", body: "Calendar event, updated", age: 40 * 60, now: now)
    #expect(FeedNotifier.select([old, fresh], now: now).map(\.title) == ["New change"])
}

@Test func aRecurringSeriesCollapsesToOneLineAndTheBatchIsCapped() {
    let now = Date()
    var records: [FeedIndexer.IndexedRecord] = []
    for day in 1...40 {
        records.append(record("calendar", "Sunday Flow + Outlook",
                              body: "Calendar event, updated\nWhen: 2026-11-\(String(format: "%02d", day % 28 + 1))T19:00:00 to 2026-11-\(String(format: "%02d", day % 28 + 1))T19:40:00", age: 30, now: now))
    }
    for n in 1...15 { records.append(record("mail", "To person \(n): hello", body: "Sent by Aaron to: person \(n)", age: 30, now: now)) }
    let lines = FeedNotifier.lines(for: FeedNotifier.select(records, now: now))
    #expect(lines.count == 12)
    #expect(lines[0].hasPrefix("Sunday Flow + Outlook: 40 occurrences updated"))
    #expect(lines[1].contains("Sent by Aaron to: person 1"))
}

@Test func backfilledSentMailNeverTriggers() {
    // A mail backfill writes old sent mail into fresh files: the file is new, the email is not.
    let now = Date()
    let oldMailFreshFile = record("mail", "To Kirk: Old", body: "Sent by Aaron to: Kirk", age: 60, now: now, itemAge: 30 * 86400)
    let backfillNamed = record("mail", "To Kirk: Named", body: "Sent by Aaron to: Kirk", age: 60, now: now, name: "backfill-20261008-223047-2995")
    let real = record("mail", "To Kirk: Now", body: "Sent by Aaron to: Kirk", age: 60, now: now, itemAge: 120)
    #expect(FeedNotifier.select([oldMailFreshFile, backfillNamed, real], now: now).map(\.title) == ["To Kirk: Now"])
}

@Test func unchangedRewritesNeverTrigger() {
    let now = Date()
    let body = "Calendar event, updated\nWhen: 2026-10-16T21:15:00 to x"
    let changed = record("calendar", "Rehearsal — Fri Oct 16, 2026 4:15 PM", body: body, age: 60, now: now)
    let base = record("calendar", "Rehearsal — Fri Oct 23, 2026 4:15 PM", body: body, age: 60, now: now)
    let rewrite = FeedIndexer.IndexedRecord(path: base.path, folder: base.folder, title: base.title, body: base.body,
                                            groupKey: nil, modifiedAt: base.modifiedAt, createdAt: base.createdAt, unchanged: true)
    #expect(FeedNotifier.select([changed, rewrite], now: now).map(\.title) == [changed.title])
}

@Test func aSeriesCollapsesEvenThoughEachTitleCarriesItsDate() {
    // Calendar titles end in " — <local date>" since feed format 2, so each occurrence's title differs.
    let now = Date()
    let records = (1...20).map { day in
        record("calendar", "Weekend Tech Rehearsal — Fri Nov \(day), 2026 4:15 PM",
               body: "Calendar event, updated\nWhen: 2026-11-\(String(format: "%02d", day))T16:15:00 to x", age: 30, now: now)
    }
    let lines = FeedNotifier.lines(for: FeedNotifier.select(records, now: now), now: now)
    #expect(lines.count == 1)
    #expect(lines[0].hasPrefix("Weekend Tech Rehearsal: 20 occurrences updated"))
}

// Aaron, 2026-10-20: "I want her looking at sent messages just like mail." His Teams messages to other people wake
// Hermes; his messages to her bot chat already reach her directly.
@Test func aaronsSentTeamsMessagesQualifyLikeSentMail() {
    let now = Date()
    let toSeth = record("teams", "Aaron Larson: On the hyperdeck?", body: "From: Aaron Larson\nSent: x\nChat: 19:aaron_seth@unq.gbl.spaces\n\nOn the hyperdeck?", age: 60, now: now)
    let toBot = record("teams", "Aaron Larson: scrum?", body: "From: Aaron Larson\nSent: x\nChat: 19:aaron_\(FeedNotifier.hermesBotId)@unq.gbl.spaces\n\nscrum?", age: 60, now: now)
    let fromSeth = record("teams", "Seth Potter: audio", body: "From: Seth Potter\nSent: x\nChat: 19:aaron_seth@unq.gbl.spaces\n\naudio", age: 60, now: now)
    let oldMessageNewFile = record("teams", "Aaron Larson: old", body: "From: Aaron Larson\nSent: x\nChat: 19:aaron_seth@unq.gbl.spaces\n\nold", age: 60, now: now, itemAge: 5 * 86400)
    let backfill = record("teams", "Aaron Larson: bf", body: "From: Aaron Larson\nSent: x\nChat: 19:aaron_seth@unq.gbl.spaces\n\nbf", age: 60, now: now, itemAge: 120, name: "backfill-1")
    // Seth's message wakes her too since the incoming-ask rule (same day); see messagesPeopleSendAaronQualify….
    #expect(FeedNotifier.select([toSeth, toBot, fromSeth, oldMessageNewFile, backfill], now: now).map(\.title) == ["Aaron Larson: On the hyperdeck?", "Seth Potter: audio"])
}

@Test func aSentTeamsMessageLineNamesWhoTheChatIsWith() {
    let now = Date()
    let long = String(repeating: "word ", count: 300)
    let msg = record("teams", "Aaron Larson: On the hyperdeck?", body: "From: Aaron Larson\nSent: 2026-10-20T17:24:49Z\nChat: 19:aaron_seth@unq.gbl.spaces\n\nOn the hyperdeck?\n\(long)", age: 60, now: now)
    let lines = FeedNotifier.lines(for: [msg], now: now) { chat in chat == "19:aaron_seth@unq.gbl.spaces" ? ["Seth Potter", "MJ Brand"] : [] }
    #expect(lines.count == 1)
    #expect(lines[0].hasPrefix("Teams message sent by Aaron in a chat with Seth Potter, MJ Brand\nSent: 2026-10-20T17:24:49Z\n\nOn the hyperdeck?"))
    #expect(lines[0].count < 900)
    #expect(!lines[0].contains("19:aaron_seth"))
    let alone = FeedNotifier.lines(for: [msg], now: now)
    #expect(alone[0].hasPrefix("Teams message sent by Aaron (no one else has written in this chat yet)\n"))
}

// Aaron, 2026-10-20: "hermes isnt catching when someone asks me to do something in email or teams ... she would say
// something like 'jason asked you to do this, would you like to add it to your to-do?'" Messages people send him wake her;
// automated senders (no-reply alerts, notifications) do not.
@Test func messagesPeopleSendAaronQualifyButAutomatedMailDoesNot() {
    let now = Date()
    let jason = record("mail", "Budget numbers", body: "From: jason.lee@northwoods.church\nTo: Aaron.Larson@northwoods.church\nReceived: x\nSubject: Budget numbers\n\nCan you send me the lighting numbers by Friday?", age: 60, now: now)
    let noreply = record("mail", "Alert", body: "From: Enterprise.Manager-noreply@reflect.qsc.com\nTo: Aaron\nReceived: x\nSubject: Alert\n\nx", age: 60, now: now)
    let github = record("mail", "PAT", body: "From: noreply@github.com\nTo: Aaron\nReceived: x\nSubject: PAT\n\nx", age: 60, now: now)
    let notify = record("mail", "Digest", body: "From: notifications@planningcenteronline.com\nTo: Aaron\nReceived: x\nSubject: Digest\n\nx", age: 60, now: now)
    let seth = record("teams", "Seth Potter: audio", body: "From: Seth Potter\nSent: x\nChat: 19:aaron_seth@unq.gbl.spaces\n\nCould you work with MJ to get the audio fixed?", age: 60, now: now)
    let oldMail = record("mail", "Old", body: "From: jason.lee@northwoods.church\nTo: Aaron\nReceived: x\nSubject: Old\n\nx", age: 60, now: now, itemAge: 3 * 86400)
    #expect(FeedNotifier.select([jason, noreply, github, notify, seth, oldMail], now: now).map(\.title) == ["Budget numbers", "Seth Potter: audio"])
}

@Test func anIncomingMessageLineSaysWhoSentItAndCarriesTheText() {
    let now = Date()
    let mail = record("mail", "Budget numbers", body: "From: jason.lee@northwoods.church\nTo: Aaron.Larson@northwoods.church; blake@northwoods.church\nReceived: 2026-10-20T15:00:00Z\nSubject: Budget numbers\n\nHi Aaron,\n\nCan you send me the lighting numbers by Friday?", age: 60, now: now)
    let teams = record("teams", "Seth Potter: audio", body: "From: Seth Potter\nSent: 2026-10-20T16:55:06Z\nChat: 19:group@thread.v2\n\nCould you work with MJ to get the audio fixed?", age: 60, now: now)
    let lines = FeedNotifier.lines(for: [mail, teams], now: now) { _ in ["Seth Potter", "MJ Brand"] }
    #expect(lines[0] == "Email to Aaron from jason.lee@northwoods.church\nTo: Aaron.Larson@northwoods.church; blake@northwoods.church\nReceived: 2026-10-20T15:00:00Z\nSubject: Budget numbers\n\nHi Aaron,\n\nCan you send me the lighting numbers by Friday?")
    #expect(lines[1] == "Teams message to Aaron from Seth Potter in a chat with MJ Brand\nSent: 2026-10-20T16:55:06Z\n\nCould you work with MJ to get the audio fixed?")
    let oneOnOne = FeedNotifier.lines(for: [teams], now: now) { _ in ["Seth Potter"] }
    #expect(oneOnOne[0].hasPrefix("Teams message to Aaron from Seth Potter (1:1 chat)\n"))
}
