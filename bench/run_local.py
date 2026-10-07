"""Runs the Puget models over every meeting through the :11434 queue.

  caffeinate -i bench/.venv/bin/python -m bench.run_local --model gemma-bigctx --reps 2
  caffeinate -i bench/.venv/bin/python -m bench.run_local --model qwen-coder --reps 2 --restore

Streaming ("stream": true) so the scheduler keeps no copy of the result. Resume-safe on
(meeting, rep). A truncated reply is retried once at a larger max_tokens. Network or server
failures go to errors.jsonl, never into the results as a zero. Standard library only.
"""
from __future__ import annotations

import argparse
import http.client
import threading
from concurrent.futures import ThreadPoolExecutor
import json
import re
import sys
import time
import urllib.error
import urllib.request
from typing import Iterable

from . import common, prompt

HOST, PORT = "10.11.4.170", 11434
BASE = f"http://{HOST}:{PORT}"
CONNECT_TIMEOUT = 15
CLIENT = "minutes-tests"
TIMEOUT = 900          # the proxy's ceiling
MAX_TOKENS = 16000
RETRY_TOKENS = 30000


def parse_sse(lines: Iterable[bytes]) -> dict:
    content, reasoning = [], []
    out = {"finish_reason": None, "usage": {}, "timings": {}, "model": None}
    for raw in lines:
        line = raw.decode("utf-8", "replace").strip()
        if not line.startswith("data:"):
            continue
        data = line[5:].strip()
        if data == "[DONE]":
            break
        try:
            chunk = json.loads(data)
        except json.JSONDecodeError:
            continue
        out["model"] = chunk.get("model") or out["model"]
        if chunk.get("usage"):
            out["usage"] = chunk["usage"]
        if chunk.get("timings"):
            out["timings"] = chunk["timings"]
        for choice in chunk.get("choices") or []:
            d = choice.get("delta") or {}
            if d.get("content"):
                content.append(d["content"])
            r = d.get("reasoning_content") or d.get("reasoning")
            if r:
                reasoning.append(r)
            if choice.get("finish_reason"):
                out["finish_reason"] = choice["finish_reason"]
    out["content"] = "".join(content)
    out["reasoning"] = "".join(reasoning)
    return out


def clean_summary(text: str) -> str:
    text = re.sub(r"<think>.*?</think>", "", text, flags=re.S).strip()
    fence = re.match(r"^```[a-zA-Z]*\n(.*?)\n?```$", text, flags=re.S)
    if fence:
        text = fence.group(1).strip()
    return text.strip()


def call(model: str, transcript: str, max_tokens: int) -> dict:
    body = {
        "model": model,
        "messages": [{"role": "system", "content": prompt.SYSTEM},
                     {"role": "user", "content": prompt.user_message(transcript)}],
        "max_tokens": max_tokens,
        "stream": True,
        "stream_options": {"include_usage": True},
    }
    t0 = time.monotonic()
    first_byte = None

    def lines(resp):
        nonlocal first_byte
        while True:
            raw = resp.readline()
            if not raw:
                return
            if first_byte is None:
                first_byte = time.monotonic() - t0
            yield raw

    # Short connect timeout (the Tailscale path drops out), long read timeout (queue + generation).
    conn = http.client.HTTPConnection(HOST, PORT, timeout=CONNECT_TIMEOUT)
    try:
        conn.connect()
        conn.sock.settimeout(TIMEOUT)
        conn.request("POST", "/v1/chat/completions", body=json.dumps(body).encode(),
                     headers={"content-type": "application/json", "X-Client": CLIENT})
        resp = conn.getresponse()
        if resp.status != 200:
            raise urllib.error.HTTPError(f"{BASE}/v1/chat/completions", resp.status, resp.read(300).decode("utf-8", "replace"), resp.headers, None)
        job = resp.headers.get("X-Job-Id")
        out = parse_sse(lines(resp))
    finally:
        conn.close()
    out.update(wall_s=round(time.monotonic() - t0, 2), first_byte_s=round(first_byte or 0, 2),
               job_id=job, max_tokens=max_tokens)
    return out


NETWORK_TRIES = 6   # the off-site Tailscale path drops for a minute at a time (seen 2026-10-07)


def call_with_retries(model: str, transcript: str, max_tokens: int) -> tuple[dict, int]:
    for attempt in range(1, NETWORK_TRIES + 1):
        try:
            return call(model, transcript, max_tokens), attempt - 1
        except (OSError, http.client.HTTPException) as e:   # URLError, timeouts, resets, no route
            if isinstance(e, urllib.error.HTTPError) and 400 <= e.code < 500 and e.code != 429:
                raise
            if attempt == NETWORK_TRIES:
                raise
            time.sleep(min(120, 15 * attempt))
    raise AssertionError("unreachable")


def run_one(model: str, meeting: str, rep: int) -> tuple[dict, dict]:
    transcript = common.load_transcript(meeting)
    first, retries = call_with_retries(model, transcript, MAX_TOKENS)
    attempts = [first]
    if attempts[-1]["finish_reason"] == "length":
        again, more = call_with_retries(model, transcript, RETRY_TOKENS)
        attempts.append(again)
        retries += more
    last = attempts[-1]
    summary = clean_summary(last["content"])
    status = "ok" if summary and last["finish_reason"] != "length" else ("truncated" if last["finish_reason"] == "length" else "empty")
    timings = last.get("timings") or {}
    model_s = round((timings.get("prompt_ms", 0) + timings.get("predicted_ms", 0)) / 1000, 2) if timings else None
    row = {
        "meeting": meeting, "rep": rep, "contestant": model, "prompt_version": prompt.PROMPT_VERSION,
        "status": status, "summary": summary, "served_model": last.get("model"),
        "wall_s": round(sum(a["wall_s"] for a in attempts), 2), "first_byte_s": last["first_byte_s"],
        "model_s": model_s, "attempts": len(attempts), "network_retries": retries,
        "prompt_tokens": (last.get("usage") or {}).get("prompt_tokens"),
        "completion_tokens": (last.get("usage") or {}).get("completion_tokens"),
        "reasoning_chars": len(last["reasoning"]), "job_id": last.get("job_id"),
        "ts": time.strftime("%Y-%m-%dT%H:%M:%S"),
    }
    trace = {"meeting": meeting, "rep": rep, "attempts": attempts}
    return row, trace


def restore_default() -> None:
    """One tiny gemma-bigctx call so the box's default model is loaded again."""
    body = {"model": "gemma-bigctx", "messages": [{"role": "user", "content": "Reply with OK."}],
            "max_tokens": 8, "chat_template_kwargs": {"enable_thinking": False}}
    req = urllib.request.Request(f"{BASE}/v1/chat/completions", data=json.dumps(body).encode(), method="POST",
                                 headers={"content-type": "application/json", "X-Client": CLIENT})
    with urllib.request.urlopen(req, timeout=TIMEOUT) as resp:
        resp.read()


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", required=True, choices=["gemma-bigctx", "qwen-coder"])
    ap.add_argument("--reps", type=int, default=2)
    ap.add_argument("--ids", nargs="*")
    ap.add_argument("--restore", action="store_true", help="load gemma-bigctx again at the end")
    ap.add_argument("--inflight", type=int, default=1,
                    help="requests kept in the queue at once; 2-3 for qwen-coder so other tenants' jobs don't force a swap per call (puget, 2026-10-07)")
    args = ap.parse_args()

    out_dir = common.RESULTS / args.model
    (out_dir / "traces").mkdir(parents=True, exist_ok=True)
    results, errors = out_dir / "results.jsonl", out_dir / "errors.jsonl"
    done = common.done_pairs(results)
    ids = args.ids or common.meeting_ids()
    todo = [(m, r) for r in range(args.reps) for m in ids if (m, r) not in done]
    print(f"{args.model}: {len(todo)} calls to make ({len(done)} done), {args.inflight} in flight", flush=True)
    lock = threading.Lock()
    counter = iter(range(1, len(todo) + 1))

    def work(item):
        meeting, rep = item
        t0 = time.monotonic()
        try:
            row, trace = run_one(args.model, meeting, rep)
        except (urllib.error.URLError, TimeoutError, OSError, ValueError, http.client.HTTPException) as e:
            with lock:
                common.append_jsonl(errors, {"meeting": meeting, "rep": rep, "error": f"{type(e).__name__}: {e}"[:500],
                                             "wall_s": round(time.monotonic() - t0, 1), "ts": time.strftime("%Y-%m-%dT%H:%M:%S")})
                print(f"[{next(counter)}/{len(todo)}] {meeting} rep{rep} ERROR {type(e).__name__}: {str(e)[:120]}", flush=True)
            return
        with lock:
            (out_dir / "traces" / f"{meeting}_rep{rep}.json").write_text(json.dumps(trace, ensure_ascii=False, indent=1))
            common.append_jsonl(results, row)
            print(f"[{next(counter)}/{len(todo)}] {meeting} rep{rep} {row['status']} wall={row['wall_s']}s model={row['model_s']}s "
                  f"in={row['prompt_tokens']} out={row['completion_tokens']}", flush=True)

    with ThreadPoolExecutor(max_workers=max(1, args.inflight)) as pool:
        list(pool.map(work, todo))
    if args.restore:
        restore_default()
        print("restored gemma-bigctx", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
