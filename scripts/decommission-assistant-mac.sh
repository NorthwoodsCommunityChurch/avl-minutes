#!/bin/bash
# Removes everything the assistant setup put on a Mac (Hermes Agent, Hermes Helper, Teams relay, Planning
# Center server, cloudflared, Homebrew packages, logs). Leaves MSP agents, iCloud/OneDrive (sign out by hand),
# and Homebrew itself unless --with-homebrew. Run only after the services live elsewhere (see
# setup-assistant-mac.sh) and Aaron has said go.
#   bash scripts/decommission-assistant-mac.sh <host> [--with-homebrew]
set -uo pipefail
HOST="${1:?host alias}"; shift || true
WITH_BREW=false; [ "${1:-}" = "--with-homebrew" ] && WITH_BREW=true
ssh "$HOST" "bash -s" </dev/null <<REMOTE 2>&1 | grep -v post-quantum
export LC_ALL=C PATH=/opt/homebrew/bin:\$HOME/.local/bin:\$PATH
U=\$(id -u)
echo "== agents"; for L in com.northwoods.hermes-teams com.northwoods.HermesHelper com.northwoods.cloudflared com.northwoods.llama-server ai.hermes.gateway; do launchctl bootout gui/\$U/\$L 2>/dev/null && echo "stopped \$L"; rm -f ~/Library/LaunchAgents/\$L.plist; done
pkill -f "HermesHelper|hermes-teams/server.js|cloudflared tunnel|hermes-agent" 2>/dev/null; sleep 2
echo "== files"; rm -rf /Applications/HermesHelper.app ~/hermes-teams ~/pco-mcp ~/.hermes ~/.local/bin/hermes ~/models ~/hermes-backup-*.zip ~/hermes-install.out ~/brew-install.out ~/hermes-desktop-build.out "\$HOME/Library/Application Support/Hermes Helper" "\$HOME/Library/Application Support/Hermes" ~/Library/Logs/HermesHelper.log ~/Library/Logs/hermes-teams.log ~/Library/Logs/cloudflared.log ~/Library/Logs/llama-server.log
sed -i "" '/\\.local\\/bin/d' ~/.zprofile ~/.zshrc 2>/dev/null; echo "files removed"
echo "== permissions"; tccutil reset AppleEvents com.northwoods.HermesHelper >/dev/null 2>&1 && echo "Notes grant reset" || true
echo "== homebrew packages"; brew uninstall --quiet --ignore-dependencies node cloudflared python@3.13 llama.cpp 2>/dev/null | tail -n 1; brew autoremove --quiet 2>/dev/null | tail -n 1
if $WITH_BREW; then echo "== homebrew itself"; NONINTERACTIVE=1 /bin/bash -c "\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/uninstall.sh)" </dev/null 2>&1 | tail -n 2; sudo rm -rf /opt/homebrew; fi
echo "== left"; launchctl list | grep -E "northwoods|hermes" || echo "no assistant agents"; ls /Applications | grep -i -E "hermes|minutes" || echo "no assistant apps"; brew list --formula 2>/dev/null | tr "\n" " "; echo; osascript -e 'tell application "System Events" to get name of every login item' 2>/dev/null
REMOTE
echo "Done. Still by hand on the Mac: sign out of iCloud and OneDrive, and remove the 'OneDrive Sync Service' login item if OneDrive is uninstalled."
