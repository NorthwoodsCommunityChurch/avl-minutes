#!/bin/bash
# Proves the guard catches a forbidden API and passes clean code.
set -euo pipefail
GUARD="$(cd "$(dirname "$0")" && pwd)/check-no-audio-writes.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/Minutes"
echo 'let x = 1' > "$TMP/Minutes/Good.swift"
"$GUARD" "$TMP" >/dev/null || { echo "FAIL: clean tree rejected"; exit 1; }
echo 'let f = try AVAudioFile(forWriting: url, settings: [:])' > "$TMP/Minutes/Bad.swift"
if "$GUARD" "$TMP" >/dev/null 2>&1; then echo "FAIL: AVAudioFile not caught"; exit 1; fi
echo 'let name = "take1.wav"' > "$TMP/Minutes/Bad.swift"
if "$GUARD" "$TMP" >/dev/null 2>&1; then echo "FAIL: .wav not caught"; exit 1; fi
echo "guard self-test: PASS"
