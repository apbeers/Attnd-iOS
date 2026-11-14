#!/usr/bin/env bash
# Build and run the unit tests on the newest available iPhone simulator.
# Live API integration tests run only when ATTND_API_KEY is provided.
set -euo pipefail
cd "$(dirname "$0")/../.."

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
echo "Testing on simulator $device"
# Start booting now so the simulator is ready by the time the build finishes.
xcrun simctl boot "$device" 2>/dev/null || true

# No index store: CI never uses it and it costs build time.
args=(-project Attnd.xcodeproj -scheme Attnd -destination "id=$device" CODE_SIGNING_ALLOWED=NO COMPILER_INDEX_STORE_ENABLE=NO
      -resultBundlePath build/TestResults.xcresult)
if [ -n "${ATTND_API_KEY:-}" ]; then
  args+=(ATTND_API_KEY="$ATTND_API_KEY" ATTND_SERVER="${ATTND_SERVER:-attnd.app}")
else
  echo "ATTND_API_KEY not set — skipping live API integration tests"
  args+=(-skip-testing:AttndTests/APIClientIntegrationTests)
fi
rm -rf build/TestResults.xcresult
xcodebuild test "${args[@]}"
