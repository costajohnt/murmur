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
# System tools only: earlier CI steps can prepend shims via $GITHUB_PATH, and
# security/openssl/base64/codesign all see the key or its password.
export PATH=/usr/bin:/bin:/usr/sbin:/sbin

APP="${1:?usage: sign-release.sh path/to/Murmur.app}"
IDENTITY="Murmur Release Signing"
ENTITLEMENTS="$(cd "$(dirname "$0")/.." && pwd)/Sources/Murmur.entitlements"
: "${MURMUR_SIGNING_P12:?MURMUR_SIGNING_P12 (base64 .p12) is not set}"
: "${MURMUR_SIGNING_P12_PASSWORD:?MURMUR_SIGNING_P12_PASSWORD is not set}"

work="$(mktemp -d)"
keychain="$work/murmur-sign.keychain-db"
kc_pass="$(openssl rand -hex 16)"
# Remember the search list so the trap can put it back exactly.
old_list=()
while IFS= read -r kc; do
  kc="${kc#"${kc%%[![:space:]]*}"}"; kc="${kc#\"}"; old_list+=("${kc%\"}")
done < <(security list-keychains -d user)
cleanup() {
  security list-keychains -d user -s "${old_list[@]}" 2>/dev/null || true
  security delete-keychain "$keychain" 2>/dev/null || true
  rm -rf "$work"
}
trap cleanup EXIT

printf %s "$MURMUR_SIGNING_P12" | base64 -D > "$work/cert.p12"

# Throwaway keychain, so neither CI nor a dev Mac's login keychain keeps the key.
echo "==> Creating temporary keychain"
security create-keychain -p "$kc_pass" "$keychain"
security set-keychain-settings "$keychain"   # no auto-lock mid-sign
security unlock-keychain -p "$kc_pass" "$keychain"
# set-key-partition-list and codesign look keys up through the user search
# list; on the GitHub macOS runner neither finds a keychain outside it.
security list-keychains -d user -s "$keychain" "${old_list[@]}"
echo "==> Importing the signing cert"
security import "$work/cert.p12" -k "$keychain" \
  -P "$MURMUR_SIGNING_P12_PASSWORD" -T /usr/bin/codesign >/dev/null
echo "==> Allowing codesign to use the key"
# Lets codesign use the key without a GUI "allow access" prompt.
security set-key-partition-list -S apple-tool:,apple:,codesign: \
  -s -k "$kc_pass" "$keychain" >/dev/null

echo "==> Signing $APP"
# ponytail: no --deep, the bundle has no nested frameworks or helpers. Add it
# (or sign the nested code first) if Contents/Frameworks ever appears.
# Hardened runtime (--options runtime) keeps other processes from injecting
# code that would inherit the Microphone/Accessibility grants.
codesign --force --options runtime --entitlements "$ENTITLEMENTS" \
  --keychain "$keychain" --sign "$IDENTITY" "$APP"
codesign --verify --strict "$APP"

req="$(codesign -d -r- "$APP" 2>&1 | sed -n 's/^designated => //p')"
echo "designated => $req"
case "$req" in
  *"certificate leaf"*) ;;
  *) echo "error: $APP is not signed with $IDENTITY" >&2; exit 1 ;;
esac
details="$(codesign -dv "$APP" 2>&1)"
case "$details" in
  *"(runtime)"*) echo "hardened runtime: on" ;;
  *) echo "error: $APP is not signed with hardened runtime" >&2; exit 1 ;;
esac
