#!/usr/bin/env bash
# Use the newest Xcode installed on the runner (iPhone Duo APIs need the latest SDK).
# Override with XCODE_APP=/Applications/Xcode_27.1.app
set -euo pipefail
app="${XCODE_APP:-$(ls -d /Applications/Xcode*.app | grep -v -i beta | sort -V | tail -1)}"
sudo xcode-select -s "$app/Contents/Developer"
xcodebuild -version
