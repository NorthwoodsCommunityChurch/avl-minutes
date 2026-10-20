import Foundation

/// Picks the feed records Hermes should hear about on its own (the proactive loop) and turns them into
/// the lines the Teams relay forwards. Pure logic; the helper does the HTTP call.
///
/// Rules (spec 2026-10-08-hermes-proactive-loop-design.md): calendar records that were updated or deleted,
/// calendar records added for the next 48 hours, mail Aaron sent, and Teams messages Aaron sent to anyone but Hermes
/// (2026-10-20, Aaron: "I want her looking at sent messages just like mail"), and mail and Teams messages people send
/// him, minus automated senders (2026-10-20, Aaron: she should see "jason asked you to do this" and offer a card). Only files newer than an hour, so a
/// backfill, a first pass, or a restart never floods Hermes; a file that repeats what is already indexed word for word
/// is not news; a recurring series collapses to one line; at most 12 lines per batch.
public enum FeedNotifier {
    /// OneDrive sync plus a pass can take a while; anything older than this is history, not news.
    public static let freshness: TimeInterval = 60 * 60
    public static let upcomingWindow: TimeInterval = 48 * 3600
    public static let maxLines = 12
    /// The sender name Aaron's own Teams messages carry in the feed.
    public static let aaronName = "Aaron Larson"
    /// Hermes's Teams bot; a 1:1 chat id names both members, so his chat with her contains this id. Those messages
    /// already reach her through the relay.
    public static let hermesBotId = "685fac05-84be-4bb9-aa30-4a2a430d22b1"
    /// A message's text is cut to this in the line Hermes gets; she can get_note the rest.
    static let teamsTextLimit = 600
    /// Mail from these never wakes her: alerts and notifications ask nothing of Aaron, and they arrive in bursts.
    static let automatedSenders = ["noreply", "no-reply", "donotreply", "do-not-reply", "notifications@", "notification@",
                                   "mailer-daemon", "postmaster@"]

    public static func select(_ records: [FeedIndexer.IndexedRecord], now: Date = Date()) -> [FeedIndexer.IndexedRecord] {
        records.filter { r in
            guard now.timeIntervalSince(r.modifiedAt) <= freshness, !r.unchanged else { return false }
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
                guard now.timeIntervalSince(r.createdAt) <= freshness else { return false }
                if r.body.hasPrefix("Sent by Aaron to:") { return true }
                guard let from = header("From", in: r.body)?.lowercased() else { return false }
                return !automatedSenders.contains { from.contains($0) }
            case "teams":
                guard now.timeIntervalSince(r.createdAt) <= freshness, let chat = teamsChat(r.body), !chat.contains(hermesBotId) else { return false }
                return r.body.hasPrefix("From: ")
            default:
                return false
            }
        }
    }

    /// One line per record, except that calendar records sharing a title and action (a recurring series) become one
    /// line naming the count and the next occurrence, and a sent Teams message names who the chat is with
    /// (`chatPeople`, from the index). Capped at `maxLines`.
    public static func lines(for records: [FeedIndexer.IndexedRecord], now: Date = Date(),
                             chatPeople: (String) -> [String] = { _ in [] }) -> [String] {
        var out: [String] = []
        var seriesSeen: [String: Int] = [:]
        var groups: [String: [FeedIndexer.IndexedRecord]] = [:]
        for r in records where r.folder == "calendar" {
            groups["\(seriesTitle(r.title))|\(calendarAction(r.body))", default: []].append(r)
        }
        for r in records {
            if r.folder == "calendar" {
                let key = "\(seriesTitle(r.title))|\(calendarAction(r.body))"
                let group = groups[key] ?? [r]
                if group.count > 1 {
                    if seriesSeen[key] != nil { continue }
                    seriesSeen[key] = group.count
                    let next = group.compactMap { firstDate(in: $0.body) }.filter { $0 >= now }.min()
                    let when = next.map { " next is \(Self.display($0))" } ?? ""
                    out.append("\(seriesTitle(r.title)): \(group.count) occurrences \(calendarAction(r.body)),\(when)")
                    continue
                }
            }
            if r.folder == "teams" {
                out.append(teamsLine(r.body, people: teamsChat(r.body).map(chatPeople) ?? []))
            } else if r.folder == "mail", !r.body.hasPrefix("Sent by Aaron to:") {
                out.append(incomingMailLine(r.body))
            } else {
                out.append(r.body.split(separator: "\n").prefix(6).joined(separator: "\n"))
            }
            if out.count == maxLines { break }
        }
        return Array(out.prefix(maxLines))
    }

    /// The "Chat: <id>" line of a Teams record.
    static func teamsChat(_ body: String) -> String? {
        body.split(separator: "\n").first(where: { $0.hasPrefix("Chat: ") }).map { String($0.dropFirst("Chat: ".count)) }
    }

    /// A Teams message, Aaron's or someone else's: who and with whom, the time, then the text (cut to `teamsTextLimit`).
    /// `people` is everyone but Aaron who writes in that chat.
    static func teamsLine(_ body: String, people: [String]) -> String {
        let sender = header("From", in: body) ?? ""
        let sent = header("Sent", in: body).map { "Sent: \($0)" } ?? ""
        let headline: String
        if sender == aaronName {
            headline = "Teams message sent by Aaron" + (people.isEmpty ? " (no one else has written in this chat yet)" : " in a chat with \(people.joined(separator: ", "))")
        } else {
            let others = people.filter { $0 != sender }
            headline = "Teams message to Aaron from \(sender)" + (others.isEmpty ? " (1:1 chat)" : " in a chat with \(others.joined(separator: ", "))")
        }
        return [headline, sent, "", messageText(body)].joined(separator: "\n")
    }

    /// "Email to Aaron from …", To, Received, Subject, then the text (cut to `teamsTextLimit`).
    static func incomingMailLine(_ body: String) -> String {
        let headline = "Email to Aaron from \(header("From", in: body) ?? "?")"
        let fields = ["To", "Received", "Subject"].compactMap { key in header(key, in: body).map { "\(key): \($0)" } }
        return ([headline] + fields + ["", messageText(body)]).joined(separator: "\n")
    }

    /// The value of a "Key: value" line in a record's header block.
    static func header(_ key: String, in body: String) -> String? {
        let head = body.components(separatedBy: "\n\n").first ?? ""
        return head.split(separator: "\n").first(where: { $0.hasPrefix("\(key): ") }).map { String($0.dropFirst(key.count + 2)) }
    }

    /// The text after a record's header block, cut to `teamsTextLimit`.
    static func messageText(_ body: String) -> String {
        var text = body.components(separatedBy: "\n\n").dropFirst().joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if text.count > teamsTextLimit { text = String(text.prefix(teamsTextLimit - 1)) + "…" }
        return text
    }

    /// A calendar title without the " — <local date>" FeedRecord adds, so a series' occurrences share it.
    static func seriesTitle(_ title: String) -> String {
        guard let dash = title.range(of: " — ", options: .backwards) else { return title }
        return String(title[..<dash.lowerBound])
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
