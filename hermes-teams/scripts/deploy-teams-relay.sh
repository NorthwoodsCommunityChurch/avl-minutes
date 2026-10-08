#!/bin/bash
# Copies the relay to the mini and (re)starts its launchd agent. Keeps the mini's config/ and data/.
#   bash hermes-teams/scripts/deploy-teams-relay.sh [host]      (default engineering-mac)
set -euo pipefail
cd "$(dirname "$0")/.."
HOST="${1:-engineering-mac}"
LABEL="com.northwoods.hermes-teams"
tar czf /tmp/hermes-teams.tgz --exclude=config/local.json --exclude=data --exclude=node_modules --exclude='teams-app/*.zip' .
scp -q /tmp/hermes-teams.tgz "$HOST:hermes-teams.tgz"
rm -f /tmp/hermes-teams.tgz
ssh "$HOST" "bash -s" <<REMOTE
set -euo pipefail
mkdir -p ~/hermes-teams ~/Library/LaunchAgents ~/Library/Logs
tar xzf ~/hermes-teams.tgz -C ~/hermes-teams
rm -f ~/hermes-teams.tgz
sed "s|__HOME__|\$HOME|g" ~/hermes-teams/launchd/$LABEL.plist > ~/Library/LaunchAgents/$LABEL.plist
launchctl bootout "gui/\$(id -u)/$LABEL" 2>/dev/null || true
for i in \$(seq 1 20); do launchctl print "gui/\$(id -u)/$LABEL" >/dev/null 2>&1 || break; sleep 0.5; done   # wait for the old one to unload
launchctl bootstrap "gui/\$(id -u)" ~/Library/LaunchAgents/$LABEL.plist
sleep 3
launchctl print "gui/\$(id -u)/$LABEL" | grep -E "state =|pid =" || true
curl -s -m 5 http://127.0.0.1:8787/health; echo
REMOTE
echo "hermes-teams deployed to $HOST."
