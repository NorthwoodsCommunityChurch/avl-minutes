# Meeting Summary Bench Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:executing-plans (inline, per Aaron's standing rule). Steps use checkbox (`- [ ]`) syntax.

**Goal:** Measure whether `gemma-bigctx` or `qwen-coder` on Puget can summarize Minutes transcripts well enough to run automatically, against Claude Sonnet.

**Architecture:** Python stdlib scripts under `bench/`. Opus (via `claude -p`) writes 30 synthetic meetings with answer keys; three contestants summarize each twice with one frozen prompt; Opus judges blind, one call per meeting; a deterministic scorer applies the bar.

**Tech stack:** Python 3 (stdlib), pytest in `bench/.venv`, `claude` CLI (Max plan, no API key), the Puget `:11434` queue.

**Spec:** [docs/superpowers/specs/2026-10-07-summary-bench-design.md](../specs/2026-10-07-summary-bench-design.md)

## Global constraints

- No Anthropic API key. Claude calls: `claude -p --model <m> --setting-sources "" --tools "" --no-session-persistence --strict-mcp-config --system-prompt <...>`, run from a scratch directory, transcript on stdin.
- Claude calls run one at a time (plan usage unknown).
- Box calls: `X-Client: minutes-tests`, `"stream": true`, client timeout 900 s, `caffeinate -i`, gemma pass then qwen pass then one gemma call. Tell `puget` before the first box call.
- Prompt `v1` is frozen once Task 1 commits. Changing it means a new version label and a rerun.
- Runners never open `bench/corpus/keys/`.
- Every runner is resume-safe on (meeting, rep) and appends one JSON line per completed item.

## Review focus

1. A contestant reply that is empty, truncated, or wrapped in a code fence or reasoning tags — must be recorded, retried once if truncated, never crash the run.
2. A judge reply that is not valid JSON or omits a summary letter — retry once, then record as a judge failure (not a contestant zero).
3. A key whose evidence is not an exact substring (Opus paraphrased) — validation must catch it before any contestant runs.
4. Blinding leaks — the judge input must contain no contestant name, model id, or rep number.
5. Control meetings — any listed decision must count as invented even when the judge calls it `supported`.

---

### Task 1: Scaffold, common helpers, frozen prompt

**Files:** create `bench/README.md`, `bench/common.py`, `bench/prompt.py`, `bench/tests/test_common.py`, `bench/.gitignore` (`.venv/`, `results/*/traces/`, `__pycache__/`).

**Produces:** `common.ROOT, CORPUS, TRANSCRIPTS, KEYS, BRIEFS, RESULTS`; `common.meeting_ids() -> list[str]`; `common.load_transcript(id) -> str`; `common.load_key(id) -> dict`; `common.append_jsonl(path, row)`; `common.done_pairs(path) -> set[tuple[str,int]]`; `common.claude_call(model, system, user, timeout) -> (text, wall_s)`; `prompt.PROMPT_VERSION = "v1"`, `prompt.SYSTEM`, `prompt.user_message(transcript) -> str`.

- [ ] Write tests: `done_pairs` reads ids/reps from a jsonl and ignores blank lines; `append_jsonl` round-trips unicode.
- [ ] Run, watch fail; implement; run, pass.
- [ ] Commit.

### Task 2: Corpus validation

**Files:** create `bench/validate.py`, `bench/tests/test_validate.py`.

**Produces:** `validate.check(transcript: str, key: dict, brief: dict) -> list[str]` (problems; empty = valid); `validate.check_corpus() -> dict[id, list[str]]` plus corpus-level checks (≥ 3 of each trap kind, exactly 3 controls); CLI prints a table and exits 1 on any problem.

Checks: header format (title line, `· N min ·` matching the brief, the Minutes line); every body line matches `^\[\d\d:\d\d:\d\d\] (Me|Speaker \d+|Caller \d+|Unknown): .+`; timestamps non-decreasing; last timestamp within ±20% of the brief's minutes; word count within ±25% of target; every `evidence` is an exact substring; ids unique; controls have zero decisions; non-controls have ≥ 1; ≥ 2 traps per meeting; owners are a label present in the transcript or a name that appears in it.

- [ ] Tests first with a tiny hand-written valid meeting, then one mutation per check.
- [ ] Implement; pass; commit.

### Task 3: Briefs

**Files:** create `bench/corpus/briefs.json` (30 objects: `id, type, title_hint, minutes, words, sources, control, counts{decisions, actions, questions}, traps[kinds], noise[features], date` with dates spread over Sep 2026–Jan 2027 and times in business hours).

- [ ] Write briefs per spec 3.1 (durations table, a third per source mix, 3 controls, trap-kind coverage ≥ 3 each, noise features spread).
- [ ] A test asserting the briefs' own distribution matches the spec table; commit.

### Task 4: Authoring

**Files:** create `bench/author.py`.

Two-stage per meeting with `claude -p --model opus`: (1) **plan call** returns JSON `{people, outline (segments of ≤ 2,500 words with what happens in each), key}` where evidence strings are left as the exact lines the transcript will contain; (2) **segment calls**, one per outline segment, each given the plan and the last 30 lines so far, returning only transcript lines. Assemble header + lines, write `transcripts/<id>.txt` and `keys/<id>.json`, then run `validate.check`. On problems: one repair call that gets the problems and the full meeting and returns corrected transcript lines and key. Still failing → leave it, record in `corpus/AUTHORING-LOG.md`, fix by hand.

- [ ] Implement with resume (skip meetings whose transcript and key both exist and validate).
- [ ] Dry run on `m01`; read it fully; adjust the authoring prompt if it reads wrong; then the remaining 29 in the background, sequentially.
- [ ] `python -m bench.validate` clean; skim 3 transcripts; commit corpus.

### Task 5: Local runner

**Files:** create `bench/run_local.py`, `bench/tests/test_run_local.py`.

**Produces:** `parse_sse(lines: Iterable[bytes]) -> dict(content, reasoning, finish_reason, usage, timings)`; `strip_reasoning(text) -> str` (removes `<think>…</think>` if a model leaks it); `run(model, reps, ids)`.

- [ ] Tests: SSE stream with content and reasoning deltas, a `[DONE]` line, a final usage chunk, `timings`; a stream that ends with `finish_reason: "length"`; keep-alive comment lines ignored.
- [ ] Implement: streaming POST with `X-Client`, record wall time, time to first byte, `X-Job-Id`; truncated → retry once at 30,000; network errors → errors.jsonl, not a zero.
- [ ] Smoke: one call to `gemma-bigctx` on `m01`; commit.

### Task 6: Claude contestant runner

**Files:** create `bench/run_claude.py`.

- [ ] `claude -p --model sonnet`, system prompt = `prompt.SYSTEM`, stdin = `prompt.user_message(transcript)`, from a scratch dir; record text and wall time; resume-safe; one at a time.
- [ ] Smoke on `m01`; commit.

### Task 7: Runs

- [ ] Message `puget` on thread `t-e989d7b0` (client name, ~120 calls, order, synthetic content, expected window).
- [ ] Sonnet: 60 calls in the background.
- [ ] Local: `caffeinate -i` gemma pass (60), qwen pass (60), one gemma call; background; check progress.
- [ ] Commit results (not traces).

### Task 8: Judge

**Files:** create `bench/judge.py`, `bench/tests/test_judge.py`.

**Produces:** `blind(meeting_id, summaries: dict[(contestant, rep)] -> text, seed) -> (letters -> text, mapping)`; `judge_prompt(transcript, key, lettered) -> str`; `parse_judgment(text, letters, key) -> dict` (validates every letter and key id present; fills missing key ids as `miss` and flags it).

- [ ] Tests: blinding is deterministic per seed, mapping covers all six, lettered text carries no contestant name/model id/rep; parser accepts fenced JSON, rejects a missing letter.
- [ ] Implement; one call per meeting with `claude -p --model opus`; retry once on parse failure; resume-safe.
- [ ] Run on 30 meetings; commit judgments.

### Task 9: Scoring and report

**Files:** create `bench/score.py`, `bench/tests/test_score.py`.

- [ ] Tests: recall with partials; owner accuracy denominator; control meetings count any decision as invented; trap counting by kind; bar verdict true/false at the edges (90.0% passes, 1 invented passes, 2 fails).
- [ ] Implement; write `results/scores.json` and `results/REPORT.md`; commit.

### Task 10: Judge check, findings, docs

- [ ] Read 5 meetings' judgments against transcripts; record agreement in `results/judge-check.md`. Under 90% on extras → tighten judge prompt (v2), re-judge, re-score.
- [ ] Write `bench/FINDINGS.md` (verdict, numbers that matter, character of mistakes with quoted examples, caveats, what would change the result).
- [ ] Update `CLAUDE.md` (status, bench pointer), the research doc, and tell `puget` the run is done. Commit.
