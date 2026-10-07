import Foundation

/// Registers Minutes' search server with Claude Code (user scope) and reports status.
enum ClaudeConnector {
    static let serverName = "minutes"

    enum Status: Equatable {
        case claudeNotFound
        case notConnected
        case connected
    }

    /// Where the `claude` command lives, checking the usual install spots first.
    static func claudeExecutable() async -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        for path in ["\(home)/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude", "\(home)/.claude/local/claude"]
        where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        let (status, output) = await run(URL(fileURLWithPath: "/bin/zsh"), ["-lc", "command -v claude"])
        let path = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return status == 0 && !path.isEmpty ? URL(fileURLWithPath: path) : nil
    }

    static func status() async -> Status {
        guard let claude = await claudeExecutable() else { return .claudeNotFound }
        let (code, _) = await run(claude, ["mcp", "get", serverName])
        return code == 0 ? .connected : .notConnected
    }

    /// Adds (or re-adds) the server pointing at this app's executable.
    static func connect() async throws {
        guard let claude = await claudeExecutable() else { throw ConnectError("Claude Code isn't installed on this Mac.") }
        guard let executable = Bundle.main.executableURL?.path else { throw ConnectError("Minutes can't find its own program file.") }
        _ = await run(claude, ["mcp", "remove", serverName, "--scope", "user"])
        let (code, output) = await run(claude, ["mcp", "add", serverName, "--scope", "user", "--", executable, "--mcp"])
        guard code == 0 else { throw ConnectError("Claude Code didn't accept the connection: \(output.trimmingCharacters(in: .whitespacesAndNewlines))") }
    }

    struct ConnectError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    private static func run(_ executable: URL, _ arguments: [String]) async -> (Int32, String) {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            process.terminationHandler = { p in
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                continuation.resume(returning: (p.terminationStatus, String(decoding: data, as: UTF8.self)))
            }
            do { try process.run() } catch { continuation.resume(returning: (-1, error.localizedDescription)) }
        }
    }
}
