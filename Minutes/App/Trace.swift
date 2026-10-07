import Foundation

/// Step tracing for the diagnostic modes: writes to stderr when MINUTES_TRACE=1.
/// State messages only — never audio or transcript text.
enum Trace {
    static let enabled = ProcessInfo.processInfo.environment["MINUTES_TRACE"] == "1"
    private static let start = Date()

    static func step(_ message: @autoclosure () -> String) {
        guard enabled else { return }
        let line = String(format: "[%7.2f] %@\n", Date().timeIntervalSince(start), message())
        FileHandle.standardError.write(Data(line.utf8))
    }
}
