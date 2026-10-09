#!/bin/bash
# Copies hermes-tools/SOUL.md to the mini's ~/.hermes/SOUL.md (keeping a dated backup) and restarts the gateway so the
# running session picks it up. The restart drains the current turn first; deploy between turns (see the relay log).
#   bash scripts/deploy-soul.sh [host]      (default edit-3)
set -euo pipefail
cd "$(dirname "$0")/.."
HOST="${1:-edit-3}"
scp -q hermes-tools/SOUL.md "$HOST:SOUL.md.new"
ssh "$HOST" 'set -euo pipefail
export PATH=$HOME/.local/bin:$PATH
cp ~/.hermes/SOUL.md ~/.hermes/SOUL.md.bak-$(date +%Y%m%d-%H%M%S)
mv ~/SOUL.md.new ~/.hermes/SOUL.md
chmod 600 ~/.hermes/SOUL.md
hermes gateway restart
sleep 10
tail -n 3 ~/.hermes/logs/gateway.log'
echo "SOUL.md deployed to $HOST."
