#!/bin/bash
# Regenerate the Xcode project from project.yml and build Debug.
#
# By default the app is ad-hoc signed, so this works on a fresh clone with
# no Apple certificate. To sign with a real cert, set:
#   DEVELOPMENT_TEAM=XXXXXXXXXX [CODE_SIGN_IDENTITY="Apple Development"] scripts/build.sh
set -euo pipefail
cd "$(dirname "$0")/.."

xcodegen generate

SIGN_ARGS=()
if [[ -n "${DEVELOPMENT_TEAM:-}" ]]; then
  SIGN_ARGS+=(
    DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM"
    CODE_SIGN_IDENTITY="${CODE_SIGN_IDENTITY:-Apple Development}"
  )
fi

xcodebuild \
  -project Murmur.xcodeproj \
  -scheme Murmur \
  -configuration Debug \
  -derivedDataPath build/DerivedData \
  build \
  "${SIGN_ARGS[@]+"${SIGN_ARGS[@]}"}"

echo
echo "Built app: build/DerivedData/Build/Products/Debug/Murmur.app"
