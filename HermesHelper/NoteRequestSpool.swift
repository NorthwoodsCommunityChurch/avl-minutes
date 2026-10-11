import Foundation
import MinutesKit
import OSLog

/// Note writes from `--mcp` travel through a spool directory to the `--index` service, the one process that
/// talks to Apple Notes. launchd starts the index service, so macOS's automation consent covers its AppleScript
/// children; a child spawned under Hermes's gateway has no such grant and its events waited forever (2026-10-10,
/// `note_write` timed out at 60 s with no consent record). A single Notes client also means the index's own
/// listing never races a second client, which wedged Notes the same evening.
///
/// Protocol: the client writes `<id>.json` (a `NotesRequest`), the server answers with `<id>.reply.json`
/// (a `NotesReply`), both written to a temp name and renamed so neither side reads a half file. The directory
/// sits next to the index (mode 700, owned by this user, checked at every start).
///
/// Scope, enforced by the server and not by trust in the client: any process running as this user could drop a
/// request here, and the server acts under the consent macOS gave the helper, so it does only what Hermes's own
/// notes need. Listing and showing notes are refused; a note is created only in the Hermes folder; a note is read
/// or rewritten only after the server itself confirms it sits in the Hermes folder; at most a few ids per read.
/// The HTML accepted is only what `HermesNote.html` produces (div, h1, h2, br, escaped text), capped at 64 KB.
/// A shared secret would not add to that (a same-user process could read it too), so the scope is the control;
/// what stays is the mini's own same-user boundary, where the relay key, the board key, and Hermes's config
/// already live, so the spool adds no capability a process there did not already have.
enum NoteRequestSpool {
    static let directoryName = "note-requests"

    static func directory(near indexURL: URL) -> URL {
        indexURL.deletingLastPathComponent().appendingPathComponent(directoryName, isDirectory: true)
    }

    static func ensure(_ directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
    }

    /// Owned by the running user, mode exactly 0700, a real directory (not a link).
    static func isPrivate(_ directory: URL) -> Bool {
        var st = stat()
        guard lstat(directory.path, &st) == 0 else { return false }
        return (st.st_mode & S_IFMT) == S_IFDIR && st.st_uid == getuid() && (st.st_mode & 0o777) == 0o700
    }

    static let folder = HermesNote.folder
    static let maxReadIDs = 5
    static let maxHTMLBytes = 65_536

    /// Only what `HermesNote.html` produces: div, h1, h2, br tags and escaped text. Anything else (links, images,
    /// scripts, styles, raw angle brackets) is refused, so the spool cannot put arbitrary markup into Aaron's Notes.
    static func isOurHTML(_ html: String) -> Bool {
        guard html.utf8.count <= maxHTMLBytes, html.hasPrefix("<div><h1>") else { return false }
        var rest = Substring(html)
        while let open = rest.firstIndex(of: "<") {
            // Text before the tag: no stray > and no entity other than the four the renderer writes, so what Notes
            // decodes is exactly the escaped text, nothing a different parser could read as markup.
            let text = rest[..<open]
            guard !text.contains(">"), Self.entitiesAreOurs(text) else { return false }
            guard let close = rest[open...].firstIndex(of: ">") else { return false }
            guard HermesNote.htmlTags.contains(String(rest[open...close])) else { return false }
            rest = rest[rest.index(after: close)...]
        }
        return !rest.contains(">") && Self.entitiesAreOurs(rest)
    }

    private static func entitiesAreOurs(_ text: Substring) -> Bool {
        var rest = text
        while let amp = rest.firstIndex(of: "&") {
            let tail = rest[amp...]
            guard let entity = ["&amp;", "&lt;", "&gt;", "&quot;"].first(where: { tail.hasPrefix($0) }) else { return false }
            rest = tail.dropFirst(entity.count)
        }
        return true
    }

    private static func writeAtomically(_ data: Data, to url: URL) throws {
        let tmp = url.appendingPathExtension("tmp")
        try data.write(to: tmp, options: .atomic)
        _ = try? FileManager.default.removeItem(at: url)
        try FileManager.default.moveItem(at: tmp, to: url)
    }

    // MARK: Client (the MCP server)

    struct Client: NoteStore {
        let directory: URL

        func send(_ request: NotesRequest) async throws -> NotesReply {
            try NoteRequestSpool.ensure(directory)
            let id = UUID().uuidString
            let requestURL = directory.appendingPathComponent("\(id).json")
            let replyURL = directory.appendingPathComponent("\(id).reply.json")
            try NoteRequestSpool.writeAtomically(try JSONEncoder().encode(request), to: requestURL)
            let deadline = Date().addingTimeInterval(TimeInterval(request.timeout.components.seconds) + 10)
            while Date() < deadline {
                if let data = try? Data(contentsOf: replyURL) {
                    try? FileManager.default.removeItem(at: replyURL)
                    let reply = try JSONDecoder().decode(NotesReply.self, from: data)
                    if case .failed(let error) = reply { throw error }
                    return reply
                }
                try await Task.sleep(for: .milliseconds(150))
            }
            try? FileManager.default.removeItem(at: requestURL)
            throw NotesBridgeError.timedOut
        }

        func plaintext(ids: [String]) async throws -> [String: String] {
            guard case .texts(let texts) = try await send(.plaintext(ids: ids)) else { throw NotesBridgeError.badOutput }
            return texts
        }

        func createNote(folder: String, html: String) async throws -> String {
            guard case .created(let id) = try await send(.create(folder: folder, html: html)) else { throw NotesBridgeError.badOutput }
            return id
        }

        func setBody(noteID: String, html: String) async throws {
            guard case .done = try await send(.setBody(noteID: noteID, html: html)) else { throw NotesBridgeError.badOutput }
        }

        func folder(ofNote id: String) async throws -> String? {
            do {
                guard case .folder(let name) = try await send(.folderOf(noteID: id)) else { throw NotesBridgeError.badOutput }
                return name
            } catch NotesBridgeError.scriptFailed {
                return nil   // the note is gone
            }
        }
    }

    // MARK: Server (the index service)

    @MainActor
    final class Server {
        private static let logger = Logger(subsystem: AppIdentity.bundleID, category: "NoteRequestSpool")
        private let directory: URL
        private let bridge = NotesBridge()
        private var source: DispatchSourceFileSystemObject?
        private var descriptor: Int32 = -1
        private var busy = false
        private var served = 0

        init(directory: URL) { self.directory = directory }

        /// Watches the directory (plus a slow timer in case a wake is missed) and serves what is there now.
        /// Refuses to serve a directory this user does not own with mode 700.
        func start() {
            do { try NoteRequestSpool.ensure(directory) } catch {
                Self.logger.error("spool directory could not be created")
                return
            }
            guard NoteRequestSpool.isPrivate(directory) else {
                Self.logger.error("spool directory is not owned by this user with mode 700; note writes disabled")
                print("\(ISO8601DateFormatter().string(from: Date())) note requests disabled: spool directory must be owned by this user with mode 700"); fflush(stdout)
                return
            }
            descriptor = open(directory.path, O_EVTONLY)
            if descriptor >= 0 {
                let s = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: .write, queue: .main)
                s.setEventHandler { [weak self] in Task { @MainActor in self?.drain() } }
                s.resume()
                source = s
            }
            Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in Task { @MainActor in self?.drain() } }
            drain()
        }

        var requestsServed: Int { served }

        private func pending() -> [URL] {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
            return names.filter { $0.hasSuffix(".json") && !$0.hasSuffix(".reply.json") }.sorted()
                .map { directory.appendingPathComponent($0) }
        }

        private func drain() {
            guard !busy else { return }
            busy = true
            Task { @MainActor in
                defer { busy = false }
                for url in pending() { await serve(url) }
                sweepStaleReplies()
            }
        }

        private func serve(_ url: URL) async {
            guard let data = try? Data(contentsOf: url) else { return }
            let reply: NotesReply
            if let request = try? JSONDecoder().decode(NotesRequest.self, from: data) {
                reply = await run(request)
            } else {
                reply = .failed(.badOutput)
            }
            let replyURL = directory.appendingPathComponent(url.deletingPathExtension().lastPathComponent + ".reply.json")
            do {
                try NoteRequestSpool.writeAtomically(try JSONEncoder().encode(reply), to: replyURL)
            } catch {
                Self.logger.error("spool reply could not be written")
            }
            try? FileManager.default.removeItem(at: url)
            served += 1
        }

        /// The scope rules live here; see the type comment.
        private func run(_ request: NotesRequest) async -> NotesReply {
            do {
                switch request {
                case .list, .show:
                    return .failed(.permissionDenied)
                case .folderOf(let noteID):
                    guard let name = try await bridge.folder(ofNote: noteID) else { return .failed(.scriptFailed("no such note")) }
                    return .folder(name)
                case .create(let folder, let html):
                    guard folder == NoteRequestSpool.folder, NoteRequestSpool.isOurHTML(html) else { return .failed(.permissionDenied) }
                    return .created(id: try await bridge.createNote(folder: folder, html: html))
                case .plaintext(let ids):
                    guard ids.count <= NoteRequestSpool.maxReadIDs else { return .failed(.permissionDenied) }
                    for id in ids where try await bridge.folder(ofNote: id) != NoteRequestSpool.folder { return .failed(.permissionDenied) }
                    return .texts(try await bridge.plaintext(ids: ids))
                case .setBody(let noteID, let html):
                    guard NoteRequestSpool.isOurHTML(html), try await bridge.folder(ofNote: noteID) == NoteRequestSpool.folder else { return .failed(.permissionDenied) }
                    try await bridge.setBody(noteID: noteID, html: html)
                    return .done
                }
            } catch let error as NotesBridgeError {
                return .failed(error)
            } catch {
                return .failed(.scriptFailed(error.localizedDescription))
            }
        }

        /// A reply nobody collected (the caller gave up) is removed after ten minutes.
        private func sweepStaleReplies() {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
            for name in names where name.hasSuffix(".reply.json") {
                let url = directory.appendingPathComponent(name)
                if let modified = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date,
                   Date().timeIntervalSince(modified) > 600 {
                    try? FileManager.default.removeItem(at: url)
                }
            }
        }
    }
}
