import Foundation

/// One file from the OneDrive "AI Feed" folder (written by Aaron's Power Automate flows: `mail/`,
/// `calendar/`, `teams/` JSON files) rendered as a note-like record for the shared index. Feed records
/// live in the same table as notes under account "AI Feed", with ids prefixed `feed:`, so the search
/// tools need no new code; `notesOnly`/`feedOnly` keep the two refreshers from deleting each other's rows.
public enum FeedRecord {
    public static let idPrefix = "feed:"
    public static let account = "AI Feed"
    /// Teams messages from these senders are not indexed (Hermes's own replies would loop back in).
    public static let skippedSenders: Set<String> = ["hermes"]
    private static let titleLimit = 80

    public struct Parsed: Sendable, Equatable {
        public let metadata: NoteMetadata
        public let body: String
        /// Records describing the same item (Outlook writes several files per calendar event); the newest wins.
        public let groupKey: String?
    }

    /// `relativePath` is the file's path inside the feed folder, e.g. `mail/20261008-161658-6678.json`.
    /// `fileModifiedAt` becomes `modifiedAt` (what the index uses to notice changes); the item's own time
    /// (received / start / created) becomes `createdAt`.
    /// Bump when the text a record produces changes shape; the indexer then re-reads every feed file.
    public static let formatVersion = 2

    public static func parse(_ data: Data, relativePath: String, fileModifiedAt: Date, timeZone: TimeZone = .current) -> Parsed? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = string(object["type"]) else { return nil }
        let folder = relativePath.split(separator: "/").first.map(String.init) ?? type
        let field = { (key: String) -> String in string(object[key]) ?? "" }
        let text = field("body")
        var title: String
        var lines: [String]
        var when: Date?
        var groupKey: String?
        switch type {
        case "mail":
            title = field("subject")
            when = date(field("received"))
            if title.isEmpty { title = "(no subject)" }
            if field("direction") == "sent" {
                // Aaron's own outgoing mail (the Sent Items flow): titled by recipient so "did I email X" is findable.
                title = "To \(field("to")): \(title)"
                lines = ["Sent by Aaron to: \(field("to"))", "Sent: \(field("received"))", "Subject: \(field("subject"))"]
            } else {
                lines = ["From: \(field("from"))", "To: \(field("to"))", "Received: \(field("received"))", "Subject: \(field("subject"))"]
            }
        case "calendar":
            title = field("subject")
            if title.isEmpty { title = "(untitled event)" }
            when = date(field("start"))
            let action = field("action").lowercased().isEmpty ? "changed" : field("action").lowercased()
            // Outlook writes UTC; the record speaks Aaron's local time so the title alone answers "when".
            if let start = when {
                let end = date(field("end"))
                title = "\(title) — \(local(start, timeZone: timeZone))"
                lines = ["Calendar event, \(action)", "When: \(span(start, end, timeZone: timeZone))",
                         "Start (UTC): \(field("start"))", "End (UTC): \(field("end"))"]
            } else {
                lines = ["Calendar event, \(action)", "When: \(field("start")) to \(field("end"))"]
            }
            lines += ["Where: \(field("location"))", "Organizer: \(field("organizer"))", "Attendees: \(field("attendees"))"]
            if !field("id").isEmpty { groupKey = "calendar:\(field("id"))" }
        case "teams":
            let from = field("from")
            // No sender = a bot or system message (Hermes's own replies arrive without a user name).
            if from.isEmpty || skippedSenders.contains(from.lowercased()) { return nil }
            when = date(field("created"))
            let preview = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
            title = "\(from): \(String(preview.prefix(titleLimit)))"
            lines = ["From: \(from)", "Sent: \(field("created"))", "Chat: \(field("chat"))"]
            // A backfill can write the same message again; the newest file for a message id wins.
            if !field("id").isEmpty { groupKey = "teams:\(field("id"))" }
        default:
            return nil
        }
        let metadata = NoteMetadata(id: idPrefix + relativePath, title: title, folder: folder, account: account,
                                    createdAt: when ?? fileModifiedAt, modifiedAt: fileModifiedAt, isLocked: false)
        return Parsed(metadata: metadata, body: (lines + ["", text]).joined(separator: "\n"), groupKey: groupKey)
    }

    public static func notesOnly(_ stamps: [String: IndexedStamp]) -> [String: IndexedStamp] {
        stamps.filter { !$0.key.hasPrefix(idPrefix) }
    }

    public static func feedOnly(_ stamps: [String: IndexedStamp]) -> [String: IndexedStamp] {
        stamps.filter { $0.key.hasPrefix(idPrefix) }
    }

    private static func string(_ value: Any?) -> String? {
        if let s = value as? String { return s }
        if let n = value as? NSNumber { return n.stringValue }
        return nil
    }

    /// Outlook writes `2026-10-09T14:00:00.0000000` (UTC, no offset) and `2026-10-08T16:16:42+00:00`.
    /// "Fri Oct 9, 2026 9:00 AM" in the given zone.
    static func local(_ date: Date, timeZone: TimeZone) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "EEE MMM d, yyyy h:mm a"
        return f.string(from: date)
    }

    /// "Fri Oct 9, 2026 9:00 AM to 10:00 AM CDT" (the end keeps only its time when it is the same day).
    static func span(_ start: Date, _ end: Date?, timeZone: TimeZone) -> String {
        let zone = timeZone.abbreviation(for: start) ?? timeZone.identifier
        guard let end else { return "\(local(start, timeZone: timeZone)) \(zone)" }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let endText: String
        if calendar.isDate(start, inSameDayAs: end) {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = timeZone
            f.dateFormat = "h:mm a"
            endText = f.string(from: end)
        } else {
            endText = local(end, timeZone: timeZone)
        }
        return "\(local(start, timeZone: timeZone)) to \(endText) \(zone)"
    }

    static func date(_ text: String) -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        // Trim 7-digit fractions to 3 and add a UTC marker when there is no offset.
        var candidate = trimmed.replacingOccurrences(of: "(\\.\\d{3})\\d+", with: "$1", options: .regularExpression)
        if candidate.range(of: "(Z|[+-]\\d{2}:?\\d{2})$", options: .regularExpression) == nil { candidate += "Z" }
        return withFraction.date(from: candidate) ?? plain.date(from: candidate)
    }
}
