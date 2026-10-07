# Auto-summaries on Puget: findings (2026-10-07)

Aaron asked whether the local model on Puget could summarize each meeting automatically, so a summary is ready without asking Claude. The Puget session (`puget`, owner of the box) answered on mesh thread `t-e989d7b0`. It measured both models on a synthetic 11k-word transcript; no real meeting content was sent.

## Answers

| Question | Finding |
|---|---|
| Model | **gemma-bigctx** (Gemma 4 31B, 256K context). It is the default resident model, so no swap. qwen-coder costs two whole-box swaps (15–25 s each) that slow other tenants. |
| Quality | No summarization eval exists for either model. On the synthetic text, Gemma flagged that the text was repetitive and hedged. Qwen confidently listed eight "decisions" the text never made. Invented decisions are the failure that matters for minutes. |
| Time (~16.5k-token prompt, reasoning on) | Gemma: about 62 s of model time (9.9 s prompt, 52 s output for a 435-word summary); 161 s wall clock, including about 100 s of queue wait. Plan on 1–3 minutes on a weekday, longer behind a Weekend Rundown build. A 30k-token meeting adds about 20 s. No chunking needed. |
| Reach | `:11434` works on the church LAN and off-site over Tailscale (subnet router). There is no auth. Off-site gotcha: macOS can synthesize an IPv6 route for the IPv4 literal that times out, so force IPv4. |
| Privacy | **Fixed 2026-10-07 09:30 box time, with Aaron's go:** llama-swap captures are off and `:8080` is closed to the LAN and Tailscale. What was found: llama-swap (`:8080`) keeps about the last 45 minutes of request and response bodies in memory, readable without auth from the LAN or Tailscale (`/api/captures/<id>`).. The scheduler never writes prompts to disk, but it holds non-streaming results for 1 hour at `/v1/jobs/<id>/result`, so use `"stream": true` and avoid `/v1/jobs`. |
| Registration | Send `X-Client: minutes`. Before shipping, tell `puget` the client name, model, and request shape so it records Minutes in Puget's `SERVICES-INVENTORY.md`. |

## What it would take

1. ~~Aaron approves the llama-swap capture fix~~ Done 2026-10-07. Real transcripts on the box are now Aaron's call; keep `"stream": true`.
2. A small quality check: 5–10 real transcripts, Gemma summaries compared with summaries Aaron approves. Watch for invented decisions.
3. Design change in Minutes: after Stop, stream the transcript to `gemma-bigctx` via `:11434` (IPv4, `X-Client: minutes`), then add the summary to the top of the meeting's note. This reverses the original "transcript only" decision, so it needs a short design and Aaron's OK.

Until then, Claude Code can summarize any transcript on request through the read-only notes search.
