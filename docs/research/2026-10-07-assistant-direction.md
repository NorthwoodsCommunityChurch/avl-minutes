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

Done on it 2026-10-07: never sleeps, restarts after power failure, Wake-on-LAN on; auto-login on; iCloud signed in (Notes syncing, 120+ notes); OneDrive signed in and syncing; Homebrew 7.0.8 + `llama.cpp` installed; `~/models/gemma-4-12b-it-Q4_K_M.gguf` downloaded; Puget reachable (5 ms). **Done 2026-10-07 night:** Minutes removed from the mini (app, data, FluidAudio models, login item, Notes grant); **Hermes Helper 0.1.0** installed as launchd agent `com.northwoods.HermesHelper` (Notes allowed by Aaron, 118 notes indexed, log `~/Library/Logs/HermesHelper.log`); **Hermes Agent v0.21.5** installed (`~/.hermes`, CLI `~/.local/bin/hermes`, Python 3.14 via uv, browser/computer-use tools came with the default install); **Gemma 4 12B** served by launchd agent `com.northwoods.llama-server` (`llama-server -c 65536 -ngl 99 --jinja --reasoning-format deepseek --alias gemma-4-12b`, 127.0.0.1:8080, RSS 8.1 GB, free memory 23%); Hermes `config.yaml` model block → `provider: custom`, `base_url: http://127.0.0.1:8080/v1`, `context_length: 65536`; `mcp_servers.notes` → `HermesHelper --mcp`. First end-to-end run: `hermes -z "find my notes about projectors…"` returned three real note titles in 2 m 48 s. No external memory provider (Honcho off).

Measured on the mini (Gemma 4 12B, 64K context, llama-server): 10-minute meetings in 144–174 s (prompt ~140 tok/s, generation ~11–12 tok/s); memory wired 9.9 GB with 0.1 GB free while the Minutes menu bar app also had speech models loaded. Expect about 4–5 minutes for an hour-long meeting. The helper (no speech models) will free about 1 GB.

## The bench

`bench/finish.sh` runs detached (nohup) and writes progress to `bench/results/orchestrate.log`: preview judge of m01–m05 → full passes for all five contestants → judge all 30 → `bench/results/REPORT.md`. Look for `PREVIEW SCORECARD READY` and `FULL SCORECARD READY`. Early hand read (meetings 1 and 5): no model fell for the traps; Gemma 31B most precise; Sonnet over-lists; Gemma 12B and Qwen 9B mis-file action items as decisions; Qwen 9B thinks 3–4× longer than Gemma 12B for no visible gain.

## Decision: the model (2026-10-07)

Aaron stopped the bench at 15:52 with the 5-meeting preview judged (all five contestants, two passes) and timing from every finished run. Gemma 4 12B and Qwen 3.5 9B tied on quality (every decision found, nothing invented, one dropped action item each in one pass) but Qwen took twice as long (159 s vs 81 s typical per 10-minute meeting on the laptop; ~6,300 vs ~1,500 output tokens) and failed the 180 s bar. Aaron chose **Gemma 4 12B on the mini** ("setup hermes with 12b on the mini"): transcript text never leaves the mini. Puget's Gemma 31B (43 s typical, most precise) remains a three-line config change away. Full table: [bench/FINDINGS.md](../../bench/FINDINGS.md).

## 2026-10-08: where it landed

- **Teams is the channel** (not Discord/Telegram): a Teams bot "Hermes" (Developer Portal) → Cloudflare Worker `hermes` → tunnel `engineering-mac` → `hermes-teams` relay → Hermes API server. Spec: [2026-10-08-hermes-teams-relay-design.md](../superpowers/specs/2026-10-08-hermes-teams-relay-design.md). Aaron: "we ARE NOT using fallbacks".
- **Tools:** terminal, browser, computer use, file, code, delegation, image, speech, and the clarifying-question tool are off (CLI and API platforms). Web search stays on (keyless free tiers).
- **AI Feed:** flows for mail and calendar live (Aaron built them with the guide); Teams chat flow pending. The helper indexes the folder every 2 minutes.
- **Model:** moved from the local Gemma 12B to **Puget's Gemma 31B** (`gemma-bigctx`) on Aaron's call once he saw the mini could host Hermes while Puget hosts the model; the local server/model/llama.cpp were removed. The 16 GB mini had been swapping 12.6 GB with the 12B resident.
- **Task board:** Planka registered as MCP server `planka` (same `@chmald/planka-mcp` as Claude Code, Aaron's API key).
- **Persona:** `SOUL.md` tells Hermes to look unknown things up on its own, never ask to research, answer briefly.

## 2026-10-08 afternoon: host moved to Edit 3

Aaron: "Since we aren't running a model local for hermes" the erased former video director mini (M1, 16 GB, renamed **DC - Edit 3**, alias `edit-3`) is the assistant host; the engineering mini goes back. Migration = `scripts/setup-assistant-mac.sh edit-3 --old-host engineering-mac` (Hermes restored from `hermes backup`; helper, relay + config/state, Planning Center server from Weekend Rundown's `pco-mcp` pinned to `mcp<2`, tunnel connector moved). Verified end to end from Teams. Leftovers on engineering-mac await `scripts/decommission-assistant-mac.sh engineering-mac` (Aaron's go).

## Next steps, in order

0. **Decommission engineering-mac** (script above, after Aaron says go); Aaron signs OneDrive in on edit-3 and enables auto-login.
1. **Teams feed flow** (Aaron, guide flow 3), then confirm the `teams` folder indexes.
2. **Planning Center** — done: Weekend Rundown's read-only `pco-mcp/server.py` runs on the host as MCP `planning_center` (token master in OneDrive `secrets/planning-center.env`).
3. **Write-back** — digests to Notes through the index service (helper spec "Later").
4. **Minutes on the laptop** — unchanged: Aaron's in-person test session, then merge `minutes-v1` → `main` with his OK.
