#!/bin/bash
# Installs the hermes mesh bridge on this Mac (Aaron's laptop, where the mesh lives). The script is copied out of
# ~/Documents so launchd's python never needs the Documents-folder permission. Safe to rerun.
#   bash mesh-bridge/install-mesh-bridge.sh
set -euo pipefail
cd "$(dirname "$0")"
LABEL="com.northwoods.hermes-mesh-bridge"
DEST="$HOME/Library/Application Support/hermes-mesh-bridge"
mkdir -p "$DEST" "$HOME/Library/LaunchAgents" "$HOME/Library/Logs" "$HOME/.claude/mesh/inbox/hermes"
cp hermes-mesh-bridge.py "$DEST/"
chmod 755 "$DEST/hermes-mesh-bridge.py"
sed "s|__HOME__|$HOME|g" "$LABEL.plist" > "$HOME/Library/LaunchAgents/$LABEL.plist"
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/$LABEL.plist"
launchctl print "gui/$(id -u)/$LABEL" | grep -E "state =|last exit" || true
echo "hermes mesh bridge installed; log: ~/Library/Logs/hermes-mesh-bridge.log"
