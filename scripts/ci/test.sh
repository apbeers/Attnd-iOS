#!/usr/bin/env bash
# Build once, then run the test suites on the newest available iPhone simulator.
#
#   scripts/ci/test.sh build                    build for testing (generic simulator; no device needed) while
#                                               the simulator boots in the background
#   scripts/ci/test.sh unit [label]             unit tests (APIClientIntegrationTests skipped)
#   scripts/ci/test.sh integration [label]      only the live API tests (AttndTests/APIClientIntegrationTests)
#   scripts/ci/test.sh                          build + unit (local use)
#
# unit / integration reuse the products of `build` (test-without-building, build/DerivedData) and the
# simulator it started (build/ci-device), so CI builds once for all three suites.
# Integration mode needs ATTND_IT_SERVER (host) and ATTND_IT_KEY (bearer key) in the environment.
# xcodebuild passes only TEST_RUNNER_-prefixed variables on to the test process (prefix stripped), so
# they are exported here as TEST_RUNNER_ATTND_IT_*; the tests read ATTND_IT_SERVER / ATTND_IT_KEY.
# ATTND_IT_RUN_ID (default GITHUB_RUN_ID) goes into the CI device ids.
# ATTND_SIM_OS_MAJOR (optional, e.g. 26): use the newest iPhone simulator of that iOS major (compat.yml).
# COMPILATION_CACHE_DIR (optional): Xcode's compilation cache (CAS) lives there, so CI can keep it
# between runs (actions/cache in ios.yml).
set -euo pipefail
cd "$(dirname "$0")/../.."

mode=${1:-all}
derived=build/DerivedData
device_file=build/ci-device
mkdir -p build

if [ "$mode" = all ]; then
  bash "$0" build
  exec bash "$0" unit
fi

case "$mode" in
  build)       label=${2:-Build for testing}; log=build/xcodebuild-build.log ;;
  unit)        label=${2:-Unit tests}; result=build/TestResults.xcresult; log=build/xcodebuild-test.log ;;
  integration) label=${2:-Integration tests}; slug=$(printf '%s' "$label" | tr -c 'A-Za-z0-9' '-')
               result=build/$slug.xcresult; log=build/xcodebuild-$slug.log ;;
  *) echo "usage: $0 [build|unit [label]|integration [label]]" >&2; exit 2 ;;
esac

common=(-project Attnd.xcodeproj -scheme Attnd -derivedDataPath "$derived")

if [ "$mode" = build ]; then
  device=$(xcrun simctl list devices available -j | python3 -c '
import json, re, sys
import os
data = json.load(sys.stdin)["devices"]
want = os.environ.get("ATTND_SIM_OS_MAJOR", "")
best = None
for runtime, devs in data.items():
    m = re.search(r"iOS-(\d+)-(\d+)", runtime)
    if not m:
        continue
    ver = (int(m.group(1)), int(m.group(2)))
    if want and str(ver[0]) != want:
        continue
    for d in devs:
        if d["name"].startswith("iPhone") and (best is None or ver > best[0]):
            best = (ver, d["udid"], d["name"])
print(best[1] if best else "")
')
  [ -n "$device" ] || { echo "No iPhone simulator available" >&2; exit 1; }
  echo "$device" > "$device_file"
  # Cold-booting a simulator on a fresh runner takes minutes and most of the CPU. Start it first: xcodebuild
  # waits for the boot before it plans the build, then compiles at full speed (~1 min). Booting after the
  # build was planned (Nov 2026 experiment) made the compile 6+ min and the whole job 5 min slower.
  xcrun simctl boot "$device" > /dev/null 2>&1 &
  # No index store (CI never uses it); only this Mac's architecture; no signing for the simulator.
  # ENABLE_DEBUG_DYLIB=NO: Debug's preview split leaves Attnd.app/Attnd a stub, so the App Intents metadata
  # step finds no AppIntents dependency and warns; CI has no previews, and the shipped Dev/Release builds don't split.
  settings=(CODE_SIGNING_ALLOWED=NO COMPILER_INDEX_STORE_ENABLE=NO ONLY_ACTIVE_ARCH=YES ARCHS="$(uname -m)" ENABLE_DEBUG_DYLIB=NO)
  if [ -n "${COMPILATION_CACHE_DIR:-}" ]; then
    settings+=(COMPILATION_CACHE_ENABLE_CACHING=YES COMPILATION_CACHE_CAS_PATH="$PWD/$COMPILATION_CACHE_DIR")
  fi
  status=0
  xcodebuild build-for-testing "${common[@]}" -destination 'generic/platform=iOS Simulator' "${settings[@]}" \
    2>&1 | tee "$log" || status=$?
  python3 scripts/ci/warnings.py "$log" "$label" || true
  exit "$status"
fi

[ -s "$device_file" ] || { echo "Run '$0 build' first" >&2; exit 1; }
device=$(cat "$device_file")

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
# Waits for the boot started by `build` (boots it if that didn't happen).
xcrun simctl bootstatus "$device" -b > /dev/null

args=("${common[@]}" -destination "id=$device" -parallel-testing-enabled NO -resultBundlePath "$result")
if [ "$mode" = integration ]; then
  args+=(-only-testing:AttndTests/APIClientIntegrationTests)
else
  args+=(-skip-testing:AttndTests/APIClientIntegrationTests)
fi
rm -rf "$result"
# The log is kept for the warnings summary (annotations only; it never changes the result).
status=0
xcodebuild test-without-building "${args[@]}" 2>&1 | tee "$log" || status=$?
python3 scripts/ci/warnings.py "$log" "$label" || true
if [ "$mode" = integration ]; then
  # Short pass/fail/skip summary (annotations + step summary). It also fails the run when every test
  # was skipped, which means the TEST_RUNNER_ variables never reached the test process.
  if ! python3 scripts/ci/test_summary.py "$log" "$label"; then
    [ "$status" -ne 0 ] || status=1
  fi
fi
exit "$status"
