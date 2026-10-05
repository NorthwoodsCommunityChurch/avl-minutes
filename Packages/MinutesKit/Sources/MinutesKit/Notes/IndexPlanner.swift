/// Decides what an index refresh must do, from Notes' listing and the index's memory.
public struct IndexPlan: Sendable, Equatable {
    public var fetch: [NoteMetadata] = []   // new or edited: read body
    public var retag: [NoteMetadata] = []   // same body, new title/folder/account
    public var delete: [String] = []        // gone, locked, or in Recently Deleted
}

public enum IndexPlanner {
    public static let excludedFolders: Set<String> = ["Recently Deleted"]

    public static func plan(current: [NoteMetadata], indexed: [String: IndexedStamp]) -> IndexPlan {
        var plan = IndexPlan()
        var keep = Set<String>()
        for note in current where !note.isLocked && !excludedFolders.contains(note.folder) {
            keep.insert(note.id)
            guard let stamp = indexed[note.id], stamp.modifiedMs == milliseconds(note.modifiedAt) else {
                plan.fetch.append(note)
                continue
            }
            if stamp.title != note.title || stamp.folder != note.folder || stamp.account != note.account {
                plan.retag.append(note)
            }
        }
        plan.delete = indexed.keys.filter { !keep.contains($0) }
        return plan
    }
}
