import Foundation

/// Picks the calendar records whose meeting starts soon and words the wake-up the relay hands Hermes
/// (spec 2026-10-09-hermes-initiative-design.md, "Clock"). Pure: `IndexService` reads the index, posts, and marks.
public enum MeetingPrep {
    /// How far ahead a meeting is announced. A helper that was down still briefs a meeting ten minutes out.
    public static let window: TimeInterval = 35 * 60
    /// Back-to-back meetings share one notify.
    public static let maxPerNotify = 3
    /// A span this long is an all-day entry, not a meeting.
    public static let allDay: TimeInterval = 23 * 3600
    public static let inviteLimit = 400
    static let markerPrefix = "meeting_announced:"

    public struct Pick: Sendable, Equatable {
        public let note: NotesIndex.UpcomingNote
        /// Index meta key recording that this meeting was announced: one per Outlook event id, else per file.
        public let key: String
        /// The start, as the marker's value. A moved meeting has a new value and is announced again.
        public let startToken: String
    }

    /// `isAnnounced(key, startToken)` answers whether this start was already sent. Soonest first, at most `maxPerNotify`.
    public static func select(_ notes: [NotesIndex.UpcomingNote], now: Date, isAnnounced: (String, String) -> Bool) -> [Pick] {
        var picks: [Pick] = []
        let formatter = ISO8601DateFormatter()
        for note in notes.sorted(by: { $0.start == $1.start ? $0.id < $1.id : $0.start < $1.start }) {
            guard note.start > now, note.start <= now.addingTimeInterval(window) else { continue }
            let action = FeedNotifier.calendarAction(note.body)
            if action == "deleted" || action == "cancelled" { continue }
            if attendees(note.body).isEmpty { continue }   // a personal block gets no brief
            if let end = FeedRecord.date(value(note.body, "End (UTC): ")), end.timeIntervalSince(note.start) >= allDay { continue }
            let key = markerPrefix + (note.groupKey ?? note.id)
            let token = formatter.string(from: note.start)
            if isAnnounced(key, token) { continue }
            picks.append(Pick(note: note, key: key, startToken: token))
            if picks.count == maxPerNotify { break }
        }
        return picks
    }

    /// The wake-up text: the invite's facts plus how soon it starts (Hermes has no clock of her own).
    public static func record(for pick: Pick, now: Date) -> String {
        let body = pick.note.body
        let minutes = Int((pick.note.start.timeIntervalSince(now) / 60).rounded())
        return [
            "Meeting prep: \(FeedNotifier.seriesTitle(pick.note.title))",
            "Starts: \(value(body, "When: ")) (in \(minutes) minutes)",
            "Where: \(value(body, "Where: "))",
            "Organizer: \(value(body, "Organizer: "))",
            "Attendees: \(attendees(body))",
            "Invite: \(invite(body))",
        ].joined(separator: "\n")
    }

    /// The text after `prefix` on the header line that starts with it; "" when there is none.
    static func value(_ body: String, _ prefix: String) -> String {
        guard let line = body.split(separator: "\n", omittingEmptySubsequences: false).first(where: { $0.hasPrefix(prefix) }) else { return "" }
        return String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
    }

    /// The attendee list without the separator Outlook leaves at the end; empty for a personal block.
    static func attendees(_ body: String) -> String {
        value(body, "Attendees: ").trimmingCharacters(in: CharacterSet(charactersIn: "; ").union(.whitespaces))
    }

    /// The invite's own text (after the header lines), whitespace collapsed, cut to `inviteLimit`.
    static func invite(_ body: String) -> String {
        guard let blank = body.range(of: "\n\n") else { return "" }
        let text = body[blank.upperBound...].replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        return text.count > inviteLimit ? String(text.prefix(inviteLimit)) + "…" : text
    }
}
