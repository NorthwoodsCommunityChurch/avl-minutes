import Foundation
import MinutesKit
import OSLog

/// `HermesHelper --index`: keeps the Notes index current with no UI, and indexes the OneDrive "AI Feed"
/// folder (mail, calendar, Teams files written by Aaron's Power Automate flows) into the same index.
/// A launchd user agent runs it for the whole login session; `HermesHelper --mcp` answers Hermes's
/// searches from the same index file.
enum IndexService {
    private static let logger = Logger(subsystem: AppIdentity.bundleID, category: "IndexService")
    private static let feedInterval: TimeInterval = 120

    @MainActor
    static func run(indexURL: URL, feedFolder: URL?) -> Never {
        let indexer: NotesIndexer
        let index: NotesIndex
        do {
            index = try NotesIndex(url: indexURL)
            indexer = NotesIndexer(index: index, bridge: NotesBridge())
        } catch {
            FileHandle.standardError.write(Data("HermesHelper --index: \(error)\n".utf8))
            exit(1)
        }
        indexer.start()
        logger.info("Index service started")
        let feed = feedFolder.map { FeedIndexer(folder: $0, index: index) }
        if let feed {
            FeedIndexer.allowDownloadingPlaceholders()
            print("\(stamp()) AI Feed folder: \(feed.folder.path)")
            refreshFeed(feed)
            Timer.scheduledTimer(withTimeInterval: feedInterval, repeats: true) { _ in
                Task { @MainActor in refreshFeed(feed) }
            }
        } else {
            print("\(stamp()) AI Feed folder not found; indexing Notes only")
        }
        report(indexer, feed)
        // A status line every 10 minutes so the log shows it's alive. State only, never note text.
        Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { _ in
            Task { @MainActor in report(indexer, feed) }
        }
        RunLoop.main.run()
        exit(0)
    }

    @MainActor private static var feedBusy = false
    @MainActor private static var lastFeedProblem: String?
    @MainActor private static var feedReported = false

    @MainActor
    private static func refreshFeed(_ feed: FeedIndexer) {
        guard !feedBusy else { return }
        feedBusy = true
        Task.detached {
            let outcome: Result<FeedIndexer.Result, Error> = Result { try feed.refresh() }
            await MainActor.run {
                feedBusy = false
                switch outcome {
                case .success(let r):
                    if r.indexed > 0 || r.removed > 0 || r.unreadable > 0 || lastFeedProblem != nil || !feedReported {
                        print("\(stamp()) feed: \(r.indexed) indexed, \(r.removed) removed, \(r.skipped) skipped, \(r.unreadable) unreadable, \(r.total) records"); fflush(stdout)
                    }
                    lastFeedProblem = nil
                    feedReported = true
                case .failure(let error):
                    let text = "\(error)"
                    if text != lastFeedProblem { print("\(stamp()) feed problem: \(text)"); fflush(stdout) }
                    lastFeedProblem = text
                    logger.error("Feed refresh failed")
                }
            }
        }
    }

    private static func stamp() -> String { ISO8601DateFormatter().string(from: Date()) }

    @MainActor
    private static func report(_ indexer: NotesIndexer, _ feed: FeedIndexer?) {
        let refreshed = indexer.lastRefresh.map { ISO8601DateFormatter().string(from: $0) } ?? "never"
        let problem = indexer.lastError.map { " problem: \($0)" } ?? ""
        let feedPart = feed == nil ? "" : ", feed records: \((try? feed!.count()) ?? -1)\(lastFeedProblem.map { " feed problem: \($0)" } ?? "")"
        print("\(stamp()) notes indexed: \(indexer.noteCount), last refresh: \(refreshed)\(problem)\(feedPart)")
        fflush(stdout)
    }
}
