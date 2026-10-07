# Assistant direction (decided 2026-10-07)

Where the "personal assistant" project landed after a day of research with Aaron. This is the record a fresh session resumes from; the earlier notes are [Puget summaries](2026-10-07-puget-meeting-summaries.md) and [16 GB models + Hermes](2026-10-07-16gb-assistant-models.md).

## The shape

| Piece | Where | Role |
|---|---|---|
| **Minutes** | Aaron's laptop | Transcribes meetings into Apple Notes. That's all. (Its Claude search server stays for Claude Code on the laptop.) |
| **Hermes Agent** (Nous Research, MIT) | The mini | The always-on assistant: memory, scheduled jobs, phone channels, skills. Model-neutral. |
| **Hermes Helper** (to build; name changeable) | The mini | A small background app with its own name: keeps a search index of Aaron's Notes (and later the OneDrive AI Feed), serves it to Hermes over MCP, and later lets Hermes write digests back to Notes. Same engine as Minutes' index (`MinutesKit` + the Notes bridge), separate target. |
| **Power Automate → OneDrive "AI Feed"** | Aaron's M365 account | Flows copy new mail, calendar items, and Teams chats into a OneDrive folder the mini syncs. Aaron is building these; design in the 2026-10-07 chat ("guide me through the power automate setup"). |
| **The model** | Puget (`gemma-bigctx`, Gemma 4 31B) over the LAN, or Gemma 4 12B on the mini | Decided by the summary bench scorecard (`bench/results/REPORT.md`). Puget keeps nothing: streamed requests only. |

Ruled out today: Microsoft Graph / Entra app registration (tenant requires admin consent; Aaron declined the MSP route; everything was cleaned up), any API key or pay-per-token Claude in Hermes (Anthropic bars subscription use in third-party harnesses), Canopy listing, custom icon, release script, a Raspberry Pi (no Notes/iCloud on Linux).

Later: wire Hermes to Teams (not native in Hermes; plan is a Power Automate bridge both ways, no admin needed).

## The mini

`engineering-mac` in `SSH-ACCESS.md`: 10.11.1.103, Mac mini M4, 16 GB, macOS 27.0.1, user `mediaadmin` (passwordless sudo, our key), MSP-managed (SentinelOne, ConnectWise, Self Service stay). Repurposed from the engineering workstation with Aaron's OK; ProPresenter and Teams deleted by Aaron, their leftovers and a Pro7 helper daemon moved to `~/.Trash/leftovers-20261007-1504/` (1.2 GB).

Done on it 2026-10-07: never sleeps, restarts after power failure, Wake-on-LAN on; auto-login on; iCloud signed in (Notes syncing, 120+ notes); OneDrive signed in and syncing; Homebrew 7.0.8 + `llama.cpp` installed; `~/models/gemma-4-12b-it-Q4_K_M.gguf` downloaded; Puget reachable (5 ms); **Minutes 0.1.0 (release build) installed and running, Notes Automation granted, index at 120 notes — to be removed and replaced by Hermes Helper (approved).**

Measured on the mini (Gemma 4 12B, 64K context, llama-server): 10-minute meetings in 144–174 s (prompt ~140 tok/s, generation ~11–12 tok/s); memory wired 9.9 GB with 0.1 GB free while the Minutes menu bar app also had speech models loaded. Expect about 4–5 minutes for an hour-long meeting. The helper (no speech models) will free about 1 GB.

## The bench

`bench/finish.sh` runs detached (nohup) and writes progress to `bench/results/orchestrate.log`: preview judge of m01–m05 → full passes for all five contestants → judge all 30 → `bench/results/REPORT.md`. Look for `PREVIEW SCORECARD READY` and `FULL SCORECARD READY`. Early hand read (meetings 1 and 5): no model fell for the traps; Gemma 31B most precise; Sonnet over-lists; Gemma 12B and Qwen 9B mis-file action items as decisions; Qwen 9B thinks 3–4× longer than Gemma 12B for no visible gain.

## Next steps, in order

1. Read the preview scorecard; spot-check the judge on 2–3 meetings (judge-check per the bench spec).
2. Build **Hermes Helper**: new XcodeGen target sharing `MinutesKit` + `Minutes/Notes/*`; modes `--index` (default under launchd) and `--mcp`; LSUIElement, no windows; own bundle id (`com.northwoods.HermesHelper`). Install on the mini as a launchd user agent; Aaron clicks Allow for Notes once. Then quit Minutes on the mini, `Minutes --unregister-login`, delete `/Applications/Minutes.app` and its Application Support folder.
3. Install Hermes on the mini (official installer; macOS); point it at the chosen model; register the helper as a stdio MCP server; test "search my notes" end to end. Keep Honcho off (local memory files only) unless Aaron decides otherwise.
4. Phone channel (Discord or Telegram first; Teams bridge later).
5. OneDrive AI Feed: once Aaron's flows produce files, extend the helper's index to them.
