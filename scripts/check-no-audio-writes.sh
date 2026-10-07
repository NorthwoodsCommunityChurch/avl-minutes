#!/bin/bash
# Fails the build if any Swift source could write audio to disk.
# Minutes must never save audio; this is the static half of that promise.
set -euo pipefail
ROOT="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
PATTERN='AVAudioFile|AVAudioRecorder|ExtAudioFile|AudioFileCreate|AudioFileOpen|AVAssetWriter|\.(wav|caf|m4a|aiff|mp3|flac)\b'
DIRS=()
for d in "$ROOT/Minutes" "$ROOT/Shared" "$ROOT/HermesHelper" "$ROOT/Packages/MinutesKit/Sources"; do
  [ -d "$d" ] && DIRS+=("$d")
done
if [ ${#DIRS[@]} -eq 0 ]; then
  echo "check-no-audio-writes: no source folders under $ROOT" >&2
  exit 2
fi
if hits=$(grep -rnE --include='*.swift' "$PATTERN" "${DIRS[@]}"); then
  echo "error: Minutes must never save audio. Found an audio-writing API or audio file type:" >&2
  echo "$hits" >&2
  exit 1
fi
echo "check-no-audio-writes: clean"
