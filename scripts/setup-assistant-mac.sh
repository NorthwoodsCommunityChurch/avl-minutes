#!/bin/bash
# Provisions a Mac as Aaron's assistant host (Hermes Agent + Hermes Helper + Teams relay + Planning Center
# MCP + Cloudflare tunnel), or moves it from one Mac to another. Idempotent: rerun after a failure.
#
#   bash scripts/setup-assistant-mac.sh <host> [--old-host <alias>]
#
# Before running: the host is in ~/.ssh/config with key auth + passwordless sudo (SSH-ACCESS.md), the same
# user name as before (mediaadmin), iCloud (Notes) and OneDrive signed in on it, auto-login on. Secrets come
# from OneDrive VS Code/Assistant/secrets/ (migration/: Hermes backup, relay config+state; planning-center.env).
# --old-host moves the Cloudflare tunnel connector off the previous Mac (the only shared piece); everything
# else on the old Mac is left for a separate, confirmed cleanup.
set -euo pipefail
cd "$(dirname "$0")/.."
HOST="${1:?host alias}"; shift || true
OLD_HOST=""
while [ $# -gt 0 ]; do case "$1" in --old-host) OLD_HOST="$2"; shift 2;; *) echo "unknown arg $1" >&2; exit 1;; esac; done
SECRETS="$HOME/Library/CloudStorage/OneDrive-NorthwoodsCommunityChurch/VS Code/Assistant/secrets"
MIG="$SECRETS/migration"
PCO_SRC="$HOME/Documents/VS Code/Weekend Rundown/Weekend Rundown/pco-mcp"
BACKUP=$(ls -t "$MIG"/hermes-backup-*.zip | head -1)
TUNNEL_ID="2a541b6e-adbc-46c6-9394-a27ba147caa4"
ACCOUNT_ID="3ee1816a7162c301a0e4b923872e828d"
log() { printf '\n== %s\n' "$*"; }
remote() { ssh "$HOST" "export LC_ALL=C PATH=/opt/homebrew/bin:\$HOME/.local/bin:\$PATH; $*" 2>&1 | grep -v post-quantum || true; }

log "1/9 power, time zone + Homebrew packages on $HOST"
remote 'sudo pmset -a sleep 0 disksleep 0 displaysleep 15 autorestart 1 womp 1 </dev/null; sudo systemsetup -settimezone America/Chicago -setusingnetworktime on </dev/null 2>/dev/null | grep -v "^$"; date "+%Z %H:%M"; which brew >/dev/null || { echo "Homebrew missing: install it on the Mac first (brew.sh)"; exit 1; }; brew install --quiet node cloudflared python@3.13 </dev/null 2>&1 | grep -E "🍺|Error" | tail -n 3; which node cloudflared'

log "2/9 Hermes Agent (official installer, no browser / screen tools)"
remote '[ -x ~/.local/bin/hermes ] && echo "hermes present: $(hermes --version 2>/dev/null | head -1)" || { curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash -s -- --non-interactive --skip-browser --skip-computer-use </dev/null 2>&1 | tail -n 3; }'

log "3/9 restore Hermes home from $(basename "$BACKUP") (config, .env, SOUL, memories, sessions)"
scp -q "$BACKUP" "$HOST:hermes-backup.zip" 2>&1 | grep -v post-quantum || true
remote 'hermes import --force ~/hermes-backup.zip </dev/null 2>&1 | tail -n 3; rm -f ~/hermes-backup.zip; sed -i "" "s|/Users/[a-z0-9_-]*/|$HOME/|g" ~/.hermes/config.yaml; grep -c "^  \(notes\|planka\|planning_center\):" ~/.hermes/config.yaml'

log "4/9 Planning Center MCP server (read-only; token from OneDrive)"
remote 'mkdir -p ~/pco-mcp && chmod 700 ~/pco-mcp'
scp -q "$PCO_SRC/server.py" "$SECRETS/planning-center.env" "$HOST:pco-mcp/" 2>&1 | grep -v post-quantum || true
remote 'cd ~/pco-mcp && mv -f planning-center.env .env && chmod 600 .env && [ -x .venv/bin/python ] || /opt/homebrew/opt/python@3.13/bin/python3.13 -m venv .venv </dev/null; cd ~/pco-mcp && .venv/bin/pip install -q "mcp>=1.2,<2" "httpx>=0.27" "python-dotenv>=1.0" </dev/null 2>&1 | tail -n 1; .venv/bin/python server.py --selftest </dev/null 2>&1 | head -n 3 | cut -c1-120'

log "5/9 Hermes tool switches + gateway service"
remote 'for p in cli api_server; do hermes tools disable --platform $p terminal browser computer_use file code_execution delegation image_gen tts clarify </dev/null 2>&1 | tail -n 1; done; hermes gateway install --start-on-login --start-now </dev/null 2>&1 | tail -n 2; hermes gateway restart </dev/null 2>&1 | tail -n 1; sleep 25; curl -s -m 5 http://127.0.0.1:8642/health; echo; hermes mcp list </dev/null 2>&1 | grep -E "planning|planka|notes"'

log "6/9 Hermes Helper (Notes + AI Feed index, MCP notes)"
bash scripts/deploy-helper.sh "$HOST" 2>&1 | grep -E "Hermes Helper|state =|deployed|FAILED|error:" | tail -n 4 || true

log "7/9 Teams relay (+ its config and state)"
bash hermes-teams/scripts/deploy-teams-relay.sh "$HOST" 2>&1 | grep -E "state =|ok|deployed|FAILED|error" | tail -n 3 || true
remote 'mkdir -p ~/hermes-teams/config ~/hermes-teams/data'
scp -q "$MIG/hermes-teams-local.json" "$HOST:hermes-teams/config/local.json" 2>&1 | grep -v post-quantum || true
scp -q "$MIG/hermes-teams-state.json" "$HOST:hermes-teams/data/state.json" 2>&1 | grep -v post-quantum || true
remote 'chmod 600 ~/hermes-teams/config/local.json ~/hermes-teams/data/state.json; cd ~/hermes-teams && node scripts/setup.js --stdin <<< "{}" | tail -n 2; sleep 2; curl -s -m 5 http://127.0.0.1:8787/health; echo'

log "8/9 Cloudflare tunnel connector (token fetched with wrangler's login, never printed)"
npx --yes wrangler@4 whoami >/dev/null 2>&1 || true   # refreshes the OAuth token on disk
OAUTH=$(grep -E '^oauth_token' "$HOME/Library/Preferences/.wrangler/config/default.toml" | sed -E 's/^oauth_token *= *"([^"]+)"/\1/')
TOKEN=$(curl -s -m 20 -H "Authorization: Bearer $OAUTH" "https://api.cloudflare.com/client/v4/accounts/$ACCOUNT_ID/cfd_tunnel/$TUNNEL_ID/token" | python3 -c "import json,sys; print(json.load(sys.stdin).get('result') or '')")
[ -n "$TOKEN" ] || { echo "could not fetch the tunnel token (run: npx wrangler@4 login)"; exit 1; }
if [ -n "$OLD_HOST" ]; then ssh "$OLD_HOST" 'launchctl bootout gui/$(id -u)/com.northwoods.cloudflared 2>/dev/null; rm -f ~/Library/LaunchAgents/com.northwoods.cloudflared.plist; echo "old connector stopped"' 2>&1 | grep -v post-quantum || true; fi
scp -q hermes-teams/scripts/install-cloudflared.sh "$HOST:install-cloudflared.sh" 2>&1 | grep -v post-quantum || true
ssh "$HOST" 'bash ~/install-cloudflared.sh && rm -f ~/install-cloudflared.sh' <<< "$TOKEN" 2>&1 | grep -v post-quantum | tail -n 2
sleep 15

log "9/9 checks"
echo "door: $(curl -s --max-time 20 https://hermes.northwoodstech.workers.dev/health)"
remote 'tail -n 2 ~/Library/Logs/HermesHelper.log; launchctl list | grep -E "northwoods|hermes" | awk "{print \$3, \$1}"'
echo
echo "Done. Aaron still: click Allow when macOS asks to let Hermes Helper control Notes; right-click OneDrive AI Feed → Always Keep on This Device."
