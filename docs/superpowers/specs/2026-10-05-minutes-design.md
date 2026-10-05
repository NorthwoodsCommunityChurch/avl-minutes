# Minutes — design spec

**Date:** 2026-10-05
**Status:** approved in conversation 2026-10-05 ("approved, build it")
**Working name:** Minutes (rename freely; bundle ID `com.northwoods.Minutes`)

## 1. Purpose

Aaron wants a searchable record of what was said in his meetings, so a personal
assistant (Claude) can answer questions like "what did we decide about the
lobby screens last Tuesday?" or "what did I promise Dan?".

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
| Where it is stored | This Mac only |
| How Claude reads it | A search server (MCP), not plain files |
| Org | Northwoods app (org repo, Sparkle) — default chosen by Claude, Aaron did not object |

### Assumptions (Claude's, open to correction)

- English only, using the Mac's current English locale.
- One Mac (Aaron's M3 Max laptop, macOS 26.5). No iPhone or iPad capture.
- Meetings up to ~3 hours.
- Illinois law: secret recording/transmitting of a private conversation needs
  all-party consent (720 ILCS 5/14-2(a)(2)); the trigger is *surreptitious*
  use. The app therefore reminds Aaron to tell attendees at each Start
  (dismissable, can be turned off). Not legal advice.

### Success criteria

1. Over a full meeting, nothing but text reaches the disk — proven by a file
   write audit (section 9), not asserted.
2. Aaron's own lines are labeled "Me" correctly in the large majority of a
   clean in-room meeting and essentially always on calls.
3. From any Claude Code session on this Mac, Aaron can ask about past meetings
   and Claude finds the right passage by searching, not by reading everything.
4. Start → speaking → text visible in the popover within a few seconds.
5. A crash or force-quit mid-meeting loses at most the last few seconds of text.

## 2. Non-goals

- Summaries, action items, or any LLM processing inside the app (Claude does
  that on demand when asked).
- Cloud anything. The only network use is the one-time model download and
  Sparkle update checks.
- Automatic meeting detection or calendar integration.
- Identifying people other than Aaron by name automatically (Aaron can rename
  "Speaker 2" → "Dan" per meeting by hand).
- Playback, audio export, or any "keep the audio just this once" option.

## 3. Architecture

One macOS app, `Minutes.app`, with two modes from the same binary:

- **App mode** (normal launch): menu bar app that captures, transcribes,
  labels speakers, and writes text to the database.
- **MCP mode** (`Minutes --mcp`): a headless stdio MCP server that Claude Code
  launches on demand to search the database read-only. It exits when Claude
  closes the pipe. Nothing runs in the background for Claude.

Using one binary means there is no helper to bundle, sign, or keep in sync,
and Sparkle updates both at once.

```
 Mic ──► MicCapture (AVAudioEngine + voice processing / echo cancel)
                │  16 kHz mono buffers (RAM only)
                ├──► SpeechAnalyzer/SpeechTranscriber (words + time ranges)
                ├──► Sortformer diarizer (who spoke when, 4 slots)
                └──► VoiceRing (last 30 s, RAM) ──► CAM++ embedder ──► "Me"?
                                         │
 Mac audio out ─► CallCapture (Core Audio process tap, all apps except Minutes)
                │  16 kHz mono buffers (RAM only)
                ├──► SpeechTranscriber
                └──► Sortformer diarizer
                                         │
                       Attributor (words × speaker segments → lines)
                                         │
                       MeetingStore (SQLite + FTS5, WAL) ◄── Minutes --mcp (read-only)
```

### 3.1 Units

| Unit | Responsibility | Depends on |
|---|---|---|
| `MicCapture` | Opens default input with voice processing (echo cancellation, other-audio ducking minimized), downmixes/resamples to 16 kHz mono Float32, emits buffers with a sample-count clock | AVFAudio |
| `CallCapture` | Creates a global process tap (all processes except Minutes itself) + private aggregate device, reads it with its own AVAudioEngine, emits 16 kHz mono buffers. Watchdog rebuilds the tap if it delivers pure zeros for 10 s while any process reports `IsRunningOutput` | CoreAudio, AVFAudio |
| `StreamTranscriber` | One per stream. Wraps a single-use SpeechAnalyzer + SpeechTranscriber with `.volatileResults` and `.audioTimeRange`; emits volatile text (for live UI) and final word runs with times | Speech |
| `StreamDiarizer` | One per stream. Wraps `SortformerDiarizer` (default/fast config, ~1 s latency); emits finalized speaker segments (slot, start, end) | FluidAudio |
| `VoicePrint` | Enrollment (≈30 s of reading → several CAM++ embeddings averaged → one 192-number vector) and matching (cosine similarity vs. threshold) | FluidAudio CAM++ |
| `SpeakerResolver` | Mic stream only: for each finalized diarizer segment ≥ 1.0 s, takes that span from `VoiceRing`, embeds it, decides Me / not-me; keeps a per-slot running vote so short segments inherit their slot's label | VoicePrint |
| `Attributor` | Pure function: given final word runs (text + time) and speaker segments, groups consecutive words by speaker into lines. Waits (bounded, 5 s) for diarization to cover a word's time before deciding; falls back to the slot that overlaps most, else "Unknown" | — |
| `MeetingSession` | Orchestrates one meeting: starts/stops both streams, maps stream time to meeting time, sends lines to the store as they finalize | all above |
| `MeetingStore` | SQLite (system libsqlite3, WAL, FTS5). Shared by app (read-write) and MCP mode (read-only) | SQLite3 |
| `MCPServer` | Three tools over stdio (section 6) | MCP Swift SDK, MeetingStore |
| UI | Menu bar popover, Meetings window, Settings, Voice training sheet | SwiftUI |

### 3.2 Clocks and time alignment

Each stream counts samples from its own start. A line's meeting time is
`streamStartOffset + sampleTime`, where `streamStartOffset` is the host-time
difference between the meeting's Start and the stream's first buffer. Both the
transcriber's `audioTimeRange` and the diarizer's segment times are in the same
sample timeline for a given stream, because both are fed the identical buffers.

### 3.3 Speaker labels

| Stream | Label rules |
|---|---|
| Mic (room) | Segment matches voiceprint → **Me**. Other slots → **Speaker 1–3** in order of first appearance. Without a voiceprint, all mic slots are Speaker 1–4 |
| Call | Slots → **Caller 1–4** in order of first appearance. (Aaron's own voice does not come back through call audio, so call audio is always others) |

Labels are per meeting. The Meetings window lets Aaron rename a label for that
meeting (e.g. "Caller 2" → "Dan"); renames are stored and used by search.

Known limits (accepted): Sortformer handles at most 4 voices per stream and
mislabels roughly a third of speaking time on hard meeting audio; CAM++ is a
beta model in FluidAudio. "Me" is the reliable part; numbering is the bonus.

## 4. The no-audio guarantee

This is the product. Rules the code must follow:

1. **No audio-writing APIs are linked or called.** A build-phase script fails
   the build if app sources mention `AVAudioFile`, `AVAudioRecorder`,
   `ExtAudioFile`, `AudioFileCreate`, `AudioFileOpen`, `AVAssetWriter`, or the
   extensions `.wav .caf .m4a .aiff .mp3 .flac`.
2. **Audio lives only in bounded RAM.** Capture buffers are processed and
   released. The only deliberate audio buffer is `VoiceRing` (30 s, ~1.9 MB),
   overwritten continuously and zeroed on Stop. Enrollment audio is held in RAM
   for the ~30 s exercise, embedded, then zeroed.
3. **Nothing derived from audio is stored except text and the voiceprint.** The
   voiceprint is 192 numbers; it cannot be played back or turned back into
   speech.
4. **No debug logging of audio or transcript text.** `os.Logger` messages carry
   state only (started, stopped, errors). No `/tmp` debug logs (unlike Whisper
   Verses).
5. **Third-party code is checked too.** FluidAudio's streaming paths keep
   audio in memory; the plan includes reading the paths we call to confirm none
   writes to disk, and the runtime audit (section 9) covers what we miss.
6. Known, accepted OS-level limit: macOS may page any app memory to its
   encrypted swap file under memory pressure; swap is encrypted with a
   per-boot key and is unreadable after reboot. Stated in README.

## 5. Data model (SQLite)

Database: `~/Library/Application Support/Minutes/minutes.db` (WAL mode).
Voiceprint: same database, `settings` table.

```sql
CREATE TABLE meetings (
  id          INTEGER PRIMARY KEY,
  title       TEXT NOT NULL,          -- defaults to "Meeting — Mon Oct 5, 2:00 PM"
  started_at  TEXT NOT NULL,          -- ISO 8601 with offset
  ended_at    TEXT,                   -- NULL while in progress / after crash
  sources     TEXT NOT NULL           -- "room", "call", or "room+call"
);
CREATE TABLE lines (
  id          INTEGER PRIMARY KEY,
  meeting_id  INTEGER NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
  start_ms    INTEGER NOT NULL,       -- ms from meeting start
  end_ms      INTEGER NOT NULL,
  source      TEXT NOT NULL,          -- "room" | "call"
  speaker     TEXT NOT NULL,          -- stable key: "me", "room-1".."room-4", "call-1".."call-4", "unknown"
  text        TEXT NOT NULL
);
CREATE TABLE speaker_names (           -- per-meeting renames
  meeting_id  INTEGER NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
  speaker     TEXT NOT NULL,
  name        TEXT NOT NULL,
  PRIMARY KEY (meeting_id, speaker)
);
CREATE TABLE settings (key TEXT PRIMARY KEY, value BLOB);
CREATE VIRTUAL TABLE lines_fts USING fts5(
  text, content='lines', content_rowid='id', tokenize='porter unicode61'
);
-- + insert/delete/update triggers keeping lines_fts in sync
```

Default display names: `me`→"Me", `room-n`→"Speaker n", `call-n`→"Caller n",
`unknown`→"Unknown". Renames override per meeting.

Schema versioning via `PRAGMA user_version`; migrations run at app start.

A meeting left with `ended_at` NULL after a crash is closed on next launch
using its last line's time.

## 6. Claude access (MCP)

Registered once, at user scope, by a button in Settings ("Connect to Claude
Code"), which runs:

```
claude mcp add minutes --scope user -- /Applications/Minutes.app/Contents/MacOS/Minutes --mcp
```

Settings shows whether it is registered (`claude mcp get minutes`).

Tools (all read-only; the MCP mode opens the database with `SQLITE_OPEN_READONLY`):

| Tool | Input | Returns |
|---|---|---|
| `list_meetings` | `since?`, `until?` (ISO dates), `limit?` (default 20) | Newest first: id, title, date, duration, speakers (with renames) |
| `search_meetings` | `query` (words or phrase), `since?`, `until?`, `limit?` (default 20) | Ranked hits (FTS5 bm25): meeting id/title/date, timestamp, speaker, the matching line plus one line before and after |
| `get_transcript` | `meeting_id`, `start_minute?`, `end_minute?` | `[hh:mm:ss] Speaker: text` lines; capped at ~40,000 characters per call with a "continue from minute N" note |

Tool descriptions tell Claude that transcripts are automatic speech
recognition (expect misheard words) and that speaker labels may be wrong.

## 7. User experience

### Menu bar

- Idle icon: outline. Listening: filled red icon (visible "it's listening").
- Popover, idle: meeting name field (optional), source toggles (Room mic / Call
  audio, both on by default), **Start** button. If no voiceprint yet, a quiet
  "Train your voice" link.
- On Start (when the reminder is on): inline line "Let everyone know you're
  transcribing." with "Don't remind me" — does not block starting.
- Popover, listening: elapsed time, a level meter per source, the last few
  lines live (volatile text in grey), **Stop**.
- Footer: Meetings…, Settings…, Quit.

### Meetings window

- Sidebar list: title, date, duration. Search field (same FTS search Claude uses).
- Detail: transcript with timestamps and speaker names; rename meeting; click a
  speaker name to rename it for that meeting; delete meeting (confirm).

### Settings

- Voice: train / retrain / delete voiceprint.
- Start reminder toggle.
- Claude: Connect / status.
- Models: download status for transcription and speaker models.
- Updates (Sparkle).

### First run

1. Explain in one screen what Minutes does and that it never saves audio.
2. Permissions, each requested at the moment it is first needed: Microphone,
   Speech Recognition, System Audio Recording (macOS's own wording says
   "recording"; our screen explains that Minutes listens but does not save).
3. Model downloads (Apple speech asset, Sortformer, CAM++) with progress.
4. Offer voice training (skippable).

### Voice training

Shows a ~30-second passage to read aloud; level meter; progress bar. Requires
at least 20 s of detected speech. Computes embeddings over 3 s windows,
averages, stores. Shows "Voice saved" and the audio is discarded.

## 8. Error handling

| Situation | Behavior |
|---|---|
| A permission denied | Popover explains which, with a button to the right System Settings pane; Start disabled for that source only |
| Model not downloaded / no network on first run | Start disabled with "Downloading speech models…" or "Connect to the internet once to download models" |
| Call tap fails to create | Room capture continues; popover shows "Call audio unavailable" |
| Tap goes silent (known macOS bug) | Watchdog rebuilds it; logs state |
| Mic device changes mid-meeting | Restart mic stream on the new default device; meeting continues |
| Diarizer/embedder throws | Lines continue as "Unknown"; transcription never stops for a labeling failure |
| Database write fails | Popover error; keep last 200 lines in memory and retry each 5 s |
| App crash / force quit | Lines already written persist; meeting closed on next launch |
| MCP: database missing | Tools return a clear message ("no meetings yet") |

## 9. Testing and proof

Automated (Swift Testing):
- `MeetingStore`: schema, insert, FTS search incl. stemming and phrases,
  renames, cascade delete, crash-close, read-only open.
- `Attributor`: word/segment alignment, speaker changes mid-sentence, gaps,
  late diarization, unknown fallback.
- `VoicePrint` matching and `SpeakerResolver` voting (pure logic, synthetic
  vectors).
- MCP tool handlers (pure layer under the SDK): formatting, paging, limits.
- No-audio build guard has a self-test (a fixture containing a forbidden symbol
  must fail the script).

Proof of no audio on disk (manual, documented in README):
- Script `scripts/audit-writes.sh`: creates a marker, Aaron runs a 3-minute
  meeting, the script lists every file modified since the marker in the user's
  home, `/private/var/folders`, and `/tmp`, filtered to non-system noise.
  Expected: only `minutes.db`, `-wal`, `-shm`, and preferences.
- Optional stronger check with root: `sudo fs_usage -w -f filesys Minutes`
  during a meeting.

Manual acceptance (with Aaron):
- In-room 2–3 people: "Me" accuracy, others numbered.
- Teams call with speakers (not headphones): call audio not duplicated as room
  text (echo cancellation works).
- Claude Code: "what did we talk about in my last meeting?" uses the tools.

## 10. Project and release

- Repo: this folder (`~/Documents/VS Code/Assistant`), proposed GitHub repo
  `NorthwoodsCommunityChurch/avl-minutes` (private, per org rule since
  2026-08-14). Created only with Aaron's OK.
- Build: XcodeGen project + local Swift package for shared, testable code.
  Dependencies: FluidAudio (Apache-2.0), MCP Swift SDK (MIT), Sparkle (MIT).
- Signing for local builds: the Apple Development certificate on this Mac, so
  macOS privacy permissions survive rebuilds. Release signing follows
  `RELEASE-PROCESS.md` at release time.
- Sparkle: own appcast `appcast-minutes.xml` in the `app-updates` repo, per
  `App Updates/SPARKLE-GUIDE.md`. First release only with Aaron's OK.
- Required files per `REPO-STANDARDS.md`: README, LICENSE (MIT), CREDITS.md,
  .gitignore, CLAUDE.md, screenshots.

## 11. Risks to retire early (plan phase 1)

1. **Echo cancellation on macOS with voice processing** while Teams also uses
   its own: verify call audio from speakers is removed from the mic stream. If
   not, the plan stops and comes back to Aaron (headphones guidance vs. other
   options) rather than silently adding a workaround.
2. **SpeechAnalyzer running two sessions at once** (mic + call). Verify both
   produce results concurrently.
3. **FluidAudio model downloads and Sortformer latency** on this Mac with two
   streams plus CAM++.
