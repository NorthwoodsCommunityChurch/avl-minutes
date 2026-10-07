#!/bin/bash
# Speaks MCP to the installed app over stdio and checks the tool list comes back.
set -euo pipefail
BIN="${1:-/Applications/Minutes.app/Contents/MacOS/Minutes}"
OUT=$( { printf '%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"smoke","version":"1"}}}' \
  '{"jsonrpc":"2.0","method":"notifications/initialized"}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' \
  '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"list_folders","arguments":{}}}'; sleep 2; } | "$BIN" --mcp )
for tool in search_notes list_notes get_note list_folders; do
  grep -q "\"$tool\"" <<<"$OUT" || { echo "FAIL: $tool missing"; echo "$OUT"; exit 1; }
done
grep -q '"id":3' <<<"$OUT" || { echo "FAIL: tools/call did not answer"; echo "$OUT"; exit 1; }
echo "MCP smoke test: PASS"
