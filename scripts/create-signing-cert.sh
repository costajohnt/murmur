#!/bin/bash
# Create a self-signed code-signing certificate and import it into a keychain.
#
#   scripts/create-signing-cert.sh                  # "Murmur Dev Signing" into the login keychain
#   KEYCHAIN=/path/x.keychain-db scripts/create-signing-cert.sh
#   scripts/create-signing-cert.sh --p12 out.p12 "Murmur Release Signing"
#
# Why: ad-hoc signing ("-") produces a different binary hash on every
# rebuild, so macOS invalidates your Accessibility and Microphone TCC
# grants each time. A stable self-signed cert fixes that; build.sh signs
# with "Murmur Dev Signing" automatically once it exists.
#
# --p12 writes the identity to a password-protected .p12 instead of
# importing it (the password goes to <file>.pass). That is how the release
# cert was made; its base64 goes into the MURMUR_SIGNING_P12 secret.
# Replacing the release cert changes every user's signing identity, so they
# re-grant permissions once. Back the .p12 up instead of regenerating it.
set -euo pipefail

p12_out=""
if [[ "${1:-}" == "--p12" ]]; then
  p12_out="${2:?--p12 needs an output path}"
  shift 2
fi
CERT_NAME="${1:-Murmur Dev Signing}"
KEYCHAIN="${KEYCHAIN:-$HOME/Library/Keychains/login.keychain-db}"

if [[ -z "$p12_out" ]]; then
  existing="$(security find-identity -p codesigning "$KEYCHAIN" 2>/dev/null || true)"
  if [[ "$existing" == *"\"$CERT_NAME\""* ]]; then
    echo "Certificate '$CERT_NAME' already exists. Nothing to do."
    exit 0
  fi
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# /usr/bin/openssl (LibreSSL) writes a .p12 the macOS keychain can import;
# OpenSSL 3 would need -legacy.
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 7300 \
  -keyout "$work/key.pem" -out "$work/cert.pem" -subj "/CN=$CERT_NAME" \
  -addext "basicConstraints=critical,CA:false" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning" 2>/dev/null
pass="$(/usr/bin/openssl rand -hex 16)"
/usr/bin/openssl pkcs12 -export -name "$CERT_NAME" \
  -inkey "$work/key.pem" -in "$work/cert.pem" \
  -out "$work/cert.p12" -passout "pass:$pass"

if [[ -n "$p12_out" ]]; then
  ( umask 077; cp "$work/cert.p12" "$p12_out"; printf %s "$pass" > "$p12_out.pass" )
  echo "Wrote $p12_out and $p12_out.pass (keep both private)."
  echo "Leaf hash: $(/usr/bin/openssl x509 -in "$work/cert.pem" -noout -fingerprint -sha1 | cut -d= -f2 | tr -d :)"
  exit 0
fi

# -T lets codesign use the key; the first signing may still ask once
# ("Always Allow") on the login keychain.
security import "$work/cert.p12" -k "$KEYCHAIN" -P "$pass" -T /usr/bin/codesign >/dev/null
echo "Imported '$CERT_NAME' into $KEYCHAIN."
echo "Rebuild with:  scripts/build.sh"
