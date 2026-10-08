import Foundation
import MinutesKit
import Observation
import OSLog

/// Keeps the local Notes index current: every 2 minutes, and on request.
@MainActor @Observable
final class NotesIndexer {
    private(set) var lastRefresh: Date?
    private(set) var noteCount = 0
    private(set) var isRefreshing = false
    private(set) var lastError: String?
    /// Notes Automation permission is off; meetings can't save until it's on.
    private(set) var permissionDenied = false

    private let bridge: NotesBridge
    private let index: NotesIndex
    private var timer: Timer?
    private static let logger = Logger(subsystem: AppIdentity.bundleID, category: "NotesIndexer")
    private static let fetchBatch = 25

    init(index: NotesIndex, bridge: NotesBridge) {
        self.index = index
        self.bridge = bridge
        lastRefresh = try? index.lastRefresh()
        noteCount = (try? index.count()) ?? 0
    }

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refreshNow() }
        }
        Task { await refreshNow() }
    }

    func refreshNow() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let current = try await bridge.listMetadata()
            let index = self.index
            // Feed records (AI Feed files) are the FeedIndexer's; leave them out of this plan or they'd be deleted.
            let plan = try await Task.detached { IndexPlanner.plan(current: current, indexed: FeedRecord.notesOnly(try index.stamps())) }.value
            try await Task.detached {
                try index.transaction {
                    for note in plan.retag { try index.retag(note) }
                    try index.delete(ids: plan.delete)
                }
            }.value
            var start = 0
            while start < plan.fetch.count {
                let chunk = Array(plan.fetch[start..<min(start + Self.fetchBatch, plan.fetch.count)])
                start += Self.fetchBatch
                let texts = try await bridge.plaintext(ids: chunk.map(\.id))
                try await Task.detached {
                    try index.transaction {
                        for note in chunk {
                            if let body = texts[note.id] { try index.upsert(note, body: body) }
                        }
                    }
                }.value
            }
            let finished = Date()
            try await Task.detached { try index.setLastRefresh(finished) }.value
            lastRefresh = finished
            noteCount = (try? index.count()) ?? noteCount
            lastError = nil
            permissionDenied = false
            Self.logger.info("Index refreshed: \(plan.fetch.count) fetched, \(plan.retag.count) retagged, \(plan.delete.count) removed")
        } catch {
            Self.logger.error("Index refresh failed")
            lastError = error.localizedDescription
            permissionDenied = (error as? NotesBridgeError) == .permissionDenied
        }
    }
}
