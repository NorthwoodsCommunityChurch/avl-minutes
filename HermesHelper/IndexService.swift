import Foundation
import MinutesKit
import OSLog

/// `HermesHelper --index`: keeps the Notes index current with no UI. A launchd user agent
/// runs it for the whole login session; `HermesHelper --mcp` answers Hermes's searches
/// from the same index file.
enum IndexService {
    private static let logger = Logger(subsystem: AppIdentity.bundleID, category: "IndexService")

    @MainActor
    static func run(indexURL: URL) -> Never {
        let indexer: NotesIndexer
        do {
            indexer = NotesIndexer(index: try NotesIndex(url: indexURL), bridge: NotesBridge())
        } catch {
            FileHandle.standardError.write(Data("HermesHelper --index: \(error)\n".utf8))
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
