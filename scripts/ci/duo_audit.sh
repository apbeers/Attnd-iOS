#!/usr/bin/env bash
# iPhone Duo layout audit (macOS runner; .github/workflows/duo-screenshots.yml, manual only).
#
#   ATTND_API_KEY=… scripts/ci/duo_audit.sh
#
# Not store screenshots: the app runs in its normal mode (Home, My schedule and the chat are the real
# ones), launched with `-AttndAudit <screen>` (AppState.launchForAudit, Debug builds only: joins DEMO
# through the normal path and opens the screen) and `-AttndDebugRegions YES` (the reserved-region
# overlay: the fold red, camera housings orange, floating controls' frames dashed blue).
#
# Poses, set with scripts/ci/duo_hinge.m (private SPI inside the simulator; simctl has no fold command,
# Xcode 27.1's Device Hub can fold it by hand):
#   folded           hinge 0,   portrait   (outer display)
#   unfolded         hinge 180, portrait   (inner display)
#   unfolded-wide    hinge 180, landscape  (inner display)
#   tabletop         hinge 90,  landscape  (inner display, the fold across the middle)
# Screens: home schedule map place chat (chat needs Apple Intelligence in the simulator: skipped with a
# note when the model isn't there). Every capture is checked for an all-black image (a display that is
# off captures black). Output: build/screenshots/duo-audit/<pose>/<n>-<screen>.png + report.txt.
# Env: ATTND_API_KEY (required), ATTND_SERVER (default dev.attnd.app), SETTLE_SECONDS (default 4)
set -euo pipefail
cd "$(dirname "$0")/../.."

: "${ATTND_API_KEY:?ATTND_API_KEY (static key for the dev server) is required}"
server="${ATTND_SERVER:-dev.attnd.app}"
screens=(home schedule map place chat)
poses=(folded unfolded unfolded-wide tabletop)
out=build/screenshots/duo-audit
report="$out/report.txt"
rm -rf "$out"
mkdir -p "$out"
: > "$report"

# --- The Duo simulator (newest runtime) -----------------------------------------------------------------
read -r runtime dtype < <(xcrun simctl list -j | python3 -c '
import json, re, sys
data = json.load(sys.stdin)
types = [t for t in data["devicetypes"] if re.match(r"^iPhone Duo\b", t["name"])]
runtimes = [r for r in data["runtimes"] if r.get("platform") == "iOS" and r.get("isAvailable")]
runtimes.sort(key=lambda r: [int(x) for x in re.findall(r"\d+", r["version"])], reverse=True)
for r in runtimes:
    supported = {t["identifier"] for t in r.get("supportedDeviceTypes", [])}
    for t in types:
        if not supported or t["identifier"] in supported:
            print(r["identifier"], t["identifier"]); sys.exit()
')
[ -n "${dtype:-}" ] || { echo "::error::No iPhone Duo simulator on this runner"; exit 1; }
udid=$(xcrun simctl create "Attnd Duo Audit" "$dtype" "$runtime" < /dev/null)
echo "Duo simulator $udid ($dtype, $runtime)"

# --- Build (Debug: LayoutAudit and the region overlay are Debug-only) ------------------------------------
xcodebuild build -project Attnd.xcodeproj -scheme Attnd -configuration Debug \
  -destination "id=$udid" -derivedDataPath build/DuoAuditDerivedData \
  ARCHS="$(uname -m)" ONLY_ACTIVE_ARCH=NO CODE_SIGNING_ALLOWED=NO COMPILER_INDEX_STORE_ENABLE=NO \
  ATTND_API_KEY="$ATTND_API_KEY" ATTND_SERVER="$server" -quiet 2>&1 | tee build/xcodebuild-duo-audit.log
app=build/DuoAuditDerivedData/Build/Products/Debug-iphonesimulator/Attnd.app
bundle_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Info.plist")

xcrun -sdk iphonesimulator clang -arch "$(uname -m)" -mios-simulator-version-min=17.0 -O2 -fobjc-arc \
  -o build/duo-hinge scripts/ci/duo_hinge.m -framework IOKit -framework CoreFoundation \
  -framework Foundation -framework CoreMotion
codesign -f -s - build/duo-hinge

xcrun simctl boot "$udid" 2>/dev/null || true
xcrun simctl bootstatus "$udid" -b > /dev/null
xcrun simctl ui "$udid" appearance light
xcrun simctl status_bar "$udid" override --time 9:41 --batteryState charged --batteryLevel 100 || true
xcrun simctl install "$udid" "$app"

hinge() { xcrun simctl spawn "$udid" "$PWD/build/duo-hinge" "$@" > /dev/null 2>&1 || true; }

active_display() {
  xcrun devicectl device info displays -d "$udid" -q -j - 2>/dev/null | python3 -c '
import json, sys
try:
    displays = json.load(sys.stdin)["result"]["displays"]
except Exception:
    sys.exit()
integrated = [d for d in displays if "integrated" in (d.get("type") or {})] or displays
active = [d for d in integrated if d.get("active")] or \
         [d for d in integrated if d.get("backlightState") not in (None, "off", "unknown")]
if active and active[0].get("name"):
    print(active[0]["name"])
' || true
}

# 0 when the PNG isn't (almost) all black: >= 1% of its decompressed bytes are non-zero.
not_black() {
  python3 - "$1" <<'PY'
import struct, sys, zlib
data = open(sys.argv[1], "rb").read()
pos, idat = 8, b""
while pos < len(data):
    length, kind = struct.unpack(">I4s", data[pos:pos + 8])
    if kind == b"IDAT":
        idat += data[pos + 8:pos + 8 + length]
    pos += 12 + length
raw = zlib.decompress(idat)
step = max(1, len(raw) // 400000)
sample = raw[::step]
nonzero = sum(1 for b in sample if b > 8)
sys.exit(0 if nonzero >= len(sample) * 0.01 else 1)
PY
}

marker() {
  local c
  c=$(xcrun simctl get_app_container "$udid" "$bundle_id" data 2>/dev/null) || return 0
  echo "$c/Documents/attnd-screenshot-ready"
}

pose() {  # name
  case "$1" in
    folded)        hinge set 0 5;   hinge orient portrait ;;
    unfolded)      hinge set 180 5; hinge orient portrait ;;
    unfolded-wide) hinge set 180 5; hinge orient landscape-left ;;
    tabletop)      hinge orient landscape-left; hinge set 90 5 ;;
  esac
  sleep 3
}

for p in "${poses[@]}"; do
  pose "$p"
  display=$(active_display)
  mkdir -p "$out/$p"
  n=1
  for screen in "${screens[@]}"; do
    m=$(marker); [ -n "$m" ] && rm -f "$m"
    xcrun simctl terminate "$udid" "$bundle_id" 2>/dev/null || true
    xcrun simctl launch "$udid" "$bundle_id" -AttndAudit "$screen" -AttndDebugRegions YES > /dev/null
    status=""
    for _ in $(seq 1 90); do
      [ -n "$m" ] || m=$(marker)
      if [ -n "$m" ] && [ -f "$m" ]; then status=$(cat "$m"); break; fi
      sleep 1
    done
    file="$out/$p/$n-$screen.png"
    case "$status" in
      "ready $screen "*)
        sleep "${SETTLE_SECONDS:-4}"
        args=(); [ -n "$display" ] && args=(--display="$display")
        xcrun simctl io "$udid" screenshot --type=png --mask=ignored ${args[@]+"${args[@]}"} "$file" > /dev/null
        if not_black "$file"; then
          echo "$p $screen ok (window ${status##* } pt, display ${display:-default})" | tee -a "$report"
        else
          echo "::warning::$p $screen: the capture is black (display ${display:-default} is off?)"
          echo "$p $screen BLACK (display ${display:-default})" >> "$report"
        fi ;;
      *)
        echo "$p $screen skipped: ${status:-no ready marker}" | tee -a "$report" ;;
    esac
    n=$((n + 1))
  done
done

xcrun simctl shutdown "$udid" 2>/dev/null || true
xcrun simctl delete "$udid" 2>/dev/null || true
echo "Report:"; cat "$report"
[ -n "$(find "$out" -name '*.png' -print -quit)" ] || { echo "::error::No Duo captures"; exit 1; }
