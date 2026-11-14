#!/usr/bin/env bash
# Archive the app (with its App Clip) and upload it to App Store Connect.
# Signing is automatic using an App Store Connect API key: profiles are managed by Xcode and the upload
# is signed with a cloud-managed distribution certificate. The archive step needs an Apple Development
# certificate; one stored certificate (IOS_DEV_CERT_P12_BASE64 + IOS_DEV_CERT_PASSWORD secrets) is
# imported into a throwaway keychain so Xcode reuses it. Without it, every fresh runner would mint a new
# "Created via API" development certificate, and Apple's per-account limit fills up after a few dozen runs.
#
# Env: ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_P8 (contents of AuthKey_XXXX.p8)
#      IOS_DEV_CERT_P12_BASE64, IOS_DEV_CERT_PASSWORD (the stored Apple Development certificate)
#      BUILD_NUMBER, MARKETING_VERSION, ATTND_SERVER (host, e.g. attnd.app)
set -euo pipefail
cd "$(dirname "$0")/../.."
: "${ASC_KEY_ID:?}" "${ASC_ISSUER_ID:?}" "${ASC_KEY_P8:?}" "${BUILD_NUMBER:?}" "${MARKETING_VERSION:?}"

# --- The stored Apple Development certificate, in a temporary keychain ---------------------------------
keychain="$RUNNER_TEMP/attnd-signing.keychain-db"
cleanup() {
  security delete-keychain "$keychain" 2>/dev/null || true
  rm -f "$RUNNER_TEMP/dev-cert.p12" "${key_path:-}"
}
trap cleanup EXIT
if [ -n "${IOS_DEV_CERT_P12_BASE64:-}" ]; then
  keychain_password=$(uuidgen)
  printf '%s' "$IOS_DEV_CERT_P12_BASE64" | base64 --decode > "$RUNNER_TEMP/dev-cert.p12"
  security create-keychain -p "$keychain_password" "$keychain"
  security set-keychain-settings -lut 21600 "$keychain"
  security unlock-keychain -p "$keychain_password" "$keychain"
  security import "$RUNNER_TEMP/dev-cert.p12" -k "$keychain" -P "${IOS_DEV_CERT_PASSWORD:-}" \
    -T /usr/bin/codesign -T /usr/bin/security -T /usr/bin/productbuild
  security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$keychain_password" "$keychain" > /dev/null
  # Search our keychain first, then the existing ones.
  security list-keychains -d user -s "$keychain" $(security list-keychains -d user | tr -d '"')
  echo "Signing identities:"; security find-identity -v -p codesigning "$keychain"
else
  echo "::warning::IOS_DEV_CERT_P12_BASE64 is not set: Xcode will create a new development certificate on this runner (Apple's limit fills up after a few dozen runs)"
fi

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
echo "Uploaded build $BUILD_NUMBER"
