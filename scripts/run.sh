#!/bin/bash
# Launch the built WisprLocal.app (build it first with scripts/build.sh).
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/DerivedData/Build/Products/Debug/WisprLocal.app"
if [ ! -d "$APP" ]; then
  echo "error: $APP not found — run scripts/build.sh first" >&2
  exit 1
fi

open "$APP"
echo "Launched $APP (menubar app — look for the waveform icon; logs: /tmp/wisprlocal.log)"
