import Foundation
import MinutesKit
import MinutesMCP

/// Hermes Helper: a background app for the assistant Mac mini. One binary, four modes:
/// `--index` (the default; run by launchd) keeps the Apple Notes index current and indexes the
/// OneDrive "AI Feed" folder (`--feed <path>` overrides the default location);
/// `--mcp` serves that index read-only to Hermes Agent over stdio; `--notes-helper`
/// runs one Apple Notes request for the index service; `--version` prints the version.
@main
enum HermesHelperMain {
    static let indexFolder = "Hermes Helper"
    static let serverName = "hermes-helper"
    static let noIndexHint = "the Hermes Helper index service hasn't run on this Mac"

    static func main() {
        let args = Set(CommandLine.arguments.dropFirst().filter { $0.hasPrefix("--") })
        if args.contains("--notes-helper") {
            MainActor.assumeIsolated { NotesHelper.run() }
        }
        if args.contains("--version") {
            print("Hermes Helper \(version) (\(build))")
            exit(0)
        }
        if args.contains("--mcp") {
            Task.detached {
                do {
                    try await MinutesMCPServer.run(indexURL: NotesIndex.defaultURL(appFolder: indexFolder),
                                                   version: version, name: serverName, noIndexHint: noIndexHint)
                    exit(0)
                } catch {
                    FileHandle.standardError.write(Data("HermesHelper --mcp: \(error)\n".utf8))
                    exit(1)
                }
            }
            dispatchMain()
        }
        if args.isEmpty || args.contains("--index") {
            MainActor.assumeIsolated { IndexService.run(indexURL: NotesIndex.defaultURL(appFolder: indexFolder), feedFolder: feedFolder()) }
        }
        FileHandle.standardError.write(Data("usage: HermesHelper [--index [--feed <folder>] | --mcp | --notes-helper | --version]\n".utf8))
        exit(2)
    }

    /// `--feed <path>` wins; otherwise the first `~/Library/CloudStorage/OneDrive-*/AI Feed` that exists.
    static func feedFolder() -> URL? {
        let argv = CommandLine.arguments
        if let i = argv.firstIndex(of: "--feed"), i + 1 < argv.count { return URL(fileURLWithPath: argv[i + 1], isDirectory: true) }
        return FeedIndexer.defaultFolder()
    }

    static var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0" }
    static var build: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0" }
}
