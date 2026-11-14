#!/usr/bin/env bash
# Archive the app (with its App Clip) and upload it to App Store Connect.
# Signing is fully automatic (cloud-managed certificates) using an App Store Connect API key,
# so no certificates or profiles live in the repo or in secrets.
#
# Env: ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_P8 (contents of AuthKey_XXXX.p8)
#      BUILD_NUMBER, MARKETING_VERSION, ATTND_SERVER (host, e.g. attnd.app)
set -euo pipefail
cd "$(dirname "$0")/../.."
: "${ASC_KEY_ID:?}" "${ASC_ISSUER_ID:?}" "${ASC_KEY_P8:?}" "${BUILD_NUMBER:?}" "${MARKETING_VERSION:?}"

key_path="$RUNNER_TEMP/AuthKey_${ASC_KEY_ID}.p8"
printf '%s\n' "$ASC_KEY_P8" > "$key_path"
auth=(-allowProvisioningUpdates -authenticationKeyPath "$key_path"
      -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID")

echo "Archiving $MARKETING_VERSION ($BUILD_NUMBER) for server ${ATTND_SERVER:-attnd.app}"
xcodebuild archive -project Attnd.xcodeproj -scheme Attnd -configuration Release \
  -destination 'generic/platform=iOS' -archivePath build/Attnd.xcarchive "${auth[@]}" \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" MARKETING_VERSION="$MARKETING_VERSION" \
  ATTND_SERVER="${ATTND_SERVER:-attnd.app}" ATTND_API_KEY= COMPILER_INDEX_STORE_ENABLE=NO

cat > build/ExportOptions.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>app-store-connect</string>
  <key>destination</key><string>upload</string>
  <key>teamID</key><string>${APPLE_TEAM_ID:-GQQX4L6TE2}</string>
  <key>signingStyle</key><string>automatic</string>
  <key>uploadSymbols</key><true/>
  <key>manageAppVersionAndBuildNumber</key><false/>
  <key>testFlightInternalTestingOnly</key><${TESTFLIGHT_INTERNAL_ONLY:-false}/>
</dict></plist>
PLIST

# destination=upload sends the build straight to App Store Connect.
xcodebuild -exportArchive -archivePath build/Attnd.xcarchive -exportPath build/export \
  -exportOptionsPlist build/ExportOptions.plist "${auth[@]}"
rm -f "$key_path"
echo "Uploaded build $BUILD_NUMBER"
