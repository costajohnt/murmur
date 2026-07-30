#!/bin/bash
# End-to-end check for install.sh: zip a locally built Release app exactly the
# way .github/workflows/release.yml does, run the installer against it into a
# throwaway directory, and assert the result is a launchable, unquarantined
# bundle. Requires a prior `xcodebuild -configuration Release` (see below).
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/DerivedData/Build/Products/Release/Murmur.app"
if [ ! -d "$APP" ]; then
  echo "No Release build at $APP" >&2
  echo "Run: xcodegen generate && xcodebuild -project Murmur.xcodeproj -scheme Murmur \\" >&2
  echo "       -configuration Release -derivedDataPath build/DerivedData build" >&2
  exit 1
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# Same packaging command as the release workflow's "Zip app bundle" step.
ditto -c -k --keepParent "$APP" "$work/Murmur-test.zip"

INSTALL_DIR="$work/Applications" MURMUR_ZIP="$work/Murmur-test.zip" \
  bash install.sh >"$work/install.log" 2>&1 \
  || { echo "FAIL: install.sh exited non-zero"; cat "$work/install.log"; exit 1; }

installed="$work/Applications/Murmur.app"

[ -d "$installed" ] || { echo "FAIL: $installed missing"; exit 1; }
[ -x "$installed/Contents/MacOS/Murmur" ] || { echo "FAIL: executable missing or not executable"; exit 1; }

# The whole point of the installer: a downloaded unsigned app must come out
# without the quarantine flag or Gatekeeper refuses to launch it.
if xattr -p com.apple.quarantine "$installed" >/dev/null 2>&1; then
  echo "FAIL: quarantine flag still set on $installed"; exit 1
fi

# ditto (not unzip) is used precisely so the bundle survives the round trip
# with its signature intact; verify that it did.
codesign --verify --deep "$installed" 2>"$work/codesign.log" \
  || { echo "FAIL: codesign --verify rejected the installed bundle"; cat "$work/codesign.log"; exit 1; }

# Re-running over an existing install must replace it cleanly, not half-apply.
INSTALL_DIR="$work/Applications" MURMUR_ZIP="$work/Murmur-test.zip" \
  bash install.sh >"$work/install2.log" 2>&1 \
  || { echo "FAIL: re-install over an existing copy failed"; cat "$work/install2.log"; exit 1; }
[ -x "$installed/Contents/MacOS/Murmur" ] || { echo "FAIL: re-install left a broken bundle"; exit 1; }

echo "PASS: install.sh produced a verified, unquarantined Murmur.app"
