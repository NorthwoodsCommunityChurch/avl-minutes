import Foundation
import Testing
@testable import MinutesKit

/// The shape of Planka's `GET /api/boards/:id`: the board under `item`, lists and cards (and users,
/// labels, memberships) under `included`. Positions can be null; archive and trash lists have no name.
private let fixture = Data("""
{"item":{"id":"b1","name":"To Do"},"included":{"lists":[
 {"id":"l-done","name":"Done","type":"closed","position":null},
 {"id":"l-gen","name":"General To Do","type":"active","position":65536},
 {"id":"l-sun","name":"Sunday","type":"active","position":32768},
 {"id":"l-arch","name":null,"type":"archive","position":null},
 {"id":"l-trash","name":null,"type":"trash","position":null},
 {"id":"l-empty","name":"Volunteers","type":"active","position":99999}],
 "cards":[
 {"id":"c2","name":"Second","listId":"l-gen","position":131072},
 {"id":"c1","name":"First","listId":"l-gen","position":65536},
 {"id":"c3","name":"Sunday thing","listId":"l-sun","position":65536},
 {"id":"c4","name":"Finished","listId":"l-done","position":65536},
 {"id":"c5","name":"Archived","listId":"l-arch","position":65536}],
 "users":[{"id":"u1","email":"x@y"}]}}
""".utf8)

@Test func parsesListsAndCardsFromThePlankaBoardResponse() throws {
    let board = try TaskBoard.parse(fixture)
    #expect(board.name == "To Do")
    #expect(board.lists.count == 6)
    #expect(board.cards.count == 5)
    #expect(board.lists.first { $0.id == "l-done" }?.type == "closed")
    #expect(board.cards.first { $0.id == "c1" }?.listId == "l-gen")
    #expect(throws: TaskBoardError.self) { try TaskBoard.parse(Data("{\"item\":{}}".utf8)) }
}

@Test func formatsEveryOpenListInOrderWithIdsAndSkipsDoneUnlessAsked() throws {
    let board = try TaskBoard.parse(fixture)
    let open = TaskBoard.format(board, includeDone: false)
    #expect(open == """
    To Do board: 3 open cards in 3 lists. Done holds 1 card (pass include_done to see it). Ids in brackets.

    Sunday (1) [l-sun]
    - Sunday thing [c3]

    General To Do (2) [l-gen]
    - First [c1]
    - Second [c2]

    Volunteers (0) [l-empty]
    """)
    let all = TaskBoard.format(board, includeDone: true)
    #expect(all.hasPrefix("To Do board: 3 open cards in 3 lists, plus Done (1). Ids in brackets."))
    #expect(all.hasSuffix("Done (1, closed) [l-done]\n- Finished [c4]"))
    #expect(!all.contains("Archived"))
}

@Test func configLoadsFromJSONAndIsNilWhenMissing() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("board-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent("task-board.json")
    #expect(try TaskBoard.loadConfig(at: url) == nil)
    try Data(#"{"baseURL":"http://10.0.0.1:8774/","apiKey":"k","boardId":"b1"}"#.utf8).write(to: url)
    let config = try #require(try TaskBoard.loadConfig(at: url))
    #expect(config.boardURL?.absoluteString == "http://10.0.0.1:8774/api/boards/b1")
    #expect(config.apiKey == "k")
}
