# Summary bench — findings (2026-10-07)

Aaron stopped the bench at 15:52 on 2026-10-07 after the 5-meeting preview (m01–m05, two passes per contestant, blind Opus judge) had answered the question that mattered: which 16 GB-class model runs on the mini. Timing below uses every finished run; quality uses the judged preview. Raw rows stay in `bench/results/` (gitignored); the scorecard is `bench/results/REPORT.md` and `scores.json`.

| | Gemma 4 12B (laptop) | Qwen 3.5 9B (laptop) | Gemma 4 31B (Puget) | Qwen 3.6 27B (Puget) | Claude Sonnet |
|---|---|---|---|---|---|
| Decisions found (pass 1 / 2) | 100% / 100% | 100% / 100% | 100% / 100% | 100% / 100% | 100% / 100% |
| Action items found | 100% / 90% | 100% / 95% | 95% / 100% | 100% / 100% | 100% / 100% |
| Open questions found | 80% / 80% | 80% / 80% | 80% / 100% | 80% / 80% | 100% / 100% |
| Invented decisions or actions (incl. traps) | 0 | 0 | 0 | 0 | 0 |
| Decisions listed in control meetings | 3 / 3 | 2 / 3 | 2 / 3 | 1 / 3 | 4 / 3 |
| Time per 10-min meeting, p50 / p90 (model time) | 81 s / 164 s | 159 s / 311 s | 43 s / 85 s | 53 s / 62 s | 13 s / 23 s (wall) |
| Output tokens, median | 1,527 | 6,278 | 1,189 | 2,698 | n/a |
| Finished runs / meetings | 29 / 24 | 10 / 5 | 39 / 30 | 10 / 5 | 60 / 30 |
| Bar (recall ≥90%, invented ≤1, 0 unusable, p90 ≤180 s local) | passes | **fails (time)** | passes | passes | passes |

## What it means

- **No model fell for a trap** in the judged meetings: reversed decisions, jokes, hypotheticals, "that's up to finance", and already-done items stayed out of every Decisions list.
- **Gemma 12B over Qwen 9B for the mini.** Same quality within noise; Qwen writes four times the tokens (its thinking) for no visible gain and takes twice as long. On the base M4 mini (about 2.5× slower than the laptop) expect ~3.5 min per 10-minute meeting with Gemma 12B, ~7 min with Qwen 9B.
- **Gemma 31B on Puget is the fastest and most precise** of the local-class models. Aaron chose the 12B on the mini so transcript text never leaves it; switching Hermes to Puget is a three-line config change.
- **Sonnet over-lists:** 3–4 "decisions" in meetings that had none (accurate, but not decisions), and the most extra items.
- **Judge spot-check** (meeting 3, hand-read against the gemma-bigctx summary): grades matched.

## Caveats

- Quality is judged on 5 of 30 meetings; Gemma 12B has 24 meetings summarized but unjudged (`bench.judge` resumes if ever wanted).
- Laptop timing (M3 Max) overstates the mini; the mini measured 144–174 s for two 10-minute meetings with the 12B at 64K context.
- Meetings are synthetic (Opus-written) with planted traps; real transcripts are noisier.
