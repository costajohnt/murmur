#!/bin/bash
# Download the latest Murmur release and install it to /Applications.
#
#   curl -fsSL https://raw.githubusercontent.com/costajohnt/murmur/main/install.sh | bash
#
# Releases are ad-hoc signed, not notarized (no Apple Developer Program
# membership behind this project), so this script clears the quarantine flag
# that would otherwise make Gatekeeper refuse the first launch. Building from
# source avoids the download path entirely - see README.
set -euo pipefail

REPO="costajohnt/murmur"
INSTALL_DIR="${INSTALL_DIR:-/Applications}"

die() { echo "error: $*" >&2; exit 1; }

[ "$(uname -s)" = "Darwin" ] || die "Murmur is macOS only."
[ "$(uname -m)" = "arm64" ] || die "Murmur requires Apple Silicon (found $(uname -m))."

# macOS 14+. sw_vers reports e.g. "14.6.1"; compare the major version only.
major="$(sw_vers -productVersion | cut -d. -f1)"
[ "$major" -ge 14 ] || die "Murmur requires macOS 14 or later (found $(sw_vers -productVersion))."

# ~/Applications does not exist on a fresh account, so create the target
# before testing it. mkdir -p is a no-op on an existing /Applications.
mkdir -p "$INSTALL_DIR" 2>/dev/null || true
[ -d "$INSTALL_DIR" ] || die "$INSTALL_DIR does not exist and could not be created."
[ -w "$INSTALL_DIR" ] || die "$INSTALL_DIR is not writable. Re-run with INSTALL_DIR=\"\$HOME/Applications\"."

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# MURMUR_ZIP points at an already-downloaded zip and skips the network. Used by
# scripts/test-install.sh to exercise the install path against a local build.
if [ -n "${MURMUR_ZIP:-}" ]; then
  [ -f "$MURMUR_ZIP" ] || die "MURMUR_ZIP=$MURMUR_ZIP does not exist."
  tag="local"
  cp "$MURMUR_ZIP" "$tmp/Murmur.zip"
else
  echo "==> Looking up the latest Murmur release"
  # ponytail: sed instead of jq so this works on a stock Mac. The asset name is
  # the convention .github/workflows/release.yml writes - keep the two in sync.
  tag="$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" \
    | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -1)"
  [ -n "$tag" ] || die "No published release found for $REPO."

  echo "==> Downloading Murmur $tag"
  curl -fL --progress-bar \
    -o "$tmp/Murmur.zip" \
    "https://github.com/$REPO/releases/download/$tag/Murmur-$tag.zip" \
    || die "Could not download the Murmur-$tag.zip asset for $tag."
fi

# ditto, not unzip: unzip drops the symlinks and extended attributes inside an
# .app bundle, producing an app that will not launch.
ditto -x -k "$tmp/Murmur.zip" "$tmp/extracted"
[ -d "$tmp/extracted/Murmur.app" ] || die "Release zip did not contain Murmur.app."

# A running copy would keep the old bundle busy and leave the replacement
# half-applied. Only touch it when it is actually running: a bare
# `osascript quit app` would *launch* Murmur just to quit it, and can raise an
# Automation permission prompt that stalls a `curl | bash` session.
if pgrep -x Murmur >/dev/null 2>&1; then
  echo "==> Quitting the running Murmur"
  osascript -e 'quit app "Murmur"' >/dev/null 2>&1 || pkill -x Murmur || true
  for _ in 1 2 3 4 5; do
    pgrep -x Murmur >/dev/null 2>&1 || break
    sleep 1
  done
fi

echo "==> Installing to $INSTALL_DIR/Murmur.app"
rm -rf "${INSTALL_DIR:?}/Murmur.app"
ditto "$tmp/extracted/Murmur.app" "$INSTALL_DIR/Murmur.app"

# Unsigned download: without this, Gatekeeper reports the app as damaged.
xattr -dr com.apple.quarantine "$INSTALL_DIR/Murmur.app"

echo
echo "Murmur $tag installed to $INSTALL_DIR/Murmur.app"
echo "Open it, then grant Microphone and Accessibility permissions when asked."
