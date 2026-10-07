# Minutes — design spec

**Date:** 2026-10-05 (revised same day: transcripts live in Apple Notes)
**Status:** approved in conversation 2026-10-05 ("approved, build it"; Notes
revision: "it can be in iCloud, in its own folder"). The UI section (§7) is superseded by
[DESIGN.md](../../../DESIGN.md) — Apple native, 2026-10-07.
**Working name:** Minutes (rename freely; bundle ID `com.northwoods.Minutes`)

## 1. Purpose

Aaron wants one synced place — Apple Notes — that holds both his own notes and
transcripts of his meetings, so a personal assistant (Claude) can search all of
it and answer questions like "what did we decide about the lobby screens last
Tuesday?" or "what did I promise Dan?". Aaron does not search the notes
himself; Claude does.

The hard constraint, stated by Aaron and non-negotiable: **audio is never
recorded.** Sound is turned into text in memory and thrown away. Only text is
kept.

### What Aaron said (decisions)

| Topic | Decision |
|---|---|
| Assistant that reads the data | Claude (Claude Code on this Mac) |
| Meetings captured | In-room (Mac mic) **and** calls (Teams/Zoom/browser audio on the Mac) |
| Speaker labels | "Me" vs. others is required; per-person numbering is a bonus. Aaron trains his voice once; others get speaker numbers |
| Start/stop | Always manual |
| What is saved | Transcript only (no auto-summary) |
| Where transcripts live | Apple Notes, iCloud account, in their own folder |
| What Claude can read | All of Aaron's notes plus the transcripts, read-only |
| How Claude reads it | A search server (MCP) |
| Org | Northwoods app (org repo, Sparkle) — default chosen by Claude, Aaron did not object |

### Assumptions (Claude's, open to correction)

- Folder name: **Meeting Transcripts** (changeable in Settings).
- English only, using the Mac's current English locale.
- One Mac (Aaron's M3 Max laptop, macOS 26.5). No iPhone or iPad capture.
- Meetings up to ~3 hours.
- Illinois law: secret recording/transmitting of a private conversation needs
  all-party consent (720 ILCS 5/14-2(a)(2)); the trigger is *surreptitious*
  use. The app reminds Aaron to tell attendees at each Start (does not block;
  can be turned off). Not legal advice.

### Success criteria

1. Over a full meeting, no audio reaches the disk — proven by a file-write
   audit (section 9), not asserted.
2. Aaron's own lines are labeled "Me" correctly in the large majority of a
   clean in-room meeting and essentially always on calls.
3. From any Claude Code session on this Mac, Claude finds the right note or
   transcript passage by searching, not by reading everything.
4. Start → speaking → text visible in the popover within a few seconds.
5. A crash or force-quit mid-meeting loses at most ~30 seconds of transcript.
6. A note Aaron wrote on his iPhone is searchable by Claude within a few minutes
   of iCloud syncing it to this Mac (while Minutes is running).

## 2. Non-goals

- Summaries, action items, or any LLM processing inside the app (Claude does
  that on demand when asked).
- Writing to, editing, or deleting Aaron's own notes. Minutes writes only the
  transcript notes it creates; Claude's access is read-only.
- Automatic meeting detection or calendar integration.
- Identifying people other than Aaron by name automatically.
- A transcript viewer inside Minutes — Notes is the viewer.
- Playback, audio export, or any "keep the audio just this once" option.
- Reading locked (password-protected) notes, attachments, images, or drawings.

## 3. Architecture

One macOS app, `Minutes.app`, with two modes from the same binary:

- **App mode** (normal launch, starts at login): menu bar app that captures,
  transcribes, labels speakers, writes transcript notes into Apple Notes, and
  keeps a local search index of all notes' text up to date.
- **MCP mode** (`Minutes --mcp`): a headless stdio MCP server that Claude Code
  launches on demand. It reads only the local search index (read-only) and
  never talks to Notes, so it needs no macOS permissions of its own. It exits
  when Claude closes the pipe.

```
 Mic ──► MicCapture (AVAudioEngine + voice processing / echo cancel)
                │  16 kHz mono buffers (RAM only)
                ├──► SpeechTranscriber (words + time ranges)
                ├──► Sortformer diarizer (who spoke when, 4 slots)
                └──► VoiceRing (last 60 s, RAM) ──► CAM++ embedder ──► "Me"?
 Mac audio out ─► CallCapture (Core Audio process tap, all apps except Minutes)
                ├──► SpeechTranscriber
                └──► Sortformer diarizer
                                │
                  Attributor → TranscriptDocument (lines, in memory)
                                │ every 30 s and at Stop
                  NotesBridge (Minutes --notes-helper) ──► Apple Notes (iCloud)
                                                             │ iCloud sync ⇄ iPhone/iPad
                 NotesIndexer (every 2 min) ◄────────────────┘
                                │
                     NotesIndex (SQLite FTS5, this Mac) ◄── Minutes --mcp (read-only)
```

### 3.1 Units

| Unit | Responsibility | Depends on |
|---|---|---|
| `MicCapture` | Opens default input with voice processing (echo cancellation, other-audio ducking minimized), takes channel 0, resamples to 16 kHz mono Float32 | AVFAudio |
| `CallCapture` | Global process tap (all processes except Minutes) + private aggregate device read by its own AVAudioEngine; sums channels to mono, resamples to 16 kHz. Watchdog rebuilds the tap if it delivers pure zeros for 10 s while any other process reports `IsRunningOutput` | CoreAudio, AVFAudio |
| `StreamTranscriber` | One per stream. Single-use SpeechAnalyzer + SpeechTranscriber with `.volatileResults` and `.audioTimeRange`; emits volatile text (live UI) and final word runs with times | Speech |
| `StreamDiarizer` | One per stream, own model instance. `SortformerDiarizer` (`.balancedV2_1`, ~1.5 s latency); appends finalized per-frame speaker probabilities (4 slots × 80 ms) to a rolling `SpeakerActivity` window (last 120 s) | FluidAudio |
| `VoicePrint` | Enrollment (≈30 s reading → CAM++ embeddings of 3 s windows → mean, L2-normalized, 192 numbers) and matching (cosine similarity) | FluidAudio CAM++ |
| `SpeakerResolver` | Slot → label. Mic stream: for each attributed line ≥ 1.0 s still inside `VoiceRing`, embeds that audio and compares with the voiceprint; per-slot running vote lets short lines inherit their slot's label. Call stream: Caller n by first appearance | VoicePrint |
| `Attributor` | Pure: each word's dominant slot (highest mean probability over the word's frames, if ≥ 0.3), else previous word's slot, else next word's, else none; consecutive same-slot words become one line. `AttributionQueue` holds a transcript result until diarization covers its end, or 5 s more audio has arrived | — |
| `TranscriptDocument` | Pure: holds a meeting's lines sorted by start time; renders Notes HTML and plain text | — |
| `MeetingSession` | One meeting: starts/stops streams, maps stream time to meeting time, feeds the document, saves through `NotesBridge` every 30 s and at Stop | all above |
| `NotesBridge` | Each Notes call runs `Minutes --notes-helper` as a child process: JSON request on stdin, JSON reply on stdout. The helper runs AppleScript handlers with NSAppleScript on its own main thread (parameters as Apple event descriptors, never spliced into source). Keeps multi-second note writes off the app's main thread. Operations: list notes metadata, read note text, create note (ensuring the folder), replace note body | NSAppleScript |
| `NotesIndexer` | Every 2 minutes (and right after each transcript save): lists all notes' id/name/folder/dates/locked flag in bulk, fetches text only for new or changed notes, removes deleted ones | NotesBridge, NotesIndex |
| `NotesIndex` | SQLite (system libsqlite3, WAL, FTS5) copy of note text. App writes; MCP mode reads | SQLite3 |
| `NotesTools` | Pure text formatting for the four MCP tools | NotesIndex |
| `MCPServer` | MCP stdio wiring | MCP Swift SDK, NotesTools |
| UI | Menu bar popover, Settings, Voice training sheet, first-run screens | SwiftUI |

### 3.2 Clocks and time alignment

Each stream counts samples from its own start. A line's meeting time is
`streamStartOffset + sampleTime`, where `streamStartOffset` is the wall-clock
difference between the meeting's Start and the stream's first buffer. The
transcriber's `audioTimeRange` and the diarizer's frame times share one sample
timeline per stream because both are fed identical buffers.

### 3.3 Speaker labels

| Stream | Label rules |
|---|---|
| Mic (room) | Line matches voiceprint → **Me**. Other slots → **Speaker 1–4** in order of first appearance. Without a voiceprint, all mic slots are Speaker n |
| Call | Slots → **Caller 1–4** in order of first appearance (Aaron's own voice does not come back through call audio) |
| Either | No diarization available for a line → **Unknown** |

Known limits (accepted): Sortformer handles at most 4 voices per stream and
mislabels roughly a third of speaking time on hard meeting audio; CAM++ is a
beta model in FluidAudio. "Me" is the reliable part; numbering is the bonus.
The voiceprint threshold (default 0.5 cosine similarity) is calibrated during
acceptance testing.

## 4. The no-audio guarantee

This is the product. Rules the code must follow:

1. **No audio-writing APIs.** A build-phase script fails the build if app or
   package sources mention `AVAudioFile`, `AVAudioRecorder`, `ExtAudioFile`,
   `AudioFileCreate`, `AudioFileOpen`, `AVAssetWriter`, or the extensions
   `.wav .caf .m4a .aiff .mp3 .flac`.
2. **Audio lives only in bounded RAM.** Capture buffers are processed and
   released. The only deliberate audio buffer is `VoiceRing` (60 s of 16 kHz
   mono, ~3.8 MB), overwritten continuously and zeroed on Stop. Enrollment
   audio is held in RAM for the ~30 s exercise, embedded, then zeroed.
3. **Only text and the voiceprint are stored.** The voiceprint is 192 numbers
   in `~/Library/Application Support/Minutes/voiceprint.json`; it cannot be
   played back or turned back into speech.
4. **No logging of audio or transcript text.** `os.Logger` messages carry
   state only. No `/tmp` debug logs. Transcript text passes to the Notes
   helper over a pipe (stdin), never through a temp file or arguments.
5. **Third-party code checked.** FluidAudio's file-based helpers
   (`AudioSourceFactory`, `processComplete(audioFileURL:)`) write temp audio;
   Minutes never calls them — only the in-memory streaming and `embed(audio:)`
   APIs. The runtime audit (section 9) covers anything missed.
6. Accepted OS-level limit: macOS may page app memory to its encrypted swap
   file under memory pressure; swap is encrypted with a per-boot key. Stated in
   README.

## 5. Transcript notes

- Account: the Notes account named "iCloud"; if none, the default account.
- Folder: "Meeting Transcripts" (setting), created if missing.
- One note per meeting, created at Start, body replaced every 30 s and at Stop.
  Edits Aaron makes to that note *during* the meeting are overwritten; after
  Stop, Minutes never touches it again.
- Body (HTML Notes accepts):

```html
<div><h1>Staff meeting</h1></div>
<div>Monday, October 5, 2026 · 2:00 PM · 47 min · Room and call</div>
<div>Transcribed by Minutes. Audio was not recorded.</div>
<div><br></div>
<div><b>[00:00:03] Me:</b> Okay, let's get started.</div>
<div><b>[00:00:07] Caller 1:</b> Can everyone hear me?</div>
```

  While listening, the second line reads "… · in progress". Text is
  HTML-escaped. Untitled meetings are titled "Meeting — Mon Oct 5, 2:00 PM".
- If Notes refuses a write (permission denied, Notes not responding), lines
  stay in memory, the popover shows the error, the next save retries, and Stop
  offers **Copy transcript** so nothing is lost.

## 6. Notes index and Claude access (MCP)

### Index

`~/Library/Application Support/Minutes/notes-index.db` (WAL):

```sql
CREATE TABLE notes (
  rowid        INTEGER PRIMARY KEY,
  note_id      TEXT NOT NULL UNIQUE,   -- Notes' id, e.g. x-coredata://…/ICNote/p123
  title        TEXT NOT NULL,
  folder       TEXT NOT NULL,
  account      TEXT NOT NULL,
  created_at   INTEGER NOT NULL,       -- Unix ms
  modified_at  INTEGER NOT NULL,       -- Unix ms
  body         TEXT NOT NULL           -- plain text
);
CREATE VIRTUAL TABLE notes_fts USING fts5(
  title, body, content='notes', content_rowid='rowid', tokenize='porter unicode61'
);
-- insert/delete/update triggers keep notes_fts in sync
CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT);  -- last_refresh (Unix ms)
```

Skipped: locked notes and the "Recently Deleted" folder.

Refresh: bulk-read every note's id, name, folder, account, creation and
modification dates, and locked flag (a few Apple Events total); fetch plain
text only where `modified_at` changed or the note is new; delete index rows for
notes that disappeared. Runs every 2 minutes while Minutes is running and right
after each transcript save. Minutes starts at login (setting, on by default)
so the index stays fresh.

### MCP tools

Registered once, at user scope, by a Settings button ("Connect to Claude
Code"):

```
claude mcp add minutes --scope user -- /Applications/Minutes.app/Contents/MacOS/Minutes --mcp
```

All read-only (`SQLITE_OPEN_READONLY`). Every response starts with the index
age ("Notes index updated 1 min ago.") and warns if older than 15 minutes
("Minutes may not be running").

| Tool | Input | Returns |
|---|---|---|
| `search_notes` | `query`, `folder?`, `since?`, `until?`, `limit?` (20) | Ranked hits (bm25, title weighted ×3): note id, title, folder, modified date, a ~30-word snippet with matches marked |
| `list_notes` | `folder?`, `since?`, `until?`, `limit?` (20) | Most recently modified first: id, title, folder, created/modified dates, length |
| `get_note` | `note_id`, `offset?` | Plain text, 40,000 characters per call, with "continue with offset N" when more remains |
| `list_folders` | — | Folder names with note counts |

Query rules: plain words are OR-ed and ranked (more matching words rank
higher); text in double quotes is a phrase. Punctuation never causes errors.
`since`/`until` accept `YYYY-MM-DD` (local; `until` includes that whole day)
and filter on modified date.

Tool descriptions tell Claude that the "Meeting Transcripts" folder holds
automatic speech-recognition transcripts (expect misheard words; speaker
labels may be wrong; "Me" is Aaron) and everything else is Aaron's own notes.

## 7. User experience

### Menu bar

- Idle icon: outline waveform. Listening: filled red icon.
- Popover, idle: meeting name field (optional), source toggles (Room mic / Call
  audio, both on), **Start**. If no voiceprint, a quiet "Train your voice" link.
- On Start (reminder on): inline "Let everyone know you're transcribing." with
  "Don't remind me" — never blocks starting.
- Popover, listening: elapsed time, a level meter per source, the last few
  lines live (volatile text dimmed), last-saved-to-Notes time, **Stop**.
- After Stop: "Saved to Notes" with **Open in Notes**; on save failure,
  **Copy transcript**.
- Footer: Settings…, Quit.

### Settings

- Voice: train / retrain / delete voiceprint.
- Transcripts folder name.
- Start reminder toggle. Launch at login toggle.
- Claude: Connect / connected status; notes indexed count and last refresh;
  **Refresh now**.
- Models: download status.
- Updates (Sparkle).

### First run

1. One screen: what Minutes does; it never saves audio; transcripts go to the
   Notes folder; Claude can read your notes.
2. Permissions, each asked when first needed: Microphone, System Audio
   Recording (macOS says "recording"; our screen explains Minutes listens but does
   not save), Automation → Notes. (SpeechAnalyzer needs no Speech Recognition
   permission — removed 2026-10-07.)
3. Model downloads (Apple speech asset, Sortformer, CAM++) with progress.
4. Voice training (skippable). 5. Connect to Claude Code.

### Voice training

A ~30-second passage to read aloud, level meter, progress bar. Needs at least
20 s of speech (RMS gate). Embeds 3 s windows, averages, saves. Shows "Voice
saved"; the audio is discarded.

## 8. Error handling

| Situation | Behavior |
|---|---|
| A permission denied | Popover names it, button opens the right System Settings pane; only that source/feature is disabled |
| Models not downloaded / offline on first run | Start disabled with the reason |
| Call tap fails | Room capture continues; popover shows "Call audio unavailable" |
| Tap goes silent (known macOS bug) | Watchdog rebuilds it |
| Mic device changes mid-meeting | Restart the mic engine on the new default device; same analyzers continue (small clock drift accepted) |
| Diarizer/embedder throws | Lines continue labeled "Unknown"; transcription never stops for a labeling failure |
| Notes write fails | Keep lines in memory, show error, retry at next save; Stop offers Copy transcript |
| Index refresh fails | Keep old index; Settings and MCP responses show its age |
| App crash / force quit | The note keeps the last save (≤ 30 s old). The note's "in progress" line remains; acceptable |
| MCP: index missing | Tools say "No notes indexed yet — open Minutes once." |

## 9. Testing and proof

Automated (Swift Testing, `swift test` in the package):
- `NotesIndex`: schema, upsert, delete, FTS (stemming, phrase, punctuation
  safety, title weighting), folder/date filters, read-only open, meta.
- Index diffing (pure): new/changed/unchanged/deleted/locked/Recently Deleted.
- `TranscriptDocument`: sorting out-of-order lines, HTML escaping, header
  states, plain-text rendering.
- `Attributor`, `SpeakerActivity`, `AttributionQueue`: alignment, mid-sentence
  speaker change, gaps, waiting and timeout, flush.
- `VoicePrint`, `SpeakerResolver`, `VoiceRing`: math, voting, numbering, ring
  wraparound and wipe.
- `NotesTools` formatting and paging; MCP dispatch (bad args, unknown tool,
  missing index).
- No-audio build guard self-test.

Proof of no audio on disk (documented in README):
- `scripts/audit-writes.sh`: marker file, Aaron runs a 3-minute meeting, the
  script lists files modified since the marker under the home folder,
  `/private/var/folders`, and `/tmp`, excluding known system noise. Expected
  from Minutes: `notes-index.db*` and preferences — plus Notes' own database
  (text). Optional root check: `sudo fs_usage -w -f filesys Minutes`.

Manual acceptance (with Aaron):
- In-room 2–3 people: "Me" accuracy, others numbered.
- Teams call on speakers: call audio not duplicated as room text.
- Transcript appears in Notes on his iPhone.
- Claude Code: "what did we talk about in my last meeting?" and a question
  about one of his own notes both use the tools.

## 10. Project and release

- Repo: `~/Documents/VS Code/Assistant`; proposed GitHub repo
  `NorthwoodsCommunityChurch/avl-minutes` (private per org rule since
  2026-08-14). Created only with Aaron's OK.
- Build: XcodeGen project + local Swift package (`Packages/MinutesKit`) for
  the testable core. Dependencies: FluidAudio 0.17.5 (Apache-2.0), MCP Swift
  SDK 0.12.1 (MIT), Sparkle 2 (MIT).
- Local builds signed with the Apple Development certificate so macOS
  permissions survive rebuilds; installed to `/Applications/Minutes.app`.
  Release signing follows `RELEASE-PROCESS.md` at release time.
- Sparkle: own appcast `appcast-minutes.xml` per `App Updates/SPARKLE-GUIDE.md`.
  First release only with Aaron's OK.
- Required files per `REPO-STANDARDS.md`: README, LICENSE (MIT), CREDITS.md,
  .gitignore, CLAUDE.md, screenshots.

## 11. Risks to retire early

1. **Echo cancellation** (voice processing) while Teams runs its own: call
   audio from speakers must not reappear as room text. If it does, stop and
   bring options to Aaron rather than silently adding a workaround.
2. **Two SpeechAnalyzer sessions at once** (mic + call).
3. **Notes scripting at scale**: bulk listing speed with Aaron's real note
   count; writing a ~200 KB body every 30 s.
4. **FluidAudio** model downloads and latency with two streams plus CAM++.
