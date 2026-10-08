#!/bin/bash
# Run ON the assistant mini. Installs the Cloudflare Tunnel connector for tunnel "engineering-mac" as a
# launchd agent for the signed-in user. The tunnel token arrives on stdin so it never lands in a shell
# history, a script argument, or a log:
#   ssh engineering-mac 'bash ~/hermes-teams/scripts/install-cloudflared.sh' <<< "$(npx wrangler@4 tunnel token <tunnel-id>)"
# Re-run with a new token to replace it. Remove: launchctl bootout gui/$(id -u)/com.northwoods.cloudflared
set -euo pipefail
LABEL="com.northwoods.cloudflared"
BIN="${CLOUDFLARED:-/opt/homebrew/bin/cloudflared}"
LOG="$HOME/Library/Logs/cloudflared.log"
# The church network drops outbound UDP 7844 (cloudflared's default QUIC transport); http2 rides TCP 7844.
PROTOCOL="${PROTOCOL:-http2}"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
[ -x "$BIN" ] || { echo "cloudflared not found at $BIN (brew install cloudflared)" >&2; exit 1; }
read -r TOKEN
[ -n "$TOKEN" ] || { echo "no token on stdin" >&2; exit 1; }
mkdir -p "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
umask 077
cat > "$PLIST" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array>
    <string>$BIN</string><string>tunnel</string><string>--no-autoupdate</string><string>--protocol</string><string>$PROTOCOL</string><string>run</string><string>--token</string><string>$TOKEN</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>10</integer>
  <key>StandardOutPath</key><string>$LOG</string>
  <key>StandardErrorPath</key><string>$LOG</string>
</dict></plist>
PL
chmod 600 "$PLIST"
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
sleep 5
echo "agent $LABEL loaded; last log lines:"
tail -n 4 "$LOG" 2>/dev/null | sed -E 's/[A-Za-z0-9+/=_-]{40,}/<redacted>/g' | cut -c1-160 || true
