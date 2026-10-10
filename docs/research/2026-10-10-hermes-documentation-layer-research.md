# How to make Hermes keep Aaron's documentation (research, 2026-10-10)

Aaron approved the direction (notes in Apple Notes, a capture rule next to each message, a nightly tidy, feed
events out of his thread) and asked: "do some more research on how to accomplish this; see if anyone else has run
into similar issues." Written by Claude from web research and the installed Hermes 0.21.6 source on 2026-10-10.
Claims carry a bracketed source number (Sources at the end) or are marked *unverified*.

## Bottom line

1. **Others have hit exactly our failures, and Hermes's own tracker names the cause.** Small local models cannot
   drive the `tool_search` / `tool_call` bridge that Hermes puts in front of MCP and plugin tools: Qwen models
   confuse the bridge's name with their own `<tool_call>` tag [1]; a 9B model failed "10 of 10 attempts" to wrap a
   plugin tool [2]; one session issued 1,523 `tool_search` calls and died [3]; the docs say tool search costs
   "about 26 points of accuracy" on smaller models [4]. The documented workaround is one setting,
   `tools.tool_search.enabled: off`, which lists every tool directly [1][4]. Our runaway `read_file`-through-
   `tool_call` loops (twice this week) are this bug. With per-server MCP filtering (`mcp_servers.<name>.tools.include`)
   [5] the eager list stays small (notes 6, board 1 to 2, Planning Center 3 to 4, core tools).
2. **The documentation layer is a named pattern: Karpathy's "LLM wiki" (early 2026).** Raw sources the agent never
   edits, a compiled wiki of interlinked Markdown pages the agent maintains, and a schema document that tells it how
   the wiki is organized and what the ingest / query / lint workflows are, plus an index and an append-only log
   [6][7]. Hermes ships it as a bundled skill (`research-llm-wiki`, `WIKI_PATH`) [8]. Our version: raw = the feed
   index (mail, Teams, calendar) and Aaron's own messages; wiki = Apple Notes in a "Hermes" folder; schema = a
   section of `SOUL.md`; index = a "Hermes index" note; log = the nightly tidy's note. Reported pitfalls: quality
   degrades past roughly 200K to 300K tokens of wiki, repeated rewrites erode facts, and the agent needs a navigation
   map (the index) or it stops finding pages [7].
3. **Capture must happen every turn, not at compaction.** Mem0's analysis of Hermes's compressor (fires at 50% of
   context, gateway safety net at 85%, protects head and tail, summarizes the middle) lists what dies in the middle:
   exact numbers, hard constraints, the *why* of decisions, cross-task dependencies, implicit preferences; its advice
   is to extract after every turn [9]. OpenClaw does the same with a "memory flush" turn before compaction and a
   nightly "dreaming" job that folds daily notes into `MEMORY.md` [10]. Hermes's built-in version is periodic memory
   nudges (`memory.nudge_interval`) that write to its own flat MEMORY.md [11]; it also supports memory-provider
   plugins (Honcho, Mem0, Supermemory, and six others, or a user-written one with turn and session hooks) [12][13].
   Our relay note is the per-turn hook we already have and that this model obeys.
4. **Writing Apple Notes from an agent is a solved shape with known edges.** Every serious server reads from the
   Notes SQLite store and writes only through AppleScript ("writing to SQLite would corrupt CloudKit sync"), about
   50 ms a call; full-body replacement drops attachments; AppleScript cannot set pins or note links; locked notes are
   unreadable; 1 MB body cap; one server reports `revision_conflict` when a note changed since it was read [14][15].
   Our helper already writes this way (Minutes transcripts). Rules for us: Hermes writes only in her own folder,
   read-then-write with a modified-time check, append-only "log" sections, never his notes.
5. **The model is still the ceiling, and Qwen is the open-weight tool-calling leader.** On the Berkeley
   Function-Calling Leaderboard Qwen holds "roughly 10 of 13" open-weight slots by mid-2026 [16]; guides for 24 GB
   cards rank Qwen3.6-27B best overall, Qwen3-Coder-30B-A3B and Qwen3.6-35B-A3B as the agent picks, Gemma 4 26B-A4B
   as the fastest (17.4 GB at 32K) [17][18][19]. Two Gemma 4 gotchas are reported for Ollama users (tool calls routed
   to `reasoning_content` unless thinking is off) [19] (*unverified for our llama.cpp server*). A bake-off on the AI
   box is the only way to know for our tasks; it needs the box's owner.

**What this changes in the design:** turn the tool bridge off and filter MCP tools (a config change, test first);
build the notes layer as an LLM wiki with the index note as the map; keep capture in the relay note; add the nightly
tidy as a cron job; move feed events to their own session; and schedule a model bake-off with the box's owner.

## 1. Agents that maintain living documents, not flat memory

- Karpathy's LLM wiki (early 2026): three layers (raw / wiki / schema), `index.md` read first on every operation,
  `log.md` append-only, three operations (ingest, query, lint). Lint looks for contradictions, orphan pages, stale
  claims, and gaps. Facts survive because every wiki claim traces to a raw source and bad ingests can be reverted
  [6][7]. A Claude Code user runs one for six projects [20]. Academic follow-ups add a raw buffer tier and scheduled
  consolidation ("Memory as Metabolism") [21].
- Hermes bundled skill `research-llm-wiki`: `raw/`, `entities/`, `concepts/`, `comparisons/`, `queries/`,
  `SCHEMA.md`, `index.md`, `log.md`; ingest / query / lint workflows; location `WIKI_PATH` (default `~/wiki`) [8].
  It writes files on the mini, which Aaron would not see; the pattern transfers to Notes, the files do not.
- OpenClaw memory: `USER.md`, `MEMORY.md`, `memory/YYYY-MM-DD.md` daily notes, optional `DREAMS.md`; the agent
  writes on request and in the pre-compaction flush; daily notes are append-only; a scheduled dreaming sweep
  consolidates them; hybrid embedding + keyword retrieval [10].
- Markdown-knowledge-base MCP servers (Basic Memory, Memento, MemoryChat) store entities, observations, and
  relations as Obsidian-compatible Markdown that the person can edit [22]. A fallback store if Apple Notes proves
  fragile: a Markdown folder in iCloud Drive is visible on a phone through Files or Obsidian.
- Letta's memory blocks (core memory the agent edits in place) are the strongest architecture but live inside
  Letta [23]; not transferable.

## 2. What Hermes already has

- **Tool search / deferred tools.** `tools.tool_search.enabled: auto | on | off` (default auto), `defer` (adds
  names; `[]` keeps core tools eager but plugin and MCP tools still defer), `threshold_pct` 5%, `listing_max_tokens`
  4000. Off = every schema in the prompt. Docs: "Smaller models do this less well", about 26 accuracy points
  behind Opus [4]. Issues: #110442 (Qwen `<tool_call>` collision; PR to rename the bridge `invoke_tool` planned,
  completion unconfirmed; workaround `hermes config set tools.tool_search.enabled off`) [1]; #135762 (no way to keep
  plugin or MCP tools direct; labeled needs-decision) [2]; #96247 (runaway `tool_search`; same prompt completed
  with `enabled: "off"`) [3]; #106728 (small local models pick wrong tools on simple tasks) [24].
- **Per-server MCP filtering.** `mcp_servers.<name>.tools.include` / `.exclude` [5]. The last catalog listing on
  the mini showed only five Planka tools being advertised (cards, cardMembers, comments, labels, tasks) plus notes,
  Planning Center, and core tools: 35 in all (checked in the session store).
- **Memory.** MEMORY.md and USER.md, periodic nudges (`memory.nudge_interval`), session search over SQLite
  history, Honcho optional [11]; memory-provider plugins with `writeFrequency` async / turn / session [12][13];
  community `hermes-lcm` replaces lossy compression with a SQLite store plus summary DAG and recall tools, local
  models supported [25]. Compression: fires at 50% of context, gateway net at 85%, prunes old tool results over
  200 chars, keeps head and tail, summarizes the middle with the auxiliary model [9].
- **Context length.** Issue #23767 (switching to a lower-context local model: oversized prompts, token estimates
  off, compression sometimes made the prompt larger) is the one we hit on day one [26].

## 3. Writing Apple Notes from an agent: pitfalls others hit

- SQLite for reads, AppleScript (`NSAppleScript`) for every write; ~50 ms per call; fallback to AppleScript reads
  when Full Disk Access is missing [14].
- Full-body update drops embedded files, images, scans, PDFs, audio; list attachments first [15].
- `revision_conflict` when the note changed since it was read; "indeterminate" outcomes need a re-read by exact id
  before retry [15].
- AppleScript cannot set pins or read/insert note links; locked notes are encrypted; 1 MB body cap; CloudKit share
  operations unsupported [14][15].
- Nobody documents iCloud sync timing; our own index already tolerates the lag (2 min passes).

## 4. Local models that follow tool rules in 24 GB

- BFCL (mid-2026): Qwen in roughly 10 of 13 open-weight slots; Qwen3 32B and 30B-A3B both ranked [16].
- 24 GB guides: Qwen3.6-27B "best overall"; Qwen3-Coder-30B-A3B and Qwen3.6-35B-A3B for agents; Gemma 4 26B-A4B
  fastest (159.8 tok/s, 17,430 MiB at 32K); gpt-oss-20b; glm-4.7-flash (~19 GB) [17][18][19].
- "Native trained-in tool template" (Qwen, Mistral, Llama, Hermes, Granite, GLM, Phi-4-mini) versus grammar-
  constrained decoding bolted on (Gemma 2/3): the distinction one guide says decides whether a model works as an
  agent brain [16]. Gemma 4 does have native tool calling (Hermes issue #7457 added support) [27].
- Aaron's own bench (2026-10-07) chose Gemma 12B over Qwen 9B for *summary prose*, not tool-following; the
  criteria differ.

## 5. Others running Hermes or OpenClaw on local models: the same symptoms

- Hermes issues above: wrong-tool selection, bridge loops, context mismatches [1][2][3][24][26].
- OpenClaw + Ollama: tool calls lost under streaming on the OpenAI-compatible endpoint (fix: native endpoint);
  models under 8B loop; 24 to 32 GB sweet spot is qwen3-coder:32b or glm-4.7; context should be 64K+ [19][28].
- Our week: rules followed only when adjacent to the message; `boards get` spill then 18 identical failing reads;
  eight list results blew the per-turn budget then five identical reads; six compactions in three days (`CLAUDE.md`).

## 6. What this means for the design (feeds the spec)

| Piece | Choice | Why |
|---|---|---|
| Tool bridge | `tools.tool_search.enabled: off`; `mcp_servers.planka.tools.include: [cards]` (plus comments if used); keep notes and Planning Center tools | Removes the loop class entirely [1][3]; small eager list keeps the per-turn cost near today's catalog cost |
| Store | Apple Notes, "Hermes" folder, one note per project / person / list, an index note, a tidy-log note | Visible and editable on his phone; indexed by the helper; the wiki pattern's index and log [6][7] |
| Write tools | helper MCP: `note_upsert(title, section, text)` append-or-replace by section, `note_create`; folder locked to "Hermes"; read-modify-write with a modified-time check; no attachments | AppleScript-only writes, conflict check, attachment loss avoided [14][15] |
| Capture | relay note: "if this message states a fact, decision, measurement, plan, or open question about a project, person, or event, write it to that note before you answer; say 'Noted in Atrium'" | Per-turn extraction is what survives compaction [9]; this model obeys adjacent rules |
| Tidy | nightly cron (deliver local): read the day's Teams messages from Aaron (feed index, folder teams) and the notes; add what is missing; rewrite nothing that is already right; append a dated line to the log note | OpenClaw dreaming, wiki lint [7][10] |
| Thread hygiene | feed and meeting prompts in their own API-server session; they read the notes, the board, and the index | Keeps Aaron's thread under the 50% compaction line [9] |
| Model | bake-off on the AI box (Gemma 4 31B vs Qwen3-Coder-30B-A3B vs Qwen3.6-27B) on our six real tasks | Qwen leads open-weight tool calling [16]; only a test settles it for our prompts |

Open questions for the spec: whether Hermes nudges can be pointed at a note instead of MEMORY.md (a small
memory-provider plugin could do it [13]); whether the index note stays under the size where wikis degrade [7]; how
the helper authenticates note writes (same `--notes-helper` child as Minutes).

## Sources

1. Hermes issue #110442, Qwen models mis-route to `tool_call` — https://github.com/NousResearch/hermes-agent/issues/110442
2. Hermes issue #135762, no way to keep plugin tools direct — https://github.com/NousResearch/hermes-agent/issues/135762
3. Hermes issue #96247, runaway tool_search loop — https://github.com/NousResearch/hermes-agent/issues/96247
4. Hermes Tool Search docs — https://hermes-agent.nousresearch.com/docs/user-guide/features/tool-search
5. Hermes MCP docs, per-server filtering (installed copy, `website/docs/user-guide/features/mcp.md`)
6. Karpathy LLM wiki guide — https://blog.starmorph.com/blog/karpathy-llm-wiki-knowledge-base-guide
7. LLM wiki pattern and pitfalls — https://www.aibuilderclub.com/blog/karpathy-llm-wiki
8. Hermes bundled skill research-llm-wiki — https://hermes-agent.nousresearch.com/docs/user-guide/skills/bundled/research/research-llm-wiki
9. Mem0 on Hermes compression — https://mem0.ai/blog/how-hermes-and-claude-handle-context-compression-in-real-production-agents-(and-what-you-should-extract)
10. OpenClaw memory — https://docs.openclaw.ai/concepts/memory
11. Hermes memory docs (installed copy, `memory.md`; `memory.nudge_interval`)
12. Hermes memory providers (installed copy, `memory-providers.md`)
13. Hermes memory provider plugin guide (installed copy, `developer-guide/memory-provider-plugin.md`)
14. che-apple-notes-mcp — https://github.com/PsychQuant/che-apple-notes-mcp
15. sweetrb/apple-notes-mcp and its private-writer PR — https://github.com/sweetrb/apple-notes-mcp/pull/262
16. Local LLM agent capability by BFCL — https://d-central.tech/local-llm-agent-capability/
17. Best local LLMs for RTX 3090 (2026) — https://www.popularai.org/p/best-local-llm-rtx-3090-24gb
18. RTX 3090 models tested — https://atomic.chat/blog/guides/best-local-llms-for-rtx-3090
19. Best Ollama models for OpenClaw — https://clawdbook.org/blog/openclaw-best-ollama-models-2026
20. Self-maintaining knowledge base with Claude Code — https://hackernoon.com/how-i-built-a-self-maintaining-knowledge-base-for-6-projects-using-claude-code-and-karpathys-llm-wiki
21. Memory as Metabolism (arXiv 2604.12034) — https://arxiv.org/pdf/2604.12034
22. Basic Memory — https://mcp.so/server/basic-memory ; Memento — https://pkg.go.dev/github.com/edgetools/memento
23. Letta Code — https://github.com/letta-ai/letta-code
24. Hermes issue #106728, local model tool selection — https://github.com/NousResearch/hermes-agent/issues/106728
25. hermes-lcm — https://hermesatlas.com/projects/stephenschoettler/hermes-lcm
26. Hermes issue #23767, lower-context local models — https://github.com/NousResearch/hermes-agent/issues/23767
27. Hermes issue #7457, Gemma 4 tool calling — https://github.com/NousResearch/hermes-agent/issues/7457
28. OpenClaw + Ollama guide — https://www.betterclaw.io/blog/openclaw-ollama-guide
