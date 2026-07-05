#!/bin/bash
# Launch the built Murmur.app (build it first with scripts/build.sh).
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/DerivedData/Build/Products/Debug/Murmur.app"
if [ ! -d "$APP" ]; then
  echo "error: $APP not found — run scripts/build.sh first" >&2
  exit 1
fi

open "$APP"
echo "Launched $APP (debug log: ~/Library/Application Support/Murmur/debug.log)"
