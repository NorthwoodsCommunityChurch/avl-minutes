#!/bin/bash
# Builds Hermes Helper (Release) and installs it on the assistant mini as a launchd user
# agent that keeps the Notes index current. Safe to rerun: it replaces the app and
# restarts the agent. Never rsync an .app (OneDrive extended attributes break signatures).
#   bash scripts/deploy-helper.sh              # to engineering-mac
#   bash scripts/deploy-helper.sh other-host   # any ~/.ssh/config alias
set -euo pipefail
cd "$(dirname "$0")/.."
HOST="${1:-engineering-mac}"
LABEL="com.northwoods.HermesHelper"
xcodegen generate --quiet
xcodebuild -project Minutes.xcodeproj -scheme HermesHelper -configuration Release \
  -derivedDataPath build/DerivedData -quiet build
APP="build/DerivedData/Build/Products/Release/HermesHelper.app"
rm -f build/HermesHelper.zip
ditto -c -k --keepParent "$APP" build/HermesHelper.zip
scp -q build/HermesHelper.zip "HermesHelper/launchd/$LABEL.plist" "$HOST:"
ssh "$HOST" "bash -s" <<REMOTE
set -euo pipefail
U=\$(id -u)
launchctl bootout "gui/\$U/$LABEL" 2>/dev/null || true
rm -rf /Applications/HermesHelper.app
ditto -x -k ~/HermesHelper.zip /Applications/
rm -f ~/HermesHelper.zip
mkdir -p ~/Library/LaunchAgents ~/Library/Logs
sed "s|__HOME__|\$HOME|g" ~/$LABEL.plist > ~/Library/LaunchAgents/$LABEL.plist
rm -f ~/$LABEL.plist
launchctl bootstrap "gui/\$U" ~/Library/LaunchAgents/$LABEL.plist
sleep 4
/Applications/HermesHelper.app/Contents/MacOS/HermesHelper --version
launchctl print "gui/\$U/$LABEL" | grep -E "state =|pid =" || true
echo "--- ~/Library/Logs/HermesHelper.log"
tail -n 5 ~/Library/Logs/HermesHelper.log
REMOTE
echo "Hermes Helper deployed to $HOST."
