import Foundation

/// Keeps the feed files in the index: new or changed files (by modification date) are read and upserted,
/// files that vanished are deleted, everything else is left alone. Files the parser rejects (unknown type,
/// Hermes's own Teams replies) are remembered by path and date so they are not re-read every pass.
/// Safe to run every couple of minutes.
public final class FeedIndexer: @unchecked Sendable {
    public let folder: URL
    public let index: NotesIndex
    private let lock = NSLock()
    private var skipped: [String: Date] = [:]

    /// One record this pass put into the index: what the notifier looks at.
    public struct IndexedRecord: Sendable, Equatable {
        public let path: String
        public let folder: String
        public let title: String
        public let body: String
        public let groupKey: String?
        public let modifiedAt: Date
        public init(path: String, folder: String, title: String, body: String, groupKey: String?, modifiedAt: Date) {
            self.path = path; self.folder = folder; self.title = title; self.body = body; self.groupKey = groupKey; self.modifiedAt = modifiedAt
        }
    }

    public struct Result: Sendable, Equatable {
        public var indexed: Int
        public var removed: Int
        public var skipped: Int
        public var total: Int
        /// Files that could not be read this pass (still downloading, permission); retried next pass.
        public var unreadable: Int
        /// The records indexed this pass, in processing order (mail and calendar first, then chats, oldest file first).
        public var records: [IndexedRecord] = []
        /// True when the pass stopped at `maxPerPass` with files left; the next pass continues.
        public var capped = false
        public init(indexed: Int, removed: Int, skipped: Int, total: Int, unreadable: Int = 0) {
            self.indexed = indexed
            self.removed = removed
            self.skipped = skipped
            self.total = total
            self.unreadable = unreadable
        }
    }

    /// OneDrive keeps synced files as cloud-only placeholders until something reads them; a background
    /// process gets "Resource deadlock avoided" unless it opts in to downloading them on read.
    public static func allowDownloadingPlaceholders() {
        setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_PROCESS, IOPOL_MATERIALIZE_DATALESS_FILES_ON)
    }

    /// Files read per pass. A backfill drops thousands of chat files at once and each OneDrive placeholder takes a
    /// moment to download, so a pass is capped and mail and calendar always go first: new mail never waits behind
    /// old chat history. The caller runs another pass right away while `Result.capped` is true.
    public let maxPerPass: Int

    public init(folder: URL, index: NotesIndex, maxPerPass: Int = 250) {
        self.folder = folder
        self.index = index
        self.maxPerPass = max(1, maxPerPass)
    }

    private static func priority(_ id: String) -> Int {
        let path = id.dropFirst(FeedRecord.idPrefix.count)
        if path.hasPrefix("calendar/") { return 0 }
        if path.hasPrefix("mail/") { return 1 }
        return 2
    }

    /// The first `~/Library/CloudStorage/OneDrive-*/AI Feed` that exists, if any.
    public static func defaultFolder(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL? {
        let cloud = home.appendingPathComponent("Library/CloudStorage", isDirectory: true)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: cloud.path)) ?? []
        for name in names.sorted() where name.hasPrefix("OneDrive") {
            let candidate = cloud.appendingPathComponent(name, isDirectory: true).appendingPathComponent("AI Feed", isDirectory: true)
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDir), isDir.boolValue { return candidate }
        }
        return nil
    }

    public func refresh() throws -> Result {
        let files = try listing()
        let stamps = FeedRecord.feedOnly(try index.stamps())
        let current = files.map { file in
            NoteMetadata(id: FeedRecord.idPrefix + file.path, title: stamps[FeedRecord.idPrefix + file.path]?.title ?? "",
                         folder: file.path.split(separator: "/").first.map(String.init) ?? "", account: FeedRecord.account,
                         createdAt: file.modifiedAt, modifiedAt: file.modifiedAt, isLocked: false)
        }
        let plan = IndexPlanner.plan(current: current, indexed: stamps)
        var result = Result(indexed: 0, removed: 0, skipped: 0, total: 0)
        lock.lock()
        defer { lock.unlock() }
        let present = Set(files.map(\.path))
        let dates = Dictionary(files.map { ($0.path, $0.modifiedAt) }, uniquingKeysWith: { a, _ in a })
        skipped = skipped.filter { present.contains($0.key) }
        try index.transaction {
            // Calendar and mail before chats; within a folder oldest file first, so within a group each newer file
            // replaces the one before it.
            let ordered = plan.fetch.sorted { a, b in
                let (pa, pb) = (Self.priority(a.id), Self.priority(b.id))
                if pa != pb { return pa < pb }
                return a.modifiedAt == b.modifiedAt ? a.id < b.id : a.modifiedAt < b.modifiedAt
            }
            var read = 0
            for note in ordered {
                let path = String(note.id.dropFirst(FeedRecord.idPrefix.count))
                if skipped[path] == note.modifiedAt { continue }
                if read == maxPerPass { result.capped = true; break }
                read += 1
                guard let data = try? Data(contentsOf: folder.appendingPathComponent(path)) else {
                    result.unreadable += 1
                    continue
                }
                guard let parsed = FeedRecord.parse(data, relativePath: path, fileModifiedAt: note.modifiedAt) else {
                    skipped[path] = note.modifiedAt
                    result.skipped += 1
                    continue
                }
                if let key = parsed.groupKey, let latest = try index.latestInGroup(key) {
                    let mine = milliseconds(note.modifiedAt)
                    if latest.modifiedMs > mine || (latest.modifiedMs == mine && latest.id > note.id) {
                        skipped[path] = note.modifiedAt   // an older copy of something already indexed
                        result.skipped += 1
                        continue
                    }
                }
                try index.upsert(parsed.metadata, body: parsed.body, groupKey: parsed.groupKey)
                result.records.append(IndexedRecord(path: path, folder: parsed.metadata.folder, title: parsed.metadata.title,
                                                    body: parsed.body, groupKey: parsed.groupKey, modifiedAt: note.modifiedAt))
                if let key = parsed.groupKey {
                    for gone in try index.delete(groupKey: key, except: parsed.metadata.id) {
                        let gonePath = String(gone.dropFirst(FeedRecord.idPrefix.count))
                        if let date = dates[gonePath] { skipped[gonePath] = date }
                    }
                }
                result.indexed += 1
            }
            try index.delete(ids: plan.delete)
            result.removed = plan.delete.count
        }
        result.total = (try? count()) ?? 0
        return result
    }

    public func count() throws -> Int {
        FeedRecord.feedOnly(try index.stamps()).count
    }

    private struct File { let path: String; let modifiedAt: Date }

    public struct ListingError: Error, CustomStringConvertible {
        public let path: String
        public let underlying: Error
        public var description: String { "could not read \(path): \(underlying.localizedDescription)" }
    }

    /// Every `*.json` under the folder, as paths relative to it; hidden files and folders are skipped.
    /// A folder macOS refuses to list (permission) is an error, not an empty feed.
    private func listing() throws -> [File] {
        var out: [File] = []
        _ = try FileManager.default.contentsOfDirectory(atPath: folder.path)   // throws on a permission denial
        var failure: ListingError?
        let keys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey]
        guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles], errorHandler: { url, error in
            if failure == nil { failure = ListingError(path: url.path, underlying: error) }
            return true
        }) else { return out }
        let base = folder.standardizedFileURL.path
        for case let url as URL in enumerator {
            guard url.pathExtension.lowercased() == "json" else { continue }
            let values = try url.resourceValues(forKeys: Set(keys))
            guard values.isRegularFile == true else { continue }
            var path = url.standardizedFileURL.path
            if path.hasPrefix(base) { path = String(path.dropFirst(base.count)) }
            path = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            out.append(File(path: path, modifiedAt: values.contentModificationDate ?? Date()))
        }
        if let failure { throw failure }
        return out.sorted { $0.path < $1.path }
    }
}
