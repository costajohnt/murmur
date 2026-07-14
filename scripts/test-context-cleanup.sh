#!/bin/bash
# Compile the real cleanup sources + the context-cleanup test harness and run
# it against live Ollama.
set -euo pipefail
cd "$(dirname "$0")/.."

OUT=build/test-context-cleanup
mkdir -p build

swiftc -parse-as-library \
  -target arm64-apple-macos14.0 \
  Sources/Murmur/OllamaClient.swift \
  Sources/Murmur/AppSettings.swift \
  Sources/Murmur/CleanupContext.swift \
  Sources/Murmur/HistoryStore.swift \
  Sources/Murmur/Log.swift \
  scripts/test-context-cleanup.swift \
  -o "$OUT"

exec "$OUT"
