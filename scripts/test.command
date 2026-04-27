#!/bin/bash
# Run iOS integration tests against the live API.
# Double-click to run, or: bash scripts/test.command
# Output saved to scripts/last_test_run.txt
cd "$(dirname "$0")/.."
LOG="scripts/last_test_run.txt"
API_KEY="$(grep -A1 ATTND_API_KEY Attnd/Info.plist | tail -1 | tr -d '\t <>/string')"

echo "Running iOS tests at $(date)" | tee "$LOG"
echo "======================================" | tee -a "$LOG"

set -o pipefail
xcodebuild test \
  -project Attnd.xcodeproj \
  -scheme Attnd \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  ATTND_API_KEY="$API_KEY" \
  -resultBundlePath scripts/TestResults.xcresult \
  2>&1 | tee -a "$LOG"

STATUS=$?
echo "" | tee -a "$LOG"
[ $STATUS -eq 0 ] && echo "✅ All tests passed." | tee -a "$LOG" \
                  || echo "❌ Tests failed. See log above." | tee -a "$LOG"
echo "Press any key to close."
read -n 1
