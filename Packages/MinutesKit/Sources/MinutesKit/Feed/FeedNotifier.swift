import Foundation

/// Picks the feed records Hermes should hear about on its own (the proactive loop) and turns them into
/// the lines the Teams relay forwards. Pure logic; the helper does the HTTP call.
///
/// Rules (spec 2026-10-08-hermes-proactive-loop-design.md): calendar records that were updated or deleted,
/// calendar records added for the next 48 hours, and mail Aaron sent. Only files newer than an hour, so a
/// backfill, a first pass, or a restart never floods Hermes; a recurring series collapses to one line; at most
/// 12 lines per batch.
public enum FeedNotifier {
    /// OneDrive sync plus a pass can take a while; anything older than this is history, not news.
    public static let freshness: TimeInterval = 60 * 60
    public static let upcomingWindow: TimeInterval = 48 * 3600
    public static let maxLines = 12

    public static func select(_ records: [FeedIndexer.IndexedRecord], now: Date = Date()) -> [FeedIndexer.IndexedRecord] {
        records.filter { r in
            guard now.timeIntervalSince(r.modifiedAt) <= freshness else { return false }
            // Backfills write old items into brand-new files; they are history, never news.
            if r.path.split(separator: "/").last?.hasPrefix("backfill-") == true { return false }
            switch r.folder {
            case "calendar":
                let action = calendarAction(r.body)
                if action == "updated" || action == "deleted" { return true }
                if action == "added", let start = firstDate(in: r.body) {
                    return start >= now.addingTimeInterval(-3600) && start <= now.addingTimeInterval(upcomingWindow)
                }
                return false
            case "mail":
                return r.body.hasPrefix("Sent by Aaron to:") && now.timeIntervalSince(r.createdAt) <= freshness
            default:
                return false
            }
        }
    }

    /// One line per record, except that calendar records sharing a title and action (a recurring series) become one
    /// line naming the count and the next occurrence. Capped at `maxLines`.
    public static func lines(for records: [FeedIndexer.IndexedRecord], now: Date = Date()) -> [String] {
        var out: [String] = []
        var seriesSeen: [String: Int] = [:]
        var groups: [String: [FeedIndexer.IndexedRecord]] = [:]
        for r in records where r.folder == "calendar" {
            groups["\(r.title)|\(calendarAction(r.body))", default: []].append(r)
        }
        for r in records {
            if r.folder == "calendar" {
                let key = "\(r.title)|\(calendarAction(r.body))"
                let group = groups[key] ?? [r]
                if group.count > 1 {
                    if seriesSeen[key] != nil { continue }
                    seriesSeen[key] = group.count
                    let next = group.compactMap { firstDate(in: $0.body) }.filter { $0 >= now }.min()
                    let when = next.map { " next is \(Self.display($0))" } ?? ""
                    out.append("\(r.title): \(group.count) occurrences \(calendarAction(r.body)),\(when)")
                    continue
                }
            }
            out.append(r.body.split(separator: "\n").prefix(6).joined(separator: "\n"))
            if out.count == maxLines { break }
        }
        return Array(out.prefix(maxLines))
    }

    static func calendarAction(_ body: String) -> String {
        guard let first = body.split(separator: "\n").first, first.hasPrefix("Calendar event, ") else { return "" }
        return String(first.dropFirst("Calendar event, ".count)).trimmingCharacters(in: .whitespaces)
    }

    /// The first ISO-looking date on the "When:" line.
    static func firstDate(in body: String) -> Date? {
        guard let line = body.split(separator: "\n").first(where: { $0.hasPrefix("When: ") }) else { return nil }
        let text = String(line.dropFirst("When: ".count))
        let token = text.split(separator: " ").first.map(String.init) ?? ""
        return FeedRecord.date(token)
    }

    private static func display(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MMM d h:mm a"
        return f.string(from: date)
    }
}
