#!/bin/bash
# Builds Minutes, installs it to /Applications, and relaunches it.
set -euo pipefail
cd "$(dirname "$0")/.."
bash scripts/fetch-deps.sh
xcodegen generate --quiet
xcodebuild -project Minutes.xcodeproj -scheme Minutes -configuration Debug \
  -derivedDataPath build/DerivedData -quiet build
# Quit the running menu bar app, but not `Minutes --mcp` servers owned by Claude Code.
pkill -f '/Minutes\.app/Contents/MacOS/Minutes$' || true
rm -rf /Applications/Minutes.app
ditto build/DerivedData/Build/Products/Debug/Minutes.app /Applications/Minutes.app
open /Applications/Minutes.app
echo "Minutes installed and launched."
