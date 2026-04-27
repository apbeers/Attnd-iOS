#!/bin/bash
cd "$(dirname "$0")"
LOG="$(dirname "$0")/test_results_ios.txt"
echo "Running iOS integration tests..." | tee "$LOG"
echo "======================================" | tee -a "$LOG"
xcodebuild test \
  -project Attnd.xcodeproj \
  -scheme Attnd \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  ATTND_API_KEY="$(grep ATTND_API_KEY Attnd/Info.plist -A1 | tail -1 | tr -d '\t <>/string')" \
  2>&1 | tee -a "$LOG"
echo "" | tee -a "$LOG"
echo "Done. Results saved to test_results_ios.txt" | tee -a "$LOG"
echo "Press any key to close."
read -n 1
