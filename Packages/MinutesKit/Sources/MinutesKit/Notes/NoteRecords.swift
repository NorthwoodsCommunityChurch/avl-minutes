import Foundation

/// A note as listed by Apple Notes (no body).
public struct NoteMetadata: Sendable, Equatable, Codable {
    public let id: String
    public let title: String
    public let folder: String
    public let account: String
    public let createdAt: Date
    public let modifiedAt: Date
    public let isLocked: Bool

    public init(id: String, title: String, folder: String, account: String, createdAt: Date, modifiedAt: Date, isLocked: Bool) {
        self.id = id
        self.title = title
        self.folder = folder
        self.account = account
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.isLocked = isLocked
    }
}

/// What the index remembers about a note, to decide whether to re-fetch it.
public struct IndexedStamp: Sendable, Equatable {
    public let title: String
    public let folder: String
    public let account: String
    public let modifiedMs: Int64
}

public struct IndexedNote: Sendable, Equatable {
    public let id: String
    public let title: String
    public let folder: String
    public let account: String
    public let createdAt: Date
    public let modifiedAt: Date
    public let body: String
}

public struct NoteSummary: Sendable, Equatable {
    public let id: String
    public let title: String
    public let folder: String
    public let createdAt: Date
    public let modifiedAt: Date
    public let length: Int
}

public struct NoteSearchHit: Sendable, Equatable {
    public let id: String
    public let title: String
    public let folder: String
    public let modifiedAt: Date
    /// ~30 words around the match; matched terms wrapped in [brackets].
    public let snippet: String
}

public struct FolderCount: Sendable, Equatable {
    public let name: String
    public let count: Int

    public init(name: String, count: Int) {
        self.name = name
        self.count = count
    }
}
