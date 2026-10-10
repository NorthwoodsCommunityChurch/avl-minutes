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
    #expect(MinutesMCPServer.tools.map(\.name) == ["search_notes", "list_notes", "get_note", "list_folders", "current_time"])
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

@Test func currentTimeNeedsNoIndexAndUsesTheGivenClock() {
    // Hermes has no terminal, so this tool is the only clock it has; it must work before any note is indexed.
    let absent = FileManager.default.temporaryDirectory.appendingPathComponent("absent-\(UUID().uuidString).db")
    let chicago = TimeZone(identifier: "America/Chicago")!
    let moment = ISO8601DateFormatter().date(from: "2026-10-08T19:32:05Z")!
    let r = MinutesMCPServer.call(name: "current_time", arguments: nil, indexURL: absent, timeZone: chicago, now: { moment })
    #expect(r.isError != true)
    let out = text(r)
    #expect(out.contains("Thursday, October 8, 2026"))
    #expect(out.contains("2:32 PM"))
    #expect(out.contains("CDT"))
    #expect(out.contains("2026-10-08T14:32:05-05:00"))
}

@Test func missingIndexIsExplained() {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("absent-\(UUID().uuidString).db")
    let r = MinutesMCPServer.call(name: "list_folders", arguments: nil, indexURL: url)
    #expect(r.isError != true)
    #expect(text(r).contains("No notes indexed yet"))
}

@Test func missingIndexUsesHint() {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("no-such-\(UUID().uuidString).db")
    let r = MinutesMCPServer.call(name: "list_folders", arguments: nil, indexURL: url, noIndexHint: "wait for the index service")
    #expect(text(r) == "No notes indexed yet — wait for the index service.")
}

@Test func unknownFolderIsAnErrorThatNamesTheFolders() throws {
    let url = try seededIndex()
    let r = MinutesMCPServer.call(name: "search_notes", arguments: ["query": .string("lobby"), "folder": .string("nope")], indexURL: url)
    #expect(r.isError == true)
    #expect(text(r).contains("No folder named \"nope\". Folders: Notes."))
    let own = MinutesMCPServer.call(name: "search_notes", arguments: ["query": .string("lobby"), "folder": .string("notes")], indexURL: url)
    #expect(own.isError != true && text(own).contains("\"Budget\""))
}

@Test func taskBoardToolAppearsOnlyWhenConfigured() throws {
    let url = try seededIndex()
    let missing = FileManager.default.temporaryDirectory.appendingPathComponent("no-board-\(UUID().uuidString).json")
    #expect(MinutesMCPServer.tools(taskBoardConfigURL: nil).map(\.name) == MinutesMCPServer.tools.map(\.name))
    #expect(MinutesMCPServer.tools(taskBoardConfigURL: missing).map(\.name) == MinutesMCPServer.tools.map(\.name))
    #expect(MinutesMCPServer.call(name: "task_board", arguments: nil, indexURL: url, taskBoardConfigURL: missing).isError == true)
    // Configured but pointing at nothing: the tool is listed and the failure is explained, never silent.
    let config = FileManager.default.temporaryDirectory.appendingPathComponent("board-\(UUID().uuidString).json")
    try Data(#"{"baseURL":"http://127.0.0.1:9","apiKey":"k","boardId":"b"}"#.utf8).write(to: config)
    #expect(MinutesMCPServer.tools(taskBoardConfigURL: config).last?.name == "task_board")
    let r = MinutesMCPServer.call(name: "task_board", arguments: ["include_done": .bool(true)], indexURL: url, taskBoardConfigURL: config)
    #expect(r.isError == true)
    #expect(text(r).hasPrefix("Task board unreachable:"))
}

private final class MemoryStore: NoteStore, @unchecked Sendable {
    var created: [(folder: String, html: String)] = []
    func plaintext(ids: [String]) async throws -> [String: String] { [:] }
    func createNote(folder: String, html: String) async throws -> String { created.append((folder, html)); return "n1" }
    func setBody(noteID: String, html: String) async throws {}
}

@Test func noteToolsAreListedOnlyWithAStoreAndWriteThroughIt() async throws {
    #expect(!MinutesMCPServer.tools(taskBoardConfigURL: nil).contains { $0.name == "note_write" })
    #expect(MinutesMCPServer.tools(taskBoardConfigURL: nil, notes: true).map(\.name).suffix(2) == ["note_write", "note_create"])
    let store = MemoryStore()
    let ok = await MinutesMCPServer.noteCall(name: "note_write", arguments: ["title": .string("Project: Atrium"), "section": .string("Facts"), "text": .string("- Walls Oct 16 (Oct 8)")], store: store)
    #expect(ok.isError != true && text(ok).hasPrefix("Created \"Project: Atrium\" in folder Hermes"))
    #expect(store.created.first?.folder == "Hermes")
    let bad = await MinutesMCPServer.noteCall(name: "note_write", arguments: ["title": .string("X"), "section": .string("Random"), "text": .string("y")], store: store)
    #expect(bad.isError == true && text(bad).contains("No section named \"Random\""))
    let missing = await MinutesMCPServer.noteCall(name: "note_create", arguments: ["title": .string("X")], store: store)
    #expect(missing.isError == true)
}
