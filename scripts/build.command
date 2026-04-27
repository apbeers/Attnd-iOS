#!/bin/bash
# Build the Attnd iOS app (no tests). Useful to verify compilation after edits.
cd "$(dirname "$0")/.."
echo "Building Attnd.xcodeproj..."
set -o pipefail
xcodebuild build \
  -project Attnd.xcodeproj \
  -scheme Attnd \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  2>&1 | xcpretty --color

STATUS=$?
[ $STATUS -eq 0 ] && echo "✅ Build succeeded." || echo "❌ Build failed."
echo "Press any key to close."
read -n 1
