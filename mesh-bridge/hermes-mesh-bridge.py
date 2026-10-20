#!/usr/bin/python3
"""Carries mesh mail for the receive-only name `hermes` to Hermes on edit-3.

Aaron, 2026-10-20: "Can we have hermes as part of the mesh, so you can post information to her? ... so she can know what
progress has been made." claude-chat registered `hermes` (dir ~/.claude/mesh/receivers/hermes, autoOpen false) and set
the rules this follows (thread t-9da69939): claim by rename, forward only `notify` mail from sessions on this Mac (Aaron:
"Just our sessions"), archive everything else unforwarded, `mesh archive` on success, `mesh unclaim` on failure. The relay
dedupes by message id, so a resend after a failed archive never wakes her twice.

Runs from launchd (WatchPaths on the inbox plus a 300 s fallback). Logs state only, never message text.
"""
import json
import os
import subprocess
import sys
import time
from pathlib import Path

HOME = Path.home()
INBOX = HOME / ".claude/mesh/inbox/hermes"
MESH = str(HOME / ".claude/mesh/bin/mesh")
HOST = os.environ.get("HERMES_HOST", "edit-3")
BODY_LIMIT = 4000
# Runs on edit-3: the notify key stays there (config/local.json), never on this Mac.
REMOTE = (
    "K=$(python3 -c 'import json,os;print(json.load(open(os.path.expanduser(\"~/hermes-teams/config/local.json\")))[\"notifyKey\"])') && "
    "curl -sS -f -m 20 -X POST http://127.0.0.1:8787/notify -H 'content-type: application/json' "
    "-H \"x-notify-key: $K\" --data-binary @-"
)


def log(event, **fields):
    print(json.dumps({"t": time.strftime("%Y-%m-%dT%H:%M:%S%z"), "event": event, **fields}), flush=True)


def mesh(*args):
    return subprocess.run([MESH, *args], capture_output=True, text=True, timeout=60)


def forwardable(msg):
    """Only notify mail written on this Mac. Hub mail (another machine) and asks or broadcasts are archived unsent."""
    if msg.get("type") != "notify":
        return False, "not notify"
    if msg.get("via") == "hub" or ":" in str(msg.get("from", "")):
        return False, "not from this Mac"
    return True, ""


def record(msg):
    body = str(msg.get("body", "")).strip()
    if len(body) > BODY_LIMIT:
        body = body[: BODY_LIMIT - 1] + "…"
    return "\n".join([
        f"From session: {msg.get('from', '?')}",
        f"Subject: {msg.get('subject', '')}",
        f"Sent: {msg.get('ts', '')}",
        "",
        body,
    ])


def post(msg):
    payload = json.dumps({"kind": "progress", "records": [record(msg)], "ids": [str(msg.get("id", ""))]})
    r = subprocess.run(["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", HOST, REMOTE],
                       input=payload, capture_output=True, text=True, timeout=90)
    return r.returncode == 0 and '"accepted"' in r.stdout, (r.stderr or r.stdout).strip()[:200]


def main():
    if not INBOX.is_dir():
        return 0
    for path in sorted(INBOX.glob("*.json")):
        claimed = path.with_name(path.name + ".claimed")
        try:
            os.rename(path, claimed)
        except OSError:
            continue  # someone else took it
        try:
            msg = json.loads(claimed.read_text())
        except (OSError, ValueError) as e:
            log("unreadable", file=claimed.name, error=str(e)[:120])
            mesh("archive", str(claimed))
            continue
        ok, why = forwardable(msg)
        if not ok:
            mesh("archive", str(claimed))
            log("skipped", id=msg.get("id"), sender=msg.get("from"), type=msg.get("type"), reason=why)
            continue
        try:
            sent, detail = post(msg)
        except subprocess.TimeoutExpired:
            sent, detail = False, "ssh timed out"
        if sent:
            a = mesh("archive", str(claimed))
            log("forwarded", id=msg.get("id"), sender=msg.get("from"), chars=len(str(msg.get("body", ""))), archived=a.returncode == 0)
        else:
            mesh("unclaim", str(claimed))
            log("forward-failed", id=msg.get("id"), sender=msg.get("from"), detail=detail)
    return 0


if __name__ == "__main__":
    sys.exit(main())
