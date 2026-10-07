# Can a 16 GB Mac mini run the assistant's AI? (research, 2026-10-07)

Aaron's question: is there a model that fits in a 16 GB M4 Mac mini that people have had success with as a personal assistant? This note is what the web says as of October 2026, weighted toward first-hand reports over marketing and calculator sites.

## Bottom line

- **Yes for reading, summarizing, and answering questions over your own files.** A 9–12B model at 4-bit fits, and several guides written for exactly this machine recommend it for "private assistants, local summaries, note search."
- **No for the judgment-heavy work, by the community's own account.** The people who run always-on personal assistants (OpenClaw) on 16 GB M4 minis say: "16GB will not do well for running primary agent work locally — tool-calling gets unreliable fast, and an agent that misfires tool calls is worse than no agent. On 16GB, run heartbeats locally and keep real work on a paid model." They run 3–4B models for routine checks and a bigger model for the real work.
- **For Minutes' use, the risk is invented decisions.** The models that fit are a size class below the 27–31B ones being tested on Puget today, and the pilot already showed the 27B Qwen inventing decisions. Nobody has measured the small ones on this task. We can: both candidates run on Aaron's laptop and can join the running summary bench.

## What fits in 16 GB

macOS needs about 3–4 GB. By default a 16 GB Apple Silicon Mac lets the GPU use roughly 10–11 GB. That leaves room for one 4-bit model in the 9–12B range plus its working memory ("KV cache", which grows with the length of the text you feed it).

| Model | Released | Weights at 4-bit | Context | Notes |
|---|---|---|---|---|
| **Gemma 4 12B** (Google, Apache 2.0) | 2026-06-03 | **6.7 GB** (Google's own table, Q4_0; weights only) | 256K | Google markets it for "local agentic workflows" on 16 GB laptops. Same family as the Gemma 31B on Puget, which was the careful one in today's pilot. Multimodal (text, image, audio). |
| **Qwen3.5 9B** (Alibaba) | Feb 2026 | ~6–8 GB | 262K native | "Excels in tool calling"; beats Gemma 4 12B on the TAU2 agent benchmark (79.1% vs 69.0%). Thinking mode on by default. Popular pick among OpenClaw users on 16 GB. |
| gpt-oss-20b (OpenAI) | Aug 2025 | ~12–13 GB (MXFP4) | 128K | o3-mini-class reasoning and strong tool calling, but on a 16 GB Mac it is "on the edge": under 1 GB left at 32K context, guides recommend ≤4K context, about 5 tok/s. **Rules it out for meeting transcripts.** |
| Gemma 4 26B / 31B, Qwen3.6 27B / 35B-A3B | — | 15–19 GB | — | **Don't fit.** These are the Puget models. |

Qwen3.6 (April 2026) ships only 27B and 35B-A3B; the small Qwen line is Qwen3.5 (0.8B/2B/4B/9B).

## Context: will a whole meeting fit?

A 60-minute Minutes transcript is roughly 10–12K tokens; a 90-minute one about 17K. For Gemma 4 12B at 4-bit:

- Community guidance: "a 4-bit quant at 8K–32K context fits in 16 GB of VRAM or unified memory"; one guide puts a 12B at 32K context at about 12 GB total; another report runs the QAT 12B at 16K context on an 8 GB GPU (Gemma 4's sliding-window attention keeps the cache small).
- Reading: **a 60-minute meeting fits comfortably; a 90-minute one fits with the context cap set to 32K and nothing else competing for memory.** Email and chat items are tiny by comparison.

## Speed on a base M4 (estimates; no direct measurements found)

The base M4 has 120 GB/s memory bandwidth, less than half of the M4 Pro's 273 GB/s. For a 6.7 GB model that caps generation near 18 tok/s; guides estimate **12–17 tok/s** for Gemma 4 12B on a base M4. Reading a 10K-token transcript first takes on the order of a minute. **Expect 2–4 minutes per meeting summary**, versus 1–3 on Puget including queue time. Fine for a background job; slow for a live chat.

## First-hand reports found

- **OpenClaw on a 16 GB M4 mini** (mrprompts, 2026): 4B models use "roughly 2.5 to 3GB loaded", total system "maybe 6 to 7GB of your 16"; verdict quoted above. Qwen3.5 9B (6–8 GB) is the step-up users rank highly for 16 GB.
- **Gemma 3 12B vs GPT-4o Mini and Claude Haiku** (kunalganglani; note: previous generation, Gemma 3 not 4): on par for structured JSON extraction, log parsing, commit messages; fell short on multi-step reasoning and nuanced review. Author routes 60–70% of automated work to the local model.
- **Mac mini buying guides** (popularai, modelfit, gemma4all, siliconscore): consistent message that 16 GB is "a strong fit for 3B to 8B models, private assistants, local summaries, and lightweight coding help", can handle some 14B workloads with care, and "is not the smart choice for 24B to 35B daily use."
- I could not reach the r/LocalLLaMA thread on Gemma 4 12B (Reddit blocks fetches). No first-hand hallucination report for Gemma 4 12B or Qwen3.5 9B on summarization was found. That gap is exactly what the bench can fill.

## Memory budget for the mini as designed

| Item | Memory |
|---|---|
| macOS, OneDrive sync, Notes | 3–4 GB |
| Search index, embedding model, assistant program | ~1–1.5 GB |
| Gemma 4 12B at 4-bit | 6.7 GB |
| Working memory for a 32K-token meeting | ~2–4 GB |
| **Total** | **13–16 GB** |

Feasible if the mini does nothing else, with the model's context capped. A 24 GB mini removes the squeeze; a 32 GB mini could run the Puget-class Gemma 31B slowly (5–10 min per summary); a 48–64 GB M4 Pro mini runs it well.

## Recommended next step

Add **Gemma 4 12B** and **Qwen3.5 9B** as contestants to the summary bench already running (`bench/`). Aaron's laptop (M3 Max, 36 GB; `ollama` and `llama-server` already installed) can run both with the same frozen prompt and the same blind Opus judge. Memory can be capped to mimic 16 GB. Speed on the laptop is faster than a base M4 (about 3× the bandwidth), so timing is scaled, not measured. Cost: two model downloads (~7 GB and ~6 GB) and about 2–3 hours of laptop GPU time; no Puget time.

The outcome decides the mini's role:

- If 12B passes the bar (≥90% recall, ≤1 invented decision): the mini can do everything locally and data never leaves it.
- If it fails: the mini stores the data and runs the small jobs; Puget's 31B does the summaries over the LAN (streamed, not kept).

## Sources

- [Google: Gemma 4 model overview and memory table](https://ai.google.dev/gemma/docs/core) · [Google Developers Blog: Gemma 4 12B on your laptop](https://developers.googleblog.com/bringing-gemma-4-12b-to-your-laptop-unlocking-local-agentic-workflows-with-google-ai-edge/) · [Gemma 4 12B developer guide](https://developers.googleblog.com/gemma-4-12b-the-developer-guide/) · [Wikipedia: Gemma](https://en.wikipedia.org/wiki/Gemma_(language_model))
- [Qwen3.5-9B model card](https://huggingface.co/Qwen/Qwen3.5-9B) · [Qwen models guide (mid-2026)](https://insiderllm.com/guides/qwen-models-guide/) · [Artificial Analysis: Gemma 4 12B vs Qwen3.5 9B](https://artificialanalysis.ai/models/releases/comparisons/gemma-4-12b-vs-qwen3-5-9b) · [llm-stats comparison](https://llm-stats.com/models/compare/gemma-4-12b-it-vs-qwen3.5-9b) · [betterclaw: best local agent model](https://www.betterclaw.io/blog/gemma-4-12b-vs-qwen-3-5-9b)
- [Best local models for OpenClaw on a 16 GB M4 mini](https://mrprompts.substack.com/p/best-local-models-for-openclaw-in) · [Towards Data Science: local LLM with OpenClaw on a Mac mini](https://towardsdatascience.com/run-a-local-llm-with-openclaw-on-your-mac-mini/) · [Mac mini M4 guide by RAM tier](https://www.popularai.org/p/best-local-llm-mac-mini-m4-2026) · [Gemma 4 on Mac mini 16–48 GB](https://gemma4all.com/blog/gemma-4-on-mac-mini) · [modelfit: Gemma 4 12B for 16 GB](https://modelfit.io/blog/gemma-4-12b-local-llm-16gb/) · [siliconscore: Mac mini M4 16 GB](https://siliconscore.com/macs/mac-mini-m4-16gb/)
- [Gemma 4 QAT 12B at 16K context on 8 GB](https://openweightllm.substack.com/p/gemma-4-qat-12b-runs-at-16k-context) · [Gemma 4 local VRAM guide](https://knightli.com/en/2026/05/01/gemma-4-local-vram-quantization-table/) · [Unsloth: run Gemma 4 locally](https://unsloth.ai/docs/models/gemma-4)
- [gpt-oss-20b on a 16 GB Mac mini](https://aliteq.com/gpt-oss-20b-mac-mini-16gb-m4-m6-2026) · [gpt-oss 20B in 16 GB with the wired-limit raise](https://smeltcore.com/recipes/gpt-oss-20b-m2-pro/) · [mlx-lm issue #644](https://github.com/ml-explore/mlx-lm/issues/644) · [gpt-oss-20b on Hugging Face](https://huggingface.co/unsloth/gpt-oss-20b-BF16)
- [Gemma 3 12B vs GPT-4o Mini vs Claude Haiku (previous generation)](https://www.kunalganglani.com/blog/gemma-4-12b-local-llm-vs-api.md)

## Addendum: Hermes Agent (asked 2026-10-07)

**What it is.** [Hermes Agent](https://github.com/NousResearch/hermes-agent) by Nous Research (Feb 2026, MIT, ~252k GitHub stars, updated daily) is a self-hosted, always-on personal agent: a messaging gateway (Telegram, Discord, Slack, WhatsApp, Signal, Email), a built-in cron scheduler, a learning loop (it writes its own skills, "nudges" itself to save memories, searches past sessions with FTS5), and a macOS desktop app (June 2026). It is model-neutral: any OpenAI-compatible endpoint, including Ollama locally or the Puget queue over the LAN. It is the direct successor to OpenClaw with a stronger built-in memory story.

**Three things that matter for Aaron.**

1. **It can't run on the Max plan for free.** Anthropic blocked subscription OAuth outside Claude Code in January 2026 and codified it; since April 4, 2026 third-party harnesses only work with "extra usage", pay-as-you-go billing on top of the subscription. Nous added a Claude-plan plugin on 2026-09-20, but every Hermes call bills as extra usage even while the Max allowance sits unused. Under Aaron's "no API keys, no pay-per-token" rule, Hermes means a local model: the 9–12B class on the mini, or Puget's Gemma 31B over the LAN.
2. **Its best memory layer is a third-party cloud by default.** Honcho (Plastic Labs) does the user modeling and, by default, runs on honcho.dev with their models reading the conversations. It can be self-hosted (Postgres + pgvector + Redis + an LLM + an embedding model, Docker; AGPL) or turned off. The built-in layers (MEMORY.md, USER.md, SQLite session archive) are local files.
3. **It writes its own memories and skills from what it reads.** With an inbox as input, a crafted email could plant a memory or a skill (memory-poisoning attacks on LLM agents are an active 2026 research topic). Hermes has command approval and container isolation, but a read-only summarizer that also self-improves is a larger surface than a plain reader.

**Where it fits.** Hermes supplies the scaffolding (gateway, cron, memory nudges, skills) that a Claude Code session would otherwise need built by hand, but it cannot supply Claude's judgment without per-token billing. So the bench still decides:

- A local model passes the bar → Hermes on the mini, model = Puget's Gemma 31B over the LAN (or the 12B locally), Honcho off or self-hosted, memory in local files. Data never leaves the church network.
- No local model passes → a Claude Code session on the mini is the only way to get Claude quality inside the Max plan; Hermes drops out.

Sources: [Hermes Agent repo](https://github.com/NousResearch/hermes-agent) · [providers](https://hermes-agent.nousresearch.com/docs/integrations/providers) · [memory providers](https://hermes-agent.nousresearch.com/docs/user-guide/features/memory-providers) · [Anthropic bans subscription auth for third-party use](https://alternativeto.net/news/2026/2/anthropic-officially-bans-using-subscription-authentication-for-third-party-claude-use) · [Hermes + Claude Max: possible isn't allowed](https://vincentvandeth.nl/blog/hermes-agent-claude-subscription-oauth) · [OpenClaw vs Hermes memory](https://vectorize.io/articles/openclaw-vs-hermes-agent-memory) · [self-hosting Honcho](https://github.com/elkimek/honcho-self-hosted) · [Hermes vs OpenClaw](https://composio.dev/content/openclaw-vs-hermes-agent) · [memory poisoning study](https://arxiv.org/pdf/2606.04329)
