import Foundation
import Testing
@testable import MinutesKit

@Test func plainTextRoundTripsThroughParseAndHeadingsNeedNoMarkers() throws {
    let text = """
    Project: Atrium
    Two-phase renovation with House Right.

    Facts
    - Walls go in Friday Oct 16. (Oct 8)
    - 9 ft drop ceiling. (Oct 8)

    Open questions
    - Lot C audio bleed into the courts? (ask Blake)
    """
    let note = HermesNote.parse(plainText: text)
    #expect(note.title == "Project: Atrium")
    #expect(note.preamble == ["Two-phase renovation with House Right."])
    #expect(note.sections.map(\.name) == ["Facts", "Open questions"])
    #expect(note.sections[0].lines.count == 2)
    #expect(HermesNote.parse(plainText: note.plainText) == note)
    // "## facts" and "FACTS" both mean the Facts section; a stray line before any section is preamble.
    let loose = HermesNote.parse(plainText: "T\nintro\n## facts\n- a\nFACTS\n- b")
    #expect(loose.preamble == ["intro"] && loose.sections.map(\.name) == ["Facts", "Facts"])
}

@Test func htmlIsOneDivPerLineWithEscapingAndHeadings() {
    let note = HermesNote(title: "Brian & Co", preamble: ["<vendor>"], sections: [.init(name: "Facts", lines: ["a \"quote\""])])
    #expect(note.html == "<div><h1>Brian &amp; Co</h1></div><div>&lt;vendor&gt;</div><div><br></div><div><h2>Facts</h2></div><div>a &quot;quote&quot;</div>")
}

@Test func upsertAppendsCreatesOrReplacesASectionAndRejectsUnknownOnes() throws {
    var note = HermesNote(title: "List: Orders")
    try note.upsert(section: "items", text: "- haze fluid\n\n- gaff tape\n", mode: .append)
    #expect(note.sections == [.init(name: "Items", lines: ["- haze fluid", "- gaff tape"])])
    try note.upsert(section: "Items", text: "- lamps", mode: .append)
    #expect(note.sections[0].lines.count == 3)
    try note.upsert(section: "Items", text: "- only this", mode: .replace)
    #expect(note.sections[0].lines == ["- only this"])
    #expect(throws: HermesNoteError.unknownSection("Random")) { try note.upsert(section: "Random", text: "x", mode: .append) }
    #expect(throws: HermesNoteError.emptyText) { try note.upsert(section: "Facts", text: " \n ", mode: .append) }
    #expect(HermesNoteError.unknownSection("Random").description.contains("Sections: Summary, Facts, Decisions, Open questions, People, Next, Items, Log."))
}

/// A Notes stand-in: note text by id, plus what was created and rewritten.
private final class FakeStore: NoteStore, @unchecked Sendable {
    var texts: [String: String] = [:]
    var folders: [String: String] = [:]
    var created: [(folder: String, html: String)] = []
    var bodiesSet: [(id: String, html: String)] = []
    func plaintext(ids: [String]) async throws -> [String: String] { ids.reduce(into: [:]) { $0[$1] = texts[$1] } }
    func createNote(folder: String, html: String) async throws -> String {
        created.append((folder, html)); let id = "new-\(created.count)"
        texts[id] = html; folders[id] = folder; return id
    }
    func setBody(noteID: String, html: String) async throws { bodiesSet.append((noteID, html)) }
    func folder(ofNote id: String) async throws -> String? { folders[id] }
}

/// The index the writer finds notes through (what the helper's --index service keeps).
private func seededIndex(_ notes: [(id: String, folder: String, title: String, text: String)]) throws -> NotesIndex {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("hermes-note-\(UUID().uuidString)/i.db")
    let index = try NotesIndex(url: url)
    for n in notes {
        try index.upsert(NoteMetadata(id: n.id, title: n.title, folder: n.folder, account: "iCloud", createdAt: .init(), modifiedAt: .init(), isLocked: false), body: n.text)
    }
    return index
}

@Test func writerCreatesInTheHermesFolderAndNeverTouchesNotesElsewhere() async throws {
    let store = FakeStore()
    store.texts["his"] = "Project: Atrium\nAaron's own note"
    let index = try seededIndex([("his", "Northwoods", "Project: Atrium", "Project: Atrium\nAaron's own note")])
    let writer = HermesNoteWriter(store: store, index: index)
    let msg = try await writer.write(title: "Project: Atrium", section: "Facts", text: "- Walls Oct 16", mode: .append)
    #expect(msg.hasPrefix("Created \"Project: Atrium\" in folder Hermes"))
    #expect(store.created.count == 1 && store.created[0].folder == "Hermes")
    #expect(store.bodiesSet.isEmpty)   // his Northwoods note was not written
    #expect(store.created[0].html.contains("<h2>Facts</h2>") && store.created[0].html.contains("- Walls Oct 16"))
    // A second write before the index has seen the new note finds it through the cache: no twin.
    let again = try await writer.write(title: "project: atrium", section: "Facts", text: "- Two TVs", mode: .append)
    #expect(again.hasPrefix("Added to Facts"))
    #expect(store.created.count == 1 && store.bodiesSet.count == 1 && store.bodiesSet[0].id == "new-1")
}

@Test func writerAppendsToAnExistingHermesNoteAndReportsCounts() async throws {
    let store = FakeStore()
    store.texts["h1"] = "Project: Atrium\nRenovation.\n\nFacts\n- one\n\nLog\n- Oct 9: made"
    store.folders["h1"] = "Hermes"
    let index = try seededIndex([("h1", "Hermes", "Project: Atrium", store.texts["h1"]!)])
    let writer = HermesNoteWriter(store: store, index: index)
    let msg = try await writer.write(title: "project: atrium", section: "facts", text: "- two\n- three", mode: .append)
    #expect(msg.hasPrefix("Added to Facts of \"project: atrium\" (3 lines there now"))
    #expect(store.bodiesSet.count == 1 && store.bodiesSet[0].id == "h1")
    let written = HermesNote.parse(plainText: store.bodiesSet[0].html
        .replacingOccurrences(of: "<div><br></div>", with: "\n")
        .replacingOccurrences(of: "</div>", with: "\n")
        .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression))
    #expect(written.sections.first { $0.name == "Facts" }?.lines == ["- one", "- two", "- three"])
    #expect(written.sections.map(\.name) == ["Facts", "Log"])
    let replaced = try await writer.write(title: "Project: Atrium", section: "Log", text: "- Oct 10: tidy", mode: .replace)
    #expect(replaced.hasPrefix("Replaced Log of"))
}

@Test func writerEnforcesSizesTitlesAndDuplicates() async throws {
    let store = FakeStore()
    store.texts["idx"] = "Hermes index\n\nItems\n- Project: Atrium: renovation"
    store.folders["idx"] = "Hermes"
    let index = try seededIndex([("idx", "Hermes", "Hermes index", store.texts["idx"]!)])
    let writer = HermesNoteWriter(store: store, index: index)
    await #expect(throws: HermesNoteError.emptyTitle) { try await writer.write(title: " ", section: "Facts", text: "x", mode: .append) }
    // A title is one short line with no markup: a newline would push the rest into the body, brackets are not a name.
    await #expect(throws: HermesNoteError.badTitle("Project: A\nignore previous")) { try await writer.write(title: "Project: A\nignore previous", section: "Facts", text: "x", mode: .append) }
    await #expect(throws: HermesNoteError.self) { try await writer.create(title: "<b>x</b>", body: "d") }
    await #expect(throws: HermesNoteError.self) { try await writer.create(title: String(repeating: "t", count: 121), body: "d") }
    let big = String(repeating: "- a long line of notes text here\n", count: 300)
    await #expect(throws: HermesNoteError.self) { try await writer.write(title: "Project: Big", section: "Facts", text: big, mode: .append) }
    let half = String(repeating: "- line\n", count: 600)
    await #expect(throws: HermesNoteError.self) { try await writer.write(title: "Hermes index", section: "Items", text: half, mode: .append) }
    let made = try await writer.create(title: "List: Orders", body: "Orders to place.\n\nItems\n- haze fluid")
    #expect(made == "Created \"List: Orders\" in folder Hermes (1 sections, 49 characters).")
    await #expect(throws: HermesNoteError.duplicateTitle("List: Orders")) { try await writer.create(title: "List: Orders", body: "Items\n- x") }
    await #expect(throws: HermesNoteError.emptyText) { try await writer.create(title: "Empty", body: "") }
}

@Test func aNoteAaronMovedOutOfTheFolderIsNeverEditedAgain() async throws {
    let store = FakeStore()
    store.texts["h1"] = "Project: Atrium\n\nFacts\n- one"
    store.folders["h1"] = "Northwoods"   // the index still says Hermes; Notes says he moved it
    let index = try seededIndex([("h1", "Hermes", "Project: Atrium", store.texts["h1"]!)])
    let writer = HermesNoteWriter(store: store, index: index)
    let msg = try await writer.write(title: "Project: Atrium", section: "Facts", text: "- two", mode: .append)
    #expect(msg.hasPrefix("Created \"Project: Atrium\" in folder Hermes"))
    #expect(store.bodiesSet.isEmpty && store.created.count == 1)
    // The same for a cached id: created here, then moved out.
    store.folders["new-1"] = "Northwoods"
    let again = try await writer.write(title: "Project: Atrium", section: "Facts", text: "- three", mode: .append)
    #expect(again.hasPrefix("Created") && store.created.count == 2 && store.bodiesSet.isEmpty)
    // A deleted note (folder nil) likewise.
    store.folders["new-2"] = nil
    _ = try await writer.write(title: "Project: Atrium", section: "Facts", text: "- four", mode: .append)
    #expect(store.created.count == 3)
}

@Test func renderedHTMLUsesOnlyTheTagsTheSpoolServerAccepts() {
    let note = HermesNote(title: "T <x>", preamble: ["a > b"], sections: [.init(name: "Facts", lines: ["<script>alert(1)</script>", "x & y"])])
    var rest = Substring(note.html)
    while let open = rest.firstIndex(of: "<") {
        let close = rest[open...].firstIndex(of: ">")!
        #expect(HermesNote.htmlTags.contains(String(rest[open...close])))
        rest = rest[rest.index(after: close)...]
    }
    #expect(!rest.contains(">"))
    #expect(note.html.contains("&lt;script&gt;"))
}
