"""Checks every synthetic meeting against its brief and answer key before any contestant runs.

  bench/.venv/bin/python -m bench.validate          # whole corpus; exits 1 on any problem
"""
from __future__ import annotations

import re
import sys
from collections import Counter

from . import common

TRAP_KINDS = ("reversed", "hypothetical", "joke", "tentative", "other_party", "already_done", "label_noise")
MINUTES_LINE = "Transcribed by Minutes. Audio was not recorded."
HEADER = re.compile(r"^[A-Z][a-z]+day, [A-Z][a-z]+ \d{1,2}, \d{4} · \d{1,2}:\d\d [AP]M · (\d+) min · (Room|Call|Room and call)$")
LINE = re.compile(r"^\[(\d\d):(\d\d):(\d\d)\] (Me|Speaker \d+|Caller \d+|Unknown): (.+)$")
SOURCES = {"Room": ["room"], "Call": ["call"], "Room and call": ["room", "call"]}


def parse_lines(transcript: str) -> tuple[list[str], list[tuple[int, str, str]], list[str]]:
    """Returns (header lines, [(seconds, label, text)], problems)."""
    raw = transcript.rstrip("\n").split("\n")
    header, body, issues = raw[:4], [], []
    for n, line in enumerate(raw[4:], start=5):
        if not line.strip():
            continue
        m = LINE.match(line)
        if not m:
            issues.append(f"line {n} doesn't match the Minutes format: {line[:60]!r}")
            continue
        h, mi, s, label, text = m.groups()
        body.append((int(h) * 3600 + int(mi) * 60 + int(s), label, text))
    return header, body, issues


def check(transcript: str, key: dict, brief: dict) -> list[str]:
    issues: list[str] = []
    header, body, line_issues = parse_lines(transcript)
    issues += line_issues

    # Header
    if len(header) < 4 or not header[0].strip():
        issues.append("header: missing title")
    else:
        m = HEADER.match(header[1])
        if not m:
            issues.append(f"header: bad date line {header[1]!r}")
        else:
            if int(m.group(1)) != brief["minutes"]:
                issues.append(f"header: says {m.group(1)} min, brief says {brief['minutes']}")
            if sorted(SOURCES[m.group(2)]) != sorted(key.get("sources", [])):
                issues.append(f"header: sources {m.group(2)!r} don't match key {key.get('sources')}")
        if header[2] != MINUTES_LINE:
            issues.append("header: third line must be the Minutes line")
        if header[3].strip():
            issues.append("header: fourth line must be blank")

    # Timing and length
    times = [t for t, _, _ in body]
    if any(b < a for a, b in zip(times, times[1:])):
        issues.append("timestamps go backwards")
    if times:
        target = brief["minutes"] * 60
        if not (0.8 * target <= times[-1] <= 1.2 * target):
            issues.append(f"length: last line at {times[-1]} s, expected about {target} s")
    words = sum(len(text.split()) for _, _, text in body)
    if not (0.75 * brief["words"] <= words <= 1.25 * brief["words"]):
        issues.append(f"words: {words}, expected about {brief['words']}")

    # Key
    items = [(group, item) for group in ("decisions", "actions", "questions", "traps") for item in key.get(group, [])]
    ids = Counter(item.get("id") for _, item in items)
    for dup in [i for i, c in ids.items() if c > 1]:
        issues.append(f"duplicate id {dup}")
    for group, item in items:
        ev = item.get("evidence", "")
        if not ev or ev not in transcript:
            issues.append(f"{item.get('id')}: evidence is not an exact substring of the transcript: {ev[:60]!r}")
    for trap in key.get("traps", []):
        if trap.get("kind") not in TRAP_KINDS:
            issues.append(f"{trap.get('id')}: unknown trap kind {trap.get('kind')!r}")

    labels = {label for _, label, _ in body}
    spoken = " ".join(text for _, _, text in body)
    for action in key.get("actions", []):
        owner = action.get("owner", "")
        if owner not in labels and not re.search(rf"\b{re.escape(owner)}\b", spoken):
            issues.append(f"{action.get('id')}: owner {owner!r} is neither a label in the transcript nor named in it")

    control = brief.get("control", False)
    if key.get("control", False) != control:
        issues.append("control flag differs between key and brief")
    if control and key.get("decisions"):
        issues.append("control meeting must have no decisions")
    if not control and not key.get("decisions"):
        issues.append("regular meeting needs at least one decision")
    if len(key.get("traps", [])) < 2:
        issues.append("needs at least two traps")
    return issues


def corpus_checks(keys: dict[str, dict]) -> list[str]:
    issues = []
    kinds = Counter(t.get("kind") for k in keys.values() for t in k.get("traps", []))
    for kind in TRAP_KINDS:
        if kinds[kind] < 3:
            issues.append(f"trap kind {kind!r} used {kinds[kind]} times (need at least 3)")
    controls = sum(1 for k in keys.values() if k.get("control"))
    if controls != 3:
        issues.append(f"{controls} control meetings (need exactly 3)")
    return issues


def check_corpus() -> tuple[dict[str, list[str]], list[str]]:
    briefs = {b["id"]: b for b in common.load_briefs()}
    per_meeting, keys = {}, {}
    for mid, brief in briefs.items():
        tpath, kpath = common.TRANSCRIPTS / f"{mid}.txt", common.KEYS / f"{mid}.json"
        if not tpath.exists() or not kpath.exists():
            per_meeting[mid] = ["missing transcript or key"]
            continue
        key = common.load_key(mid)
        keys[mid] = key
        per_meeting[mid] = check(tpath.read_text(), key, brief)
    return per_meeting, corpus_checks(keys)


def main() -> int:
    per_meeting, corpus = check_corpus()
    bad = 0
    for mid, issues in sorted(per_meeting.items()):
        status = "ok" if not issues else f"{len(issues)} problem(s)"
        print(f"{mid}: {status}")
        for issue in issues:
            print(f"    {issue}")
        bad += bool(issues)
    for issue in corpus:
        print(f"corpus: {issue}")
    print(f"{len(per_meeting) - bad}/{len(per_meeting)} meetings valid; {len(corpus)} corpus problem(s)")
    return 1 if bad or corpus else 0


if __name__ == "__main__":
    sys.exit(main())
