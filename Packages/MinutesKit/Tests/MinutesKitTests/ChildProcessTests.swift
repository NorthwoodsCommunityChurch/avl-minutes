import Foundation
import Testing
@testable import MinutesKit

@Test func childProcessPassesStdinThroughToStdout() async throws {
    let input = Data("hello, notes".utf8)
    let output = try await ChildProcess.run(executable: URL(filePath: "/bin/cat"), arguments: [],
                                            stdin: input, timeout: .seconds(10))
    #expect(output == input)
}

@Test func childProcessReturnsLargeOutputWithoutStalling() async throws {
    let input = Data(repeating: 0x61, count: 2_000_000)   // well past a pipe's buffer
    let output = try await ChildProcess.run(executable: URL(filePath: "/bin/cat"), arguments: [],
                                            stdin: input, timeout: .seconds(20))
    #expect(output.count == input.count)
}

@Test func childProcessIsKilledAtTheDeadline() async throws {
    let started = Date()
    await #expect(throws: ChildProcess.Failure.timedOut) {
        try await ChildProcess.run(executable: URL(filePath: "/bin/sleep"), arguments: ["30"],
                                   stdin: Data(), timeout: .milliseconds(500))
    }
    #expect(Date().timeIntervalSince(started) < 5)
}

@Test func childThatIgnoresStdinDoesNotCrashTheParent() async throws {
    // /usr/bin/true exits without reading; writing 1 MB to its stdin hits a closed pipe.
    let output = try await ChildProcess.run(executable: URL(filePath: "/usr/bin/true"), arguments: [],
                                            stdin: Data(repeating: 1, count: 1_000_000), timeout: .seconds(10))
    #expect(output.isEmpty)
}

@Test func missingExecutableThrowsOnce() async {
    await #expect(throws: (any Error).self) {
        try await ChildProcess.run(executable: URL(filePath: "/nonexistent/minutes"), arguments: [],
                                   stdin: Data(), timeout: .seconds(5))
    }
}
