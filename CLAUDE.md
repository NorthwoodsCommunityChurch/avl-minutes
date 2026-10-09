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

## Status — 2026-10-09
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
Hermes's own cron jobs → `~/.hermes/cron/output/<job>/<time>.md` → relay `CronOutputWatcher` → Teams. Each of Aaron's messages reaches
Hermes with a relay note appended (card first, search first).

### Where things live
- `Packages/MinutesKit/` — pure, tested logic (attribution, speakers, transcript doc, Notes index, MCP tools)
- `Packages/AudioDeps/` — wraps vendored FluidAudio with its unused NeMo engine turned off
- `Minutes/Audio`, `Minutes/Pipeline`, `Minutes/Claude`, `Minutes/App`
- `Shared/Notes` — Notes bridge, indexer, AppleScript runner, compiled into both apps; `Shared/AppIdentity.swift` names the running app for logs/messages
- `HermesHelper/` — the mini's background app: main, `IndexService`, Info.plist, entitlements, launchd template
- `hermes-teams/` — Node relay between the Teams bot and Hermes's API (lib/ incl. `relay.js` prompts + queue and `cron-output.js` watcher, test/, cloudflare/, launchd/, scripts/)
- `hermes-tools/` — what runs on the mini but is not an app: `SOUL.md` (Hermes's standing rules, master copy) and the `pco-mcp/` mirror
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
| Hermes Helper | `com.northwoods.HermesHelper` 0.1.0 (1); on `engineering-mac` at `/Applications/HermesHelper.app`, launchd `com.northwoods.HermesHelper`, log `~/Library/Logs/HermesHelper.log`; deploy with `scripts/deploy-helper.sh` |
| Hermes Agent (mini) | `~/.hermes/config.yaml` (model block → Puget `gemma-bigctx`; `mcp_servers.notes` + `mcp_servers.planka`; `tool_loop_guardrails.hard_stop_enabled: true`, `agent.max_turns: 60`), `~/.hermes/SOUL.md` (standing rules; master `hermes-tools/SOUL.md`, deploy `scripts/deploy-soul.sh`), `~/.hermes/.env` (`API_SERVER_KEY`), CLI `~/.local/bin/hermes`, one-shot `hermes -z "…"`, gateway log `~/.hermes/logs/gateway.log`, session db `~/.hermes/state.db` (`messages`, read-only for debugging) |
| Teams relay (mini) | `hermes-teams/` in this repo → `~/hermes-teams` on the mini, launchd `com.northwoods.hermes-teams`, log `~/Library/Logs/hermes-teams.log`, config `~/hermes-teams/config/local.json` (600); door `https://hermes.northwoodstech.workers.dev` (Worker `hermes`, tunnel `engineering-mac`, launchd `com.northwoods.cloudflared`); bot id `685fac05-84be-4bb9-aa30-4a2a430d22b1`; secrets master in OneDrive `VS Code/Assistant/secrets/` |
| AI Feed | OneDrive `AI Feed/{mail,calendar,teams}` written by Power Automate flows "AI Feed: mail/mail sent/calendar/teams" plus run-once backfills ([docs/guides/power-automate-ai-feed.md](docs/guides/power-automate-ai-feed.md); packages in OneDrive `VS Code/Assistant/flows/`, generators `scripts/power-automate/`); indexed by the helper every 2 min (account "AI Feed", ids `feed:<path>`, group keys `calendar:<event id>` / `teams:<message id>`) |
| Proactive loop | helper `FeedNotifier` (kind `feed`) and `MeetingPrep` (kind `meeting`) → relay `POST http://127.0.0.1:8787/notify` (`x-notify-key` = `notifyKey` in the relay's `config/local.json`) → Hermes in Aaron's home conversation → Teams; relay `CronOutputWatcher` posts `~/.hermes/cron/output/*/*.md` (state `postedOutputs`); task board list "Done" (id 1881546439595656482) on board "To Do" |
| Hermes cron | job "Scrum Prep Notes" `ebe61605a654` (Tue/Wed/Fri 9:00, `deliver local`; the relay delivers); Hermes creates jobs with her `cronjob_manage` tool; `hermes cron list` on the mini |
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
  it reaches the compression threshold (~55.7K of 65K tokens) faster than chat alone would.
- **Puget's gateway needs `X-Client`** and streaming; Hermes sends both via `model.default_headers` and its default
  `stream: true`. Puget's `gemma-bigctx` has n_ctx 262144 (confirmed by the puget session 2026-10-08); Hermes's
  `context_length` stays 65536 on purpose, so one long chat never ties up the box's single slot. The queue is strict
  first come, first served: a question can wait minutes behind a Weekend Rundown build (worst seen 6.7 min) plus a
  15-25 s model swap, and a caller that disconnects loses its place, so the Teams relay waits up to 20 min. Live view:
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
