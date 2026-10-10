import Foundation

public enum TaskBoardError: Error, Equatable, CustomStringConvertible {
    case badConfig(String)
    case http(Int)
    case badResponse(String)

    public var description: String {
        switch self {
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

    /// One GET with the API key; synchronous because the MCP tool call is.
    public static func fetch(_ config: Config, timeout: TimeInterval = 20) throws -> Data {
        guard let url = config.boardURL else { throw TaskBoardError.badConfig("baseURL or boardId does not form a URL") }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.setValue(config.apiKey, forHTTPHeaderField: "X-Api-Key")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
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
