# Meeting summary bench

Measures how well five models summarize Minutes transcripts: three on the Puget box or Claude (`gemma-bigctx`, `qwen-coder`, `claude-sonnet`) and two 16 GB-class models run locally (`gemma-4-12b`, `qwen3.5-9b`). Design: [docs/superpowers/specs/2026-10-07-summary-bench-design.md](../docs/superpowers/specs/2026-10-07-summary-bench-design.md). Why the small models were added: [docs/research/2026-10-07-16gb-assistant-models.md](../docs/research/2026-10-07-16gb-assistant-models.md).

Everything is Python standard library; `pytest` lives in `bench/.venv`. Run commands from the repo root.

## Steps

```bash
bench/.venv/bin/python -m pytest -q bench/tests                     # self-tests
bench/.venv/bin/python -m bench.author                              # Opus writes any meeting not yet valid (resume-safe)
bench/.venv/bin/python -m bench.validate                            # whole corpus must be clean before any contestant runs

# Contestants (all resume-safe on meeting + rep)
caffeinate -i bench/.venv/bin/python -m bench.run_claude --reps 2
caffeinate -i bench/.venv/bin/python -m bench.run_local --model gemma-bigctx --reps 2
caffeinate -i bench/.venv/bin/python -m bench.run_local --model qwen-coder --reps 2 --inflight 3 --restore
# 16 GB-class models on this Mac (one at a time; port 11435 so it never collides with anything on 11434):
llama-server -m ~/.local/share/summary-bench/models/gemma-4-12b-it-Q4_K_M.gguf -c 65536 -ngl 99 --jinja --reasoning-format deepseek --port 11435 &
caffeinate -i bench/.venv/bin/python -m bench.run_local --base http://127.0.0.1:11435 --model gemma-4-12b --reps 2
llama-server -m ~/.local/share/summary-bench/models/Qwen3.5-9B-Q4_K_M.gguf -c 65536 -ngl 99 --jinja --reasoning-format deepseek --port 11435 &
caffeinate -i bench/.venv/bin/python -m bench.run_local --base http://127.0.0.1:11435 --model qwen3.5-9b --reps 2

bench/.venv/bin/python -m bench.judge                               # Opus grades blind, one call per meeting, needs all 10 summaries
bench/.venv/bin/python -m bench.score                               # results/scores.json + results/REPORT.md
```

## Rules

- The contestant prompt (`prompt.py`, `v1`) is frozen. Changing it means a new version and a full rerun.
- Runners never read `corpus/keys/`. Only the judge sees keys.
- Puget calls carry `X-Client: minutes-tests` and use `"stream": true` so the scheduler keeps no copy. During the `qwen-coder` pass keep 2–3 requests in flight (`--inflight 3`) so other tenants' Gemma jobs don't force a model swap on every call (asked by the `puget` session, 2026-10-07).
- Laptop runs of the small models measure quality. Memory fit for a 16 GB mini comes from published numbers; laptop speed is about 2.5× a base M4 mini's (300 vs 120 GB/s memory bandwidth), so scale timings before comparing with the bar.

## Layout

```
bench/
├── corpus/briefs.json      30 meeting briefs
├── corpus/transcripts/     m01.txt …  synthetic Minutes transcripts
├── corpus/keys/            m01.json … answer keys (never shown to contestants)
├── prompt.py               frozen contestant prompt (v1)
├── author.py validate.py   corpus authoring and checks
├── run_local.py            OpenAI-compatible runner (Puget queue or a local llama-server)
├── run_claude.py           claude -p sonnet runner
├── judge.py score.py       blind judging and deterministic scoring
├── results/<contestant>/   results.jsonl (+ traces/, git-ignored)
└── results/judgments/, blind-map.json, scores.json, REPORT.md
```
