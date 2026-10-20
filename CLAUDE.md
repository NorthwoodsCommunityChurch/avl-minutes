# Minutes — Project Context

Menu bar Mac app that transcribes Aaron's meetings (room mic + Teams/Zoom/browser call audio)
**without ever recording audio**, writes each transcript into an iCloud Apple Notes folder
("Meeting Transcripts"), and lets Claude Code search all of Aaron's notes through a local MCP
server. The same repo builds **Hermes Helper**, the background app on the assistant Mac mini that
indexes Notes for Hermes Agent (spec: [docs/superpowers/specs/2026-10-07-hermes-helper-design.md](docs/superpowers/specs/2026-10-07-hermes-helper-design.md)). Stack: macOS 26 Swift/SwiftUI, Apple SpeechAnalyzer, FluidAudio (Sortformer + CAM++),
SQLite FTS5, MCP Swift SDK, XcodeGen.

> **Read first:** [README.md](README.md) (what it is, usage, privacy), then the product definition
> [docs/superpowers/specs/2026-10-05-minutes-design.md](docs/superpowers/specs/2026-10-05-minutes-design.md)
> and [DESIGN.md](DESIGN.md) (Apple-native visual rules). Build plan + task status:
> [docs/superpowers/plans/2026-10-05-minutes.md](docs/superpowers/plans/2026-10-05-minutes.md).
> If you read one more thing after this file, read the spec.

---

## Status — 2026-10-20
- **2026-10-20, a day of Hermes fixes (all live on edit-3, details in the gotchas):** Puget's two-lane cutover moved Hermes to
  `strata` (her own lane; 17 s on a three-tool question); Teams layout (relay `toTeamsMarkdown`, SOUL layout rule); she wakes on
  mail and Teams Aaron sends and receives and offers asks as cards on his yes; receive-only member `hermes` of the session mesh
  (`mesh-bridge/` on the laptop → relay kind `progress`); board tools `task_list_order` and `task_card_move`; deploys wait for an
  idle relay (`/status`, `scripts/wait-hermes-idle.sh`); web search confirmed on with a query-privacy rule. Found: OneDrive on
  edit-3 silently stopped syncing for ~5 h (restarted; no detection yet). Semantic search was tested 2026-10-13
  ([results](docs/research/2026-10-13-semantic-search-test.md): hybrid recommended) but never built; Aaron has not decided to build it.
- **2026-10-10, documentation layer (spec [docs/superpowers/specs/2026-10-10-hermes-documentation-layer-design.md](docs/superpowers/specs/2026-10-10-hermes-documentation-layer-design.md),
  plan [docs/superpowers/plans/2026-10-10-hermes-documentation-layer.md](docs/superpowers/plans/2026-10-10-hermes-documentation-layer.md), research
  [options](docs/research/2026-10-10-assistant-platform-options.md) and [how](docs/research/2026-10-10-hermes-documentation-layer-research.md)):** Aaron: "I keep coming
  back to you for her memory … that's what she is for: creating and maintaining lists, projects, to do, calendars." Constraints he set: no Claude API
  spend, no new hardware, model stays local (test the box's `qwen-coder` against `gemma-bigctx`). Built: Hermes keeps her own notes in the **Hermes**
  folder of Aaron's Apple Notes (`HermesNote`, `note_write` / `note_create` on the helper's MCP server), captures a stated fact before answering
  (relay note), reads the project's note for meeting prep, and feed prompts run in their own Hermes thread (relay key `feed`) so his thread stops
  compacting. Bake-off (six real tasks as one-shots, research doc section 7): Gemma correct on all six with or without the bridge; the box's
  `qwen-coder` correct on all six, three to eight times faster, terser. Live since the evening of Oct 10: `model.default: "qwen-coder"`,
  `tools.tool_search.enabled: "off"`, Planka filtered to `cards` (backups `config.yaml.bak-20261010-bridge` and `-model`), helper with the
  note tools, relay with the feed thread and capture sentence, SOUL "Your notes", nightly "Notes tidy" cron job (11 PM, deliver local).
- **2026-10-09, Hermes initiative (spec [docs/superpowers/specs/2026-10-09-hermes-initiative-design.md](docs/superpowers/specs/2026-10-09-hermes-initiative-design.md),
  plan [docs/superpowers/plans/2026-10-09-hermes-initiative.md](docs/superpowers/plans/2026-10-09-hermes-initiative.md), Aaron's "approved"):** Aaron's tasks had been living in
  Hermes's chat lists, not on the board, so his sent email to Danny (Higher Ground, Dante ticket #2050007) closed nothing, and the "Scrum Prep
  Notes" cron job he asked for ran 42 min and could not deliver (Hermes cron has no path to the API server). Now: the relay posts every new
  `~/.hermes/cron/output` file to his chat (`lib/cron-output.js`); the helper wakes Hermes 35 min before each meeting (`MeetingPrep`, notify
  `kind: "meeting"`) and she briefs him; a relay note under each of his messages says card first, search first; `SOUL.md` rewritten with exact
  tool JSON and versioned at `hermes-tools/SOUL.md`; today's 13 chat-only tasks put on the board by hand. Scrum job switched to `deliver local`.
  Same afternoon: Hermes was found in a runaway loop (18 identical failing `read_file` calls, one Puget turn each, for an hour; Aaron's 11:02
  question timed out behind it) — gateway hard-restarted, `tool_loop_guardrails.hard_stop_enabled: true`, `agent.max_turns: 60`
  (backup `config.yaml.bak-20261009-loops`). Live checks: see the gotchas and the relay log (`cron-output`, `kind: meeting`).
- **Roles (Aaron, 2026-10-07):** Minutes is **only the transcriber on Aaron's laptop**. The always-on assistant is
  **Hermes Agent on the engineering Mac mini** (`engineering-mac`). Record + remaining steps:
  [docs/research/2026-10-07-assistant-direction.md](docs/research/2026-10-07-assistant-direction.md).
- **HOST MOVED 2026-10-08 afternoon:** the assistant now runs on **`edit-3`** (DC - Edit 3, 10.11.1.104, the erased
  former video director M1 mini); `engineering-mac` is back in engineering and was wiped of our software the same day
  (`scripts/decommission-assistant-mac.sh engineering-mac`, Aaron's go; verified: no agents, apps, brew packages or procs left). Provisioning/migration is one
  command: `scripts/setup-assistant-mac.sh <host> [--old-host <alias>]` (Hermes restored from the backup in OneDrive
  `secrets/migration/`). Verified on edit-3: Teams message answered in 35 s, notes question in 55 s, 118 notes indexed.
  Edit-3 time zone fixed (came up Pacific), OneDrive signed in and the feed indexed (needed Aaron's Allow click on the mini's
  screen), auto-login on.
- **Mini is live (2026-10-08, originally on engineering-mac):** Hermes Agent (now v0.21.6 on edit-3; `~/.hermes`, gateway as launchd `ai.hermes.gateway` with its
  API server on 127.0.0.1:8642) talks to **Puget's Gemma 4 31B** (`http://10.11.4.170:11434/v1`, model `gemma-bigctx`,
  header `X-Client: hermes`, streaming; Aaron's call 2026-10-08, "Hermes can run on that mini, but use the models on
  the puget"). The local Gemma 12B server and model file were removed the same day (swap had hit 12.6 GB).
  **Hermes Helper** (launchd `com.northwoods.HermesHelper`) indexes Notes plus the OneDrive **AI Feed**
  (`mail/`, `calendar/`, `teams/` JSON from Aaron's Power Automate flows; mail + calendar flows live, Teams flow pending)
  and serves MCP `notes`. **Teams bot "Hermes"** (1:1 chat) reaches Hermes through Cloudflare Worker `hermes` →
  tunnel `engineering-mac` → `hermes-teams` relay (launchd `com.northwoods.hermes-teams`) → Hermes API; verified
  end to end. Also registered: the Planka task board as MCP `planka`. Hermes's `SOUL.md` carries Aaron's standing
  rules (look things up on its own, never ask to research, answer briefly); terminal/browser/file/code/clarify tools
  are off on both platforms. Honcho/cloud memory off. Next: Teams feed flow (Aaron), a read-only Planning Center MCP
  server (Aaron creates a Personal Access Token), docs.
- **Afternoon of 2026-10-08, all live on edit-3:** flow 3 (Teams chats) plus run-once backfills for Teams (since Jan 1) and the
  calendar (past 30 / next 120 days) and a Sent Items mail flow, all built as import packages by `scripts/power-automate/*.py`
  from Aaron's own exports (OneDrive `VS Code/Assistant/flows/`); Hermes got a clock (`current_time` on the helper's MCP),
  song prep (`song_prep` / `song_energy_note` on the Planning Center server, mirror in `hermes-tools/pco-mcp/`), and the
  **proactive loop** (helper → relay `POST /notify` → Hermes in Aaron's thread → Teams line; spec
  [docs/superpowers/specs/2026-10-08-hermes-proactive-loop-design.md](docs/superpowers/specs/2026-10-08-hermes-proactive-loop-design.md)):
  calendar changes and sent mail reach Hermes within ~2 min; she creates task cards when Aaron says "I need to…" and moves
  them to the board's new **Done** list when a sent email closes one. Minutes: the Start hang (TimelineView in the menu bar
  label) is fixed and Aaron's test passed. Unverified live: the first proactive Teams line (needs one message from Aaron to
  the bot after the relay restart so it learns the home conversation).
- **Summary bench** (`bench/`): Aaron stopped it 2026-10-07 15:52 after the 5-meeting preview decided it
  (Gemma 12B over Qwen 9B; see [bench/FINDINGS.md](bench/FINDINGS.md)). Partial rows stay in `bench/results/`; every runner resumes.
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
One binary, several modes: app (default), `--mcp`, `--notes-helper`, `--unregister-login`, `--audio-check`,
`--transcribe-check`; debug builds also have `--gallery` (all screens in one off-screen, non-focusable window).

**Hermes Helper** (`HermesHelper.app`, second target, no UI) shares the Notes code: `--index` (default; launchd keeps
the index fresh every 2 min), `--mcp` (read-only server named `hermes-helper`), `--notes-helper`, `--version`. Its index is
`~/Library/Application Support/Hermes Helper/notes-index.db`; Minutes' index is untouched.

**Proactive paths (plumbing in code, judgment in Hermes):** feed changes and sent mail (`FeedNotifier`) and meetings starting within 35 min
(`MeetingPrep`, marker meta keys `meeting_announced:<event>`) → relay `POST /notify {records, kind}` → Hermes in Aaron's thread → Teams.
Mail and Teams messages people send Aaron (automated senders skipped: `FeedNotifier.automatedSenders`) wake her too; she offers
an ask as a card ("Jason asked you to … Add it to your to-do?") and creates it only on his yes; his next message carries a relay
note with what she posted on her own since her last answer (`buildAutomaticNote`), so the yes reaches a thread that knows the offer.
Aaron's sent Teams messages to anyone but her bot (`FeedNotifier` teams rule, the line names who the chat is with via
`NotesIndex.teamsChatPeople`) ride the same feed path (2026-10-20, Aaron: "I want her looking at sent messages just like mail").
**Mesh progress notes** (2026-10-20): a Claude session on Aaron's Mac runs `mesh send --to hermes --type notify`; launchd
`com.northwoods.hermes-mesh-bridge` on the laptop (`mesh-bridge/`, installed to `~/Library/Application Support/hermes-mesh-bridge/`,
log `~/Library/Logs/hermes-mesh-bridge.log`) claims `~/.claude/mesh/inbox/hermes/*.json`, forwards notify mail from local sessions
only (Aaron: "Just our sessions"; hub mail, asks, and broadcasts are archived unsent) over SSH to relay `/notify` kind `progress`
with the mesh id (relay state `progressSeen` dedupes), then `mesh archive` (or `mesh unclaim` on failure). Hermes files it in the
project's note and always tells Aaron in a line (his call: "yes to a teams line update untill I change my mind"). The mesh name
`hermes` was registered by claude-chat (dir `~/.claude/mesh/receivers/hermes`, `autoOpen: false`); never open Claude Code there.
Hermes's own cron jobs → `~/.hermes/cron/output/<job>/<time>.md` → relay `CronOutputWatcher` → **"Job review" prompt to Hermes** → Teams
(her reply, only the new part, or nothing). Each of Aaron's messages reaches
Hermes with a relay note appended (card first, note first, search first). Feed, meeting, and job-review prompts stay out of his chat and each
starts a fresh Hermes conversation (`ask({fresh: true})`): in the old shared `feed` thread a job review posted a calendar line from the
day before (2026-10-13 live test). **One update per thing**
(spec [docs/superpowers/specs/2026-10-13-hermes-one-update-design.md](docs/superpowers/specs/2026-10-13-hermes-one-update-design.md)): every
automated prompt ends with what the relay sent Aaron in the last 12 h (`lib/outbox.js`) and her jobs due in 2 h (`lib/jobs.js`); she
may change or remove her own jobs when they duplicate, and the relay reports any job change she did not name (jobs.json snapshot before/after).

**Documentation layer (Karpathy's "LLM wiki" on Apple Notes):** raw sources (feed index, his notes, transcripts, board) stay untouched; Hermes
maintains a compiled wiki in the Notes folder **Hermes** (`Project: <name>`, `<Person> (<org>)`, `List: <name>`, plus `Hermes index` and
`Hermes log`), plain text with fixed sections (Summary, Facts, Decisions, Open questions, People, Next, Items, Log; each line dated), rendered to
HTML by the helper and read back as plain text; schema in `SOUL.md` "Your notes"; a nightly tidy cron job fills gaps from the day's messages.

### Where things live
- `Packages/MinutesKit/` — pure, tested logic (attribution, speakers, transcript doc, Notes index, MCP tools)
- `Packages/AudioDeps/` — wraps vendored FluidAudio with its unused NeMo engine turned off
- `Minutes/Audio`, `Minutes/Pipeline`, `Minutes/Claude`, `Minutes/App`
- `Shared/Notes` — Notes bridge, indexer, AppleScript runner, compiled into both apps; `Shared/AppIdentity.swift` names the running app for logs/messages
- `HermesHelper/` — the mini's background app: main, `IndexService`, `NoteRequestSpool` (note writes relayed to the index service), Info.plist, entitlements, launchd template
- `hermes-teams/` — Node relay between the Teams bot and Hermes's API (lib/ incl. `relay.js` prompts + queue and `cron-output.js` watcher, test/, cloudflare/, launchd/, scripts/)
- `mesh-bridge/` — runs on Aaron's laptop, not the mini: carries mesh mail for `hermes` to the relay (`install-mesh-bridge.sh`)
- `hermes-tools/` — what runs on the mini but is not an app: `SOUL.md` (Hermes's standing rules, master copy) and the `pco-mcp/` mirror
- `Packages/MinutesKit/Sources/MinutesKit/Tools/` — `NotesTools` (search/list/get formatting), `TaskBoard` (Planka in one call), `HermesNote` + `HermesNoteWriter` + `NoteStore` (her notes)
- `Packages/MinutesKit/Sources/MinutesKit/Feed/` — `FeedRecord` + `FeedIndexer` (AI Feed files → index records), `FeedNotifier` (which changes wake Hermes), `MeetingPrep` (which meetings wake her)
- `scripts/` — build-and-run, fetch-deps, no-audio guard (+ self-test), audit-writes, mcp-smoke-test, deploy-helper / deploy-soul / deploy-pco-mcp (to the mini), power-automate/ flow generators

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
| Hermes Helper | `com.northwoods.HermesHelper` 0.1.0 (1); on `edit-3` (since 2026-10-08) at `/Applications/HermesHelper.app`, launchd `com.northwoods.HermesHelper`, log `~/Library/Logs/HermesHelper.log`; deploy with `scripts/deploy-helper.sh` |
| Hermes Agent (mini) | `~/.hermes/config.yaml` (model block → Puget `strata` since 2026-10-20, backup `config.yaml.bak-20261020-strata`; was `qwen-coder` from 2026-10-10, `gemma-bigctx` before; `tools.tool_search.enabled: "off"`; `mcp_servers.planka.tools.include: [cards]`; `mcp_servers.notes` + `mcp_servers.planka`; `tool_loop_guardrails.hard_stop_enabled: true`, `agent.max_turns: 60`; `model.context_length: 131072` with `compression.threshold_tokens: 56000` since 2026-10-12), `~/.hermes/SOUL.md` (standing rules; master `hermes-tools/SOUL.md`, deploy `scripts/deploy-soul.sh`), `~/.hermes/.env` (`API_SERVER_KEY`), CLI `~/.local/bin/hermes`, one-shot `hermes -z "…"`, gateway log `~/.hermes/logs/gateway.log`, session db `~/.hermes/state.db` (`messages`, read-only for debugging) |
| Teams relay (mini) | `hermes-teams/` in this repo → `~/hermes-teams` on the mini, launchd `com.northwoods.hermes-teams`, log `~/Library/Logs/hermes-teams.log`, config `~/hermes-teams/config/local.json` (600); local-only `GET /status` (`{busy, waiting}`); door `https://hermes.northwoodstech.workers.dev` (Worker `hermes`, tunnel `engineering-mac`, launchd `com.northwoods.cloudflared`); bot id `685fac05-84be-4bb9-aa30-4a2a430d22b1`; secrets master in OneDrive `VS Code/Assistant/secrets/` |
| AI Feed | OneDrive `AI Feed/{mail,calendar,teams}` written by Power Automate flows "AI Feed: mail/mail sent/calendar/teams" plus run-once backfills ([docs/guides/power-automate-ai-feed.md](docs/guides/power-automate-ai-feed.md); packages in OneDrive `VS Code/Assistant/flows/`, generators `scripts/power-automate/`); indexed by the helper every 2 min (account "AI Feed", ids `feed:<path>`, group keys `calendar:<event id>` / `teams:<message id>`) |
| Proactive loop | helper `FeedNotifier` (kind `feed`) and `MeetingPrep` (kind `meeting`) → relay `POST http://127.0.0.1:8787/notify` (`x-notify-key` = `notifyKey` in the relay's `config/local.json`) → Hermes in Aaron's home conversation → Teams; relay `CronOutputWatcher` posts `~/.hermes/cron/output/*/*.md` (state `postedOutputs`); task board list "Done" (id 1881546439595656482) on board "To Do"; relay state keys `outbox` (12 h, 40 entries) and `inReview`; job list read from `cronJobsFile` (`~/.hermes/cron/jobs.json`); log events `scheduled-reviewed` / `scheduled-review-failed` |
| Hermes cron | jobs "Scrum Prep Notes" `ebe61605a654` (Tue/Wed/Fri 9:00) and "Nightly notes tidy" (daily 11 PM, prompt in `docs/superpowers/plans/2026-10-10-hermes-documentation-layer.md` Task 7), both `deliver local` (the relay delivers); Hermes creates jobs with her `cronjob_manage` tool; `hermes cron list` on the mini |
| Hermes's notes | Apple Notes folder **Hermes** on the mini's iCloud (Aaron's account); tools `note_write {title, section, text, mode}` and `note_create {title, body}` on the helper's MCP server, listed only where a note store is wired (`HermesHelperMain`: `NoteRequestSpool.Client`, served by the `--index` service through `~/Library/Application Support/Hermes Helper/note-requests/`); sections fixed (`HermesNote.sectionNames`); limits 8,000 chars per note, 4,000 for `Hermes index`; writes via AppleScript only, never outside the folder |
| Task board tool | `task_board` on the helper's MCP server (`TaskBoard.swift`): Planka `GET /api/boards/<id>` with `X-Api-Key`, formatted one line per card (~90 chars) for every open list; config `~/Library/Application Support/Hermes Helper/task-board.json` on the mini only (mode 600: `baseURL`, `apiKey` = Hermes's `PLANKA_API_KEY`, `boardId`); the tool is listed only where that file exists, so Minutes' server for Claude Code never shows it. Beside it, `task_list_create {name}` (2026-10-14, Aaron: "let hermes create lists"): adds an open list before Done, refuses a name already on the board (any case) and a 21st open list; create only, because deleting a Planka list deletes its cards and the Planka MCP's `lists` tool would expose delete. `task_list_order {order}` (2026-10-20, Aaron: "Heremes needs to be able to reorder columns"): named lists first in that order, the rest keep theirs, all spaced evenly below Done; `PATCH /api/lists/<id> {position}` for each list that moves, positions only |
| Planning Center server | Weekend Rundown's `pco-mcp` (its folder is not under git; versioned mirror `hermes-tools/pco-mcp/`), on edit-3 at `~/pco-mcp` (venv, `mcp<2`, `pypdf`); tools incl. `song_prep`, `song_energy_note(s)`; Aaron's notes in `~/pco-mcp/song-energy-notes.json`; deploy `scripts/deploy-pco-mcp.sh` |

## Build / Run / Release
```bash
bash scripts/build-and-run.sh            # fetch deps, xcodegen, build, install to /Applications, relaunch
swift test --package-path Packages/MinutesKit
bash scripts/test-check-no-audio-writes.sh
bash scripts/mcp-smoke-test.sh
MINUTES_TRACE=1 /Applications/Minutes.app/Contents/MacOS/Minutes --transcribe-check [--both] [--save]
bash scripts/audit-writes.sh start  # … run a meeting …  bash scripts/audit-writes.sh report
bash scripts/deploy-helper.sh [host]     # Release-build Hermes Helper, install + (re)start its launchd agent on the mini
bash scripts/deploy-pco-mcp.sh [host]    # copy the Planning Center server (+ song prep) to the mini, pip install, restart Hermes
bash scripts/deploy-soul.sh [host]       # copy hermes-tools/SOUL.md to the mini (dated backup) + hermes gateway restart; deploy between turns
python3 scripts/power-automate/make-feed-flows.py sent|calendar <export.zip> <out.zip>   # import packages from Aaron's exports
bash hermes-teams/scripts/deploy-teams-relay.sh [host]   # copy the relay to the mini + restart its agent
bash scripts/wait-hermes-idle.sh [host]  # wait until the relay is idle (the deploy scripts that restart Hermes run it first)
bash mesh-bridge/install-mesh-bridge.sh  # on Aaron's laptop: the launchd bridge for the mesh name `hermes`
(cd hermes-teams && npm test)             # relay tests (node --test)
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
- **Never put a `TimelineView` in the `MenuBarExtra` label** (macOS 26.5): the host re-renders the status item in a tight
  loop and pins the main thread at 100% (Aaron's first live Start hung, 2026-10-08; reproduced with a scratch app, any
  schedule, any start date). The label reads a once-a-second `MeetingSession.now` instead. `TimelineView` inside the
  popover content is fine.
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
- **Hermes Helper has no Sparkle** (ruling 2026-10-07): UI-less launchd agent, redeployed over SSH. Its Notes grant is
  per bundle id; a launchd-run process gets the prompt on the mini's screen (Aaron clicks Allow once).
- **Hermes has no clock without its terminal tool** (its prompt tells the model to run `date`, and the terminal is off):
  it told Aaron a 2 pm meeting was "coming up" at 2:32. The helper's MCP server now serves `current_time` and `SOUL.md`
  says to call it before anything time-dependent.
- **Hermes config.yaml:** `provider: "auto"` appears 9 times; edit only the `model:` block (regex to the next top-level key).
  No API key is needed for `provider: custom` against llama-server. `hermes doctor` validates; `hermes -z "…"` is one-shot.
- **zsh does not word-split `$VAR`**: `kill $PIDS` fails with "illegal pid"; pipe `pgrep` into `xargs kill`. The sandbox
  can't signal detached (`nohup`) processes either; killing the bench needed the sandbox off.
- **OneDrive files are cloud placeholders** on the mini until something reads them; a background process gets
  "Resource deadlock avoided" unless it opts in (`setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES…)`, plus
  `MaterializeDatalessFiles` in the launchd plist). A file still downloading is counted "unreadable" and retried.
  **The helper's first touch of the OneDrive folder raises a macOS permission prompt on the mini's screen** and its
  directory open blocks until someone clicks Allow (edit-3, 2026-10-08: stuck 25 min, a shell over SSH read the same
  folder fine). The helper also keeps looking for the folder every 2 min, since OneDrive is usually signed in after it starts.
- **Never list a OneDrive folder with `FileManager.enumerator`** in a long-lived process: on edit-3 the helper kept getting the
  listing as it was at launch and never saw files written later (new mail waited for a restart). `FeedIndexer.listing()` now
  does plain `contentsOfDirectory` reads two levels deep, which see new files at once. The feed is also read calendar and
  mail first, 250 files per pass (a Teams backfill of thousands of files no longer delays new mail), and a `feed_format`
  version in the index triggers a full re-read when record text changes shape (calendar titles now carry the local date).
- **Outlook writes several files per calendar event** (added, added, updated, updated); feed records carry a
  `group_key` (`calendar:<event id>`) and the newest file replaces the rest (index schema 2, migrates in place).
- **Outlook re-sends a whole recurring series, word for word, whenever it is touched** (2026-10-09: nine identical
  copies of every Weekend Tech Rehearsal in 90 min). Each burst became a 12-line feed event, each took Hermes 2-5 min on
  Puget, and they shared the relay's one queue with chat, so Aaron's questions waited 10+ min ("Hermes isn't responding").
  Now: the indexer marks a rewrite identical to the indexed record `unchanged` and the notifier drops it; a series groups
  by title without the " — <date>" suffix; the relay runs Aaron's messages ahead of waiting feed events and merges
  waiting events into one prompt (up to 24 records).
- **Two hidden 300 s limits** cut Teams answers off behind a busy Puget queue (2026-10-09): Node's built-in `fetch`
  drops a response slower than 300 s (undici `headersTimeout`; the relay now uses `node:http`, so its own 20-min abort
  is the only deadline), and Hermes's history compression times out at 300 s (edit-3 `config.yaml` now sets
  `auxiliary.compression.timeout: 900`; backup `config.yaml.bak-20261009`). Feed events land in Aaron's own thread, so
  it reaches the compression threshold (56K tokens) faster than chat alone would.
- **At 65K, compaction had no room to fail** (2026-10-12): Aaron's thread stopped answering with "Context compression could
  not bring this session under the model's context window (~66,149 tokens vs 65,536)". Hermes floors small windows' trigger
  at 85% (55,705); the 20 protected recent messages were 16.5K (three 10K-char note searches in one turn) and the other
  ~49.6K was the system prompt (33K chars), the tool list, and two summaries from earlier compactions (39K chars). Nothing between
  the summaries and that tail was left to summarize (`failure_class: empty_post_handoff_window`), and once the request is
  over the window Hermes refuses to send it. Fix: `model.context_length: 131072` (qwen-coder then served 256K) and
  `compression.threshold_tokens: 56000` (backup `config.yaml.bak-20261012-headroom`). The per-result and per-turn tool
  budgets scale with the window too (~78K / ~157K chars now), so fewer results spill to files.
- **A recurring meeting flooded search** (2026-10-13): each occurrence of an Outlook series is its own calendar record, so
  "Scrum" returned 12 occurrences in the top 20 and Feb 2027 occurrences as the "newest matches". Jason's Monday "we will skip
  scrum on Tuesday" never reached Hermes, and her meeting-prep brief said nothing new had come from him. `search_notes` now
  shows a series as one line (occurrence count, next and last start, the next one's id), fetches more hits until the list
  is full, and "newest matches" stop at now. The same live search went from 20 of 68 to all 68 in 14 lines.
- **Two updates for one meeting** (2026-10-13): the 8:46 meeting prep and the 9:00 "Scrum Prep Notes" job both briefed the 9:20
  Scrum, because three paths posted to Teams without knowing about each other, and job output was posted raw. Now every job's
  output goes back to Hermes as a "Job review" (not "Scheduled job": SOUL's in-job rule says answer `[SILENT]`, which leaked as text
  in review), with the outbox and her jobs due. A nag reminder's own next run is left out of "jobs due" or she would suppress it.
  A finished one-shot is `enabled:false, state:completed` in jobs.json, which is not a change she made. If Teams refuses the post,
  the reviewed text is kept and only the send is retried, a full poll later (each retry used to cost a Puget turn).
- **Scrum notes three times** (2026-10-14): Aaron asked at 8:38, the answer took 5 min behind Puget's queue, he asked again at 8:43
  and got the same notes twice; the 9:00 job's review then posted them a third time at 9:21 because the outbox cut each entry to
  700 chars (she saw half of each chat answer) and the prompt had no clock. Now a message sent while his previous one was still being
  answered carries a relay note saying so (`buildResentNote`; a repeat gets one line pointing up), outbox entries keep 3,000 chars in a
  12,000-char section, and every automated prompt says "It is now …". Replay of that review with the new prompt: two new Dante lines
  instead of the whole brief.
- **Jobs land late on a busy Puget** (2026-10-14): the 9:00 scrum brief's runs took 42, 2, and 19 min, so it finished at 9:19 for a
  9:20 meeting. Aaron: Hermes should plan for this herself. The relay keeps each job's last six run times (state `jobRuns`: start =
  `last_dispatch.dispatched_at` in jobs.json, finish = the output file's name), each Job review says when the run started and
  finished, how long recent runs took, and to move the job earlier (`cronjob_manage` `update` with `schedule`) if its slowest run
  plus the review lands less than 15 min before what it prepares for; the jobs-due list shows the same numbers; `SOUL.md`
  "Plan for how long a job takes" covers creating a job. The scrum job's three runs were seeded by hand.
- **A deploy can swallow Aaron's question** (2026-10-20, twice): his 4:26 PM board answer never reached Teams (relay restarted
  mid-turn), and a 4:51 PM message failed with "ECONNREFUSED 127.0.0.1:8642" (gateway restarting while it waited in line). The relay
  now serves local-only `GET /status` (`{busy, waiting}`; the Worker forwards only `/webhooks/teams` and `/health`), and
  `scripts/wait-hermes-idle.sh` runs first in `deploy-soul.sh`, `deploy-teams-relay.sh`, and `deploy-pco-mcp.sh` (20 min limit,
  then it refuses). A few seconds between the check and the restart remain open.
- **OneDrive on edit-3 stopped noticing changes** (2026-10-20): its SyncDiagnostics said 0 changes to process while the AI Feed
  was five hours behind Aaron's laptop (mail, Teams), so Hermes saw nothing new that afternoon. `killall OneDrive; open -a OneDrive`
  over SSH caught it up within a minute. Check: compare `ls -t "AI Feed/mail" | head -1` on the laptop and the mini. Records that
  arrive late are older than `FeedNotifier.freshness` (1 h) by item time and never wake her. No automatic detection yet.
- **Made-up card ids froze the board tool** (2026-10-20): moving cards to a new MJ list, she sent six `cards update` calls with ids
  not on the board ("Card not found"); Hermes's MCP circuit breaker then paused `planka` and refused her retry with real ids, and the
  loop guard stopped the turn. `task_card_move` (helper MCP) moves cards by name in one call; SOUL uses it for every move and Done.
- **Walls of text in Teams** (2026-10-20, Aaron: "I'm getting just walls of text from her"). Two causes. Teams joins two plain
  lines that a single newline separates (the job name and the brief's first line arrived as one line), so the relay now runs
  every outgoing message through `toTeamsMarkdown` (`lib/teams.js`: a blank line between plain lines; list items and code
  fences keep single newlines). And the Job review turned the job's bold-topic-and-bullets brief into one paragraph per
  topic, because every prompt said "short" and "lines" and `SOUL.md` said "never answer a task with a bulleted list". Now
  `SOUL.md` "How to write" sets the layout (answer line, one fact per bullet under ~20 words, a bold line per topic, no
  emoji status), the Job review says keep the output's layout and drop bullets rather than merge them, meeting prep asks for
  bullets under bold labels, and the relay note asks for the same. A two-topic test question came back in that layout in 83 s.
  The same relay deploy shipped the 2026-10-14 job-timing work, which had been built and tested but never deployed.
- **Puget's gateway needs `X-Client`** and streaming; Hermes sends both via `model.default_headers` and its default
  `stream: true`. **Since 2026-10-20 Hermes uses `strata`** (Qwen3.8-Flash-Next 125B MoE on GPU 0, its own lane reserved
  for the Hermes agents, up to 262144 context); every app shares the other lane (`qwen3.8-27b`, 131072 shared by 4 slots;
  the old names `gemma`, `gemma-bigctx`, `qwen-coder` land there). Hermes's window stays 131072 with compression
  pinned at 56K (`compression.threshold_tokens: 56000`), so a normal chat stays the size it was at 65K and the space above
  56K is headroom (see the compaction gotcha). Each lane is strict first come, first served and there are no model swaps any
  more; before the switch a question could wait minutes behind a Weekend Rundown build (worst seen 6.7 min) and Aaron's
  2026-10-20 9:19 message timed out at 20 min. A caller that disconnects loses its place, so the Teams relay waits up to 20 min. Live view:
  Box Status Board `http://10.11.4.170:8777` (Hermes shows as "hermes"). Hermes's `hermes gateway restart` drains the current turn first, so a restart mid-question shows
  as "Hermes couldn't answer: fetch failed" in Teams.
- **An erased Mac defaults to Pacific time** (edit-3 came up `America/Los_Angeles`, two hours behind the fleet's
  `America/Chicago`), which skews Hermes's sense of "today" and calendar times; `setup-assistant-mac.sh` step 1 now sets
  the zone, and `hermes gateway restart` is needed for a running gateway to notice.
- **Memory on the 16 GB mini:** the local 12B at 64K context pinned 10.4 GB and pushed 12.6 GB to swap; a quantized
  KV cache (`-ctk q8_0 -ctv q8_0 -fa on`) fixed it before the model was removed altogether.
- **Hermes cron cannot deliver to the API server** (its deliver targets are its own chat platforms; `api_server` is reply-only). A job
  Aaron asked for ran 42 min and its brief sat in `~/.hermes/cron/output` (2026-10-09). The relay's `CronOutputWatcher` posts each new
  output file (skips `[SILENT]`, flags `[CRON_FAILURE]`, never replays files older than 10 min at startup); jobs use `deliver local`. The
  output file is written by the run itself, whatever the delivery target.
- **Gemma follows a rule next to the message, not one 20K tokens up the system prompt.** `SOUL.md` said the board is the only task list; a
  dozen tasks still became chat lists (2026-10-09). The relay now appends a one-paragraph note under each of Aaron's messages (card first,
  search first), and `SOUL.md` spells tool calls as exact JSON: the shorthand "boards get <id>" produced `{"boardId": …}` and the tool was
  never invoked. Planka card creation needs `"type":"project"` or the board answers 400.
- **A tool result over 50K chars is spilled to a file** (`tool_budget.mcp_result_size_chars`), and `boards get` on the To Do board is
  already over it. Gemma then tried to read the file through the `tool_call` wrapper, got "'read_file' is a directly-listed tool", and
  repeated the identical call 18 times (one Puget turn each, an hour) because `tool_loop_guardrails.hard_stop_enabled` was false and
  `max_turns` 500; Aaron's question behind it timed out at 20 min. Now `hard_stop_enabled: true`, `max_turns: 60`, and `SOUL.md` says
  `cards list` per list (small) and `read_file` called directly. `launchctl kickstart -k gui/$(id -u)/ai.hermes.gateway` ends a wedged
  run in 30 s (`hermes gateway restart` waits up to 30 min for it).
- **The notes tool's folder filter was exact and silent.** For "my notes on the atrium" Hermes passed folder "notes" (by analogy with
  "mail"/"teams"), got "No notes match", and told Aaron he had none (2026-10-09) while an "Atrium" note, 13 of his own Teams messages
  from the day before, and the Oct 8 transcript were all indexed. Now a folder name matches regardless of case, "notes" means every
  account but the AI Feed (`NoteScope.ownNotes`), "email"/"transcripts"/"chats" land on their folders, and an unknown name is a tool
  error that lists the real folders. `SOUL.md`: "my notes" means his notes, transcripts, and what he told her in Teams; search with no folder.
  Second miss the same evening: an unfiltered "atrium" search returned the 20 most relevant of 134 hits (a June chat first) with nothing
  saying more existed, and she ignored the "20 of 134, narrow with since" line when it was added. Now a cut result also lists the newest
  matches by date, the `since` help says to pass it whenever he names a day, and the relay note says the same next to his message
  (that version answered "my notes on atrium from yesterday" correctly in 308 s). Card rule in the note now says "if this message names
  something he has to do": the first version made her file cards from the day-old messages the search turned up.
- **Feed records are dated by the file, not the item.** `modified_at` is when the flow wrote the file, so the Oct 8 backfill made 6,746
  old emails and chats look modified "today": `since` on mail/teams was useless and Hermes quoted file times as dates ("Modified today,
  3:58 PM" for an older email). The tools now filter, sort, and label by the item's own time (`datedAt`: sent for mail/Teams, start for
  calendar); the column itself is unchanged because the indexer uses it for change detection.
- **"Remind me every 30 minutes until I do it" became a forever job** (2026-10-09 13:58): each run searched mail for 4-11 min of Puget
  time and nothing would ever stop it. `SOUL.md` now gives the exact schedule forms (one-shots are "in 30m" or an ISO time) and a
  self-ending prompt for nag reminders: check the card with `cards list`, and when it is gone, `cronjob_manage remove` the job (found
  by name with `cronjob_manage list`; jobs are named after their card) and answer `[SILENT]`. The live job was edited the same way.
- **"Open my todo" got one list of eight** (2026-10-10): `SOUL.md` said "start with General To Do" and "summarize counts and the few most
  relevant cards", so Hermes listed General To Do (24 cards) and Aaron, who had 71 open cards and remembered more, did not trust it. Ten
  items from the Oct 8-9 chat had never become cards at all (Kirk/Blake confirmations, storage with Tiffany, Jason's Dante update, kids'
  room audio, three Blake cost projects, lighting pricing); added by hand 2026-10-10, descriptions say so. The rule now names all eight
  open lists with ids, one `cards list` each in the same turn, every card shown; `boards get` is never used (it spills and started the
  runaway loop). Same morning she answered "Moved '…' to Done" with no tool call made: the rule now says move first, report only a move
  that succeeded. The eight-list rule then failed on its own weight: eight `cards list` results (80K chars, ~830 per card with every null
  field and the callers' user records) blew Hermes's per-turn tool budget, which is scaled to the model's context (65K tokens: ~39K chars
  per result, ~79K per turn, `tools/budget_config.py`), the 28K General To Do result spilled, and Gemma again tried to read it through
  `tool_call` until the hard stop. Fix is plumbing: the helper's MCP server now serves `task_board`, the whole board in one ~9K call
  (see Key identifiers); every board-reading rule in `SOUL.md` uses it. A one-shot "open my todo" with the relay note then listed all lists.
- **Apple Notes returns headings as bare lines.** A note written with `<h2>Facts</h2>` comes back from `plaintext` as the line "Facts", so
  `HermesNote` recognizes sections by a fixed vocabulary (and tolerates "## Facts"), never by markers. Notes names a note after its first line,
  so the title rides in an `<h1>` and `note_create`'s body is content only. Last write wins inside the Hermes folder (a re-list before every write
  costs seconds); his own notes are never matched for writing, whatever their title.
- **Only the index service may talk to Notes.** A `--notes-helper` child spawned under Hermes's gateway (python → `HermesHelper --mcp` →
  child) never completed an AppleScript call: macOS's automation consent was granted to the launchd-started helper, not to that chain, and
  the consent-blocked event wedged Notes.app itself ("AppleEvent timed out" for the index service too, twice on 2026-10-10, fixed each time
  by `killall Notes`). No consent record was readable from `log show`. Note writes therefore go through `NoteRequestSpool`: the MCP server
  drops `<id>.json` (a `NotesRequest`) in `~/Library/Application Support/Hermes Helper/note-requests/`, the index service serves it with its
  own `NotesBridge` and drops `<id>.reply.json`; the first write through it took 10 s. The server enforces the scope itself (any same-user process could drop a request): list and show refused, create only into the Hermes folder, read or rewrite only after confirming a note's folder, five ids per read, and the spool directory must be this user's with mode 700. The writer also never lists notes (the index plus a
  cache finds them) and confirms the folder with one `folderOf` event before editing, so a note Aaron moved out is left alone. If a
  `note_write` ever times out again, check the helper log's "last refresh": a stale one means Notes is wedged, and `killall Notes` clears it.
- **Never drive Notes from an SSH shell on the mini** (`osascript -e 'tell application "Notes" …'`): it waits for a consent prompt nobody
  sees and wedges Notes.app for every client until `killall Notes` (2026-10-10, third time). Go through the helper's spool instead.
- **`container of note` fails on macOS 26.5** ("Can't get name of container of note id …"). The first folder check used it, every lookup
  read as "note moved", and `note_write` created a fresh note each time: ten copies of three notes in one tidy run (2026-10-10). `folderOf`
  now looks the id up folder by folder. Duplicates were merged into the newest copy; the older copies are titled "Duplicate of … (safe to
  delete)" because nothing in the helper can delete a note, by design.
- **Hermes's deferred-tool bridge fails with small local models** (`tools.tool_search`, default `auto`, hides MCP and plugin tools behind
  `tool_search` / `tool_describe` / `tool_call`). Hermes issues #110442 (Qwen's `<tool_call>` tag collides with the bridge name), #135762 (no way to
  keep MCP tools direct; 9B model failed 10 of 10), #96247 (1,523 `tool_search` calls; `enabled: "off"` fixed it) are our two `read_file` loops.
  The documented workaround is `tools.tool_search.enabled: "off"` with `mcp_servers.<name>.tools.include` keeping the eager list small
  (`~/bakeoff/apply-config.sh` on the mini applies it with a dated backup); the per-turn tool budget (`tools/budget_config.py`: 15% of the
  context window per result, 30% per turn, so ~39K and ~79K chars at 65K tokens) is what spilled a 28K result when eight list calls ran in one turn.
- **Meeting wake-ups come from the index, not OneDrive:** feed calendar records store the event start as `created_at`
  (`NotesIndex.upcoming`); one marker per Outlook event id (meta `meeting_announced:<group key>`, value = start ISO) keeps a series
  rewrite quiet and re-announces a moved meeting. No attendees, all-day (≥ 23 h), deleted and cancelled events are skipped before Hermes is
  woken; a routine rehearsal reaches her and she answers NO_MESSAGE.

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
| 2026-10-08 | Hermes Helper target built and live on the mini; Minutes removed there; Hermes Agent + Gemma 12B set up; bench stopped on the preview |
| 2026-10-08 | Teams relay + Cloudflare door live; AI Feed (mail, calendar) indexed; model moved to Puget's Gemma 31B, local 12B removed; Planka MCP; SOUL rules |
| 2026-10-08 | Host migrated engineering-mac → edit-3 (setup-assistant-mac.sh); Planning Center MCP (Weekend Rundown's pco-mcp) registered; decommission script written |
| 2026-10-08 | Engineering mini wiped; Edit 3 time zone; Minutes menu-bar hang fixed; clock tool; Teams/calendar/sent flows + backfills; song prep tools; proactive loop (helper → relay /notify → Hermes → Teams) |
| 2026-10-09 | Hermes initiative: cron-output voice, meeting wake-ups, relay note, SOUL.md versioned + exact tool JSON, 13 tasks backfilled; runaway tool loop found and capped (hard stops on, 60 turns) |
| 2026-10-09 | "Hermes couldn't find my notes": folder names resolve loosely and unknown ones are errors; feed records dated by item time; self-ending reminder jobs |
| 2026-10-10 | "Todo isn't comprehensive": `task_board` tool (whole board, one call) on the helper's MCP server; SOUL reads the board through it; verified Done moves; stop-reminder rule; 10 chat-only tasks added to the board |
| 2026-10-10 | Documentation layer: her notes in Apple Notes (`HermesNote`, `note_write`/`note_create`), capture rule, feed prompts in their own thread, SOUL "Your notes"; research on platform options and on how others keep agent documentation; bake-off runner |
| 2026-10-12 | "Compression could not bring this session under the window": Hermes window 65K → 131K, compression pinned at 56K for headroom |
| 2026-10-13 | Two scrum briefs, one missing Jason's cancellation: `search_notes` collapses recurring meetings, "newest" stops at now |
| 2026-10-13 | One update per thing: job output reviewed by Hermes with the outbox and jobs due; she fixes duplicate jobs, the relay reports changes |
| 2026-10-14 | Scrum notes three times: re-sent message note, whole answers in the outbox, current time in automated prompts |
| 2026-10-14 | Hermes plans job timing: relay run log, timing in Job review and jobs due, SOUL lead-time rule |
| 2026-10-14 | Icebox list on the board; `task_list_create` (create-only) on the helper's MCP server; SOUL names every list and how to move a card |
| 2026-10-20 | Hermes moved to Puget's `strata` lane (two-lane cutover); Teams layout fix: `toTeamsMarkdown` in the relay, SOUL layout rule, review keeps layout; job-timing relay deployed |
| 2026-10-20 | Sent Teams messages wake Hermes like sent mail; Hermes is a receive-only mesh member (bridge on the laptop → relay kind `progress`) |
| 2026-10-20 | `task_list_order` on the helper's MCP server; SOUL list-order rule; a progress note may unblock a request Aaron made |
| 2026-10-20 | Incoming asks offered as cards; `task_card_move` by name; relay `/status` + `wait-hermes-idle.sh` in deploys; OneDrive stall on edit-3 found and restarted; web search confirmed on, query privacy rule |
