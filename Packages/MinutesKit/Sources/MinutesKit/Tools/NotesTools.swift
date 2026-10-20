import Foundation

public enum ToolError: Error, Equatable, CustomStringConvertible {
    case notFound(String)
    case invalidArgument(String)

    public var description: String {
        switch self {
        case .notFound(let m), .invalidArgument(let m): m
        }
    }
}

/// Formats index contents as plain text for Claude.
public struct NotesTools: Sendable {
    public static let transcriptFolderHint = """
    Notes in the "Meeting Transcripts" folder are automatic speech-recognition transcripts \
    made by Minutes: expect misheard words, and treat speaker labels as approximate. \
    "Me" is Aaron; "Speaker n" are people in the room; "Caller n" are people on a call. \
    If folders "mail", "calendar", or "teams" exist (account "AI Feed"), they hold copies of Aaron's \
    email, calendar events, and Teams chat messages, each dated by its own sent or start time; "teams" includes \
    his own messages to Hermes, titled "Aaron Larson: …". All other folders are Aaron's own notes. \
    When he asks for "my notes" on something, search everything (no folder): his notes, transcripts, and what he said in Teams.
    """

    /// Words that mean "Aaron's own notes and transcripts" rather than any one folder.
    static let ownNotesNames: Set<String> = ["notes", "note", "my notes", "own", "own notes", "apple notes", "notes app",
                                             "notes and transcripts"]

    public let index: NotesIndex
    public let timeZone: TimeZone
    public let now: @Sendable () -> Date
    public let pageSize: Int

    public init(index: NotesIndex, timeZone: TimeZone = .current, now: @escaping @Sendable () -> Date = { Date() }, pageSize: Int = 40_000) {
        self.index = index
        self.timeZone = timeZone
        self.now = now
        self.pageSize = pageSize
    }

    public func searchNotes(query: String, folder: String?, since: Date?, until: Date?, limit: Int?) throws -> String {
        let scope = try scope(for: folder)
        let wanted = clamp(limit)
        // A recurring meeting is one item, not one hit per occurrence: 52 "Scrum — <date>" invites through Feb 2027
        // took 12 of Hermes's top 20 for "Scrum" and pushed out Jason's "we will skip scrum on Tuesday" (2026-10-13).
        let items = try collapsedSearch(wanted) {
            try index.search(query, scope: scope, since: since, until: until, limit: $0)
        }
        var out = [try freshness(), ""]
        guard !items.isEmpty else {
            out.append("No notes match \"\(query)\".")
            return out.joined(separator: "\n")
        }
        let total = try index.searchCount(query, scope: scope, since: since, until: until)
        let shownRecords = items.reduce(0) { $0 + $1.occurrences.count }
        // A silently cut list reads as the whole story: Hermes took the top 20 of 134 "atrium" hits, a June
        // chat first, as all there was (2026-10-09). Say what was left out, and since relevance ranking buries
        // the recent items her rules care about, show the newest matches too: newest that already happened, since
        // a future invite is not news (the "newest" Scrum matches were Feb 2027 occurrences).
        var newest: [SearchItem] = []
        if total > shownRecords {
            let shownIds = Set(items.flatMap { $0.occurrences.map(\.id) })
            let shownSeries = Set(items.compactMap(\.seriesTitle))
            let latest = min(until ?? now(), now())
            newest = try collapsedSearch(Self.newestShown, keep: { item in
                !item.occurrences.contains { shownIds.contains($0.id) } && !(item.seriesTitle.map(shownSeries.contains) ?? false)
            }) {
                try index.search(query, scope: scope, since: since, until: latest, limit: $0, newestFirst: true)
            }
        }
        if total > shownRecords {
            out.append("\(shownRecords) of \(total) notes match \"\(query)\" (most relevant first; the rest are not shown — narrow with since, until, or folder, or raise limit up to 50):")
        } else {
            out.append("\(shownRecords) \(shownRecords == 1 ? "note matches" : "notes match") \"\(query)\":")
        }
        for (i, item) in items.enumerated() { out += lines(i + 1, item) }
        if !newest.isEmpty {
            out.append("")
            out.append("Newest matches, not in the list above:")
            for (i, item) in newest.enumerated() { out += lines(items.count + i + 1, item) }
        }
        return out.joined(separator: "\n")
    }

    /// How many of the newest matches a cut search result adds.
    static let newestShown = 5
    /// Raw hits first fetched per item wanted, and the most ever fetched for one list.
    static let overFetch = 5
    static let maxFetch = 2_000

    /// Up to `wanted` items from `fetch(limit)`, series collapsed, fetching more raw hits while collapsed series
    /// (or `keep` dropping items) leave the list short and the index still has more.
    private func collapsedSearch(_ wanted: Int, keep: (SearchItem) -> Bool = { _ in true },
                                 _ fetch: (Int) throws -> [NoteSearchHit]) throws -> [SearchItem] {
        var limit = wanted * Self.overFetch
        while true {
            let hits = try fetch(limit)
            let items = collapseSeries(hits).filter(keep)
            if items.count >= wanted || hits.count < limit || limit >= Self.maxFetch { return Array(items.prefix(wanted)) }
            limit = min(limit * 4, Self.maxFetch)
        }
    }

    /// One line of search output: a single record, or every matched occurrence of one recurring calendar series.
    struct SearchItem {
        var occurrences: [NoteSearchHit]
        /// Set for calendar feed records (the title without its " — <date>" suffix).
        let seriesTitle: String?
    }

    /// Groups calendar occurrences of one series under the place its best-ranked occurrence held; order is kept.
    func collapseSeries(_ hits: [NoteSearchHit]) -> [SearchItem] {
        var items: [SearchItem] = []
        var seriesAt: [String: Int] = [:]
        for hit in hits {
            guard hit.account == FeedRecord.account, hit.folder == "calendar" else {
                items.append(SearchItem(occurrences: [hit], seriesTitle: nil))
                continue
            }
            let series = FeedNotifier.seriesTitle(hit.title)
            if let at = seriesAt[series] {
                items[at].occurrences.append(hit)
            } else {
                seriesAt[series] = items.count
                items.append(SearchItem(occurrences: [hit], seriesTitle: series))
            }
        }
        return items
    }

    private func lines(_ number: Int, _ item: SearchItem) -> [String] {
        guard let series = item.seriesTitle, item.occurrences.count > 1 else {
            let hit = item.occurrences[0]
            return ["",
                    "\(number). \"\(hit.title)\" — \(hit.folder) — \(dateLabel(folder: hit.folder, account: hit.account)) \(format(hit.datedAt))",
                    "   id: \(hit.id)",
                    "   \(hit.snippet.replacingOccurrences(of: "\n", with: " "))"]
        }
        // Shown by the occurrence that matters for prep: the next one, else the latest that happened.
        let byStart = item.occurrences.sorted { $0.datedAt < $1.datedAt }
        let current = now()
        let next = byStart.first { $0.datedAt >= current }
        let last = byStart.last { $0.datedAt < current }
        let shown = next ?? last ?? byStart[0]
        var when: [String] = []
        if let next { when.append("next starts \(format(next.datedAt))") }
        if let last { when.append("last started \(format(last.datedAt))") }
        return ["",
                "\(number). \"\(series)\" — calendar — recurring, \(item.occurrences.count) occurrences match; \(when.joined(separator: ", "))",
                "   id: \(shown.id)",
                "   \(shown.snippet.replacingOccurrences(of: "\n", with: " "))"]
    }

    public func listNotes(folder: String?, since: Date?, until: Date?, limit: Int?) throws -> String {
        let notes = try index.list(scope: try scope(for: folder), since: since, until: until, limit: clamp(limit))
        var out = [try freshness(), ""]
        guard !notes.isEmpty else {
            out.append("No notes found.")
            return out.joined(separator: "\n")
        }
        out.append("\(notes.count) \(notes.count == 1 ? "note" : "notes"), newest first:")
        for (i, n) in notes.enumerated() {
            out.append("")
            let when = n.account == FeedRecord.account
                ? "\(dateLabel(folder: n.folder, account: n.account)) \(format(n.datedAt))"
                : "modified \(format(n.modifiedAt)) · created \(format(n.createdAt))"
            out.append("\(i + 1). \"\(n.title)\" — \(n.folder) — \(when) · \(n.length) characters")
            out.append("   id: \(n.id)")
        }
        return out.joined(separator: "\n")
    }

    /// Folder names are matched loosely: case does not matter, "notes" means all of Aaron's own notes, and
    /// common aliases land on the folder they mean. An unknown name is an error that lists the real folders,
    /// because a silent "No notes match" reads as "Aaron has no such notes" (Hermes passed folder "notes"
    /// for his Atrium notes, 2026-10-09, and told him he had none).
    func scope(for folder: String?) throws -> NoteScope {
        guard let raw = folder?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return .all }
        let key = raw.lowercased()
        if key == "all" || key == "everything" { return .all }
        if Self.ownNotesNames.contains(key) { return .ownNotes }
        let names = try index.folders().map(\.name)
        if let name = names.first(where: { $0.lowercased() == key }) { return .folder(name) }
        let alias: String? = if key.contains("transcript") || key == "meetings" { "meeting transcripts" }
            else if key.contains("mail") || key.contains("inbox") { "mail" }
            else if key.contains("chat") || key.contains("message") || key.contains("teams") { "teams" }
            else if key.contains("calendar") || key.contains("event") { "calendar" }
            else { nil }
        if let alias, let name = names.first(where: { $0.lowercased() == alias }) { return .folder(name) }
        throw ToolError.invalidArgument(
            "No folder named \"\(raw)\". Folders: \(names.joined(separator: ", ")). " +
            "Omit folder to search everything, or pass \"notes\" for Aaron's own notes and transcripts.")
    }

    /// "modified" for a note; "sent" for mail and Teams; "starts" for a calendar event.
    private func dateLabel(folder: String, account: String) -> String {
        guard account == FeedRecord.account else { return "modified" }
        return folder == "calendar" ? "starts" : "sent"
    }

    public func getNote(id: String, offset: Int?) throws -> String {
        guard let note = try index.note(id: id) else {
            throw ToolError.notFound("No note with id \"\(id)\" in the index.")
        }
        let body = note.body
        let length = body.count
        let start = offset ?? 0
        guard start >= 0, start <= length else {
            throw ToolError.invalidArgument("offset \(start) is past the end of this note (\(length) characters).")
        }
        let lo = body.index(body.startIndex, offsetBy: start)
        let hi = body.index(lo, offsetBy: pageSize, limitedBy: body.endIndex) ?? body.endIndex
        var out = [
            try freshness(),
            "",
            "\"\(note.title)\"",
            "Folder: \(note.folder) · created \(format(note.createdAt)) · modified \(format(note.modifiedAt))",
            "id: \(note.id)",
            "",
            String(body[lo..<hi]),
        ]
        if hi < body.endIndex {
            out.append("")
            out.append("[More text remains — call get_note with offset: \(start + body.distance(from: lo, to: hi))]")
        }
        return out.joined(separator: "\n")
    }

    public func listFolders() throws -> String {
        let folders = try index.folders()
        var out = [try freshness(), ""]
        guard !folders.isEmpty else { return out.joined(separator: "\n") }
        out.append("Folders:")
        for f in folders { out.append("- \(f.name) (\(f.count) \(f.count == 1 ? "note" : "notes"))") }
        return out.joined(separator: "\n")
    }

    func freshness() throws -> String {
        guard let refreshed = try index.lastRefresh() else {
            return "No notes indexed yet — open Minutes once so it can index your notes."
        }
        let age = max(0, now().timeIntervalSince(refreshed))
        let text: String
        switch age {
        case ..<60: text = "just now"
        case ..<3600: text = "\(Int(age / 60)) min ago"
        default:
            let hours = Int(age / 3600)
            text = "\(hours) \(hours == 1 ? "hour" : "hours") ago"
        }
        var line = "Notes index updated \(text)."
        if age > 15 * 60 { line += " It may be out of date — Minutes might not be running." }
        return line
    }

    private func clamp(_ limit: Int?) -> Int { min(max(limit ?? 20, 1), 50) }

    private func format(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "EEE MMM d, yyyy h:mm a"
        return f.string(from: date)
    }
}
