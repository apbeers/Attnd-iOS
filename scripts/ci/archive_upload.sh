#!/usr/bin/env bash
# Archive the app (with its App Clip and the AttndWidgets Live Activity extension) and upload it to App
# Store Connect. Signing is automatic using an App Store Connect API key: profiles are managed by Xcode
# (-allowProvisioningUpdates also registers new App IDs and capabilities, e.g. com.arcu.Attnd.widgets and
# Time Sensitive Notifications) and the upload is signed with a cloud-managed distribution certificate. The archive step needs an Apple Development
# certificate; one stored certificate (IOS_DEV_CERT_P12_BASE64 + IOS_DEV_CERT_PASSWORD secrets) is
# imported into a throwaway keychain so Xcode reuses it. Without it, every fresh runner would mint a new
# "Created via API" development certificate, and Apple's per-account limit fills up after a few dozen runs.
#
# Env: ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_P8 (contents of AuthKey_XXXX.p8)
#      IOS_DEV_CERT_P12_BASE64, IOS_DEV_CERT_PASSWORD (the stored Apple Development certificate)
#      BUILD_NUMBER, MARKETING_VERSION, ATTND_SERVER (host, e.g. attnd.app)
#      CONFIGURATION: Dev (develop → TestFlight: -Onone, DEBUG + DEV, readable crash logs, continuous
#      log upload) or Release (main, the default). Both are distribution-signed by the export: the
#      archive is signed for development (so it carries get-task-allow, as every archive does) and
#      -exportArchive re-signs it with the App Store distribution profile, whose entitlements have no
#      get-task-allow; the export is checked below before anything is uploaded.
#      The archive's dSYMs (build/Attnd.xcarchive/dSYMs) are uploaded to App Store Connect and kept
#      as a CI artifact by ios.yml.
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

# Both xcodebuild runs are logged for the warnings summary (annotations only; never fails the job).
mkdir -p build
log=build/xcodebuild-archive.log
: > "$log"
trap 'python3 scripts/ci/warnings.py "$log" "Archive & upload" || true; cleanup' EXIT

# COMPILATION_CACHE_DIR (optional): Xcode's compilation cache, kept between CI runs by ios.yml.
cache=()
if [ -n "${COMPILATION_CACHE_DIR:-}" ]; then
  cache=(COMPILATION_CACHE_ENABLE_CACHING=YES COMPILATION_CACHE_CAS_PATH="$PWD/$COMPILATION_CACHE_DIR")
fi

configuration=${CONFIGURATION:-Release}
case "$configuration" in Dev|Release) ;; *) echo "CONFIGURATION must be Dev or Release" >&2; exit 2 ;; esac
echo "Archiving $MARKETING_VERSION ($BUILD_NUMBER), $configuration, for server ${ATTND_SERVER:-attnd.app}"
xcodebuild archive -project Attnd.xcodeproj -scheme Attnd -configuration "$configuration" \
  -destination 'generic/platform=iOS' -archivePath build/Attnd.xcarchive "${auth[@]}" \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" MARKETING_VERSION="$MARKETING_VERSION" \
  ATTND_SERVER="${ATTND_SERVER:-attnd.app}" ATTND_API_KEY= COMPILER_INDEX_STORE_ENABLE=NO ${cache[@]+"${cache[@]}"} 2>&1 | tee -a "$log"

# dSYMs for every binary (app, App Clip, widgets), also with Dev's -Onone (DEBUG_INFORMATION_FORMAT =
# dwarf-with-dsym in both configurations).
ls build/Attnd.xcarchive/dSYMs/*.dSYM > /dev/null 2>&1 || echo "::warning::The archive has no dSYMs"

write_export_options() {
cat > build/ExportOptions.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>app-store-connect</string>
  <key>destination</key><string>$1</string>
  <key>teamID</key><string>${APPLE_TEAM_ID:-GQQX4L6TE2}</string>
  <key>signingStyle</key><string>automatic</string>
  <key>uploadSymbols</key><true/>
  <key>manageAppVersionAndBuildNumber</key><false/>
  <key>testFlightInternalTestingOnly</key><${TESTFLIGHT_INTERNAL_ONLY:-false}/>
</dict></plist>
PLIST
}

# 1. Export locally and check the distribution signature: App Store Connect rejects a build whose
#    binaries are signed with get-task-allow (a debuggable build). Dev is a Debug copy, so check every
#    executable bundle in the .ipa (app, App Clip, widgets).
write_export_options export
xcodebuild -exportArchive -archivePath build/Attnd.xcarchive -exportPath build/export-check \
  -exportOptionsPlist build/ExportOptions.plist "${auth[@]}" 2>&1 | tee -a "$log"
ipa=$(ls build/export-check/*.ipa | head -1)
rm -rf build/ipa-check && mkdir -p build/ipa-check && unzip -q "$ipa" -d build/ipa-check
bad=0
while IFS= read -r -d '' bundle; do
  codesign -d --entitlements - --xml "$bundle" > build/ipa-check/entitlements.plist 2>/dev/null || true
  allow=$(/usr/libexec/PlistBuddy -c 'Print :get-task-allow' build/ipa-check/entitlements.plist 2>/dev/null || echo absent)
  echo "${bundle#build/ipa-check/Payload/}: get-task-allow $allow"
  if [ "$allow" = true ]; then
    echo "::error::$bundle is signed with get-task-allow=true; TestFlight would reject it"
    bad=1
  fi
done < <(find build/ipa-check/Payload \( -name '*.app' -o -name '*.appex' \) -type d -print0)
[ "$bad" = 0 ] || exit 1
echo "Distribution signature OK (no get-task-allow) for $configuration"

# 2. destination=upload sends the build straight to App Store Connect.
write_export_options upload
xcodebuild -exportArchive -archivePath build/Attnd.xcarchive -exportPath build/export \
  -exportOptionsPlist build/ExportOptions.plist "${auth[@]}" 2>&1 | tee -a "$log"
echo "Uploaded build $BUILD_NUMBER ($configuration)"
