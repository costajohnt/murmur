#!/bin/bash
# Regenerate the Xcode project from project.yml and build Debug.
#
# By default the app is ad-hoc signed, so this works on a fresh clone with
# no Apple certificate. To sign with a real cert, set:
#   DEVELOPMENT_TEAM=XXXXXXXXXX [CODE_SIGN_IDENTITY="Apple Development"] scripts/build.sh
set -euo pipefail
cd "$(dirname "$0")/.."

xcodegen generate

APP="build/DerivedData/Build/Products/Debug/Murmur.app"
DEV_CERT="Murmur Dev Signing"

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

# Re-sign with the local self-signed cert so TCC grants survive rebuilds.
# codesign directly, not CODE_SIGN_IDENTITY: the cert is deliberately
# untrusted, and xcodebuild only accepts trusted identities.
# Create it once with:  scripts/create-signing-cert.sh
identities="$(security find-identity -p codesigning 2>/dev/null || true)"
if [[ -z "${DEVELOPMENT_TEAM:-}" && "$identities" == *"\"$DEV_CERT\""* ]]; then
  codesign --force --options runtime --entitlements Sources/Murmur.entitlements \
    --sign "$DEV_CERT" "$APP"
  echo "Signed with $DEV_CERT"
fi

echo
echo "Built app: $APP"
