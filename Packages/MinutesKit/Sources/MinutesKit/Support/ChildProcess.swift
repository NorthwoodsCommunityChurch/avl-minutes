import Foundation

/// Runs a child process, feeds it `stdin`, and returns everything it wrote to stdout.
/// The child is killed at `timeout`, a child that exits without reading its input can't
/// crash the parent with SIGPIPE, and the result is delivered exactly once.
public enum ChildProcess {
    public enum Failure: Error, Equatable {
        case timedOut
    }

    public static func run(executable: URL, arguments: [String], stdin: Data,
                           timeout: Duration) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            let result = ResumeOnce(continuation)
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            let input = Pipe(), output = Pipe()
            process.standardInput = input
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            // Writing to a pipe the child has closed returns EPIPE instead of killing us.
            _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)

            let collected = OutputBox()
            process.terminationHandler = { _ in
                collected.done.wait()
                if collected.timedOut {
                    result.resume(throwing: Failure.timedOut)
                } else {
                    result.resume(returning: collected.data)
                }
            }
            do {
                try process.run()
            } catch {
                result.resume(throwing: error)
                return
            }
            // Drain stdout and fill stdin on their own threads so neither pipe can stall.
            Thread {
                collected.data = output.fileHandleForReading.readDataToEndOfFile()
                collected.done.signal()
            }.start()
            Thread {
                try? input.fileHandleForWriting.write(contentsOf: stdin)
                try? input.fileHandleForWriting.close()
            }.start()

            let pid = process.processIdentifier
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout.timeInterval) {
                guard process.isRunning else { return }
                collected.timedOut = true
                process.terminate()
                DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                    if process.isRunning { kill(pid, SIGKILL) }
                }
            }
        }
    }

    private final class OutputBox: @unchecked Sendable {
        var data = Data()
        var timedOut = false
        let done = DispatchSemaphore(value: 0)
    }

    private final class ResumeOnce: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Data, any Error>?

        init(_ continuation: CheckedContinuation<Data, any Error>) {
            self.continuation = continuation
        }

        func resume(returning data: Data) {
            lock.withLock { continuation.take() }?.resume(returning: data)
        }

        func resume(throwing error: any Error) {
            lock.withLock { continuation.take() }?.resume(throwing: error)
        }
    }
}

extension Duration {
    var timeInterval: TimeInterval {
        let parts = components
        return TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) / 1e18
    }
}
