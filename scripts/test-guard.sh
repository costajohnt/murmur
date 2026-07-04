#!/bin/bash
# Compile the real TranscriptGuard + its test harness and run it.
set -euo pipefail
cd "$(dirname "$0")/.."

OUT=build/test-guard
mkdir -p build

swiftc -parse-as-library \
  -target arm64-apple-macos14.0 \
  Sources/WisprLocal/TranscriptGuard.swift \
  scripts/test-guard.swift \
  -o "$OUT"

exec "$OUT"
