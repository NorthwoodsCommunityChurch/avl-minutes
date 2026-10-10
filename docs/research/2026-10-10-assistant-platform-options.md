# Is there a better agent than Hermes for Aaron's assistant? (research, 2026-10-10)

Asked by Aaron after three days of live use: "is there a better agent than Hermes for what I want, do research."
Written by Claude from web research and the installed Hermes source on 2026-10-10. Every claim carries a source
in brackets (numbers refer to the Sources list) or is marked *unverified*.

## What Aaron wants (from the 2026-10-08 to 10-10 conversations)

1. Lives in Microsoft Teams (1:1 chat, phone and desktop).
2. Reads his mail, calendar, and Teams chats (M365), his Apple Notes and Minutes transcripts, the Planka task
   board, Planning Center.
3. Acts on its own: meeting prep before each meeting, closes tasks when a sent email does them, notices calendar
   changes, schedules its own jobs.
4. Creates and maintains documentation he can see and trust: lists, projects, to-dos, calendars ("that's what
   she is for").
5. Keeps memory across days; does not forget what he told it directly.
6. Church data stays private; the model runs on the AI box in the building today (open question: cloud model).
7. Aaron is not a programmer; Claude builds and maintains it; native Mac mini host, no Docker.

## Bottom line

**No agent product fixes what is wrong. The harness is not the problem; the model and the missing documentation
layer are, and both are the same work on every platform.** Specifically:

- Every candidate that fits Teams and self-hosting (Hermes, OpenClaw) has the same two gaps for Aaron: none
  ships "maintain my project notes", and all are only as reliable as the model behind them. Letta and Khoj have
  no Teams channel. Copilot Studio is the one platform with native mail, calendar, Teams, and OneNote, but it is
  built in a GUI that Claude cannot maintain the way it maintains code, has no persistent agent memory concept
  we could find, and would need every local tool (notes index, board, Planning Center) exposed as a public HTTPS
  MCP endpoint.
- Hermes is the most-adopted open-source agent of 2026 (193K GitHub stars by June, ahead of OpenClaw on
  OpenRouter token volume) [8], gained a native Microsoft Teams adapter in v0.14 (May 2026) [6][7] which our
  installed 0.21.6 carries (`plugins/platforms/teams/adapter.py`), treats Anthropic as a first-class provider
  (`provider: anthropic`, API key or Claude Max OAuth with extra-usage credits) [9], and already runs all of our
  plumbing (relay, feeds, index, board tool, rules). Switching it to a frontier model is a config change; moving to
  another harness is a rebuild that keeps the same two gaps.
- The three days of real traffic (below) price a Claude-backed Hermes at roughly $75 to $150 a month on
  Sonnet-class pricing, $25 to $50 on Haiku-class, two to three times that on Opus-class (*unverified*: token
  counts are the local server's accounting; pricing pages cite the 4.6 generation [10]).
- A bigger local model is probably not an option without new hardware: the inventory lists the AI host as an
  RTX 3090 24 GB class machine [11] (*unverified today*; a 70B-class model does not fit in 24 GB at a usable
  quantization).

**Recommendation:** keep Hermes; decide the model (cloud frontier via API or Claude Max credits, versus staying
local on Gemma-class); build the documentation layer (Apple Notes written by the helper) either way. Later,
retire our Teams relay in favor of Hermes's native Teams adapter, which also removes the cron-output watcher.

## Candidates

### Hermes Agent (current, v0.21.6 on edit-3)

- What it is: Nous Research's open-source "self-improving" agent: terminal, 30+ messaging platforms, cron,
  subagents, skills it writes itself, MEMORY.md/USER.md memory, SQLite session history with full-text search,
  Honcho user modeling optional [1][8]. MIT.
- Teams: native since v0.14.0 (2026-05-16) [6]; the docs require a public HTTPS webhook (default port 3978,
  any tunnel), bot registration through `@microsoft/teams.cli` (no Azure portal), DMs answered without
  @mention, group chats on @mention [7]. Our installed copy has the adapter under `plugins/platforms/teams/`
  and "teams" in the gateway platform list (checked on the mini). Images, threads, typing indicators; no
  files, reactions, or streaming [1].
- Memory: compact persistent notes (~1.3K tokens) plus searchable session history; memory edits reach the
  prompt only in a new session [8]. On the mini her memory file holds ~20 facts (checked).
- Model: any provider; Anthropic first class (`hermes model` → Anthropic OAuth through Claude Code's
  credential store, or `ANTHROPIC_API_KEY`; Max subscribers consume only purchased extra-usage credits) [9].
- Safety: five layers (user authorization, dangerous-command approval, container isolation, credential
  filtering, context-file scanning) [8]; we run with terminal/file/browser off.
- Verdict: fits every requirement except 4 and 5, which no candidate ships. Our three days of pain
  (ignored rules, loops, six compactions) trace to Gemma 31B at 65K context, not to the harness.

### OpenClaw

- What it is: "the AI that really does things"; a Node 24+ gateway that answers on Discord, iMessage, Slack,
  Teams, Telegram, WhatsApp and 20+ more; MIT; ~392K GitHub stars; stewarded by the OpenClaw Foundation
  (501(c)(3)); Microsoft maintains a distribution fork under `microsoft/openclaw` [2][3][4]. Native macOS
  install script, no Docker.
- Teams: supported; needs an Azure Bot, a Teams app manifest, a public messaging endpoint; DMs in pairing mode;
  proactive messaging supported; file sending in channels needs SharePoint site id plus Graph permissions [5].
- Memory: Markdown files are the canonical source (`USER.md`, `MEMORY.md`, `memory/YYYY-MM-DD.md` daily notes,
  optional `DREAMS.md`); the agent writes on request and in a "memory flush" before compaction; a scheduled
  "dreaming" sweep consolidates daily notes into MEMORY.md; hybrid embedding + keyword retrieval [12]. This is
  the closest thing to "the agent keeps documentation", but the files live on the host, not on Aaron's phone.
- MCP: yes (registry, mcporter) [2]. Models: hosted or local (Ollama) [2].
- Safety: assumes a trusted operator boundary; needs active hardening [8].
- Verdict: the richest personal-assistant semantics and the best built-in memory discipline, but a full
  rebuild of our feeds, proactive loop, and rules for the same model problem, with a weaker safety model for
  church data. Not worth the migration; its memory-flush idea is worth copying.

### Letta (MemGPT)

- Memory-first agents (core memory blocks the agent edits, archival memory); March 2026 pivot to "Letta Code"
  (CLI, desktop apps, browser, Slack/Telegram/Discord/GitHub Actions); server-side MCP integrations deprecated
  [13][14]. Apache-2.0.
- Channels: Telegram, Slack, Discord, WhatsApp, Signal, custom; **no Microsoft Teams**; proactive messaging not
  documented [14]. Self-hosted app server via Docker.
- Verdict: the best memory architecture on paper, but no Teams and a Docker server. Not a fit.

### Microsoft Copilot Studio / Microsoft 365 Copilot agents

- Native M365: Agent 365 MCP servers for Outlook mail and calendar, Teams, SharePoint, OneDrive; "Workflows"
  are the autonomous, trigger-driven agents ("when X happens, do Y") [15][16]. Custom MCP servers are supported
  (tools and resources; generative orchestration required) [17]; a self-hosted server would have to be reachable
  as a public HTTPS endpoint (our stdio helper is not).
- Price: pay-as-you-go $0.01 per Copilot Credit, $200/month for 25,000; generative answer 2 credits, agent
  action 5, tenant-graph-grounded message 10. **No charge for employee-facing use by a Microsoft 365 Copilot
  licensed user** (fair use) [18]; that license is $30/user/month Enterprise, $18 to $21 Business [19]. For one
  user doing Hermes-level traffic (100 to 300 actions a day), the license is far cheaper than credits.
- Memory: no persistent agent memory concept found in the pages read (*unverified*). Documentation would live in
  OneNote, To Do, Planner, Loop through connectors, which is native and visible on his phone.
- Builder: a GUI product; Claude can help but cannot own it as code. Data stays in the church's tenant; the
  model is Microsoft-hosted.
- Verdict: the one platform where "mail, calendar, Teams, OneNote" need no plumbing at all. The cost is giving
  up Claude as the maintainer, the local index (Apple Notes, Minutes transcripts), Planka, Planning Center, and
  the local model. Right answer only if Aaron wants to leave the self-hosted path entirely.

### Claude-based agent (Claude Managed Agents / Claude Agent SDK)

- Managed Agents: public beta since 2026-04-08; sessions with persistent filesystem and server-side history,
  scheduled deployments (cron), MCP servers, cloud sandbox or self-hosted sandbox; not eligible for zero data
  retention [20][21]. No Teams or Slack adapter (Claude Tag is Slack-only, Enterprise/Team plans) [22]; our relay
  would carry Teams.
- Verdict: the strongest model with the builder that already maintains everything here, but it keeps our relay,
  stores conversation history at Anthropic, and is beta. The same model is reachable from Hermes by config, so
  this buys nothing over "Hermes + Claude" except a second harness to learn.

### Khoj

- Self-hostable "second brain": document QA, custom agents, scheduled automations (research digests), web
  research; browser, Obsidian, Emacs, WhatsApp; local models via Ollama; Docker or Python; AGPL-3.0; the hosted
  cloud was sunset in 2026 [23]. No Teams, no action tools comparable to MCP in the pages read.
- Verdict: a notes-QA tool, not an assistant that acts. Not a fit.

### n8n (workflow agents)

- Workflow automation with AI agent nodes, MCP Client Tool and MCP Server Trigger (since early 2025), Teams
  nodes; installs with `npm install -g n8n` (Node 18 to 22) [24]. A pipeline tool, not a conversational agent
  with memory. Could replace Power Automate flows someday; not an answer to this question.

### Others seen (not evaluated in depth)

From the awesome-personal-agents list [25]: ZeroClaw and Moltis (Rust single binaries), nanobot, NanoClaw,
QwenPaw, Rakazo, IronClaw; memory layers Basic Memory (Markdown knowledge base over MCP), memU, Mem0,
Supermemory, Graphiti, Honcho. None mention Teams, Apple Notes, or M365. Too young to be a church production
dependency maintained by a non-programmer.

## Requirements matrix

| | Hermes | OpenClaw | Letta | Copilot Studio | Claude Managed | Khoj |
|---|---|---|---|---|---|---|
| 1 Teams 1:1 | native (v0.14+) or our relay | native | no | native | our relay | no |
| 2 Mail/calendar/Teams data | our feed + index | would need our feed | would need our feed | native (Agent 365 MCP) | our feed + index | no |
| 2 Apple Notes, Planka, PCO | our MCP servers | MCP | limited (MCP deprecated server-side) | only via public HTTPS MCP | MCP | no |
| 3 Proactive, own schedule | cron + our wake-ups | cron, dreaming, proactive msgs | schedules; proactive not documented | Workflows/triggers | scheduled deployments | automations |
| 4 Maintains documentation | to build (Notes layer) | Markdown memory on host | memory blocks | OneNote/To Do via connectors | to build | notes QA only |
| 5 Memory across days | MEMORY.md + session search | strongest file discipline | strongest architecture | none found | session filesystem | knowledge base |
| 6 Private / local model | yes, any model | yes | yes | M365 tenant, MS-hosted model | Anthropic cloud | yes |
| 7 Claude maintains it as code | yes | yes | yes | GUI | yes | partly |
| Migration cost from today | none | rebuild | rebuild | rebuild | rebuild | n/a |

## Measured traffic (Hermes session store on edit-3, 2026-10-08 to 10-10)

| Day | Sessions | Input tokens | Output tokens | Cache-read tokens |
|---|---|---|---|---|
| Oct 8 (backfills, feed bursts) | 9 | 4,196,096 | 67,476 | 4,860,805 |
| Oct 9 (busy normal day) | 12 | 606,979 | 26,120 | 788,582 |
| Oct 10 (to 3 PM) | 2 | 50,411 | 6,752 | 172,406 |

By source over the three days: Teams thread (api_server) 4.15M in / 62K out; cron 566K / 18K; one-shots 136K / 20K.
Sonnet-class pricing ($3 in, $15 out, cache reads at 10%) makes Oct 9 about $2.50 and Oct 8 about $15; a month of
Oct-9 days is roughly $75, with heavy days pushing toward $150. Haiku-class is about a third of that, Opus-class two
to three times. *Unverified*: counts are the local llama-server's accounting, and the pricing pages cite the 4.6
generation [10].

## Sources

1. Hermes messaging platforms — https://hermes-agent.nousresearch.com/docs/user-guide/messaging/
2. OpenClaw repository — https://github.com/openclaw/openclaw
3. Microsoft's OpenClaw fork — https://github.com/microsoft/openclaw
4. OpenClaw alternatives roundup (stars, Foundation) — https://openalternative.co/blog/best-openclaw-alternatives
5. OpenClaw Teams channel — https://docs.openclaw.ai/channels/msteams
6. Hermes v0.14.0 Teams setup guide — https://www.betterclaw.io/blog/hermes-agent-microsoft-teams-setup
7. Hermes Teams doc (installed repo) — `website/docs/user-guide/messaging/teams.md` on edit-3
8. Hermes vs OpenClaw comparison — https://www.turingpost.com/p/hermes
9. Hermes providers (Anthropic) — https://hermes-agent.nousresearch.com/docs/integrations/providers
10. Claude API pricing pages (third party) — https://metacto.com/blogs/anthropic-api-pricing-a-full-breakdown-of-costs-and-integration
11. Machine inventory — OneDrive `VS Code/SSH-ACCESS.md` (not in git)
12. OpenClaw memory — https://docs.openclaw.ai/concepts/memory
13. Letta Code — https://github.com/letta-ai/letta-code
14. Letta channels — https://docs.letta.com/configuration/channels
15. Agent 365 MCP servers in Copilot Studio — https://microsoft.github.io/mcscatblog/posts/a365-mcp-servers-copilot-studio/
16. Copilot Studio Workflows — https://microsoft.github.io/mcs-labs/labs/mcs-workflows/
17. Copilot Studio MCP — https://learn.microsoft.com/en-us/microsoft-copilot-studio/agent-extend-action-mcp
18. Copilot Studio billing rates — https://learn.microsoft.com/en-us/microsoft-copilot-studio/requirements-messages-management
19. M365 Copilot license prices — https://eesel.ai/blog/copilot-pricing
20. Claude Managed Agents overview — https://platform.claude.com/docs/en/managed-agents/overview
21. Managed Agents explained — https://www.lowcode.agency/blog/claude-managed-agents
22. Claude Tag (Slack) — https://www.developersdigest.tech/blog/claude-tag-slack-agent-workspace
23. Khoj — https://github.com/khoj-ai/khoj and https://www.promptquorum.com/power-local-llm/khoj-ai-second-brain-review
24. n8n MCP nodes — https://leanware.co/insights/n8n-mcp-guide
25. awesome-personal-agents — https://github.com/ahmadyan/awesome-personal-agents
