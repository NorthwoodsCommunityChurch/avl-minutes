#!/bin/bash
# Downloads FluidAudio at the pinned release as a shallow clone. Xcode's own package
# fetch clones its full ~300 MB history, which stalls on slow connections.
set -euo pipefail
cd "$(dirname "$0")/.."
FLUIDAUDIO_VERSION="v0.17.5"
DEST="Vendor/FluidAudio"
if [ "$(cat "$DEST/.minutes-version" 2>/dev/null)" = "$FLUIDAUDIO_VERSION" ]; then
  exit 0
fi
rm -rf "$DEST"
mkdir -p Vendor
git -c advice.detachedHead=false clone --quiet --depth 1 --branch "$FLUIDAUDIO_VERSION" \
  https://github.com/FluidInference/FluidAudio.git "$DEST"
echo "$FLUIDAUDIO_VERSION" > "$DEST/.minutes-version"
echo "FluidAudio $FLUIDAUDIO_VERSION ready in $DEST"
