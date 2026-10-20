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

@Test func newListGoesAfterTheLastOpenListAndBeforeDone() throws {
    // Real board shape (2026-10-14): open lists up to 589824, Done at 655360.
    let board = TaskBoard.Snapshot(name: "To Do", lists: [
        .init(id: "sun", name: "Sunday", type: "active", position: 32768),
        .init(id: "ice", name: "Icebox", type: "active", position: 589824),
        .init(id: "done", name: "Done", type: "closed", position: 655360),
        .init(id: "arch", name: "", type: "archive", position: nil),
    ], cards: [])
    let plan = try TaskBoard.planNewList(named: "  Summer camp \n", on: board)
    #expect(plan.name == "Summer camp")
    #expect(plan.position == 622592)
    // Nothing after the open lists: one step past the last.
    let noDone = TaskBoard.Snapshot(name: "To Do", lists: [.init(id: "a", name: "A", type: "active", position: 65536)], cards: [])
    #expect(try TaskBoard.planNewList(named: "B", on: noDone).position == 131072)
    // No open lists yet: before Done.
    let onlyDone = TaskBoard.Snapshot(name: "To Do", lists: [.init(id: "d", name: "Done", type: "closed", position: 65536)], cards: [])
    #expect(try TaskBoard.planNewList(named: "B", on: onlyDone).position == 32768)
}

@Test func newListRefusesDuplicatesEmptyNamesAndARunawayBoard() throws {
    let board = TaskBoard.Snapshot(name: "To Do", lists: [
        .init(id: "ice", name: "Icebox", type: "active", position: 65536),
        .init(id: "done", name: "Done", type: "closed", position: 131072),
    ], cards: [])
    #expect(throws: TaskBoardError.badRequest("a list named \"Icebox\" already exists [ice]; add cards to it instead")) {
        try TaskBoard.planNewList(named: "icebox", on: board)
    }
    #expect(throws: TaskBoardError.self) { try TaskBoard.planNewList(named: "done", on: board) }
    #expect(throws: TaskBoardError.self) { try TaskBoard.planNewList(named: "   ", on: board) }
    #expect(throws: TaskBoardError.self) { try TaskBoard.planNewList(named: String(repeating: "x", count: 129), on: board) }
    let full = TaskBoard.Snapshot(name: "To Do", lists: (0..<TaskBoard.maxOpenLists).map {
        .init(id: "l\($0)", name: "L\($0)", type: "active", position: Double($0 + 1) * 65536)
    }, cards: [])
    #expect(throws: TaskBoardError.self) { try TaskBoard.planNewList(named: "One more", on: full) }
}

@Test func parsesTheCreatedList() throws {
    let data = Data(#"{"item":{"id":"1885755744481969670","type":"active","position":589824,"name":"Icebox","boardId":"b"}}"#.utf8)
    #expect(try TaskBoard.parseCreatedList(data) == .init(id: "1885755744481969670", name: "Icebox", type: "active", position: 589824))
    #expect(throws: TaskBoardError.self) { try TaskBoard.parseCreatedList(Data("{}".utf8)) }
}

// Aaron, 2026-10-20: "Heremes needs to be able to reorder columns" after she told him to drag the two new lists himself.
private let ordered = TaskBoard.Snapshot(name: "To Do", lists: [
    .init(id: "sun", name: "Sunday", type: "active", position: 32768),
    .init(id: "gen", name: "General To Do", type: "active", position: 65536),
    .init(id: "ice", name: "Icebox", type: "active", position: 589824),
    .init(id: "high", name: "High priority", type: "active", position: 606208),
    .init(id: "week", name: "This weeks to do", type: "active", position: 622592),
    .init(id: "done", name: "Done", type: "closed", position: 655360),
    .init(id: "arch", name: "", type: "archive", position: nil),
], cards: [])

@Test func listOrderPutsNamedListsFirstAndKeepsTheRestInTheirOrderBeforeDone() throws {
    let plan = try TaskBoard.planListOrder(["high priority", "week", "Sunday"], on: ordered)
    #expect(plan.map(\.id) == ["high", "week", "sun", "gen", "ice"])
    let positions = plan.map(\.position)
    #expect(positions == positions.sorted())
    #expect(positions.allSatisfy { $0 > 0 && $0 < 655360 })
    #expect(Set(positions).count == positions.count)
    // Ids work as well as names, and an id wins over a name.
    #expect(try TaskBoard.planListOrder(["week", "high"], on: ordered).prefix(2).map(\.id) == ["week", "high"])
    // No Done list: steps of 65536.
    let open = TaskBoard.Snapshot(name: "To Do", lists: [.init(id: "a", name: "A", type: "active", position: 1), .init(id: "b", name: "B", type: "active", position: 2)], cards: [])
    #expect(try TaskBoard.planListOrder(["B"], on: open).map(\.position) == [65536, 131072])
}

@Test func listOrderRefusesUnknownRepeatedAndClosedLists() throws {
    #expect(throws: TaskBoardError.refused("no open list named \"Someday\"; open lists: Sunday, General To Do, Icebox, High priority, This weeks to do")) {
        try TaskBoard.planListOrder(["Someday"], on: ordered)
    }
    #expect(throws: TaskBoardError.self) { try TaskBoard.planListOrder(["Done"], on: ordered) }
    #expect(throws: TaskBoardError.self) { try TaskBoard.planListOrder(["Icebox", "icebox"], on: ordered) }
    #expect(throws: TaskBoardError.self) { try TaskBoard.planListOrder([], on: ordered) }
}

@Test func listOrderDescribesTheNewOrder() {
    #expect(TaskBoard.describeOrder(["High priority", "Sunday"], boardName: "To Do", moved: 2) ==
            "Lists on the To Do board, in order: High priority, Sunday, then Done. Moved 2 lists.")
}

// 2026-10-20: asked to move cards to a new MJ list, she sent six moves with card ids that were not on the board, the
// Planka tool paused itself, and her retry with real ids was refused too. task_card_move takes card names.
private let carded = TaskBoard.Snapshot(name: "To Do", lists: [
    .init(id: "gen", name: "General To Do", type: "active", position: 65536),
    .init(id: "mj", name: "MJ", type: "active", position: 131072),
    .init(id: "done", name: "Done", type: "closed", position: 196608),
], cards: [
    .init(id: "c1", name: "Follow up with MJ on all the atrium audio things", listId: "gen", position: 65536),
    .init(id: "c2", name: "Send all Hermes tweaks to MJ", listId: "gen", position: 131072),
    .init(id: "c3", name: "Kids' room audio: work with Kirk and MJ", listId: "gen", position: 196608),
    .init(id: "c4", name: "Order cables", listId: "gen", position: 262144),
    .init(id: "c5", name: "Order cables", listId: "done", position: 65536),
    .init(id: "m1", name: "Already here", listId: "mj", position: 65536),
])

@Test func cardMoveFindsCardsByNameOrIdAndAppendsThem() throws {
    let plan = try TaskBoard.planCardMove(["send all hermes tweaks to mj", "c1", "Kids' room audio"], to: "MJ", top: false, on: carded)
    #expect(plan.list.id == "mj")
    #expect(plan.moves.map(\.id) == ["c2", "c1", "c3"])
    #expect(plan.moves.map(\.position) == [131072, 196608, 262144])
    #expect(plan.problems.isEmpty)
    let top = try TaskBoard.planCardMove(["c4"], to: "mj", top: true, on: carded)
    #expect(top.moves.map(\.position) == [32768])
}

@Test func cardMoveReportsUnknownAmbiguousAndAlreadyThereCards() throws {
    let plan = try TaskBoard.planCardMove(["Order cables", "Nope", "Already here", "audio"], to: "MJ", top: false, on: carded)
    #expect(plan.moves.isEmpty == true)
    #expect(plan.problems == [
        "\"Order cables\" matches 2 cards: Order cables [c4] (General To Do), Order cables [c5] (Done); pass the id",
        "no card named \"Nope\"",
        "\"Already here\" is already in MJ",
        "\"audio\" matches 2 cards: Follow up with MJ on all the atrium audio things [c1] (General To Do), Kids' room audio: work with Kirk and MJ [c3] (General To Do); pass the id",
    ])
    #expect(throws: TaskBoardError.refused("no list named \"Someday\"; lists: General To Do, MJ, Done")) {
        try TaskBoard.planCardMove(["c1"], to: "Someday", top: false, on: carded)
    }
    #expect(throws: TaskBoardError.self) { try TaskBoard.planCardMove([], to: "MJ", top: false, on: carded) }
}
