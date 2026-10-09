import Foundation
import Testing
@testable import MinutesKit

/// ISO 8601 text for a date (a fresh formatter each time: a global one is not concurrency-safe under Swift 6).
private enum Iso {
    static func string(from date: Date) -> String { ISO8601DateFormatter().string(from: date) }
}
private let iso = Iso.self

/// A calendar record as FeedRecord writes it (format 2): header lines, blank line, the invite's text.
private func note(_ title: String, start: Date, minutes: Double = 60, action: String = "added",
                  attendees: String = "blake@nw.church;aaron@nw.church;", group: String? = nil,
                  text: String = "Agenda: conduit, TVs", id: String = UUID().uuidString) -> NotesIndex.UpcomingNote {
    let end = start.addingTimeInterval(minutes * 60)
    let body = ["Calendar event, \(action)", "When: Fri Oct 9, 2026 3:00 PM to 4:00 PM CDT",
                "Start (UTC): \(iso.string(from: start))", "End (UTC): \(iso.string(from: end))",
                "Where: Blake's office", "Organizer: tiffiny@nw.church", "Attendees: \(attendees)", "", text].joined(separator: "\n")
    return NotesIndex.UpcomingNote(id: "feed:calendar/\(id).json", groupKey: group, title: "\(title) — Fri Oct 9, 2026 3:00 PM", body: body, start: start)
}

@Test func onlyRealUpcomingMeetingsAreAnnouncedSoonestFirst() {
    let now = Date()
    let notes = [
        note("Later", start: now.addingTimeInterval(30 * 60)),
        note("Soon", start: now.addingTimeInterval(10 * 60)),
        note("Started", start: now.addingTimeInterval(-60)),
        note("Far", start: now.addingTimeInterval(40 * 60)),
        note("Deleted", start: now.addingTimeInterval(20 * 60), action: "deleted"),
        note("Cancelled", start: now.addingTimeInterval(20 * 60), action: "cancelled"),
        note("Focus block", start: now.addingTimeInterval(20 * 60), attendees: ""),
        note("Only separators", start: now.addingTimeInterval(20 * 60), attendees: "; "),
        note("Conference day", start: now.addingTimeInterval(20 * 60), minutes: 24 * 60),
    ]
    let picks = MeetingPrep.select(notes, now: now) { _, _ in false }
    #expect(picks.map { FeedNotifier.seriesTitle($0.note.title) } == ["Soon", "Later"])
}

@Test func announcedMeetingsStayQuietUntilTheyMove() {
    let now = Date()
    let start = now.addingTimeInterval(20 * 60)
    let token = iso.string(from: start)
    let same = note("Sync", start: start, group: "calendar:AAA")
    #expect(MeetingPrep.select([same], now: now) { key, t in key == "meeting_announced:calendar:AAA" && t == token }.isEmpty)
    // Outlook rewrote the series (new file, same event id, same start): still quiet.
    let rewrite = note("Sync", start: start, group: "calendar:AAA", id: "newer-file")
    #expect(MeetingPrep.select([rewrite], now: now) { key, t in key == "meeting_announced:calendar:AAA" && t == token }.isEmpty)
    // Moved by a quarter hour: a new start token, announced again under the same key.
    let moved = note("Sync", start: start.addingTimeInterval(15 * 60), group: "calendar:AAA")
    let picks = MeetingPrep.select([moved], now: now) { key, t in key == "meeting_announced:calendar:AAA" && t == token }
    #expect(picks.count == 1)
    #expect(picks[0].key == "meeting_announced:calendar:AAA")
    #expect(picks[0].startToken == iso.string(from: start.addingTimeInterval(15 * 60)))
}

@Test func withoutAGroupTheFileIdIsTheKeyAndAtMostThreeGo() {
    let now = Date()
    let lone = note("Lone", start: now.addingTimeInterval(5 * 60), id: "lone")
    #expect(MeetingPrep.select([lone], now: now) { _, _ in false }.first?.key == "meeting_announced:feed:calendar/lone.json")
    let many = (1...5).map { note("M\($0)", start: now.addingTimeInterval(Double($0) * 60)) }
    #expect(MeetingPrep.select(many, now: now) { _, _ in false }.count == 3)
}

@Test func theRecordCarriesTheInviteFactsAndMinutesUntilStart() {
    let now = Date()
    let long = String(repeating: "word ", count: 120)
    let n = note("Atrium Tech Discussion", start: now.addingTimeInterval(28 * 60 + 20), text: "Agenda:\n  conduit,   TVs. \(long)")
    let pick = MeetingPrep.select([n], now: now) { _, _ in false }[0]
    let lines = MeetingPrep.record(for: pick, now: now).split(separator: "\n").map(String.init)
    #expect(lines[0] == "Meeting prep: Atrium Tech Discussion")
    #expect(lines[1] == "Starts: Fri Oct 9, 2026 3:00 PM to 4:00 PM CDT (in 28 minutes)")
    #expect(lines[2] == "Where: Blake's office")
    #expect(lines[3] == "Organizer: tiffiny@nw.church")
    #expect(lines[4] == "Attendees: blake@nw.church;aaron@nw.church")
    #expect(lines[5].hasPrefix("Invite: Agenda: conduit, TVs. word word"))
    #expect(lines[5].hasSuffix("…"))
    #expect(lines[5].count <= "Invite: ".count + MeetingPrep.inviteLimit + 1)
    #expect(lines.count == 6)
}
