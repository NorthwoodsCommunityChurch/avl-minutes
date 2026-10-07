# Meeting summary bench — design

**Date:** 2026-10-07 · **Status:** approved by Aaron in chat ("made up meetings is okay, go ahead") · **Home:** `bench/` in this repo

## 1. Purpose

Answer one question with evidence: **can a local model on the Puget box summarize Minutes transcripts well enough to do it automatically after every meeting?** The candidates are Gemma (`gemma-bigctx`) and Qwen (`qwen-coder`). Claude Sonnet is the reference bar. The result decides whether Minutes gets an automatic "summary at the top of the note" feature, and with which model.

Background: [docs/research/2026-10-07-puget-meeting-summaries.md](../../research/2026-10-07-puget-meeting-summaries.md). On one synthetic transcript, Qwen listed eight decisions that were never made; Gemma hedged. For meeting minutes, **an invented decision is the failure that matters most**, so the bench is built to provoke and count it.

### What Aaron approved (the decision summary)

- About 30 made-up meetings in Minutes' real transcript format, staff / production / vendor / one-on-one, 10–90 minutes, written by Opus with a hidden answer key.
- Traps that catch invented content: reversed decisions, "what if" ideas, jokes, implicit chores, speech-recognition mistakes.
- Scoring: decisions and action items found, owner right, invented content (invented decisions weighted most). Opus grades blind to the model. Each model runs twice.
- Bar: ≥ 9 in 10 decisions and action items caught; ≤ 1 invented decision across the 30 meetings; never empty; finishes within 3 minutes.
- About 2–3 hours of box time through the normal queue; the Puget session is told first.
- Made-up meetings only (no real transcripts exist yet, and real content must not reach the box until the llama-swap capture fix lands).

## 2. Non-goals

- Not a general summarization benchmark; it measures what Minutes would ship.
- No prompt tuning during the run. The prompt is frozen (v1). A tuned prompt is a later round with a new version label.
- No Opus or Haiku as contestants. No API key (Aaron's standing rule): every Claude call runs through Claude Code on his Max plan.
- No changes to Minutes in this bench.

## 3. Corpus

### 3.1 Shape

30 meetings, ids `m01`–`m30`. Durations and word targets (about 140 spoken words per minute):

| Minutes | Count | Words (≈) |
|---|---|---|
| 10 | 6 | 1,400 |
| 20 | 6 | 2,800 |
| 30 | 7 | 4,200 |
| 45 | 5 | 6,300 |
| 60 | 4 | 8,400 |
| 90 | 2 | 12,600 |

Total ≈ 145k words. Sources: about a third room only, a third call only, a third room and call. Meeting types drawn from Aaron's world at Northwoods (all people and details invented): weekend production meeting, staff meeting, vendor call (projectors, LED wall, intercom), one-on-one with a direct report, Christmas Eve / Easter planning, MSP or IT ticket call, budget review, volunteer scheduling, facilities walkthrough, event debrief, hiring debrief (personnel-sensitive), and similar. **Three meetings are controls with no decisions at all** (pure status or information sharing); any decision a model lists there is invented.

### 3.2 Transcript format

Exactly Minutes' plain-text format (`TranscriptDocument.plainText`):

```
<Title>
Tuesday, October 13, 2026 · 2:00 PM · 30 min · Room and call
Transcribed by Minutes. Audio was not recorded.

[00:00:04] Me: Okay, let's get started.
[00:00:09] Caller 1: Can everyone hear me?
```

Labels: `Me` (Aaron Larson, AVL director), `Speaker n` (room), `Caller n` (call), `Unknown`. Realism features, spread across the corpus: speech-recognition errors (homophones, mangled product names such as "carbon light" for Carbonite, dropped words), filler and false starts, crosstalk, off-topic chat, short `Unknown` lines, and **label noise** (one person split across two labels, or a short line attributed to the wrong speaker). Names appear only when people use them in speech.

### 3.3 Answer key

One JSON file per meeting in `bench/corpus/keys/` (never shown to contestants):

```json
{
  "id": "m07", "title": "...", "type": "vendor call", "minutes": 30, "sources": ["call"],
  "control": false,
  "people": [{"label": "Me", "name": "Aaron", "role": "AVL director"}, {"label": "Caller 1", "name": "Priya", "role": "vendor rep"}],
  "decisions": [{"id": "d1", "text": "Order two replacement lamps", "evidence": "exact substring of the transcript"}],
  "actions": [{"id": "a1", "task": "Send the PO", "owner": "Me", "due": "Friday", "evidence": "..."}],
  "questions": [{"id": "q1", "text": "Whether the warranty covers the fan", "evidence": "..."}],
  "traps": [{"id": "t1", "kind": "reversed", "claim": "They decided to buy a new projector", "evidence": "..."}]
}
```

- `owner` is the speaker label, or a name if the transcript names someone not present.
- Trap kinds: `reversed` (agreed, then undone), `hypothetical` ("what if we…"), `joke`, `tentative` (leaning but explicitly not decided), `other_party` (someone else will decide), `already_done` (reported as done, not a new action), `label_noise` (owner would be wrong if the label is trusted naively). Every meeting has at least two traps; every kind appears at least three times in the corpus.
- Counts scale with length: decisions 0–8 (0 only in controls), actions 1–10, questions 0–4.
- `evidence` strings must be exact substrings of the transcript; `bench/validate.py` enforces this and the count rules.

### 3.4 Authoring

`claude -p --model opus` with a clean context (`--setting-sources ""`, `--tools ""`, own system prompt, `--no-session-persistence`), one call per meeting, sequential, writing each transcript and key as it finishes (resume-safe). Inputs: a per-meeting brief from `bench/corpus/briefs.json` (id, type, minutes, sources, counts, traps to include, noise features). Output: one JSON object with `transcript` and `key`. Meetings longer than 30 minutes are authored in parts (outline and key first, then the transcript in sequential segments that continue from the previous one) so no single response is too long. A meeting that fails validation is regenerated once; a second failure is fixed by hand and noted.

## 4. Contestants and the frozen prompt

| Contestant | How it runs | Settings |
|---|---|---|
| `gemma-bigctx` | `POST http://10.11.4.170:11434/v1/chat/completions`, `X-Client: minutes-tests`, `"stream": true` with `stream_options.include_usage` | Reasoning on (box default). Sampling at the box's defaults (what Minutes would get). `max_tokens` 16,000; a truncated reply is retried once at 30,000. |
| `qwen-coder` | Same | Same |
| `claude-sonnet` | `claude -p --model sonnet`, clean context as in 3.4, transcript on stdin | Claude Code defaults |

Every contestant gets the same system prompt and the same user message (`bench/prompt.py`, version `v1`): who Aaron is, what the labels mean, that the text comes from speech recognition and labels can be wrong, and the required output:

```
## Summary
2–4 sentences.
## Decisions
- One bullet per decision actually agreed. "None." if none.
## Action items
- Owner — task (due date if one was said). "None." if none.
## Open questions
- "None." if none.
```

Rules in the prompt: list only decisions that were actually agreed (not ideas floated, reversed, joked about, or left to someone else); when unsure, put it under Open questions; use a person's name only when the transcript makes it clear, otherwise the label; never invent dates or owners.

Each contestant runs every meeting twice (rep 0 and rep 1). 180 summaries in total.

## 5. Grading

### 5.1 Judge

`claude -p --model opus`, clean context, **one call per meeting**: the transcript, the answer key, and that meeting's six summaries (3 contestants × 2 reps) shuffled and labeled A–F. The mapping lives only in `bench/results/blind-map.json`, which the judge never sees. The judge returns JSON per summary:

```json
{"A": {
  "decisions": {"d1": "hit", "d2": "partial", "d3": "miss"},
  "actions":   {"a1": {"found": "hit", "owner": "right"}, "a2": {"found": "miss", "owner": "n/a"}},
  "questions": {"q1": "hit"},
  "extras": [{"section": "decisions", "claim": "...", "verdict": "invented", "trap": null},
             {"section": "actions", "claim": "...", "verdict": "trap", "trap": "t2"},
             {"section": "decisions", "claim": "...", "verdict": "supported", "trap": null}],
  "format_ok": true
}}
```

`hit` = the item is there with its meaning intact; `partial` = there but missing a key element (who, what, or which); `miss` = absent. `extras` lists every decision or action item in the summary that does not match a key item: `supported` (really in the transcript, the key just omitted it), `trap` (matches a planted trap), or `invented`. Owners count as `right` if the summary names the right label or the right person.

### 5.2 Judge check

Before the numbers are trusted, I (the main session) read the judgments for 5 meetings in full against the transcripts and record agreement per verdict in `bench/results/judge-check.md`. Under 90% agreement on extras verdicts → tighten the judge prompt and re-judge everything.

### 5.3 Scores (deterministic, `bench/score.py`)

Per contestant, per rep, then averaged:

- **Decision recall** = (hits + 0.5 × partials) / key decisions. Same for **action recall** and **question recall**. **Core recall** = decisions and actions pooled.
- **Owner accuracy** = actions found with the right owner / actions found.
- **Invented decisions** = extras in the Decisions section judged `invented` or `trap`. Same count for action items, reported separately.
- **Trap violations** by kind.
- **Control meetings**: any decision listed in a control counts as invented.
- **Empty or unusable** = no reply after the retry, or `format_ok` false.
- **Time**: wall time per call; for local models also model time from the server's `timings` (prompt + generation) when present, and time to first streamed byte.

### 5.4 The bar ("good enough to run automatically")

All four, on both reps:

1. Core recall ≥ 90%.
2. Invented decisions ≤ 1 across the 30 meetings.
3. Zero empty or unusable summaries.
4. 90th-percentile model time ≤ 180 s (local models; queue wait reported separately because it depends on other tenants).

## 6. Operations

- **Tell `puget` first** (mesh thread `t-e989d7b0`): client name `minutes-tests`, both models, about 120 calls, run order, and that the content is synthetic.
- **Run order on the box:** all `gemma-bigctx` calls, then all `qwen-coder` calls, then one small `gemma-bigctx` call to put the default model back. Runs under `caffeinate -i` (the proofreading bench lost time to the Mac sleeping). Client timeout 900 s (the proxy ceiling).
- The local runner and the Claude runners are resume-safe on (meeting, rep).
- Claude calls (authoring, Sonnet, judge) run one at a time. Plan-usage reading was unavailable at design time, so no parallel fan-out.
- **Hide the answers:** contestants receive only the transcript text through stdin or the request body; the runners never read `keys/`. The judge sees keys by design.

## 7. Outputs

- `bench/results/<contestant>/results.jsonl` (one row per meeting and rep: status, summary text, tokens, timings), `traces/` (git-ignored).
- `bench/results/judgments/<meeting>.json`, `blind-map.json`, `scores.json`, `REPORT.md` (tables + bar verdict).
- `bench/FINDINGS.md`: the plain-language verdict for Aaron, with the character of each model's mistakes and examples.

## 8. Layout

```
bench/
├── README.md               how to run each step
├── corpus/briefs.json      the 30 meeting briefs (committed)
├── corpus/transcripts/     m01.txt … (committed; synthetic)
├── corpus/keys/            m01.json … (committed; never sent to contestants)
├── prompt.py               frozen v1 system prompt + user message; judge prompt
├── author.py               claude -p opus authoring, resume-safe
├── validate.py             evidence substrings, counts, trap coverage
├── run_local.py            box runner (streaming, retry-on-truncation, resume-safe)
├── run_claude.py           claude -p sonnet runner, resume-safe
├── judge.py                blind judging, one call per meeting
├── score.py                deterministic scores + REPORT.md
├── common.py               paths, loaders, helpers
├── tests/                  pytest: validate, SSE parsing, scoring, blinding
└── results/
```

Python 3 standard library only (plus pytest in a local `.venv` for tests).

## 9. Risks

- **Judge bias toward Claude-style summaries.** Mitigated by blinding, a fixed rubric anchored to the key, and the 5-meeting judge check. Stated as a caveat in the findings.
- **Synthetic meetings are cleaner than real ones.** Mitigated by deliberate noise; the follow-up round on 5–10 real transcripts (after the capture fix) is the real confirmation.
- **Sonnet runs in Claude Code, local models run bare.** Same prompt and input, different rigs; stated as a caveat (the proofreading bench did the same).
- **One rep is noise; two reps show variance but not much more.** Differences under about 3 points are treated as ties.
