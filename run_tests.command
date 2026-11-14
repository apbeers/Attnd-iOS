#!/bin/bash
cd "$(dirname "$0")"
LOG="$(dirname "$0")/test_results_ios.txt"
# The static dev key comes from Config/Secrets.xcconfig (gitignored, picked up by the
# build automatically). Exporting ATTND_API_KEY overrides it for this run.
KEY_ARGS=()
[ -n "$ATTND_API_KEY" ] && KEY_ARGS=(ATTND_API_KEY="$ATTND_API_KEY")
echo "Running iOS integration tests..." | tee "$LOG"
echo "======================================" | tee -a "$LOG"
xcodebuild test \
  -project Attnd.xcodeproj \
  -scheme Attnd \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  "${KEY_ARGS[@]}" \
  2>&1 | tee -a "$LOG"
echo "" | tee -a "$LOG"
echo "Done. Results saved to test_results_ios.txt" | tee -a "$LOG"
echo "Press any key to close."
read -n 1
