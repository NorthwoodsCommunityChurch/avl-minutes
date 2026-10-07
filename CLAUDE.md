# Minutes — Project Context

Menu bar Mac app that transcribes Aaron's meetings (room mic + Teams/Zoom/browser call audio)
**without ever recording audio**, writes each transcript into an iCloud Apple Notes folder
("Meeting Transcripts"), and lets Claude Code search all of Aaron's notes through a local MCP
server. Stack: macOS 26 Swift/SwiftUI, Apple SpeechAnalyzer, FluidAudio (Sortformer + CAM++),
SQLite FTS5, MCP Swift SDK, XcodeGen.

> **Read first:** [docs/superpowers/specs/2026-10-05-minutes-design.md](docs/superpowers/specs/2026-10-05-minutes-design.md)
> (the product definition), then [DESIGN.md](DESIGN.md) (visual system; mockup in `design/sketches/`).
> The build plan is [docs/superpowers/plans/2026-10-05-minutes.md](docs/superpowers/plans/2026-10-05-minutes.md).

---

## Status — 2026-10-07
- **Stage:** active development, branch `minutes-v1` (not pushed; no GitHub repo yet)
- **Works:** testable core (41 tests), Notes index + MCP search over Aaron's real notes, Notes
  read/write via helper process, call + echo-cancelled mic capture, transcription + speaker
  separation end to end (`--transcribe-check`), voice training logic, no-audio build guard and audit script.
- **In progress / next:** real menu bar UI (design mockup awaiting Aaron's OK), Sparkle, README.
- **Known issues / pending with Aaron:** echo-cancellation proof with speakers on during a real call;
  voice training + "Me" threshold calibration (default 0.5).

## What it does
Aaron clicks Start in the menu bar before a meeting and Stop after. Speech becomes text in RAM;
lines are labeled Me / Speaker n (room) / Caller n (call) and saved to a note every 30 s. The app
also indexes every Apple Note's text every 2 minutes so `Minutes --mcp` can answer Claude's searches.

## Architecture
```
Mic (voice processing) ─┐            ┌─ SpeechTranscriber (words + times)
Call tap (IOProc) ──────┴─ 16 kHz ───┼─ Sortformer diarizer (who spoke when)
                                      └─ VoiceRing 60 s → CAM++ → "Me"
→ Attributor → TranscriptDocument → NotesBridge (Minutes --notes-helper) → Apple Notes
NotesIndexer → notes-index.db (FTS5) ← Minutes --mcp (read-only) ← Claude Code
```
One binary, five modes: app (default), `--mcp`, `--notes-helper`, `--audio-check`, `--transcribe-check`.

### Where things live
- `Packages/MinutesKit/` — pure, tested logic (attribution, speakers, transcript doc, Notes index, MCP tools)
- `Packages/AudioDeps/` — wraps vendored FluidAudio with its unused NeMo engine turned off
- `Minutes/Audio`, `Minutes/Pipeline`, `Minutes/Notes`, `Minutes/Claude`, `Minutes/App`
- `scripts/` — build-and-run, fetch-deps, no-audio guard (+ self-test), audit-writes, mcp-smoke-test

## Key identifiers
| Thing | Value |
|---|---|
| Type / stack | macOS 26 Swift app (XcodeGen) + local Swift packages |
| GitHub repo | not yet (proposed `NorthwoodsCommunityChurch/avl-minutes`, private) |
| Bundle ID | `com.northwoods.Minutes` |
| Current version | 0.1.0 (1) |
| Update feed (Sparkle) | not yet wired (`appcast-minutes.xml` planned) |
| Secrets location | none yet (Sparkle key will follow `FILE-ORGANIZATION.md`) |
| Data on disk | `~/Library/Application Support/Minutes/` (notes-index.db, voiceprint.json); models in `…/FluidAudio/Models` |

## Build / Run / Release
```bash
bash scripts/build-and-run.sh            # fetch deps, xcodegen, build, install to /Applications, relaunch
swift test --package-path Packages/MinutesKit
bash scripts/test-check-no-audio-writes.sh
bash scripts/mcp-smoke-test.sh
MINUTES_TRACE=1 /Applications/Minutes.app/Contents/MacOS/Minutes --transcribe-check [--both] [--save]
bash scripts/audit-writes.sh start  # … run a meeting …  bash scripts/audit-writes.sh report
```
Release: not yet — ask Aaron before any version bump, repo creation, or appcast publish.

## Conventions & gotchas
- **Never save audio.** The build fails on audio-writing APIs or audio file extensions in any source
  (`scripts/check-no-audio-writes.sh`). No transcript text in logs; `Trace` prints state only.
- FluidAudio is a **shallow vendored clone** (`scripts/fetch-deps.sh`); Xcode's own package fetch
  clones ~300 MB of history and stalled for 40+ min. Bump the version in that script.
- Notes' **JXA returns empty collections** on macOS 26.5 — use AppleScript (`NotesScriptSource`).
- NSAppleScript must run on the main thread and big note writes take seconds → every Notes call
  runs in a `Minutes --notes-helper` child process (JSON over stdin/stdout).
- **Don't touch `engine.mainMixerNode`** when voice processing is on: init fails with -10875.
- **Call tap must be read with an IOProc**, not AVAudioEngine — AVAudioEngine on a tap aggregate
  started late or never in ~1/3 runs (and starved SpeechAnalyzer hangs its results stream).
- SpeechAnalyzer needs **no** `SFSpeechRecognizer.requestAuthorization`; calling it from a terminal
  run crashes with a TCC violation.
- Running modes from a terminal attributes permissions to the terminal/VS Code, not Minutes.

## Update Protocol
| When you… | Update… |
|---|---|
| ship a version | Status date · Current version · appcast |
| add/rename a feature, screen, or mode | What it does · Architecture |
| hit & fix a gotcha | Conventions & gotchas |
| change how it builds or releases | Build / Run / Release |

End a work session with **`/save`**.

## Document history
| Date | Change |
|---|---|
| 2026-10-07 | Initial CLAUDE.md to Northwoods standard |
