import Foundation
import Testing
@testable import MinutesKit

private func record(_ folder: String, _ title: String, body: String, age: TimeInterval, now: Date,
                    itemAge: TimeInterval? = nil, name: String = UUID().uuidString) -> FeedIndexer.IndexedRecord {
    FeedIndexer.IndexedRecord(path: "\(folder)/\(name).json", folder: folder, title: title, body: body,
                              groupKey: nil, modifiedAt: now.addingTimeInterval(-age), createdAt: now.addingTimeInterval(-(itemAge ?? age)))
}

@Test func onlyCalendarChangesAndSentMailQualify() {
    let now = Date()
    let records = [
        record("calendar", "Sync", body: "Calendar event, updated\nWhen: 2026-10-15T19:00:00 to 2026-10-15T19:40:00", age: 60, now: now),
        record("calendar", "Gone", body: "Calendar event, deleted\nWhen: x", age: 60, now: now),
        record("calendar", "Later", body: "Calendar event, added\nWhen: \(ISO8601DateFormatter().string(from: now.addingTimeInterval(3 * 3600))) to x", age: 60, now: now),
        record("calendar", "Far", body: "Calendar event, added\nWhen: \(ISO8601DateFormatter().string(from: now.addingTimeInterval(10 * 86400))) to x", age: 60, now: now),
        record("calendar", "Backfilled", body: "Calendar event, backfill\nWhen: x", age: 60, now: now),
        record("mail", "To Kirk: Screens", body: "Sent by Aaron to: Kirk\nSent: x", age: 60, now: now),
        record("mail", "Invoice", body: "From: vendor\nTo: Aaron", age: 60, now: now),
        record("teams", "Kirk: hi", body: "From: Kirk", age: 60, now: now),
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
