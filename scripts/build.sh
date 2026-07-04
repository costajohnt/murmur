#!/bin/bash
# Regenerate the Xcode project from project.yml and build Debug.
set -euo pipefail
cd "$(dirname "$0")/.."

xcodegen generate

xcodebuild \
  -project WisprLocal.xcodeproj \
  -scheme WisprLocal \
  -configuration Debug \
  -derivedDataPath build/DerivedData \
  build

echo
echo "Built app: build/DerivedData/Build/Products/Debug/WisprLocal.app"
