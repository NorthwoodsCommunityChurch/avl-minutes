"""Writes the synthetic meetings with Opus (claude -p, clean context, one call at a time).

  bench/.venv/bin/python -m bench.author --ids m01            # one meeting
  bench/.venv/bin/python -m bench.author                      # every meeting not yet valid

Per meeting: a plan call (people, segment outline, answer key with verbatim evidence phrases),
one call per segment (transcript lines only), then validation and at most one key-repair call.
Resume-safe: a meeting whose transcript and key exist and validate is skipped.
"""
from __future__ import annotations

import argparse
import json
import re
import sys
import time

from . import common, validate

MODEL = "opus"
SEGMENT_MINUTES = 20

AUTHOR_SYSTEM = """You write realistic, entirely fictional meeting transcripts for a test that checks how well AI models summarize meetings. Accuracy of the answer key matters more than anything else.

Setting: Northwoods Community Church. "Me" is always Aaron Larson, the AVL (audio, video, and lighting) director. Everyone else is invented; use first names only, and only when people say them out loud. Topics are realistic church production and operations work: weekend services, cameras, lighting, audio consoles, ProPresenter, livestreams, LED walls, intercom, volunteers, budgets, vendors, the outside IT provider (MSP), facilities.

The transcript imitates the Minutes app: speech recognition output with speaker labels.
- Line format, exactly: [hh:mm:ss] Label: words
- Labels: "Me" (Aaron), "Speaker 1", "Speaker 2", ... for people in the room, numbered in order of first appearance; "Caller 1", "Caller 2", ... for people on the call; "Unknown" for short lines the app could not attribute. No other labels, ever. Never put a name in a label.
- Lines are 1 to 3 spoken sentences. Timestamps increase by realistic amounts (people speak about 140 words a minute, with pauses).
- Speech is natural: filler ("um", "you know"), false starts, people interrupting, small talk, tangents.
- Speech recognition mistakes, as requested by the brief: misheard common words and mangled product names (for example "carbon light" for Carbonite, "pro presenter" for ProPresenter, "cue sis" for Q-SYS, "clear calm" for Clear-Com, "ultra ex" for Ultrix). Keep it readable: a careful human can still follow the meeting.
- Noise features from the brief: label_split = one person appears under two labels for part of the meeting; misattributed_short_line = a short line credited to the wrong person; crosstalk = overlapping fragments; offtopic = a stretch of unrelated chat; unknown_lines = several short "Unknown" lines.

The answer key lists what a careful, attentive human would write as the meeting's minutes:
- decisions: things the group actually agreed, clearly and finally.
- actions: tasks someone committed to do, with the owner (a label from the transcript such as "Me" or "Caller 2", or a first name that is spoken in the transcript for someone not present) and a due date only if one was said.
- questions: issues raised and left unresolved.
- traps: things a careless summarizer would wrongly report. Kinds: reversed (agreed, then explicitly undone later in the meeting), hypothetical ("what if we..." never settled), joke (said in jest), tentative (someone leans toward it but it is explicitly not decided), other_party (left for someone else, such as the elders or finance, to decide), already_done (reported as finished; not a new task), label_noise (the label on the key line points to the wrong person; context makes the real person clear, and the key's owner is the real one). Each trap has "claim": the wrong statement a careless summary would make.
Every key item has "evidence": a distinctive phrase of at least six words that appears VERBATIM, character for character, in one transcript line. Items must be unambiguous to an attentive reader."""

PLAN_INSTRUCTIONS = """Plan this meeting. Reply with one JSON object only, no prose:
{
  "title": "short meeting title",
  "people": [{"label": "Me", "name": "Aaron", "role": "AVL director"}, ...],
  "segments": [{"start_min": 0, "end_min": 20, "beats": "what happens in this stretch, in order, citing the ids of the key items and traps that occur here, e.g. (d1) (a2) (t1)"}],
  "key": {
    "decisions": [{"id": "d1", "text": "...", "evidence": "exact phrase to be spoken"}],
    "actions":   [{"id": "a1", "task": "...", "owner": "label or spoken first name", "due": "Friday" or null, "evidence": "..."}],
    "questions": [{"id": "q1", "text": "...", "evidence": "..."}],
    "traps":     [{"id": "t1", "kind": "reversed", "claim": "...", "evidence": "..."}]
  }
}
Use exactly the counts and trap kinds in the brief. Segments cover the whole meeting in stretches of at most {segment} minutes. Each evidence phrase must be a natural part of a spoken sentence and must be written verbatim later. A reversed trap's evidence is the original agreement; the reversal must happen later in a different segment or later in the same one.

Brief:
"""

SEGMENT_INSTRUCTIONS = """Write the transcript lines for segment {n} of {total} (minutes {start} to {end}, about {words} words).
Reply with transcript lines only, one per line, in the exact format [hh:mm:ss] Label: words. No headings, no code fences, no commentary.
The first timestamp is at or after {first_ts}. The last is close to {end_ts}.
These exact phrases MUST appear verbatim, character for character, inside spoken lines in this segment:
{phrases}

Meeting plan:
{plan}

{tail}"""

REPAIR_INSTRUCTIONS = """The answer key below fails validation against its transcript. Fix the KEY only, so every evidence string is an exact substring of one transcript line (copy it character for character from the transcript), owners are labels that appear in the transcript or first names spoken in it, and ids are unique. Keep the same items and meanings; do not add or drop items unless an item truly does not occur in the transcript, in which case remove it. Reply with the corrected key as one JSON object only.

Problems:
{problems}

Key:
{key}

Transcript:
{transcript}"""

LINE = re.compile(r"^\[\d\d:\d\d:\d\d\] (Me|Speaker \d+|Caller \d+|Unknown): .+$")
SOURCE_TEXT = {("room",): "Room", ("call",): "Call", ("call", "room"): "Room and call"}


def ts(minutes: float) -> str:
    s = int(minutes * 60)
    return f"{s // 3600:02d}:{s % 3600 // 60:02d}:{s % 60:02d}"


def header(plan: dict, brief: dict) -> str:
    src = SOURCE_TEXT[tuple(sorted(brief["sources"]))]
    return f"{plan['title']}\n{brief['date']} · {brief['time']} · {brief['minutes']} min · {src}\n{validate.MINUTES_LINE}\n\n"


def phrases_for(plan: dict, start: int, end: int, segments: list[dict]) -> list[str]:
    """Evidence phrases whose items the plan places in this segment (falls back to all, for one segment)."""
    key = plan["key"]
    items = [i for g in ("decisions", "actions", "questions", "traps") for i in key.get(g, [])]
    if len(segments) == 1:
        return [i["evidence"] for i in items]
    beats = next(s["beats"] for s in segments if s["start_min"] == start)
    chosen = [i["evidence"] for i in items if re.search(rf"\b{re.escape(i['id'])}\b", beats)]
    return chosen


def author(brief: dict, log) -> bool:
    mid = brief["id"]
    brief_text = json.dumps(brief, indent=1)
    plan_text, wall = common.claude_call(MODEL, AUTHOR_SYSTEM, PLAN_INSTRUCTIONS.replace("{segment}", str(SEGMENT_MINUTES)) + brief_text)
    plan = common.extract_json(plan_text)
    log(f"{mid}: plan {wall:.0f}s, {len(plan['segments'])} segment(s)")

    segments = plan["segments"]
    placed = set()
    lines: list[str] = []
    for n, seg in enumerate(segments, 1):
        phrases = phrases_for(plan, seg["start_min"], seg["end_min"], segments)
        if n == len(segments):  # anything the beats didn't place goes in the last segment
            all_ev = [i["evidence"] for g in ("decisions", "actions", "questions", "traps") for i in plan["key"].get(g, [])]
            phrases += [p for p in all_ev if p not in placed and p not in phrases]
        placed.update(phrases)
        words = int((seg["end_min"] - seg["start_min"]) * 140)
        tail = ("The meeting so far ends with these lines; continue naturally from them:\n" + "\n".join(lines[-30:])) if lines else "This is the start of the meeting."
        prompt = SEGMENT_INSTRUCTIONS.format(
            n=n, total=len(segments), start=seg["start_min"], end=seg["end_min"], words=words,
            first_ts=ts(seg["start_min"]), end_ts=ts(seg["end_min"]),
            phrases="\n".join(f"- {p}" for p in phrases) or "- (none in this segment)",
            plan=json.dumps({k: plan[k] for k in ("title", "people", "segments")}, indent=1), tail=tail)
        text, wall = common.claude_call(MODEL, AUTHOR_SYSTEM, prompt)
        new = [l.strip() for l in text.splitlines() if LINE.match(l.strip())]
        lines += new
        log(f"{mid}: segment {n}/{len(segments)} {wall:.0f}s, {len(new)} lines")

    transcript = header(plan, brief) + "\n".join(lines) + "\n"
    key = {"id": mid, "title": plan["title"], "type": brief["type"], "minutes": brief["minutes"],
           "sources": brief["sources"], "control": brief["control"], "people": plan["people"], **plan["key"]}
    problems = validate.check(transcript, key, brief)
    if problems and any("evidence" in p or "owner" in p or "duplicate" in p for p in problems):
        fixed_text, wall = common.claude_call(MODEL, AUTHOR_SYSTEM, REPAIR_INSTRUCTIONS.format(
            problems="\n".join(problems), key=json.dumps(plan["key"], indent=1), transcript=transcript))
        fixed = common.extract_json(fixed_text)
        key.update({g: fixed.get(g, key.get(g, [])) for g in ("decisions", "actions", "questions", "traps")})
        problems = validate.check(transcript, key, brief)
        log(f"{mid}: key repair {wall:.0f}s, {len(problems)} problem(s) left")

    common.TRANSCRIPTS.mkdir(parents=True, exist_ok=True)
    common.KEYS.mkdir(parents=True, exist_ok=True)
    (common.TRANSCRIPTS / f"{mid}.txt").write_text(transcript)
    (common.KEYS / f"{mid}.json").write_text(json.dumps(key, indent=1, ensure_ascii=False) + "\n")
    log(f"{mid}: {'VALID' if not problems else 'PROBLEMS: ' + '; '.join(problems)}")
    return not problems


def is_valid(brief: dict) -> bool:
    t, k = common.TRANSCRIPTS / f"{brief['id']}.txt", common.KEYS / f"{brief['id']}.json"
    return t.exists() and k.exists() and not validate.check(t.read_text(), common.load_key(brief["id"]), brief)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--ids", nargs="*")
    ap.add_argument("--force", action="store_true", help="rewrite even if valid")
    args = ap.parse_args()
    log_path = common.CORPUS / "AUTHORING-LOG.md"

    def log(msg: str) -> None:
        line = f"- {time.strftime('%H:%M:%S')} {msg}"
        print(line, flush=True)
        with log_path.open("a") as f:
            f.write(line + "\n")

    briefs = [b for b in common.load_briefs() if not args.ids or b["id"] in args.ids]
    failed = []
    for brief in briefs:
        if not args.force and is_valid(brief):
            continue
        try:
            if not author(brief, log):
                failed.append(brief["id"])
        except Exception as e:  # keep going; the log says what broke
            log(f"{brief['id']}: ERROR {type(e).__name__}: {str(e)[:300]}")
            failed.append(brief["id"])
    print(f"done; needs attention: {failed or 'none'}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
