import Foundation
import ServiceManagement
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
        #if DEBUG
        if CommandLine.arguments.contains("--unregister-login") {
            try? SMAppService.mainApp.unregister()
            print("login item status: \(SMAppService.mainApp.status.rawValue)")
            exit(0)
        }
        if CommandLine.arguments.contains("--gallery") {
            MainActor.assumeIsolated { Gallery.run() }
        }
        #endif
        if CommandLine.arguments.contains("--transcribe-check") {
            TranscribeCheck.run()
        }
        if CommandLine.arguments.contains("--audio-check") {
            AudioCheck.run(voiceProcessing: !CommandLine.arguments.contains("--raw"))
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
