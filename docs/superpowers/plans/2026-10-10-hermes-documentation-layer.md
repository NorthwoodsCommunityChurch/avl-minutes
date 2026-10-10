# Hermes Documentation Layer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Hermes keeps Aaron's documentation in his Apple Notes (folder "Hermes"), captures facts as he states them, tidies nightly, and stops losing them to context compression; and the tool bridge that looped her twice is turned off.

**Architecture:** Plumbing in code (note model + writer in MinutesKit, two MCP tools on the helper, feed prompts in their own Hermes thread in the relay, config), judgment in Hermes (SOUL.md schema, relay-note capture sentence, a nightly tidy cron job). The note is plain text with a fixed section vocabulary; the helper renders HTML for Notes and reads plain text back.

**Tech Stack:** Swift 6 / MinutesKit + MCP Swift SDK (helper), Node (relay, node --test), Hermes 0.21.6 config.yaml + SOUL.md + cron, Apple Notes via AppleScript (existing NotesBridge).

**Spec:** [docs/superpowers/specs/2026-10-10-hermes-documentation-layer-design.md](../specs/2026-10-10-hermes-documentation-layer-design.md)

## Global Constraints

- Hermes writes only inside the Apple Notes folder "Hermes" (`HermesNote.folder`); his notes are never read for writing or changed.
- Writes go through AppleScript (NotesBridge), never the Notes database.
- A note stays under 8,000 characters; "Hermes index" under 4,000 (`HermesNote.maxCharacters`, `maxIndexCharacters`).
- Section names are exactly: Summary, Facts, Decisions, Open questions, People, Next, Items, Log.
- No deletes anywhere; no secrets in git; logs never carry note text.
- Model stays local (`gemma-bigctx` or `qwen-coder` per bake-off); no API spend.

## Review Focus

1. A note Aaron renames or moves out of the Hermes folder: `note_write` must create a fresh note rather than edit the moved one (writer matches title only inside the folder; test `writerCreatesInTheHermesFolderAndNeverTouchesNotesElsewhere`).
2. Notes returns headings as bare lines: a line that merely *equals* a section name inside a section ("Next" as a bullet text would be "- Next", fine; a bare "Next" line starts a section by design). Documented in `HermesNote.parse`.
3. A `text` with HTML characters must not break the note: `escape` covers `& < > "` (test `htmlIsOneDivPerLineWithEscapingAndHeadings`).
4. A feed event that used to rely on Aaron's chat history ("if he told you earlier in this conversation") now has none: the SOUL rule drops that clause and reads the board and notes (Task 5).
5. With the bridge off, every tool schema is in the prompt: Planka is filtered to `cards`; if a one-shot shows worse answers the block is removed (Task 6 verification).

---

### Task 1: HermesNote model (parse, render, upsert) — DONE 2026-10-10

**Files:** Create `Packages/MinutesKit/Sources/MinutesKit/Tools/HermesNote.swift`, `Packages/MinutesKit/Tests/MinutesKitTests/HermesNoteTests.swift`.
**Interfaces:** Produces `HermesNote` (`parse(plainText:)`, `plainText`, `html`, `upsert(section:text:mode:)`, `sectionName(_:)`, constants), `HermesNoteError`.
- [x] Tests: round trip, headings without markers, HTML escaping, upsert append/replace/unknown/empty.
- [x] `swift test --package-path Packages/MinutesKit` green.

### Task 2: NoteStore protocol and HermesNoteWriter — DONE 2026-10-10

**Files:** same source file; tests in `HermesNoteTests.swift` with `FakeStore`.
**Interfaces:** `protocol NoteStore { listMetadata(); plaintext(ids:); createNote(folder:html:); setBody(noteID:html:) }` (matches `NotesBridge`); `HermesNoteWriter(store:folder:)` with `write(title:section:text:mode:) async throws -> String` and `create(title:body:) async throws -> String`.
- [x] Tests: create in Hermes folder when only his note has that title; append to an existing Hermes note; replace; sizes; duplicates; empty title/body.

### Task 3: MCP tools `note_write` / `note_create` and helper wiring — DONE 2026-10-10

**Files:** `Packages/MinutesKit/Sources/MinutesMCP/MinutesMCPServer.swift` (`noteTools`, `tools(taskBoardConfigURL:notes:)`, `noteCall(name:arguments:store:)`, `run(... noteStore:)`), `Packages/MinutesKit/Tests/MinutesMCPTests/MinutesMCPTests.swift`, `HermesHelper/HermesHelperMain.swift` (passes `NotesBridge()`), `Shared/Notes/NotesBridge.swift` (`extension NotesBridge: NoteStore {}`).
- [x] Test `noteToolsAreListedOnlyWithAStoreAndWriteThroughIt`.
- [ ] Deploy: `bash scripts/deploy-helper.sh`; stdio check that `tools/list` shows `note_write`, `note_create`; one `note_write` to "Hermes log" from the shell; confirm the note appears in Notes on the mini and in `list_notes folder: Hermes` two minutes later.

### Task 4: Relay: feed prompts in their own Hermes thread — DONE 2026-10-10 (deploy pending)

**Files:** `hermes-teams/lib/relay.js` (`FEED_CONVERSATION = "feed"`, `runFeedEvent` asks with it), `hermes-teams/test/notify.test.js`.
- [x] `npm test` green (45).
- [ ] Deploy: `bash hermes-teams/scripts/deploy-teams-relay.sh` between turns.

### Task 5: SOUL.md "Your notes" schema and the relay-note capture sentence

**Files:** `hermes-tools/SOUL.md`, `hermes-teams/lib/relay.js` (RELAY_NOTE).

- [ ] Step 1: Add to `RELAY_NOTE`, after the ticket/person sentence: `If this message states a fact, a decision, a measurement, a plan, or an open question about a project, a person, or an event, write it into that thing's note with note_write before you answer (section Facts, Decisions, Open questions, or Next; end each line with the date in parentheses) and confirm in two words, like "Noted in Atrium".`
- [ ] Step 2: Add a `## Your notes` section to `SOUL.md`:

```
## Your notes
- You keep Aaron's documentation in the "Hermes" folder of his Apple Notes with note_write and note_create. These are your notes; every other folder is his and you never change it. One note per project ("Project: Atrium"), per person or vendor outside the staff ("Brian Turnbull (House Right)"), and per standing list ("List: Scrum plan", "List: Orders", "List: Christmas"). Two more: "Hermes index" (one line per note: title, then a one-sentence summary) and "Hermes log" (one dated line per change worth remembering).
- Sections, in this order and with these names only: Summary (two lines, what it is and where it stands), Facts (measurements, counts, dates, names), Decisions (what was decided, with whom), Open questions (what still needs an answer, and who answers it), People (who is involved), Next (what happens next, with dates), Items (for lists), Log (dated one-liners). Every line ends with its date in parentheses: "- Walls go in Friday Oct 16. (Oct 8)". Say who told you when it matters: "(Oct 8, Blake)".
- When Aaron states something about a project, a person, or an event, write it before you answer: get_note the note first if it exists (search_notes with folder "Hermes"), then note_write the one or two lines, then confirm in two words ("Noted in Atrium"). A new project or person gets a note with note_create and a line in "Hermes index" the same turn. Never write what you were not told; never rewrite a note from memory.
- "My notes on X" means: open "Project: X" (or the person's note) first, then search everything with no folder, then answer from the note and the newest hits.
- Keep notes short: under 8,000 characters (the tool refuses more); move old Log lines out with note_write mode "replace" when a section grows past about forty lines; "Hermes index" stays under 4,000.
```
- [ ] Step 3: Change the sent-mail rule: remove "If no card matches but he told you earlier in this conversation that he needed to send it, create the card and move it to Done in the same turn, then tell him." Replace with: "If no card matches, reply NO_MESSAGE; the board is the record."
- [ ] Step 4: Meeting prep rule: add "and the project's or person's note in the Hermes folder" to the gather list.
- [ ] Step 5: `cd hermes-teams && npm test`; `bash scripts/deploy-soul.sh`; `bash hermes-teams/scripts/deploy-teams-relay.sh`.
- [ ] Step 6: Commit: `git add hermes-tools/SOUL.md hermes-teams/lib/relay.js && git commit -m "SOUL + relay note: Hermes keeps her notes in Apple Notes; capture before answering; feed prompts read notes not chat"`.

### Task 6: Hermes config: tool bridge off, Planka filtered

**Files:** `~/.hermes/config.yaml` on edit-3 (backup `config.yaml.bak-20261010-bridge`).

- [ ] Step 1: After the bake-off's baseline finishes (`~/bakeoff/gemma-on/timings.txt` ends with "=== done"), append to config.yaml:
```yaml
tools:
  tool_search:
    enabled: "off"
```
and under `mcp_servers.planka` add `    tools:\n      include: [cards]`.
- [ ] Step 2: `hermes doctor` on the mini; `bash ~/bakeoff/run.sh gemma-off gemma-bigctx`, then `bash ~/bakeoff/run.sh qwen-off qwen-coder`.
- [ ] Step 3: Compare `timings.txt` and the one-shot sessions (tool calls, loop warnings, answers). Keep the block if no task got worse; otherwise delete it and record why in CLAUDE.md.
- [ ] Step 4: `hermes gateway restart` between turns (the config is read at start).

### Task 7: Nightly tidy job

- [ ] Step 1: On the mini: `hermes cron create "every day at 11pm" --name "Nightly notes tidy" --deliver local "<prompt>"` with the prompt:

```
Tidy Hermes's notes for today. 1) current_time, then search_notes with folder "teams", query "Aaron Larson", since today's date, limit 50: these are Aaron's own messages to you today. 2) get_note "Hermes index". 3) For each message that states a fact, decision, measurement, plan, or open question about a project, person, or event: get_note that note and, if the line is missing, note_write it with its date. 4) list_notes with folder "Hermes": any note missing from "Hermes index" gets its line added there. 5) note_write "Hermes log", section Log, one line: today's date and what you added (or "nothing new"). Reply exactly [SILENT] unless two notes contradict each other; then reply one line naming both notes and the contradiction.
```
- [ ] Step 2: `hermes cron run <id>` once by hand; read `~/.hermes/cron/output/<id>/*.md`; confirm the log line in Notes.

### Task 8: Live check with Aaron

- [ ] Aaron tells her one fact in Teams ("the atrium drop ceiling is 9 ft"); expected: "Noted in Atrium" within a minute of her turn, and the note on his phone.
- [ ] Next morning: "Hermes log" has a dated line; meeting prep still arrives (feed thread works without chat history).

### Task 9: Docs

- [ ] CLAUDE.md: Status, Architecture (notes layer), Where things live (`HermesNote.swift`), Key identifiers (Hermes folder, index/log notes, tidy job id, config block), gotchas (headings come back bare; bridge off; feed thread), history row. README: one sentence.
- [ ] Commit and push.

### Task 10: Model decision from the bake-off

- [ ] Record the three runs' results in `docs/research/2026-10-10-hermes-documentation-layer-research.md` (new section "Bake-off results").
- [ ] If `qwen-coder` wins on tool-following without losing answer quality: `model.default: "qwen-coder"` on the mini (backup), `hermes gateway restart`, CLAUDE.md row. Otherwise stay on Gemma and say why.
