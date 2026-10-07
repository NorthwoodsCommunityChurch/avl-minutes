"""Shared paths and helpers for the meeting summary bench. Standard library only."""
from __future__ import annotations

import json
import subprocess
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent
CORPUS = ROOT / "corpus"
TRANSCRIPTS = CORPUS / "transcripts"
KEYS = CORPUS / "keys"
BRIEFS = CORPUS / "briefs.json"
RESULTS = ROOT / "results"

CONTESTANTS = ("gemma-bigctx", "qwen-coder", "claude-sonnet")


def load_briefs() -> list[dict]:
    return json.loads(BRIEFS.read_text())


def meeting_ids() -> list[str]:
    return sorted(p.stem for p in TRANSCRIPTS.glob("m*.txt"))


def load_transcript(meeting: str) -> str:
    return (TRANSCRIPTS / f"{meeting}.txt").read_text()


def load_key(meeting: str) -> dict:
    return json.loads((KEYS / f"{meeting}.json").read_text())


def append_jsonl(path: Path, row: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a", encoding="utf-8") as f:
        f.write(json.dumps(row, ensure_ascii=False) + "\n")


def read_jsonl(path: Path) -> list[dict]:
    if not path.exists():
        return []
    return [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines() if line.strip()]


def done_pairs(path: Path) -> set[tuple[str, int]]:
    return {(r["meeting"], r["rep"]) for r in read_jsonl(path)}


class ClaudeCallError(RuntimeError):
    pass


def claude_call(model: str, system: str, user: str, timeout: float = 1800) -> tuple[str, float]:
    """One headless Claude Code call on Aaron's Max plan, with a clean context: no settings,
    CLAUDE.md, tools, MCP servers, or saved session. The user message goes in on stdin."""
    cmd = [
        "claude", "-p", "--model", model,
        "--system-prompt", system,
        "--setting-sources", "",
        "--tools", "",
        "--strict-mcp-config",
        "--no-session-persistence",
        "--output-format", "text",
    ]
    t0 = time.monotonic()
    with tempfile.TemporaryDirectory(prefix="summary-bench-") as scratch:
        proc = subprocess.run(cmd, input=user, capture_output=True, text=True, timeout=timeout, cwd=scratch)
    wall = time.monotonic() - t0
    if proc.returncode != 0:
        raise ClaudeCallError(f"claude exited {proc.returncode}: {(proc.stderr or proc.stdout)[:500]}")
    return proc.stdout.strip(), wall


def extract_json(text: str):
    """Parse the first JSON object or array in a reply, tolerating code fences and prose around it."""
    text = text.strip()
    if text.startswith("```"):
        text = text.split("\n", 1)[1] if "\n" in text else ""
        if text.rstrip().endswith("```"):
            text = text.rstrip()[:-3]
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        pass
    starts = [i for i in (text.find("{"), text.find("[")) if i >= 0]
    if not starts:
        raise ValueError("no JSON found")
    start = min(starts)
    decoder = json.JSONDecoder()
    obj, _ = decoder.raw_decode(text[start:])
    return obj
