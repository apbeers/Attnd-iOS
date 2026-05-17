#!/bin/bash
# Archive the Attnd iOS app for distribution (App Store / TestFlight).
# After archiving, open Xcode Organizer to validate and upload.
# Usage: double-click, or: bash scripts/archive.command
set -o pipefail
cd "$(dirname "$0")/.."

ARCHIVE_PATH="build/Attnd.xcarchive"

echo "Archiving Attnd.xcodeproj (Release)..."
xcodebuild archive \
  -project Attnd.xcodeproj \
  -scheme Attnd \
  -configuration Release \
  -archivePath "$ARCHIVE_PATH" \
  2>&1 | xcpretty --color

STATUS=$?
if [ $STATUS -eq 0 ]; then
  echo "✅ Archive succeeded: $ARCHIVE_PATH"
  echo "Open Xcode Organizer (Window > Organizer) to distribute."
  open -a Xcode "$ARCHIVE_PATH"
else
  echo "❌ Archive failed."
fi
echo "Press any key to close."
read -n 1
