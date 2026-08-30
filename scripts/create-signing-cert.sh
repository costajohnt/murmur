#!/bin/bash
# Create a self-signed code-signing certificate in the login keychain.
# Run this ONCE; afterwards build.sh will find and use it automatically.
#
# Why: ad-hoc signing ("-") produces a different binary hash on every
# rebuild, so macOS invalidates your Accessibility and Microphone TCC
# grants each time. A stable self-signed cert fixes that.
set -euo pipefail

CERT_NAME="Murmur Dev Signing"

# Check if cert already exists
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$CERT_NAME"; then
  echo "Certificate '$CERT_NAME' already exists. Nothing to do."
  echo "Rebuild with:  scripts/build.sh"
  exit 0
fi

echo "Opening Keychain Access..."
echo
echo "In Keychain Access choose Keychain Access > Certificate Assistant > Create a Certificate..., then:"
echo "  Name:             $CERT_NAME"
echo "  Identity Type:    Self Signed Root"
echo "  Certificate Type: Code Signing"
echo "  Then click Create, then Done."
echo

# Open Keychain Access; Certificate Assistant is only reachable from its menu
open -b com.apple.keychainaccess

echo "After creating the certificate, verify with:"
echo "  security find-identity -v -p codesigning"
echo
echo "Then rebuild:  scripts/build.sh"
