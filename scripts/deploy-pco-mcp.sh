#!/bin/bash
# Copies the Planning Center MCP server (Weekend Rundown's pco-mcp, plus the song prep tools Hermes uses)
# to the assistant Mac, installs its Python deps into the venv there, and restarts Hermes's gateway so the
# new tools are picked up.   bash scripts/deploy-pco-mcp.sh [host]
set -euo pipefail
HOST="${1:-edit-3}"
SRC="$HOME/Documents/VS Code/Weekend Rundown/Weekend Rundown/pco-mcp"
MIRROR="$(cd "$(dirname "$0")/.." && pwd)/hermes-tools/pco-mcp"
cp "$SRC/server.py" "$SRC/song_prep.py" "$SRC/test_song_prep.py" "$SRC/requirements.txt" "$MIRROR/"
scp -q "$SRC/server.py" "$SRC/song_prep.py" "$SRC/requirements.txt" "$SRC/test_song_prep.py" "$HOST:pco-mcp/" 2>&1 | grep -v post-quantum || true
ssh "$HOST" 'export PATH=$HOME/.local/bin:/opt/homebrew/bin:$PATH; cd ~/pco-mcp && .venv/bin/pip install -q "mcp>=1.2,<2" -r requirements.txt </dev/null && .venv/bin/python server.py --selftest </dev/null 2>&1 | tail -n 2 && hermes gateway restart </dev/null 2>&1 | tail -n 1' 2>&1 | grep -v post-quantum
echo "pco-mcp deployed to $HOST."
