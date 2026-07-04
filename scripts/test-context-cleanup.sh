#!/bin/bash
# Compile the real cleanup sources + the context-cleanup test harness and run
# it against live Ollama. See docs/context-cleanup.md "Verify".
set -euo pipefail
cd "$(dirname "$0")/.."

OUT=build/test-context-cleanup
mkdir -p build

swiftc -parse-as-library \
  -target arm64-apple-macos14.0 \
  Sources/WisprLocal/OllamaClient.swift \
  Sources/WisprLocal/AppSettings.swift \
  Sources/WisprLocal/CleanupContext.swift \
  Sources/WisprLocal/HistoryStore.swift \
  Sources/WisprLocal/Log.swift \
  scripts/test-context-cleanup.swift \
  -o "$OUT"

exec "$OUT"
