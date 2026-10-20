import Foundation

public enum TaskBoardError: Error, Equatable, CustomStringConvertible {
    case badConfig(String)
    case http(Int)
    case badResponse(String)
    case badRequest(String)
    /// A change that was not made (list order); the board is untouched.
    case refused(String)

    public var description: String {
        switch self {
        case .badRequest(let m): "Not created: \(m)."
        case .refused(let m): "Not changed: \(m)."
        case .badConfig(let m): "Task board config: \(m)"
        case .http(let code): "Task board answered HTTP \(code)"
        case .badResponse(let m): "Task board answer not understood: \(m)"
        }
    }
}

/// Aaron's Planka task board, read straight from Planka's REST API and shown compactly: one line per
/// card, every list in one call. The Planka MCP server's `cards list` runs ~830 characters per card
/// (every null field plus the callers' user records); eight lists in one turn blew Hermes's tool-result
/// budget and the biggest spilled to a file she could not read (2026-10-10). This is ~90 per card.
public enum TaskBoard {
    public struct List: Sendable, Equatable {
        public let id: String
        public let name: String
        /// Planka: "active" (open), "closed" (Done), "archive", "trash".
        public let type: String
        public let position: Double?
    }

    public struct Card: Sendable, Equatable {
        public let id: String
        public let name: String
        public let listId: String
        public let position: Double?
    }

    public struct Snapshot: Sendable, Equatable {
        public let name: String
        public let lists: [List]
        public let cards: [Card]
    }

    /// Lives on the mini only (`~/Library/Application Support/Hermes Helper/task-board.json`, mode 600):
    /// `{"baseURL": "http://host:port", "apiKey": "…", "boardId": "…"}`. The key is the one Hermes's
    /// Planka MCP server uses (`PLANKA_API_KEY`); Planka takes it in the `X-Api-Key` header.
    public struct Config: Sendable, Equatable, Codable {
        public let baseURL: String
        public let apiKey: String
        public let boardId: String

        public var boardURL: URL? {
            var base = baseURL
            while base.hasSuffix("/") { base.removeLast() }
            return URL(string: "\(base)/api/boards/\(boardId)")
        }
    }

    public static func loadConfig(at url: URL) throws -> Config? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            return try JSONDecoder().decode(Config.self, from: Data(contentsOf: url))
        } catch {
            throw TaskBoardError.badConfig("\(url.lastPathComponent) needs baseURL, apiKey, and boardId (\(error))")
        }
    }

    /// Planka's `GET /api/boards/:id`: the board under `item`, lists and cards under `included`.
    public static func parse(_ data: Data) throws -> Snapshot {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let item = root["item"] as? [String: Any],
              let included = root["included"] as? [String: Any],
              let lists = included["lists"] as? [[String: Any]],
              let cards = included["cards"] as? [[String: Any]] else {
            throw TaskBoardError.badResponse("no item, included.lists, and included.cards")
        }
        return Snapshot(
            name: item["name"] as? String ?? "Task",
            lists: lists.compactMap { l in
                guard let id = l["id"] as? String else { return nil }
                return List(id: id, name: l["name"] as? String ?? "", type: l["type"] as? String ?? "active",
                            position: l["position"] as? Double)
            },
            cards: cards.compactMap { c in
                guard let id = c["id"] as? String, let listId = c["listId"] as? String else { return nil }
                return Card(id: id, name: c["name"] as? String ?? "", listId: listId, position: c["position"] as? Double)
            })
    }

    /// Open lists by position, each card on one line with its id; Done only when asked, archive and
    /// trash never.
    public static func format(_ board: Snapshot, includeDone: Bool) -> String {
        let byPosition: (List, List) -> Bool = { ($0.position ?? .infinity, $0.id) < ($1.position ?? .infinity, $1.id) }
        let open = board.lists.filter { $0.type == "active" }.sorted(by: byPosition)
        let done = board.lists.filter { $0.type == "closed" }.sorted(by: byPosition)
        let cards = Dictionary(grouping: board.cards, by: \.listId)
        func sorted(_ list: List) -> [Card] {
            (cards[list.id] ?? []).sorted { ($0.position ?? .infinity, $0.id) < ($1.position ?? .infinity, $1.id) }
        }
        let openCount = open.reduce(0) { $0 + (cards[$1.id]?.count ?? 0) }
        let doneCount = done.reduce(0) { $0 + (cards[$1.id]?.count ?? 0) }
        var head = "\(board.name) board: \(openCount) open \(openCount == 1 ? "card" : "cards") in \(open.count) \(open.count == 1 ? "list" : "lists")"
        if includeDone {
            head += ", plus Done (\(doneCount))."
        } else {
            head += ". Done holds \(doneCount) \(doneCount == 1 ? "card" : "cards") (pass include_done to see \(doneCount == 1 ? "it" : "them"))."
        }
        var out = [head + " Ids in brackets."]
        for list in open {
            let items = sorted(list)
            out.append("")
            out.append("\(list.name) (\(items.count)) [\(list.id)]")
            out += items.map { "- \($0.name) [\($0.id)]" }
        }
        if includeDone {
            for list in done {
                let items = sorted(list)
                out.append("")
                out.append("\(list.name) (\(items.count), closed) [\(list.id)]")
                out += items.map { "- \($0.name) [\($0.id)]" }
            }
        }
        return out.joined(separator: "\n")
    }

    /// Longest list name Planka accepts.
    public static let maxListNameLength = 128
    /// A guard against a runaway loop filling the board, far above the board's real size (eight open lists).
    public static let maxOpenLists = 20

    /// Checks a new list's name against the board and picks its position: after the last open list, so it
    /// lands before Done. Refuses an empty or overlong name, a name already on the board (any case), and a
    /// board at `maxOpenLists`. Returns the trimmed name and the position.
    public static func planNewList(named raw: String, on board: Snapshot) throws -> (name: String, position: Double) {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw TaskBoardError.badRequest("the list needs a name") }
        guard name.count <= maxListNameLength else {
            throw TaskBoardError.badRequest("a list name is at most \(maxListNameLength) characters")
        }
        let named = board.lists.filter { $0.type == "active" || $0.type == "closed" }
        if let existing = named.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            throw TaskBoardError.badRequest("a list named \"\(existing.name)\" already exists [\(existing.id)]; add cards to it instead")
        }
        let open = board.lists.filter { $0.type == "active" }
        guard open.count < maxOpenLists else {
            throw TaskBoardError.badRequest("the board already has \(open.count) open lists, the most allowed; ask Aaron which to use")
        }
        let positions = named.compactMap(\.position)
        let lastOpen = open.compactMap(\.position).max()
        guard let lastOpen else { return (name, (positions.min() ?? 131072) / 2) }
        if let next = positions.filter({ $0 > lastOpen }).min() { return (name, (lastOpen + next) / 2) }
        return (name, lastOpen + 65536)
    }

    /// Planka's `POST /api/boards/:id/lists` answer: the new list under `item`.
    public static func parseCreatedList(_ data: Data) throws -> List {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let item = root["item"] as? [String: Any], let id = item["id"] as? String else {
            throw TaskBoardError.badResponse("no item.id in the new list")
        }
        return List(id: id, name: item["name"] as? String ?? "", type: item["type"] as? String ?? "active",
                    position: item["position"] as? Double)
    }

    /// Creates one open list on the board: read the board, plan, POST. Never renames or deletes; deleting a
    /// list in Planka deletes its cards, so no tool here does it.
    public static func createList(configURL: URL, name: String) throws -> String? {
        guard let config = try loadConfig(at: configURL) else { return nil }
        let board = try parse(try fetch(config))
        let plan = try planNewList(named: name, on: board)
        guard let url = config.boardURL?.appendingPathComponent("lists") else {
            throw TaskBoardError.badConfig("baseURL or boardId does not form a URL")
        }
        let body = try JSONSerialization.data(withJSONObject: ["type": "active", "position": plan.position, "name": plan.name])
        let list = try parseCreatedList(try send(config, url: url, method: "POST", body: body))
        return "Created list \"\(list.name)\" [\(list.id)] on the \(board.name) board. Add cards with cards {\"action\":\"create\",\"id\":\"\(list.id)\",…}."
    }

    /// The open lists in their new order with new positions. Lists named in `wanted` (a name, any case, or an id;
    /// an id wins) come first in that order, every other open list keeps its order after them, and all of them stay
    /// before Done. Refuses an empty order, an unknown or closed list, and a list named twice.
    public static func planListOrder(_ wanted: [String], on board: Snapshot) throws -> [(id: String, name: String, position: Double)] {
        let byPosition: (List, List) -> Bool = { ($0.position ?? .infinity, $0.id) < ($1.position ?? .infinity, $1.id) }
        let open = board.lists.filter { $0.type == "active" }.sorted(by: byPosition)
        guard !wanted.isEmpty else { throw TaskBoardError.refused("name the lists in the order Aaron wants") }
        var first: [List] = []
        for raw in wanted {
            let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let list = open.first(where: { $0.id == key }) ?? open.first(where: { $0.name.caseInsensitiveCompare(key) == .orderedSame }) else {
                if board.lists.contains(where: { $0.type == "closed" && ($0.id == key || $0.name.caseInsensitiveCompare(key) == .orderedSame) }) {
                    throw TaskBoardError.refused("\"\(key)\" is the Done list; it always stays last")
                }
                throw TaskBoardError.refused("no open list named \"\(key)\"; open lists: \(open.map(\.name).joined(separator: ", "))")
            }
            guard !first.contains(where: { $0.id == list.id }) else { throw TaskBoardError.refused("\"\(list.name)\" is named twice") }
            first.append(list)
        }
        let final = first + open.filter { l in !first.contains(where: { $0.id == l.id }) }
        let ceiling = board.lists.filter { $0.type == "closed" }.compactMap(\.position).min()
        let step = ceiling.map { $0 / Double(final.count + 1) } ?? 65536
        return final.enumerated().map { (i, l) in (l.id, l.name, step * Double(i + 1)) }
    }

    public static func describeOrder(_ names: [String], boardName: String, moved: Int) -> String {
        "Lists on the \(boardName) board, in order: \(names.joined(separator: ", ")), then Done. Moved \(moved) \(moved == 1 ? "list" : "lists")."
    }

    /// Reorders the open lists: read the board, plan, then `PATCH /api/lists/:id {position}` for each list whose
    /// position changes. Only positions change; no list is renamed, closed, or deleted.
    public static func orderLists(configURL: URL, order: [String]) throws -> String? {
        guard let config = try loadConfig(at: configURL) else { return nil }
        let board = try parse(try fetch(config))
        let plan = try planListOrder(order, on: board)
        var base = config.baseURL
        while base.hasSuffix("/") { base.removeLast() }
        let current = Dictionary(uniqueKeysWithValues: board.lists.map { ($0.id, $0.position) })
        var moved = 0
        for item in plan where current[item.id] ?? nil != item.position {
            guard let url = URL(string: "\(base)/api/lists/\(item.id)") else { throw TaskBoardError.badConfig("baseURL does not form a URL") }
            _ = try send(config, url: url, method: "PATCH", body: try JSONSerialization.data(withJSONObject: ["position": item.position]))
            moved += 1
        }
        return describeOrder(plan.map(\.name), boardName: board.name, moved: moved)
    }

    public struct CardMovePlan: Sendable, Equatable {
        public let list: List
        public let moves: [Move]
        /// One line per card that is not moved: unknown, ambiguous, or already there.
        public let problems: [String]
        public struct Move: Sendable, Equatable {
            public let id: String
            public let name: String
            public let position: Double
        }
    }

    /// Which cards move where. A card is named by its id, its exact name (any case), or a piece of its name that only
    /// one card has; a name two cards share must be passed as an id. Moved cards go to the bottom of the list (or the
    /// top) in the order given. Throws only for a missing or unknown list or an empty card list; every card problem
    /// is reported in `problems`, so the good moves still happen.
    public static func planCardMove(_ refs: [String], to listRef: String, top: Bool, on board: Snapshot) throws -> CardMovePlan {
        let lists = board.lists.filter { $0.type == "active" || $0.type == "closed" }
            .sorted { ($0.position ?? .infinity, $0.id) < ($1.position ?? .infinity, $1.id) }
        let key = listRef.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let list = lists.first(where: { $0.id == key }) ?? lists.first(where: { $0.name.caseInsensitiveCompare(key) == .orderedSame }) else {
            throw TaskBoardError.refused("no list named \"\(key)\"; lists: \(lists.map(\.name).joined(separator: ", "))")
        }
        guard !refs.isEmpty else { throw TaskBoardError.refused("name the cards to move") }
        let listName = Dictionary(uniqueKeysWithValues: lists.map { ($0.id, $0.name) })
        let cards = board.cards.filter { listName[$0.listId] != nil }
        var picked: [Card] = []
        var problems: [String] = []
        for raw in refs {
            let ref = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            var matches = cards.filter { $0.id == ref }
            if matches.isEmpty { matches = cards.filter { $0.name.caseInsensitiveCompare(ref) == .orderedSame } }
            if matches.isEmpty, !ref.isEmpty { matches = cards.filter { $0.name.range(of: ref, options: .caseInsensitive) != nil } }
            if matches.isEmpty { problems.append("no card named \"\(ref)\""); continue }
            if matches.count > 1 {
                let shown = matches.prefix(4).map { "\($0.name) [\($0.id)] (\(listName[$0.listId] ?? "?"))" }.joined(separator: ", ")
                problems.append("\"\(ref)\" matches \(matches.count) cards: \(shown); pass the id")
                continue
            }
            let card = matches[0]
            if card.listId == list.id { problems.append("\"\(card.name)\" is already in \(list.name)"); continue }
            if !picked.contains(where: { $0.id == card.id }) { picked.append(card) }
        }
        let inList = board.cards.filter { $0.listId == list.id }.compactMap(\.position)
        let moves: [CardMovePlan.Move] = picked.enumerated().map { (i, card) in
            let position = top
                ? (inList.min() ?? 65536) * Double(i + 1) / Double(picked.count + 1)
                : (inList.max() ?? 0) + 65536 * Double(i + 1)
            return .init(id: card.id, name: card.name, position: position)
        }
        return CardMovePlan(list: list, moves: moves, problems: problems)
    }

    /// Moves cards to a list by name: read the board, plan, then `PATCH /api/cards/:id {listId, position}` per card.
    /// Never deletes or renames a card.
    public static func moveCards(configURL: URL, cards: [String], to list: String, top: Bool) throws -> String? {
        guard let config = try loadConfig(at: configURL) else { return nil }
        let plan = try planCardMove(cards, to: list, top: top, on: try parse(try fetch(config)))
        var base = config.baseURL
        while base.hasSuffix("/") { base.removeLast() }
        var out: [String] = []
        for move in plan.moves {
            guard let url = URL(string: "\(base)/api/cards/\(move.id)") else { throw TaskBoardError.badConfig("baseURL does not form a URL") }
            do {
                _ = try send(config, url: url, method: "PATCH", body: try JSONSerialization.data(withJSONObject: ["listId": plan.list.id, "position": move.position]))
                out.append("Moved \"\(move.name)\" [\(move.id)] to \(plan.list.name).")
            } catch {
                out.append("Not moved: \"\(move.name)\" [\(move.id)] (\(error)).")
            }
        }
        out += plan.problems.map { "Not moved: \($0)." }
        return out.joined(separator: "\n")
    }

    /// One GET of the board with the API key; synchronous because the MCP tool call is.
    public static func fetch(_ config: Config, timeout: TimeInterval = 20) throws -> Data {
        guard let url = config.boardURL else { throw TaskBoardError.badConfig("baseURL or boardId does not form a URL") }
        return try send(config, url: url, method: "GET", body: nil, timeout: timeout)
    }

    private static func send(_ config: Config, url: URL, method: String, body: Data?, timeout: TimeInterval = 20) throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = method
        request.httpBody = body
        request.setValue(config.apiKey, forHTTPHeaderField: "X-Api-Key")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let box = ResultBox()
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { data, response, error in
            defer { done.signal() }
            if let error { box.result = .failure(error); return }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(status), let data else { box.result = .failure(TaskBoardError.http(status)); return }
            box.result = .success(data)
        }.resume()
        done.wait()
        return try box.result.get()
    }

    /// Config, fetch, parse, format: the whole tool call.
    public static func describe(configURL: URL, includeDone: Bool) throws -> String? {
        guard let config = try loadConfig(at: configURL) else { return nil }
        return format(try parse(try fetch(config)), includeDone: includeDone)
    }

    private final class ResultBox: @unchecked Sendable {
        var result: Result<Data, Error> = .failure(TaskBoardError.badResponse("no response"))
    }
}
