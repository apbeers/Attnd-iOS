#!/usr/bin/env bash
# Build and run tests on the newest available iPhone simulator.
#
#   scripts/ci/test.sh                          unit tests only (APIClientIntegrationTests skipped)
#   scripts/ci/test.sh integration [label]      only the live API tests (AttndTests/APIClientIntegrationTests)
#
# Integration mode needs ATTND_IT_SERVER (host) and ATTND_IT_KEY (bearer key) in the environment.
# xcodebuild passes only TEST_RUNNER_-prefixed variables on to the test process (prefix stripped), so
# they are exported here as TEST_RUNNER_ATTND_IT_*; the tests read ATTND_IT_SERVER / ATTND_IT_KEY.
# ATTND_IT_RUN_ID (default GITHUB_RUN_ID) goes into the CI device ids.
set -euo pipefail
cd "$(dirname "$0")/../.."

mode=${1:-unit}
case "$mode" in
  unit)        label=${2:-Build & unit tests}; result=build/TestResults.xcresult; log=build/xcodebuild-test.log ;;
  integration) label=${2:-Integration tests}; result=build/IntegrationResults.xcresult; log=build/xcodebuild-integration.log ;;
  *) echo "usage: $0 [unit|integration [label]]" >&2; exit 2 ;;
esac

if [ "$mode" = integration ]; then
  if [ -z "${ATTND_IT_SERVER:-}" ] || [ -z "${ATTND_IT_KEY:-}" ]; then
    echo "::error title=$label::ATTND_IT_SERVER / ATTND_IT_KEY not set (missing secret?)"
    [ -n "${GITHUB_STEP_SUMMARY:-}" ] && echo "### $label: not run — server or key not configured" >> "$GITHUB_STEP_SUMMARY"
    exit 1
  fi
  export TEST_RUNNER_ATTND_IT_SERVER="$ATTND_IT_SERVER"
  export TEST_RUNNER_ATTND_IT_KEY="$ATTND_IT_KEY"
  export TEST_RUNNER_ATTND_IT_RUN_ID="${ATTND_IT_RUN_ID:-${GITHUB_RUN_ID:-local}}"
  echo "Live API tests against $ATTND_IT_SERVER"
fi

device=$(xcrun simctl list devices available -j | python3 -c '
import json, re, sys
data = json.load(sys.stdin)["devices"]
best = None
for runtime, devs in data.items():
    m = re.search(r"iOS-(\d+)-(\d+)", runtime)
    if not m:
        continue
    ver = (int(m.group(1)), int(m.group(2)))
    for d in devs:
        if d["name"].startswith("iPhone") and (best is None or ver > best[0]):
            best = (ver, d["udid"], d["name"])
print(best[1] if best else "")
')
[ -n "$device" ] || { echo "No iPhone simulator available" >&2; exit 1; }
device_label=$(xcrun simctl list devices -j | python3 -c '
import json, sys
udid = sys.argv[1]
for runtime, devices in json.load(sys.stdin)["devices"].items():
    for d in devices:
        if d["udid"] == udid:
            version = runtime.rsplit(".", 1)[-1].replace("iOS-", "iOS ").replace("-", ".")
            print(d["name"] + ", " + version)
' "$device" 2>/dev/null || true)
echo "Testing on ${device_label:-simulator} ($device)"
# Cold-booting the simulator on a fresh runner takes 1.5-4 min. Start it in the background so it overlaps
# the ~1 min build (xcodebuild waits for it); it is shut down after the tests (trap below), so it never
# competes with the archive that follows in the same job.
xcrun simctl boot "$device" > /dev/null 2>&1 &

# No index store: CI never uses it and it costs build time.
args=(-project Attnd.xcodeproj -scheme Attnd -destination "id=$device" CODE_SIGNING_ALLOWED=NO COMPILER_INDEX_STORE_ENABLE=NO
      -resultBundlePath "$result")
if [ "$mode" = integration ]; then
  args+=(-only-testing:AttndTests/APIClientIntegrationTests)
else
  args+=(-skip-testing:AttndTests/APIClientIntegrationTests)
fi
rm -rf "$result"
mkdir -p build
# Shut the simulator down afterwards: left running, it slows the archive that follows in the same job.
trap 'xcrun simctl shutdown all 2>/dev/null || true' EXIT
# The log is kept for the warnings summary (annotations only; it never changes the result).
status=0
xcodebuild test "${args[@]}" 2>&1 | tee "$log" || status=$?
python3 scripts/ci/warnings.py "$log" "$label" || true
if [ "$mode" = integration ]; then
  # Short pass/fail/skip summary (annotations + step summary). It also fails the run when every test
  # was skipped, which means the TEST_RUNNER_ variables never reached the test process.
  if ! python3 scripts/ci/test_summary.py "$log" "$label"; then
    [ "$status" -ne 0 ] || status=1
  fi
fi
exit "$status"
