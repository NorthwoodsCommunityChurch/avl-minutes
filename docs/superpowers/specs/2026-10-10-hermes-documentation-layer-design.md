# Hermes documentation layer: design

**Date:** 2026-10-10 · **Status:** approved in direction by Aaron 2026-10-10 ("I think you've nailed what I want
hermes to do"), additions (tool bridge off, model test on the existing Qwen) approved the same day ("Go ahead and get
to work"). Research behind it: [2026-10-10-assistant-platform-options.md](../../research/2026-10-10-assistant-platform-options.md)
and [2026-10-10-hermes-documentation-layer-research.md](../../research/2026-10-10-hermes-documentation-layer-research.md).
Builds on [2026-10-09-hermes-initiative-design.md](2026-10-09-hermes-initiative-design.md).

## 1. What Aaron asked for

> "She has access to the planka board, but there is SO much more I've told her directly about. It seems to me that I
> keep coming back to you for her memory, that she's not maintaining good documentation. In my mind, that's what she
> is for: creating and maintaining lists, projects, to do, calendars. All of that kind of stuff and more."

Constraints he set the same day: no Claude API spend, no new hardware; the model stays local on the AI box (Gemma 4
31B today; the box also serves `qwen-coder`, to be tested).

## 2. Why she does not keep documentation today

- Her only durable store is the task board (cards) plus a flat `MEMORY.md` of about twenty one-line facts. Everything
  else Aaron tells her lives in the Teams thread, which Hermes compresses at 50% of a 65K context; six compressions in
  three days, each one the moment she "forgot" (research doc 2, section 2).
- What he told her is not lost: the feed index holds his own Teams messages to her (folder `teams`, titled
  "Aaron Larson: …"), and the helper's search finds them. But nothing organizes them; "my notes on the atrium" means a
  search, not a document, and a search ranked by relevance cut at 20 hid the newest items (2026-10-09).
- Hermes's deferred-tool bridge (`tool_search` / `tool_call`) fails with small local models: Hermes issues #110442,
  #135762, #96247 describe our two runaway `read_file` loops exactly, and the docs give one workaround:
  `tools.tool_search.enabled: off`.

## 3. Shape

The design is Karpathy's "LLM wiki" pattern mapped onto things Aaron already uses, with our standing rule: plumbing
(stores, tools, wake-ups, sessions) in code; judgment (what is worth writing, how to say it) in Hermes.

| Wiki layer | Ours |
|---|---|
| Raw sources, never edited by the agent | The feed index (mail, calendar, Teams incl. his messages to her), his own Apple Notes, Minutes transcripts, the board |
| Compiled wiki, agent-maintained | Apple Notes, folder **Hermes**: one note per project, person or vendor, and list |
| Schema | A "Your notes" section of `SOUL.md`: note types, names, sections, when to write |
| Index | The note **Hermes index**: one line per note with its one-sentence summary |
| Log | The note **Hermes log**: dated lines appended by the nightly tidy and by notable captures |
| Ingest | The relay note under each of Aaron's messages: write the fact before answering |
| Query | `search_notes` (no folder) and `get_note`, as today, now finding her notes too |
| Lint | A nightly cron job (deliver local): fill gaps from the day's messages, check the index, flag contradictions |

Four pieces, in build order:

### 3.1 Tool bridge off, MCP tools filtered (config)

`~/.hermes/config.yaml` gains

```yaml
tools:
  tool_search:
    enabled: "off"
mcp_servers:
  planka:
    tools:
      include: [cards]        # the only Planka tool the rules use (create, update, list)
```

Every remaining tool's schema sits in the prompt: notes (6 + task_board), Planka cards, Planning Center (3 to 4), and
Hermes's core tools. The deferred catalog already cost about 4K tokens a turn, so the net change is small; the
`tool_call` bridge disappears, and with it the "read_file is a directly-listed tool" loop. Verified by one-shots
before the gateway restarts (section 6); reverted by deleting the block if a task gets worse.

### 3.2 The notes store and the helper's write tools

**Where.** Apple Notes on the mini, which is signed into Aaron's iCloud, folder **Hermes** (created by the helper if
missing). Notes sync to his phone and laptop; the helper indexes them like any other note, so she searches and reads
them with the existing tools. She never writes outside that folder; his own notes stay his.

**Note shapes** (plain text with `## ` section headings; the helper renders them as HTML for Notes and reads them back
as plain text):

```
Project: Atrium
## Summary
Two-phase renovation with House Right (Brian Turnbull); atrium first, lobby and connection center after Christmas; ~$130k.
## Facts
- Nursing mothers: two TVs on opposite walls (entrance wall high, other low), 9 ft drop ceiling. (Oct 8)
- Walls go in Friday Oct 16. (Oct 8)
## Decisions
- Keep the existing conduit and add one larger one. (Oct 8, with Blake)
## Open questions
- Does the lot C audio bleed into the courts and playgrounds? (ask Blake)
## People
Brian Turnbull (House Right), Blake, Jason, Kirk
## Log
- Oct 10: added lot C question from Aaron's 3 PM agenda.
```

Types and names: `Project: <name>`, `<Person> (<org>)` for people and vendors, `List: <name>` for standing lists
(scrum plan, orders, Christmas), plus **Hermes index** and **Hermes log**. The sections above are the full set;
a note never grows past about 8,000 characters (the helper refuses and says so, so Hermes splits or trims); the
index stays under 4,000.

**Tools** (helper MCP server, listed only where the Notes folder is writable, i.e. the mini):

| Tool | Arguments | Does |
|---|---|---|
| `note_write` | `title`, `section`, `text`, `mode` (`append` default, or `replace`) | Finds the note by exact title in folder Hermes (creates it with that title if absent), appends `text` as new lines at the end of `section` (creating the section if absent) or replaces the section's lines; writes the whole body back through AppleScript; returns the note's new length and the section's line count |
| `note_create` | `title`, `body` | Creates a note in folder Hermes from the plain-text shape above; refuses a duplicate title |

Both read the live body first (through the `--notes-helper` child, not the index, which can be two minutes stale),
compare the note's modification time before writing, and retry once on a mismatch; they never touch attachments
(her notes have none), never delete, never move. A title that resolves to a note outside the Hermes folder is an
error. All text is escaped before it becomes HTML.

### 3.3 Capture: the rule next to the message, and the schema in SOUL.md

The relay note gains one sentence: *"If this message states a fact, a decision, a measurement, a plan, or an open
question about a project, a person, or an event, write it into that thing's note with note_write before you answer,
and confirm in two words ('Noted in Atrium')."* `SOUL.md` gets a **Your notes** section that holds the schema: the
note types and names, the sections and what goes in each, the dating convention ("(Oct 8)"), the rule to read a note
with `get_note` before adding to it, the size limits, the index line format, and the standing instruction that his
Apple Notes outside the Hermes folder are read-only. "My notes on X" now reads: search with no folder, then open
`Project: X` first if it exists.

### 3.4 The nightly tidy, and feed events in their own session

**Tidy** is a Hermes cron job (daily at 11 PM, deliver local, name "Nightly notes tidy"). Its prompt: list today's
messages from Aaron (`search_notes`, folder `teams`, since today, query `"Aaron Larson"`), read **Hermes index**,
and for each message that states something about a project, person, or event, check that its note holds it; add what
is missing with `note_write`; make sure every note in folder Hermes has an index line; append one dated line to
**Hermes log** saying what changed; reply `[SILENT]` unless two notes contradict each other, in which case reply one
line naming them (the relay posts it to Teams).

**Feed events** (calendar changes, sent mail, meeting prep) stop sharing Aaron's thread. The relay keys Hermes
conversations by `previous_response_id`; it gives automated prompts their own key (`feed`), so they run in a session
that holds no chat history and reads the notes, the board, and the index instead. The sent-mail rule's clause "if he
told you earlier in this conversation" is dropped; the card is the record. Aaron's thread shrinks to his own
messages and her replies, so it crosses the 50% compression line far less often.

## 4. Model

The box serves `gemma-bigctx` (today) and `qwen-coder`. The bake-off runs six real tasks as one-shots against each,
bridge on and off: his to-do, "my notes on atrium from yesterday", a message that needs a card and a search, a
forced oversized result, and a sent-mail feed event that should close a test card. Scored on: right tool calls, right
answer, seconds, loop warnings. The winner becomes `model.default`; nothing else in this design depends on it.

## 5. Security

- Hermes can create and edit notes only inside the Hermes folder; the helper enforces it, not the rules.
- Writes go through AppleScript only (never the Notes database), the same path Minutes uses for transcripts.
- Outside text (feed records) stays inside the nonce-tagged untrusted block; a note's content is Hermes's own words
  and is treated like her replies, which Aaron already reads.
- No secrets anywhere new; the notes hold church business facts in Aaron's own iCloud, where his notes already live.
- Nothing is deleted by any tool or rule; a wrong note is fixed by a `replace` of one section, visible in the Log.

## 6. Testing

- Unit (MinutesKit): plain-text ↔ HTML rendering round-trips; section append/replace on a body with and without the
  section; size limits; folder guard; title duplicate refusal. MCP: tools listed only when the folder is writable;
  argument errors are tool errors.
- Relay (node --test): feed and meeting prompts use the `feed` conversation key; Aaron's messages keep theirs.
- Live, before the gateway restart: one-shots for each bake-off task with the new config. After: Aaron tells her
  one fact ("the atrium drop ceiling is 9 ft") and sees "Noted in Atrium" and the note on his phone; the first
  tidy run's log line; a feed event answered without his thread.

## 7. Rollout (what Aaron experiences)

1. **This session:** bake-off results and the bridge setting (no visible change except fewer failures).
2. **This session:** note tools, SOUL schema, relay note capture; Aaron's test: tell her one fact, open the note.
3. **Next session, after a day of use:** nightly tidy and the feed session; Aaron's test: look at Hermes log the next
   morning, confirm meeting prep still arrives.

## 8. Cost

Each captured fact is one `note_write` (a few hundred milliseconds of AppleScript, one extra tool call in the turn);
the tidy job is one Puget run a night. Eager tool schemas add a few thousand tokens a turn at most. Compressions of
Aaron's thread drop because automated traffic leaves it.

## 9. Rulings

- Her notes, not his: she never edits a note outside the Hermes folder, even one named like a project (his
  "Atrium" note in Northwoods stays his). He can move text between them himself.
- Plain text with `## ` headings, not rich formatting: the helper owns the rendering, and plain text survives the
  index and the model.
- The index is a note, not a file: it has to be visible on his phone like everything else.
- No memory-provider plugin yet: the relay note is the per-turn hook this model follows; a plugin can come later
  if captures are missed.
