# Minutes — Project Context

Menu bar Mac app that transcribes Aaron's meetings (room mic + Teams/Zoom/browser call audio)
**without ever recording audio**, writes each transcript into an iCloud Apple Notes folder
("Meeting Transcripts"), and lets Claude Code search all of Aaron's notes through a local MCP
server. Stack: macOS 26 Swift/SwiftUI, Apple SpeechAnalyzer, FluidAudio (Sortformer + CAM++),
SQLite FTS5, MCP Swift SDK, XcodeGen.

> **Read first:** [README.md](README.md) (what it is, usage, privacy), then the product definition
> [docs/superpowers/specs/2026-10-05-minutes-design.md](docs/superpowers/specs/2026-10-05-minutes-design.md)
> and [DESIGN.md](DESIGN.md) (Apple-native visual rules). Build plan + task status:
> [docs/superpowers/plans/2026-10-05-minutes.md](docs/superpowers/plans/2026-10-05-minutes.md).
> If you read one more thing after this file, read the spec.

---

## Status — 2026-10-07 (evening)
- **Direction change (Aaron, 2026-10-07):** Minutes is now **only the transcriber on Aaron's laptop**. The always-on
  assistant is **Hermes Agent on the engineering Mac mini** (`engineering-mac`), fed by a to-be-built **Hermes Helper**
  (notes index + MCP search, same engine) and Power Automate → OneDrive feeds. Full record + next steps:
  [docs/research/2026-10-07-assistant-direction.md](docs/research/2026-10-07-assistant-direction.md). **Resume there.**
- **Summary bench** (`bench/`, 5 models, 30 synthetic meetings) is running detached via `bench/finish.sh`;
  progress in `bench/results/orchestrate.log`, scorecard at `bench/results/REPORT.md` when `FULL SCORECARD READY` appears.
- **Stage:** active development on branch `minutes-v1`, pushed to private repo
  `NorthwoodsCommunityChurch/avl-minutes` (created 2026-10-07 with Aaron's OK). `main` holds spec + plan only;
  merging `minutes-v1` into `main` still needs Aaron's OK.
- **Works:** everything end to end — testable core (50 tests); Notes index + MCP search
  over Aaron's real notes (118); Notes read/write via helper process; call capture (IOProc) +
  echo-cancelled mic; transcription + speaker separation (`--transcribe-check` 8/8 + 3/3 both-stream
  runs perfect); native Liquid Glass UI (menu bar panel, Welcome checklist, Settings, voice training);
  no-audio build guard + audit script. Debug build installed at `/Applications/Minutes.app` (not launched).
- **Plan status (tasks 1–13):** 1–11 done; 12 (UI) done, native screens approved by Aaron 2026-10-07 ([docs/images/minutes-screens.png](docs/images/minutes-screens.png)); 13: Sparkle wired
  (feed `appcast-minutes.xml` not published yet); final whole-branch review done and its Important findings fixed
  (2026-10-07). Remaining: Aaron's test session, then merge to main (needs his OK).
- **Needs Aaron in person:** echo-cancellation test on a Teams call with speakers on (`--audio-check`
  or a real meeting; his speakers were muted and were left muted); voice training + "Me" threshold
  calibration (default cosine 0.5); first real launch through the Welcome checklist.
- **Known issues:** 10 deferred minor review findings (ledger `Final: minor (deferred)` lines), e.g. a Notes
  create that times out but succeeds can leave a duplicate note; one-word lines may be labeled Unknown. Ledger of every deviation from the plan ("Ruling:" lines):
  `.superpowers/sdd/2026-10-05-minutes/progress.md` (gitignored, local only).

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
One binary, several modes: app (default), `--mcp`, `--index` (headless Notes indexing, no UI — built for the mini,
now superseded by the planned Hermes Helper target), `--notes-helper`, `--unregister-login`, `--audio-check`,
`--transcribe-check`; debug builds also have `--gallery` (all screens in one off-screen, non-focusable window).

### Where things live
- `Packages/MinutesKit/` — pure, tested logic (attribution, speakers, transcript doc, Notes index, MCP tools)
- `Packages/AudioDeps/` — wraps vendored FluidAudio with its unused NeMo engine turned off
- `Minutes/Audio`, `Minutes/Pipeline`, `Minutes/Notes`, `Minutes/Claude`, `Minutes/App`
- `scripts/` — build-and-run, fetch-deps, no-audio guard (+ self-test), audit-writes, mcp-smoke-test

## Key identifiers
| Thing | Value |
|---|---|
| Type / stack | macOS 26 Swift app (XcodeGen) + local Swift packages |
| GitHub repo | [NorthwoodsCommunityChurch/avl-minutes](https://github.com/NorthwoodsCommunityChurch/avl-minutes) (private) |
| Bundle ID | `com.northwoods.Minutes` |
| Current version | 0.1.0 (1) |
| Update feed (Sparkle) | `https://northwoodscommunitychurch.github.io/app-updates/appcast-minutes.xml` (org key; file not published until first release) |
| Secrets location | none of its own — uses the org Sparkle key (`~/.sparkle/ed25519-private.txt`, master in OneDrive per `FILE-ORGANIZATION.md`) |
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
Release: not yet — ask Aaron before any version bump or appcast publish.
Aaron's calls (2026-10-07): **not listed in Canopy** (`app-updates/catalog.json` gets no entry);
**no custom app icon** and **no release script** — don't build them unless he asks. If a release
happens, follow `../App Updates/SPARKLE-GUIDE.md` by hand.

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
- **Design is Apple native** (Aaron, 2026-10-07): system controls, `.glass`/`.glassProminent`, no brand
  fonts/colors. The `northwoods-mac-app-design` skill's custom-brand direction was overridden.
- **Screenshots: capture only the gallery window** (`screencapture -l <id>`, id printed as
  `GALLERY_WINDOW=` on stderr). A region capture once caught Aaron's Teams chat; never do that again.
- Login item auto-registers only for `/Applications` copy launched with no arguments.
- **Start never waits on the notes index** — only Notes *permission* blocks it; index trouble shows in the footer.
- Notes helper calls have deadlines (`NotesRequest.timeout`, run by MinutesKit `ChildProcess`).
- **A transcript whose final save failed blocks New Meeting, Quit, and update relaunch** until Try Again
  succeeds or it's copied (`MeetingSession.hasUnsavedTranscript`).
- **Sparkle never interrupts a meeting** (`Updater.swift`): background checks are skipped while one runs and
  an accepted update's relaunch waits until it ends. The gallery never starts Sparkle.

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
| 2026-10-07 | /save: status after native UI; README added; screenshot and login-item gotchas |
| 2026-10-07 | Repo created (private); Sparkle wired; feed + secrets rows filled |
| 2026-10-07 | Final review fix pass: timeline across capture gaps, helper deadlines, unsaved-transcript guard, Start gating |
| 2026-10-07 | Aaron: no Canopy listing, no custom icon, no release script |
| 2026-10-07 | Direction: Minutes = transcriber only; Hermes + Hermes Helper on the engineering mini; summary bench; `--index` mode |
