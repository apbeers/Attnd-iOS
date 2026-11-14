#!/usr/bin/env bash
# Select the pinned Xcode (XCODE_VERSION, default 27.2 = build 27B52, the newest release as of Nov 2026).
# The iPhone Duo APIs need Xcode 27.1+ and the JSON project format (project.xcproj) needs 27.2+.
# Bump XCODE_VERSION (repo variable, or the default below) when a newer release is on the runner image.
set -euo pipefail
XCODE_VERSION="${XCODE_VERSION:-27.2}"
app="${XCODE_APP:-/Applications/Xcode_${XCODE_VERSION}.app}"

echo "Installed Xcodes:"; ls -d /Applications/Xcode*.app
if [[ ! -d "$app" ]]; then
  echo "::error::$app is not on this runner image. Pick one of the versions listed above (repo variable XCODE_VERSION) or a newer runner (MACOS_RUNNER)."
  exit 1
fi
sudo xcode-select -s "$app/Contents/Developer"
xcodebuild -version
xcrun --sdk iphoneos --show-sdk-version

# The runner image ships tvOS/watchOS simulator devices whose runtimes aren't installed. Every xcodebuild
# run then logs "DVTAssertions: Warning ... SimDevice native architecture is nil" for each of them; the
# devices can never boot, so delete them (only devices simctl itself reports as unavailable).
unavailable=$(xcrun simctl list devices unavailable | grep -c '(unavailable' || true)
if [ "$unavailable" -gt 0 ]; then
  xcrun simctl delete unavailable
  echo "Deleted $unavailable unavailable simulator device(s) (runtime not installed)"
fi
