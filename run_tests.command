#!/bin/bash
cd "$(dirname "$0")"
LOG="$(dirname "$0")/test_results_ios.txt"
# The static dev key comes from Config/Secrets.xcconfig (gitignored, picked up by the
# build automatically). Exporting ATTND_API_KEY overrides it for this run.
KEY_ARGS=()
[ -n "$ATTND_API_KEY" ] && KEY_ARGS=(ATTND_API_KEY="$ATTND_API_KEY")
# Live API tests (APIClientIntegrationTests) run only when both are exported, e.g.
#   ATTND_IT_SERVER=dev.attnd.app ATTND_IT_KEY=<dev key> ./run_tests.command
# xcodebuild forwards only TEST_RUNNER_-prefixed variables to the tests; otherwise they are skipped.
export TEST_RUNNER_ATTND_IT_SERVER="$ATTND_IT_SERVER" TEST_RUNNER_ATTND_IT_KEY="$ATTND_IT_KEY"
echo "Running iOS tests..." | tee "$LOG"
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
