#!/bin/bash
# Finishes the summary bench end to end, detached from any session (launch with nohup).
# Resume-safe throughout: every runner and the judge skip work that already exists.
set -u
cd "$(dirname "$0")/.."
PY=bench/.venv/bin/python
log(){ echo "$(date +%H:%M:%S) $*" >> bench/results/orchestrate.log; }

log "finish.sh: preview judge (m01-m05)"
$PY -m bench.judge --ids m01 m02 m03 m04 m05 >> bench/results/judge.log 2>&1
$PY -m bench.score > /dev/null 2>&1 && log "PREVIEW SCORECARD READY"

log "finish.sh: full passes"
$PY -m bench.run_claude --reps 2 >> bench/results/sonnet-run-2.log 2>&1 &
SONNET=$!
bash bench/run-16gb.sh >> bench/results/local-16gb-run-2.log 2>&1 &
LOCAL=$!
$PY -m bench.run_local --model gemma-bigctx --reps 2 >> bench/results/gemma-run-2.log 2>&1
$PY -m bench.run_local --model qwen-coder --reps 2 --inflight 3 --restore >> bench/results/qwen-coder-run.log 2>&1
wait $SONNET $LOCAL
log "ALL RUNS DONE; judging all 30"
$PY -m bench.judge >> bench/results/judge.log 2>&1
$PY -m bench.score > /dev/null 2>&1 && log "FULL SCORECARD READY: bench/results/REPORT.md"
