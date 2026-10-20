#!/bin/bash
# Waits until the Teams relay on the mini has nothing running and nothing waiting, so a deploy never restarts Hermes or
# the relay mid-answer (2026-10-20: one board answer never reached Aaron and a later message failed with
# "ECONNREFUSED 127.0.0.1:8642", both from restarts during a turn). Exits 1 after the limit; nothing is restarted then.
#   bash scripts/wait-hermes-idle.sh [host] [max seconds, default 1200]
set -euo pipefail
HOST="${1:-edit-3}"
MAX="${2:-1200}"
start=$(date +%s)
while true; do
  status=$(ssh -o ConnectTimeout=10 "$HOST" 'curl -s -m 5 http://127.0.0.1:8787/status' || true)
  if [ -z "$status" ]; then echo "Relay on $HOST did not answer /status; not waiting on it."; exit 0; fi
  if echo "$status" | grep -q '"busy":false' && echo "$status" | grep -q '"waiting":0'; then exit 0; fi
  # A relay from before /status answers 404 JSON; treat it as unknown, not busy.
  if ! echo "$status" | grep -q '"busy"'; then echo "Relay on $HOST has no /status yet; not waiting on it."; exit 0; fi
  waited=$(( $(date +%s) - start ))
  if [ "$waited" -ge "$MAX" ]; then echo "Hermes on $HOST is still busy after ${MAX}s ($status); not deploying."; exit 1; fi
  echo "Hermes on $HOST is answering ($status); waiting..."
  sleep 15
done
