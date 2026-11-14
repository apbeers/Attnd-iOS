#!/usr/bin/env bash
# Use the newest *released* Xcode on the runner. The iPhone Duo APIs need Xcode 27.1+ (iOS 27.1 SDK),
# and App Store Connect rejects builds from beta or release-candidate Xcodes.
# Override with XCODE_APP=/Applications/Xcode_27.2.app
set -euo pipefail
MIN_VERSION="27.1"

echo "Installed Xcodes:"; ls -d /Applications/Xcode*.app
if [[ -n "${XCODE_APP:-}" ]]; then
  app="$XCODE_APP"
else
  app="$(ls -d /Applications/Xcode_*.app | grep -viE 'beta|release_candidate|_rc' | sort -V | tail -1)"
fi
sudo xcode-select -s "$app/Contents/Developer"
xcodebuild -version

version="$(xcodebuild -version | awk '/^Xcode/ {print $2}')"
if [[ "$(printf '%s\n%s\n' "$MIN_VERSION" "$version" | sort -V | head -1)" != "$MIN_VERSION" ]]; then
  echo "::error::Xcode $version is older than $MIN_VERSION, which the iPhone Duo APIs need. Use a newer runner image (MACOS_RUNNER) or set XCODE_APP."
  exit 1
fi
xcrun --sdk iphoneos --show-sdk-version
