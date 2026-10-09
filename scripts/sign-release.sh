#!/bin/bash
# Re-sign a built Murmur.app with the project's self-signed release cert.
#
#   MURMUR_SIGNING_P12=<base64 .p12> MURMUR_SIGNING_P12_PASSWORD=<pw> \
#     scripts/sign-release.sh path/to/Murmur.app
#
# Why: an ad-hoc signature's designated requirement is the binary's cdhash,
# which changes every release, so macOS drops the Microphone and Accessibility
# grants on each upgrade. Signed with one long-lived cert, the requirement is
# `identifier "com.costajohnt.murmur" and certificate leaf = H"..."`, the same
# for every release, and the grants carry over.
#
# The cert is self-signed (no Apple Developer Program), so this does not
# satisfy Gatekeeper; install.sh and the Homebrew cask still clear quarantine.
# The cert is untrusted on purpose: codesign signs with it anyway, and trusting
# it would need an admin prompt for no gain.
set -euo pipefail

APP="${1:?usage: sign-release.sh path/to/Murmur.app}"
IDENTITY="Murmur Release Signing"
: "${MURMUR_SIGNING_P12:?MURMUR_SIGNING_P12 (base64 .p12) is not set}"
: "${MURMUR_SIGNING_P12_PASSWORD:?MURMUR_SIGNING_P12_PASSWORD is not set}"

work="$(mktemp -d)"
keychain="$work/murmur-sign.keychain-db"
kc_pass="$(openssl rand -hex 16)"
trap 'security delete-keychain "$keychain" 2>/dev/null || true; rm -rf "$work"' EXIT

printf %s "$MURMUR_SIGNING_P12" | base64 -D > "$work/cert.p12"

# Throwaway keychain, so neither CI nor a dev Mac's login keychain keeps the key.
security create-keychain -p "$kc_pass" "$keychain"
security set-keychain-settings "$keychain"   # no auto-lock mid-sign
security unlock-keychain -p "$kc_pass" "$keychain"
security import "$work/cert.p12" -k "$keychain" \
  -P "$MURMUR_SIGNING_P12_PASSWORD" -T /usr/bin/codesign >/dev/null
# Lets codesign use the key without a GUI "allow access" prompt.
security set-key-partition-list -S apple-tool:,apple:,codesign: \
  -s -k "$kc_pass" "$keychain" >/dev/null

# ponytail: no --deep, the bundle has no nested frameworks or helpers. Add it
# (or sign the nested code first) if Contents/Frameworks ever appears.
codesign --force --keychain "$keychain" --sign "$IDENTITY" "$APP"
codesign --verify --strict "$APP"

req="$(codesign -d -r- "$APP" 2>&1 | sed -n 's/^designated => //p')"
echo "designated => $req"
case "$req" in
  *"certificate leaf"*) ;;
  *) echo "error: $APP is not signed with $IDENTITY" >&2; exit 1 ;;
esac
