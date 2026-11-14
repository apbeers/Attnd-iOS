#!/usr/bin/env bash
# Capture raw App Store screenshots on simulators (macOS runner; see .github/workflows/store-screenshots.yml).
#
#   ATTND_API_KEY=… scripts/ci/screenshots.sh
#
# Builds the app ONCE for the simulator (Debug, static API key, dev server), then for each device:
# boot, light appearance, clean status bar (9:41, full bars, charged), install, and for each screen
# launch the app in screenshot mode (ScreenshotMode in Attnd/Helpers.swift: joins event DEMO through the
# normal lookup/join path and opens the screen), wait for its ready marker, capture.
# Output: build/screenshots/raw/<device>/<n>-<screen>.png (compose_screenshots.py frames them).
#
# Devices (newest iOS runtime; device types picked from `simctl list runtimes/devicetypes -j`):
#   iphone-69   newest "iPhone NN Pro Max"  (6.9", 1320x2868)
#   iphone-63   newest "iPhone NN Pro"      (6.3", 1206x2622)
#   iphone-duo  "iPhone Duo", captured twice:
#                 folded   -> raw/iphone-duo-cover/  (cover display, 1398x2034)
#                 unfolded -> raw/iphone-duo/        (inner display, 2007x2853)
#               The simulator boots folded on its cover display and simctl can't unfold it, so scripts/ci/duo_hinge.m (an
#               in-simulator helper using private SPI, see there) sets the hinge flat. The app's ready
#               marker reports its window size, which must be the inner display (>= 600 pt wide,
#               portrait) before anything is captured; a foldable needs `screenshot --display=<name>`
#               (the active display, from devicectl). An orientation probe (red over blue) is captured
#               too, so compose_screenshots.py can rotate the inner display's captures upright. If
#               unfolding fails, the Duo screenshots are skipped with a warning (DUO_REQUIRED=1: fail).
#               The folded set is checked the same way (window < 600 pt wide, portrait) and has its own
#               probe; if it fails only the folded set is skipped.
# Env: ATTND_API_KEY (required: static key for the dev server)
#      ATTND_SERVER (default attnd-dev-7ab893f37020.herokuapp.com; the static key only works there)
#      SCREENSHOT_DEVICES (default "iphone-69 iphone-63 iphone-duo")
#      SCREENSHOT_EVENT_CODE (default DEMO), SETTLE_SECONDS (default 5), DUO_REQUIRED (default 0)
set -euo pipefail
cd "$(dirname "$0")/../.."

: "${ATTND_API_KEY:?ATTND_API_KEY (static key for the dev server) is required}"
server="${ATTND_SERVER:-attnd-dev-7ab893f37020.herokuapp.com}"
devices="${SCREENSHOT_DEVICES:-iphone-69 iphone-63 iphone-duo}"
event_code="${SCREENSHOT_EVENT_CODE:-DEMO}"
settle="${SETTLE_SECONDS:-5}"
phone_screens=(map schedule location locations updates)
duo_screens=(map-pane location schedule updates)          # unfolded, inner display
duo_cover_screens=(map schedule location updates)           # folded, cover display

out=build/screenshots/raw
display=""     # the display to capture (set for the iPhone Duo only)
duo_dir=""     # iphone-duo (unfolded, portrait) or iphone-duo-wide (unfolded, landscape)
ready_size=""  # the app's window size from its last ready marker
rm -rf "$out"
mkdir -p "$out"

# --- Pick device types + runtime and find or create one simulator per target ---------------------
xcrun simctl list runtimes -j > build/simctl-runtimes.json
xcrun simctl list devicetypes -j > build/simctl-devicetypes.json
plan=$(python3 - "$devices" <<'PY'
import json, re, sys

wanted = sys.argv[1].split()
runtimes = json.load(open('build/simctl-runtimes.json'))['runtimes']
devicetypes = json.load(open('build/simctl-devicetypes.json'))['devicetypes']

def version(v):
    return tuple(int(x) for x in re.findall(r'\d+', v))

ios = sorted((r for r in runtimes if r.get('platform') == 'iOS' and r.get('isAvailable', True)),
             key=lambda r: version(r['version']), reverse=True)
if not ios:
    sys.exit('No available iOS simulator runtime')

patterns = {
    'iphone-69': re.compile(r'^iPhone (\d+) Pro Max$'),
    'iphone-63': re.compile(r'^iPhone (\d+) Pro$'),
    'iphone-duo': re.compile(r'^iPhone Duo\b'),
}

def candidates(runtime):
    supported = runtime.get('supportedDeviceTypes')
    return supported if supported else devicetypes

for key in wanted:
    pattern = patterns.get(key)
    if not pattern:
        sys.exit(f'Unknown screenshot device {key}')
    choice = None
    for runtime in ios:  # newest runtime that has a matching device type
        matches = [t for t in candidates(runtime) if pattern.match(t['name'])]
        if matches:
            # Highest model number (e.g. iPhone 18 Pro Max over 17 Pro Max); Duo: the first.
            best = max(matches, key=lambda t: version(t['name']) or (0,))
            choice = (runtime, best)
            break
    if not choice:
        names = sorted({t['name'] for t in devicetypes if t.get('productFamily') == 'iPhone'})
        print(f'::warning::No simulator device type for {key}; iPhone types: {", ".join(names)}', file=sys.stderr)
        continue
    runtime, dtype = choice
    print(f"{key}\t{runtime['identifier']}\t{dtype['identifier']}\t{dtype['name']}\t{runtime['version']}")
PY
)
[ -n "$plan" ] || { echo "::error::No screenshot devices available"; exit 1; }
echo "Screenshot devices:"; echo "$plan"

# "key udid" lines (macOS ships bash 3.2: no associative arrays).
udids=""
while IFS=$'\t' read -r key runtime dtype dname rversion; do
  name="Attnd Screenshots ${key}"
  udid=$(xcrun simctl list devices -j | python3 -c '
import json, sys
name, runtime, dtype = sys.argv[1:4]
for rt, devs in json.load(sys.stdin)["devices"].items():
    if rt != runtime:
        continue
    for d in devs:
        if d["name"] == name and d.get("deviceTypeIdentifier", dtype) == dtype and d.get("isAvailable", True):
            print(d["udid"]); sys.exit()
' "$name" "$runtime" "$dtype")
  if [ -z "$udid" ]; then
    udid=$(xcrun simctl create "$name" "$dtype" "$runtime" < /dev/null)
    echo "Created $name ($dname, iOS $rversion): $udid"
  else
    echo "Using $name ($dname, iOS $rversion): $udid"
  fi
  udids="$udids$key $udid"$'\n'
done <<< "$plan"
# Simulators are booted one at a time, after the build (prepare): booting them during the build starves
# the compiler of CPU (a 2-minute build took 13+ minutes with three simulators booting alongside it).

# --- Build once -------------------------------------------------------------------------------------
xcrun simctl shutdown all 2>/dev/null || true  # nothing else competing with the build
echo "Building for the simulator against $server"
build_started=$SECONDS
# A concrete simulator as the destination: the generic "Any iOS Simulator Device" placeholder makes
# xcodebuild log "missing operatingSystemVersion". The build runs on every screenshot simulator (same SDK).
build_udid=$(printf '%s' "$udids" | head -n 1 | cut -d' ' -f2)
xcodebuild build -project Attnd.xcodeproj -scheme Attnd -configuration Debug \
  -destination "id=$build_udid" -derivedDataPath build/ScreenshotsDerivedData \
  ARCHS="$(uname -m)" ONLY_ACTIVE_ARCH=NO CODE_SIGNING_ALLOWED=NO COMPILER_INDEX_STORE_ENABLE=NO \
  ATTND_API_KEY="$ATTND_API_KEY" ATTND_SERVER="$server" -quiet 2>&1 | tee build/xcodebuild-screenshots.log
python3 scripts/ci/warnings.py build/xcodebuild-screenshots.log "Screenshot build" || true
app=build/ScreenshotsDerivedData/Build/Products/Debug-iphonesimulator/Attnd.app
bundle_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Info.plist")
echo "Built $app ($bundle_id) in $((SECONDS - build_started)) s"

# --- Helpers ----------------------------------------------------------------------------------------
png_size() {  # "WIDTHxHEIGHT" of a PNG
  python3 -c 'import struct, sys; d = open(sys.argv[1], "rb").read(24); print("%dx%d" % struct.unpack(">II", d[16:24]))' "$1"
}

marker_path() {  # the app's ready marker (empty if the data container doesn't exist yet)
  local container
  container=$(xcrun simctl get_app_container "$1" "$bundle_id" data 2>/dev/null) || return 0
  echo "$container/Documents/attnd-screenshot-ready"
}

# Launches the app on one screen and waits for its ready marker; sets $ready_size (window, points).
launch_screen() {  # udid screen
  local udid=$1 screen=$2 marker status=""
  marker=$(marker_path "$udid")
  [ -n "$marker" ] && rm -f "$marker"
  xcrun simctl terminate "$udid" "$bundle_id" 2>/dev/null || true
  xcrun simctl launch "$udid" "$bundle_id" \
    -AttndScreenshotMode YES -AttndScreen "$screen" -AttndEventCode "$event_code" \
    -AttndSettleSeconds "$settle" > /dev/null
  for _ in $(seq 1 120); do
    [ -n "$marker" ] || marker=$(marker_path "$udid")
    if [ -n "$marker" ] && [ -f "$marker" ]; then
      status=$(cat "$marker")
      break
    fi
    sleep 1
  done
  case "$status" in
    "ready $screen "*) ready_size=${status##* } ;;
    "") echo "::error::$screen: the app never became ready (no marker after 120 s)"; return 1 ;;
    *)  echo "::error::$screen: $status"; return 1 ;;
  esac
}

# Captures the display that hosts the app ($display: empty for single-display iPhones).
snap() {  # udid file
  local args=()
  [ -n "$display" ] && args=(--display="$display")
  xcrun simctl io "$1" screenshot --type=png --mask=ignored ${args[@]+"${args[@]}"} "$2" > /dev/null
}

capture() {  # udid screen file
  launch_screen "$1" "$2" || return 1
  sleep 1
  snap "$1" "$3"
  echo "  $3  $(png_size "$3")  (window $ready_size pt)"
}

clean_status_bar() {  # udid
  xcrun simctl status_bar "$1" override --time 9:41 --dataNetwork wifi --wifiMode active \
    --wifiBars 3 --cellularMode active --cellularBars 4 --batteryState charged --batteryLevel 100
}

prepare() {  # udid
  local udid=$1 started=$SECONDS
  xcrun simctl boot "$udid" 2>/dev/null || true
  xcrun simctl bootstatus "$udid" -b > /dev/null
  echo "  booted in $((SECONDS - started)) s"
  xcrun simctl ui "$udid" appearance light
  clean_status_bar "$udid"
  xcrun simctl uninstall "$udid" "$bundle_id" 2>/dev/null || true
  xcrun simctl install "$udid" "$app"
}

finish() {  # udid
  xcrun simctl status_bar "$1" clear 2>/dev/null || true
  xcrun simctl shutdown "$1" 2>/dev/null || true
}

# The name of the display that hosts the UI ("LCD-1" = the Duo's inner display), from devicectl.
active_display() {  # udid
  xcrun devicectl device info displays -d "$1" -q -j - 2>/dev/null | python3 -c '
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

duo_hinge() {  # udid args…  (runs the helper inside the simulator)
  local udid=$1; shift
  xcrun simctl spawn "$udid" "$PWD/build/duo-hinge" "$@"
}

build_hinge() {  # → 0 when build/duo-hinge is ready
  [ -x build/duo-hinge ] && return 0
  if ! xcrun -sdk iphonesimulator clang -arch "$(uname -m)" -mios-simulator-version-min=17.0 -O2 -fobjc-arc \
      -o build/duo-hinge scripts/ci/duo_hinge.m -framework IOKit -framework CoreFoundation \
      -framework Foundation -framework CoreMotion \
      || ! codesign -f -s - build/duo-hinge; then
    echo "::warning::Could not build the iPhone Duo hinge helper"; rm -f build/duo-hinge; return 1
  fi
}

# Folds the Duo (it boots folded; closing again is harmless) and checks that the app's window is on
# the cover display in portrait. Captures the orientation probe for the cover set.
fold_duo() {  # udid → 0 when the cover display hosts the app in portrait
  local udid=$1 attempt width height
  for attempt in 1 2 3; do
    if [ -x build/duo-hinge ]; then
      duo_hinge "$udid" set 0 5 > /dev/null 2>&1 || true
      duo_hinge "$udid" orient portrait > /dev/null 2>&1 || true
      sleep 3
    fi
    display=$(active_display "$udid")
    [ -n "$display" ] || display=LCD
    clean_status_bar "$udid"
    launch_screen "$udid" orientation-probe || return 1
    width=${ready_size%x*}; height=${ready_size#*x}
    echo "iPhone Duo folded: display $display, app window $ready_size pt"
    if [ "$width" -lt 600 ] 2>/dev/null && [ "$height" -gt "$width" ]; then
      mkdir -p "$out/iphone-duo-cover"
      snap "$udid" "$out/iphone-duo-cover/orientation-probe.png"
      echo "  orientation probe: $(png_size "$out/iphone-duo-cover/orientation-probe.png")"
      return 0
    fi
    [ -x build/duo-hinge ] || break
  done
  echo "::warning::The iPhone Duo never showed the app on its folded cover display in portrait (last: ${ready_size:-?} pt)"
  return 1
}

# Unfolds the Duo flat in portrait and checks that the app's window is on the inner display.
unfold_duo() {  # udid → 0 when the inner display hosts the app in portrait
  local udid=$1 attempt width height
  build_hinge || return 1
  for attempt in 1 2 3; do
    duo_hinge "$udid" set 180 5 || { echo "::warning::Could not unfold the iPhone Duo simulator (attempt $attempt)"; continue; }
    duo_hinge "$udid" orient portrait || true
    sleep 3  # the display switch follows the angle after 1-2.5 s
    display=$(active_display "$udid")
    [ -n "$display" ] || display=LCD-1
    clean_status_bar "$udid"  # again, now that the inner display is active
    launch_screen "$udid" orientation-probe || return 1
    width=${ready_size%x*}; height=${ready_size#*x}
    echo "iPhone Duo after unfolding: display $display, app window $ready_size pt"
    if [ "$width" -ge 600 ] 2>/dev/null; then
      # Unfolded. Portrait is preferred; the simulator often keeps the inner display in landscape
      # whatever the orientation request, and App Store Connect takes that too (2853x2007).
      if [ "$height" -gt "$width" ]; then duo_dir=iphone-duo; else duo_dir=iphone-duo-wide; fi
      [ "$attempt" -lt 3 ] && [ "$duo_dir" = iphone-duo-wide ] && { duo_hinge "$udid" orient portrait > /dev/null 2>&1 || true; sleep 3; continue; }
      mkdir -p "$out/$duo_dir"
      snap "$udid" "$out/$duo_dir/orientation-probe.png"
      echo "  $duo_dir orientation probe: $(png_size "$out/$duo_dir/orientation-probe.png")"
      return 0
    fi
    # Folded (cover display, ~466x678 pt) or landscape: send the angle again.
    duo_hinge "$udid" set 0 5 > /dev/null 2>&1 || true
    sleep 2
  done
  echo "::warning::The iPhone Duo never showed the app on its unfolded inner display in portrait (last: ${ready_size:-?} pt)"
  return 1
}

# --- Capture ----------------------------------------------------------------------------------------
for key in $devices; do
  udid=$(printf '%s' "$udids" | awk -v k="$key" '$1 == k { print $2 }')
  [ -n "$udid" ] || continue
  echo "== $key ($udid)"
  prepare "$udid"
  display=""
  if [ "$key" = iphone-duo ]; then
    # Folded first (the simulator boots folded): the cover display set.
    build_hinge || true
    if fold_duo "$udid"; then
      n=1
      for screen in "${duo_cover_screens[@]}"; do
        capture "$udid" "$screen" "$out/iphone-duo-cover/$n-$screen.png"
        n=$((n + 1))
      done
    else
      rm -rf "${out:?}/iphone-duo-cover"
      if [ "${DUO_REQUIRED:-0}" = 1 ]; then exit 1; fi
      echo "::warning::Skipping folded iPhone Duo screenshots"
    fi
    # Then unfolded: the inner display set.
    display=""
    if ! unfold_duo "$udid"; then
      finish "$udid"
      rm -rf "${out:?}/iphone-duo" "${out:?}/iphone-duo-wide"
      if [ "${DUO_REQUIRED:-0}" = 1 ]; then exit 1; fi
      echo "::warning::Skipping iPhone Duo screenshots"
      continue
    fi
    screens=("${duo_screens[@]}")
    dest="$out/$duo_dir"
  else
    screens=("${phone_screens[@]}")
    dest="$out/$key"
  fi
  mkdir -p "$dest"
  n=1
  for screen in "${screens[@]}"; do
    capture "$udid" "$screen" "$dest/$n-$screen.png"
    n=$((n + 1))
  done
  xcrun simctl terminate "$udid" "$bundle_id" 2>/dev/null || true
  finish "$udid"
done

echo "Raw screenshots:"; find "$out" -name '*.png' | sort
[ -n "$(find "$out" -name '[0-9]*-*.png' -print -quit)" ] || { echo "::error::No screenshots captured"; exit 1; }
