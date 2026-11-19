#!/usr/bin/env bash
# Archive the app (with its App Clip and their Live Activity extensions, AttndWidgets and
# AttndClipWidgets) and upload it to App Store Connect.
#
# Manual signing only (since Nov 19, 2026): the archive and the export are signed with the stored Apple
# Distribution certificate and four App Store profiles (IOS_PROFILE_APP_B64, IOS_PROFILE_WIDGETS_B64,
# IOS_PROFILE_CLIP_B64, IOS_PROFILE_CLIP_WIDGETS_B64; scripts/ci/signing_profiles.py checks and installs
# them). Automatic signing with the API key had failed ("Authentication failed") on some capabilities, so
# it is no longer offered: without the distribution secrets this script fails. Renewal: attnd-web SETUP.md
# (iOS signing). The App Store Connect API key is only used for the upload.
#
# Env: IOS_DIST_CERT_P12_BASE64, IOS_DIST_CERT_PASSWORD, IOS_PROFILE_{APP,WIDGETS,CLIP,CLIP_WIDGETS}_B64
#      ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_P8 (contents of AuthKey_XXXX.p8)
#      BUILD_NUMBER, MARKETING_VERSION, ATTND_SERVER (host, e.g. attnd.app)
#      CONFIGURATION: Dev (develop → TestFlight: -Osize like Release, DEBUG + DEV, assertions on, continuous
#      log upload) or Release (main, the default). Both are signed with the App Store distribution profiles,
#      whose entitlements have no get-task-allow; the export is checked below before anything is uploaded.
#      The archive's dSYMs (build/Attnd.xcarchive/dSYMs) are uploaded to App Store Connect and kept
#      as a CI artifact by ios.yml.
set -euo pipefail
cd "$(dirname "$0")/../.."
: "${ASC_KEY_ID:?}" "${ASC_ISSUER_ID:?}" "${ASC_KEY_P8:?}" "${BUILD_NUMBER:?}" "${MARKETING_VERSION:?}"
if [ -z "${IOS_DIST_CERT_P12_BASE64:-}" ]; then
  echo "::error title=Signing::IOS_DIST_CERT_P12_BASE64 is not set: the archive needs the Apple Distribution certificate and the App Store profiles (attnd-web SETUP.md, iOS signing)"
  exit 1
fi

# --- The Apple Distribution certificate, in a temporary keychain ----------------------------------------
keychain="$RUNNER_TEMP/attnd-signing.keychain-db"
cleanup() {
  security delete-keychain "$keychain" 2>/dev/null || true
  rm -f "$RUNNER_TEMP/dist-cert.p12" "${key_path:-}"
}
trap cleanup EXIT
keychain_password=$(uuidgen)
security create-keychain -p "$keychain_password" "$keychain"
security set-keychain-settings -lut 21600 "$keychain"
security unlock-keychain -p "$keychain_password" "$keychain"
printf '%s' "$IOS_DIST_CERT_P12_BASE64" | base64 --decode > "$RUNNER_TEMP/dist-cert.p12"
security import "$RUNNER_TEMP/dist-cert.p12" -k "$keychain" -P "${IOS_DIST_CERT_PASSWORD:-}" \
  -T /usr/bin/codesign -T /usr/bin/security -T /usr/bin/productbuild
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$keychain_password" "$keychain" > /dev/null
# Search our keychain first, then the existing ones.
security list-keychains -d user -s "$keychain" $(security list-keychains -d user | tr -d '"')
echo "Signing identities:"; security find-identity -v -p codesigning "$keychain"

key_path="$RUNNER_TEMP/AuthKey_${ASC_KEY_ID}.p8"
printf '%s\n' "$ASC_KEY_P8" > "$key_path"
auth=(-authenticationKeyPath "$key_path" -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID")
mkdir -p build
echo "Manual signing: Apple Distribution + App Store profiles"
python3 -I scripts/ci/signing_profiles.py build  # -I: scripts/ci/warnings.py would shadow the stdlib module
signing=(-xcconfig build/Signing.xcconfig)
# The checked-in entitlements say aps-environment=development (local Xcode runs); an App Store
# profile only allows production, and the export would switch it anyway.
for f in Attnd/Attnd.entitlements AttndAppClip/AttndAppClip.entitlements; do
  /usr/libexec/PlistBuddy -c 'Set :aps-environment production' "$f"
done

# Both xcodebuild runs are logged for the warnings summary (annotations only; never fails the job).
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
  -destination 'generic/platform=iOS' -archivePath build/Attnd.xcarchive "${auth[@]}" "${signing[@]}" \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" MARKETING_VERSION="$MARKETING_VERSION" \
  ATTND_SERVER="${ATTND_SERVER:-attnd.app}" ATTND_API_KEY= COMPILER_INDEX_STORE_ENABLE=NO ${cache[@]+"${cache[@]}"} 2>&1 | tee -a "$log"

# dSYMs for every binary (app, App Clip, widgets) in both configurations (DEBUG_INFORMATION_FORMAT =
# dwarf-with-dsym for Dev and Release).
ls build/Attnd.xcarchive/dSYMs/*.dSYM > /dev/null 2>&1 || echo "::warning::The archive has no dSYMs"

write_export_options() {
  python3 - "$1" <<'PY'
import plistlib, sys, os
opts = {"method": "app-store-connect", "destination": sys.argv[1],
        "teamID": os.environ.get("APPLE_TEAM_ID", "GQQX4L6TE2"), "signingStyle": "manual",
        "signingCertificate": "Apple Distribution",
        "provisioningProfiles": plistlib.load(open("build/export-profiles.plist", "rb")),
        "uploadSymbols": True, "manageAppVersionAndBuildNumber": False,
        "testFlightInternalTestingOnly": os.environ.get("TESTFLIGHT_INTERNAL_ONLY", "false") == "true"}
plistlib.dump(opts, open("build/ExportOptions.plist", "wb"))
PY
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

# 1b. Size report (informational, never fails the build): what is in the .ipa and how big each part is.
#     Apple's App Thinning Size Report would need an ad hoc (release-testing) profile, which CI doesn't have.
python3 scripts/ci/size_report.py "$ipa" build/ipa-check/Payload "$configuration" || true

# 2. destination=upload sends the build straight to App Store Connect.
write_export_options upload
xcodebuild -exportArchive -archivePath build/Attnd.xcarchive -exportPath build/export \
  -exportOptionsPlist build/ExportOptions.plist "${auth[@]}" 2>&1 | tee -a "$log"
echo "Uploaded build $BUILD_NUMBER ($configuration)"
