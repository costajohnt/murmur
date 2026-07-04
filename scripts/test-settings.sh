#!/bin/bash
# Compile the real settings-related sources + the settings test harness and
# run it against live Ollama. See docs/settings-panel.md "Wiring & guardrails".
set -euo pipefail
cd "$(dirname "$0")/.."

OUT=build/test-settings
mkdir -p build

swiftc -parse-as-library \
  -target arm64-apple-macos14.0 \
  Sources/WisprLocal/OllamaClient.swift \
  Sources/WisprLocal/AppSettings.swift \
  Sources/WisprLocal/Log.swift \
  scripts/test-settings.swift \
  -o "$OUT"

exec "$OUT"
