import Foundation
import Testing
@testable import MinutesKit

private func meta(_ id: String, folder: String = "Notes", title: String = "T", modified: TimeInterval = 100, locked: Bool = false) -> NoteMetadata {
    NoteMetadata(id: id, title: title, folder: folder, account: "iCloud",
                 createdAt: Date(timeIntervalSince1970: 1), modifiedAt: Date(timeIntervalSince1970: modified), isLocked: locked)
}

private func stamp(_ m: NoteMetadata) -> IndexedStamp {
    IndexedStamp(title: m.title, folder: m.folder, account: m.account, modifiedMs: milliseconds(m.modifiedAt))
}

@Test func planFetchesNewAndChangedRetagsMovedDeletesGone() {
    let unchanged = meta("a")
    let changed = meta("b", modified: 200)
    let moved = meta("c", folder: "Work")
    let new = meta("d")
    let locked = meta("e", locked: true)
    let trashed = meta("f", folder: "Recently Deleted")
    let indexed: [String: IndexedStamp] = [
        "a": stamp(unchanged),
        "b": stamp(meta("b", modified: 100)),
        "c": stamp(meta("c", folder: "Notes")),
        "e": stamp(meta("e")),          // became locked
        "f": stamp(meta("f")),          // moved to trash
        "g": stamp(meta("g")),          // deleted
    ]
    let plan = IndexPlanner.plan(current: [unchanged, changed, moved, new, locked, trashed], indexed: indexed)
    #expect(plan.fetch.map(\.id).sorted() == ["b", "d"])
    #expect(plan.retag.map(\.id) == ["c"])
    #expect(plan.delete.sorted() == ["e", "f", "g"])
}
