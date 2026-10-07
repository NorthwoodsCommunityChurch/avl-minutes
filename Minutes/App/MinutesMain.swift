import Foundation
import MinutesKit
import MinutesMCP

/// One binary, three modes: `--mcp` runs the headless search server for Claude Code;
/// `--notes-helper` runs one Apple Notes request for the app; anything else launches
/// the menu bar app.
@main
enum MinutesMain {
    static func main() {
        if CommandLine.arguments.contains("--notes-helper") {
            MainActor.assumeIsolated { NotesHelper.run() }
        }
        if CommandLine.arguments.contains("--mcp") {
            let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
            Task.detached {
                do {
                    try await MinutesMCPServer.run(indexURL: NotesIndex.defaultURL(), version: version)
                    exit(0)
                } catch {
                    FileHandle.standardError.write(Data("minutes --mcp: \(error)\n".utf8))
                    exit(1)
                }
            }
            dispatchMain()
        }
        MinutesApp.main()
    }
}
