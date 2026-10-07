"""Runs Claude Sonnet over every meeting with the frozen prompt, one call at a time.

  bench/.venv/bin/python -m bench.run_claude --reps 2

Each call is a headless Claude Code run on Aaron's Max plan with a clean context (no settings,
CLAUDE.md, tools, or MCP), the frozen system prompt, and the user message on stdin, so Sonnet
sees exactly what the Puget models see. Resume-safe on (meeting, rep).
"""
from __future__ import annotations

import argparse
import subprocess
import sys
import time

from . import common, prompt
from .run_local import clean_summary

CONTESTANT = "claude-sonnet"


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--reps", type=int, default=2)
    ap.add_argument("--ids", nargs="*")
    ap.add_argument("--model", default="sonnet")
    args = ap.parse_args()

    out_dir = common.RESULTS / CONTESTANT
    results, errors = out_dir / "results.jsonl", out_dir / "errors.jsonl"
    done = common.done_pairs(results)
    ids = args.ids or common.meeting_ids()
    todo = [(m, r) for r in range(args.reps) for m in ids if (m, r) not in done]
    print(f"{CONTESTANT}: {len(todo)} calls to make ({len(done)} done)", flush=True)
    for i, (meeting, rep) in enumerate(todo, 1):
        transcript = common.load_transcript(meeting)
        try:
            text, wall = common.claude_call(args.model, prompt.SYSTEM, prompt.user_message(transcript), timeout=900)
        except (common.ClaudeCallError, subprocess.TimeoutExpired) as e:
            common.append_jsonl(errors, {"meeting": meeting, "rep": rep, "error": str(e)[:500],
                                         "ts": time.strftime("%Y-%m-%dT%H:%M:%S")})
            print(f"[{i}/{len(todo)}] {meeting} rep{rep} ERROR {str(e)[:120]}", flush=True)
            continue
        summary = clean_summary(text)
        row = {"meeting": meeting, "rep": rep, "contestant": CONTESTANT, "prompt_version": prompt.PROMPT_VERSION,
               "status": "ok" if summary else "empty", "summary": summary, "served_model": args.model,
               "wall_s": round(wall, 2), "first_byte_s": None, "model_s": None, "attempts": 1,
               "ts": time.strftime("%Y-%m-%dT%H:%M:%S")}
        common.append_jsonl(results, row)
        print(f"[{i}/{len(todo)}] {meeting} rep{rep} {row['status']} wall={row['wall_s']}s", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
