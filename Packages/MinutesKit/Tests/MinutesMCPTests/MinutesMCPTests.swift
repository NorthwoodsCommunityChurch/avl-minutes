import Foundation
import MCP
import Testing
@testable import MinutesKit
@testable import MinutesMCP

private func text(_ result: CallTool.Result) -> String {
    result.content.compactMap { if case .text(let t, _, _) = $0 { t } else { nil } }.joined()
}

private func seededIndex() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("mcp-\(UUID().uuidString)/i.db")
    let index = try NotesIndex(url: url)
    try index.upsert(NoteMetadata(id: "n1", title: "Budget", folder: "Notes", account: "iCloud",
                                  createdAt: Date(), modifiedAt: Date(), isLocked: false), body: "budget for lobby screens")
    try index.setLastRefresh(Date())
    return url
}

@Test func toolsAreListedWithSchemas() {
    #expect(MinutesMCPServer.tools.map(\.name) == ["search_notes", "list_notes", "get_note", "list_folders"])
}

@Test func searchCallReturnsText() throws {
    let r = MinutesMCPServer.call(name: "search_notes", arguments: ["query": .string("lobby"), "limit": .int(5)], indexURL: try seededIndex())
    #expect(r.isError != true)
    #expect(text(r).contains("\"Budget\""))
}

@Test func badCallsAreToolErrors() throws {
    let url = try seededIndex()
    #expect(MinutesMCPServer.call(name: "search_notes", arguments: [:], indexURL: url).isError == true)
    #expect(MinutesMCPServer.call(name: "nope", arguments: nil, indexURL: url).isError == true)
    #expect(MinutesMCPServer.call(name: "list_notes", arguments: ["since": .string("yesterday")], indexURL: url).isError == true)
    #expect(MinutesMCPServer.call(name: "get_note", arguments: ["note_id": .string("missing")], indexURL: url).isError == true)
}

@Test func missingIndexIsExplained() {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("absent-\(UUID().uuidString).db")
    let r = MinutesMCPServer.call(name: "list_folders", arguments: nil, indexURL: url)
    #expect(r.isError != true)
    #expect(text(r).contains("No notes indexed yet"))
}
