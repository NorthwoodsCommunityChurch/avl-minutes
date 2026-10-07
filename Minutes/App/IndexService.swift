import Foundation
import MinutesKit
import OSLog

/// `Minutes --index`: headless Notes indexing for a machine that only hosts the search
/// service (the assistant mini). No menu bar, no speech models, no login item; a launchd
/// agent keeps it running and `Minutes --mcp` answers searches from the same index.
enum IndexService {
    private static let logger = Logger(subsystem: "com.northwoods.Minutes", category: "IndexService")

    @MainActor
    static func run() -> Never {
        let indexer: NotesIndexer
        do {
            indexer = NotesIndexer(index: try NotesIndex(url: NotesIndex.defaultURL()), bridge: NotesBridge())
        } catch {
            FileHandle.standardError.write(Data("minutes --index: \(error)\n".utf8))
            exit(1)
        }
        indexer.start()
        logger.info("Index service started")
        report(indexer)
        // A status line every 10 minutes so the log shows it's alive. State only, never note text.
        Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { _ in
            Task { @MainActor in report(indexer) }
        }
        RunLoop.main.run()
        exit(0)
    }

    @MainActor
    private static func report(_ indexer: NotesIndexer) {
        let refreshed = indexer.lastRefresh.map { ISO8601DateFormatter().string(from: $0) } ?? "never"
        let problem = indexer.lastError.map { " problem: \($0)" } ?? ""
        print("\(ISO8601DateFormatter().string(from: Date())) notes indexed: \(indexer.noteCount), last refresh: \(refreshed)\(problem)")
        fflush(stdout)
    }
}
