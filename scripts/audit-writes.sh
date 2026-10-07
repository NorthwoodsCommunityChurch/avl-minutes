#!/bin/bash
# Proof that Minutes saves no audio. Usage:
#   scripts/audit-writes.sh start     # before the test meeting
#   (run a 3-minute meeting in Minutes, then Stop)
#   scripts/audit-writes.sh report    # lists every file changed since "start"
# Flags any audio-type file and anything with "Minutes" in its path.
set -euo pipefail
MARKER="${TMPDIR:-/tmp}/minutes-audit-marker"
case "${1:-}" in
  start)
    touch "$MARKER"
    echo "Marker set at $(date '+%H:%M:%S'). Run a meeting, then: $0 report"
    ;;
  report)
    [ -f "$MARKER" ] || { echo "Run '$0 start' first." >&2; exit 2; }
    CHANGED=$(find "$HOME" /private/var/folders /tmp -xdev -type f -newer "$MARKER" 2>/dev/null \
      | grep -v -E '/Library/(Caches|Logs|Metadata|Biome|Saved Application State|Containers/com\.apple\.|Group Containers/[A-Z0-9]+\.com\.apple\.|Safari|WebKit|Cookies|HTTPStorages|Application Support/(com\.apple|CallHistory|Knowledge|Google|Code|Claude|AddressBook|FileProvider|CloudDocs|Dock|Spotlight)|Daemon Containers)|/\.Trash/|/\.claude/|/node_modules/|/DerivedData/|/\.git/|/Documents/VS Code/' || true)
    AUDIO=$(grep -i -E '\.(wav|caf|m4a|aiff|aif|mp3|flac|aac|opus)$' <<<"$CHANGED" || true)
    MINUTES=$(grep -i 'minutes' <<<"$CHANGED" || true)
    echo "== Audio files changed since marker =="
    if [ -n "$AUDIO" ]; then echo "$AUDIO"; else echo "(none)"; fi
    echo
    echo "== Files with 'Minutes' in the path =="
    if [ -n "$MINUTES" ]; then echo "$MINUTES"; else echo "(none)"; fi
    echo
    echo "Expected from Minutes: Application Support/Minutes/notes-index.db (and -wal, -shm), voiceprint.json if you trained, and Preferences/com.northwoods.Minutes.plist."
    [ -z "$AUDIO" ] && echo "RESULT: no audio files were written." || { echo "RESULT: audio files found — investigate."; exit 1; }
    ;;
  *)
    echo "Usage: $0 start|report" >&2; exit 2 ;;
esac
