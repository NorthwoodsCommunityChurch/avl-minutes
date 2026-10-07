"""Blind grading: one Opus call per meeting judges that meeting's six summaries against the key.

  bench/.venv/bin/python -m bench.judge                 # every meeting with all six summaries
  bench/.venv/bin/python -m bench.judge --ids m01 --force

Summaries are shuffled into letters A-F per meeting (seeded); the letter -> contestant map is
written only to results/blind-map.json, which the judge never sees. Resume-safe per meeting.
"""
from __future__ import annotations

import argparse
import json
import random
import sys
import time

from . import common

MODEL = "opus"
SEED = "summary-bench-v1"
JUDGE_VERSION = "j1"
LETTERS = "ABCDEF"
FOUND = {"hit", "partial", "miss"}
OWNER = {"right", "wrong", "missing", "n/a"}
EXTRA = {"supported", "trap", "invented"}
SECTIONS = {"decisions", "actions"}


class JudgeError(ValueError):
    pass


JUDGE_SYSTEM = """You grade meeting summaries against an answer key, strictly and consistently. You will get a meeting transcript, its answer key, and several summaries labeled with letters. Grade every summary independently against the key and the transcript.

The transcript comes from speech recognition: words can be misheard and speaker labels can be wrong. "Me" is Aaron. Labels like "Speaker 2" or "Caller 1" are people; a summary may use the label or the person's name (the key's "people" list maps labels to names) and both count as the same person.

For each summary, return:

"decisions": for every key decision id, one of
  "hit"     - the summary lists it as a decision (or clearly states it was decided), with its meaning intact;
  "partial" - it is there but a key element is wrong or missing (what, which, or how much);
  "miss"    - absent, or only mentioned as an open question or idea.
"actions": for every key action id, {"found": hit|partial|miss, "owner": right|wrong|missing|n/a}
  "found" as above, judged on the task; "owner" is "right" when the summary assigns it to the key's owner (label or name), "wrong" when to someone else, "missing" when no owner is given, "n/a" when the task was missed.
"questions": for every key question id, hit|partial|miss (anywhere in the summary counts).
"extras": every bullet in the summary's Decisions and Action items sections that does NOT correspond to a key decision or action. For each: {"section": "decisions" or "actions", "claim": short quote, "verdict": ..., "trap": trap id or null}
  "trap"      - it matches one of the key's traps (a reversed decision, a hypothetical, a joke, something tentative, something left to another party, something already done, or the wrong owner because of a mislabeled line); give the trap id;
  "supported" - the transcript really supports it as a decision or task (the key just did not list it) and it does not match a trap;
  "invented"  - the transcript does not support it as a decision or task (it was never agreed, never assigned, or did not happen).
  Do not list bullets that match key items. A key item listed in the wrong section (a decision under action items) counts for the key item; do not also list it as an extra.
"format_ok": true if the summary has the four sections (Summary, Decisions, Action items, Open questions) and is a usable summary; false if empty, cut off, or not a summary.

Be strict about decisions: listing something as decided when the transcript shows it was only floated, reversed, joked about, tentative, or left to someone else is a trap or invented, even if worded softly.

Reply with one JSON object only, no prose: {"A": {...}, "B": {...}, ...}"""


def blind(meeting: str, summaries: dict, seed: str = SEED) -> tuple[dict, dict]:
    keys = sorted(summaries)
    rng = random.Random(f"{seed}|{meeting}")
    rng.shuffle(keys)
    lettered = {LETTERS[i]: summaries[k] for i, k in enumerate(keys)}
    mapping = {LETTERS[i]: list(k) for i, k in enumerate(keys)}
    return lettered, mapping


def judge_user_message(transcript: str, key: dict, lettered: dict) -> str:
    key_view = {g: key.get(g, []) for g in ("people", "decisions", "actions", "questions", "traps")}
    parts = ["ANSWER KEY:", json.dumps(key_view, indent=1, ensure_ascii=False), "", "TRANSCRIPT:", transcript.strip(), ""]
    for letter in sorted(lettered):
        text = lettered[letter].strip() or "(no summary returned)"
        parts += [f"SUMMARY {letter}:", text, ""]
    parts.append(f"Grade summaries {', '.join(sorted(lettered))}.")
    return "\n".join(parts)


def parse_judgment(text: str, letters: list[str], key: dict) -> tuple[dict, list[str]]:
    try:
        data = common.extract_json(text)
    except (ValueError, json.JSONDecodeError) as e:
        raise JudgeError(f"not JSON: {e}") from e
    if not isinstance(data, dict):
        raise JudgeError("not an object")
    trap_ids = {t["id"] for t in key.get("traps", [])}
    flags, out = [], {}
    for letter in letters:
        if letter not in data:
            raise JudgeError(f"missing summary {letter}")
        g = data[letter]
        res = {"decisions": {}, "actions": {}, "questions": {}, "extras": [], "format_ok": bool(g.get("format_ok", False))}
        for group in ("decisions", "questions"):
            given = g.get(group) or {}
            for item in key.get(group, []):
                v = given.get(item["id"])
                if v is None:
                    flags.append(f"{letter}: {item['id']} not graded; counted as miss")
                    v = "miss"
                if v not in FOUND:
                    raise JudgeError(f"{letter}: bad verdict {v!r} for {item['id']}")
                res[group][item["id"]] = v
        given = g.get("actions") or {}
        for item in key.get("actions", []):
            v = given.get(item["id"])
            if v is None:
                flags.append(f"{letter}: {item['id']} not graded; counted as miss")
                v = {"found": "miss", "owner": "n/a"}
            if v.get("found") not in FOUND or v.get("owner") not in OWNER:
                raise JudgeError(f"{letter}: bad action verdict {v!r} for {item['id']}")
            res["actions"][item["id"]] = {"found": v["found"], "owner": v["owner"]}
        for x in g.get("extras") or []:
            if x.get("section") not in SECTIONS or x.get("verdict") not in EXTRA:
                raise JudgeError(f"{letter}: bad extra {x!r}")
            if x["verdict"] == "trap" and x.get("trap") not in trap_ids:
                raise JudgeError(f"{letter}: extra names unknown trap {x.get('trap')!r}")
            res["extras"].append({"section": x["section"], "claim": str(x.get("claim", ""))[:300],
                                  "verdict": x["verdict"], "trap": x.get("trap") if x["verdict"] == "trap" else None})
        out[letter] = res
    return out, flags


def load_summaries(meeting: str) -> dict | None:
    found = {}
    for contestant in common.CONTESTANTS:
        for row in common.read_jsonl(common.RESULTS / contestant / "results.jsonl"):
            if row["meeting"] == meeting:
                found[(contestant, row["rep"])] = row["summary"] if row["status"] == "ok" else ""
    expected = {(c, r) for c in common.CONTESTANTS for r in (0, 1)}
    return found if set(found) == expected else None


def judge_meeting(meeting: str) -> dict:
    summaries = load_summaries(meeting)
    if summaries is None:
        raise JudgeError("not all six summaries exist yet")
    key = common.load_key(meeting)
    lettered, mapping = blind(meeting, summaries)
    user = judge_user_message(common.load_transcript(meeting), key, lettered)
    last_error = None
    for attempt in (1, 2):
        text, wall = common.claude_call(MODEL, JUDGE_SYSTEM, user, timeout=1800)
        try:
            parsed, flags = parse_judgment(text, sorted(lettered), key)
            return {"meeting": meeting, "judge_version": JUDGE_VERSION, "attempts": attempt, "wall_s": round(wall, 1),
                    "grades": parsed, "flags": flags, "raw": text, "mapping": mapping}
        except JudgeError as e:
            last_error = e
            user += f"\n\nYour previous reply could not be used ({e}). Reply with the JSON object only, covering every summary letter and every key id."
    raise JudgeError(f"judge failed twice: {last_error}")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--ids", nargs="*")
    ap.add_argument("--force", action="store_true")
    args = ap.parse_args()
    out_dir = common.RESULTS / "judgments"
    out_dir.mkdir(parents=True, exist_ok=True)
    map_path = common.RESULTS / "blind-map.json"
    blind_map = json.loads(map_path.read_text()) if map_path.exists() else {}
    failed = []
    for meeting in args.ids or common.meeting_ids():
        path = out_dir / f"{meeting}.json"
        if path.exists() and not args.force:
            continue
        try:
            result = judge_meeting(meeting)
        except Exception as e:
            print(f"{meeting}: {type(e).__name__}: {str(e)[:200]}", flush=True)
            failed.append(meeting)
            continue
        blind_map[meeting] = result.pop("mapping")
        map_path.write_text(json.dumps(blind_map, indent=1))
        path.write_text(json.dumps(result, indent=1, ensure_ascii=False))
        print(f"{meeting}: judged in {result['wall_s']}s ({result['attempts']} attempt(s)); {len(result['flags'])} flag(s)", flush=True)
        time.sleep(1)
    print(f"done; failed: {failed or 'none'}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
