#!/bin/bash
# Runs the two 16 GB-class contestants on this Mac, one model at a time, through a local
# llama-server on port 11435. Resume-safe (bench.run_local skips finished meeting+rep pairs).
#   bash bench/run-16gb.sh                 # both models, 2 reps, every written meeting
#   bash bench/run-16gb.sh gemma-4-12b     # one model
#   IDS="m01 m02" REPS=1 bash bench/run-16gb.sh gemma-4-12b   # subset
set -euo pipefail
cd "$(dirname "$0")/.."
MODELS_DIR="$HOME/.local/share/summary-bench/models"
PORT=11435
REPS="${REPS:-2}"
CTX="${CTX:-65536}"

model_file() {   # macOS ships bash 3.2: no associative arrays
  case "$1" in
    gemma-4-12b) echo "gemma-4-12b-it-Q4_K_M.gguf" ;;
    qwen3.5-9b)  echo "Qwen3.5-9B-Q4_K_M.gguf" ;;
    *) echo "unknown contestant: $1" >&2; exit 1 ;;
  esac
}
CONTESTANTS=("$@")
[ ${#CONTESTANTS[@]} -eq 0 ] && CONTESTANTS=(gemma-4-12b qwen3.5-9b)

stop_server() { [ -n "${SERVER_PID:-}" ] && kill "$SERVER_PID" 2>/dev/null && wait "$SERVER_PID" 2>/dev/null || true; }
trap stop_server EXIT

for name in "${CONTESTANTS[@]}"; do
  file="$MODELS_DIR/$(model_file "$name")"
  [ -s "$file" ] || { echo "missing model file: $file" >&2; exit 1; }
  echo "== $name: starting llama-server on :$PORT ($(date +%H:%M:%S))"
  llama-server -m "$file" -c "$CTX" -ngl 99 --jinja --reasoning-format deepseek \
    --port "$PORT" --host 127.0.0.1 -np 1 --log-disable > "bench/results/llama-server-$name.log" 2>&1 &
  SERVER_PID=$!
  for i in $(seq 1 120); do
    curl -s -m 2 "http://127.0.0.1:$PORT/health" | grep -q '"ok"' && break
    sleep 2
    kill -0 "$SERVER_PID" 2>/dev/null || { echo "llama-server died; see bench/results/llama-server-$name.log" >&2; exit 1; }
  done
  curl -s -m 2 "http://127.0.0.1:$PORT/health" | grep -q '"ok"' || { echo "llama-server never became healthy" >&2; exit 1; }
  # shellcheck disable=SC2086
  bench/.venv/bin/python -m bench.run_local --base "http://127.0.0.1:$PORT" --model "$name" --reps "$REPS" ${IDS:+--ids $IDS}
  stop_server; SERVER_PID=""
  echo "== $name: done ($(date +%H:%M:%S))"
done
