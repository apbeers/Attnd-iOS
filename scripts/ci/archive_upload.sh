#!/usr/bin/env bash
# Archive the app (with its App Clip and the AttndWidgets Live Activity extension) and upload it to App
# Store Connect.
#
# MANUAL SIGNING (since Nov 19, 2026; used whenever IOS_DIST_CERT_P12_BASE64 is set): the archive and the
# export are signed with the stored Apple Distribution certificate and three App Store profiles
# (IOS_PROFILE_APP_B64, IOS_PROFILE_WIDGETS_B64, IOS_PROFILE_CLIP_B64; scripts/ci/signing_profiles.py checks
# and installs them). Needed because automatic signing with the API key fails ("Authentication failed")
# with some capabilities (it did on the App Group, since removed). Renewal: attnd-web SETUP.md (iOS signing). The API key is
# then only used for the upload.
#
# AUTOMATIC SIGNING (fallback without those secrets; the WeatherKit entitlement is removed for that build,
# so weather is off) using an App Store Connect API key: profiles are managed by Xcode
# (-allowProvisioningUpdates also registers new App IDs and capabilities, e.g. com.arcu.Attnd.widgets and
# Time Sensitive Notifications) and the upload is signed with a cloud-managed distribution certificate. The archive step needs an Apple Development
# certificate; one stored certificate (IOS_DEV_CERT_P12_BASE64 + IOS_DEV_CERT_PASSWORD secrets) is
# imported into a throwaway keychain so Xcode reuses it. Without it, every fresh runner would mint a new
# "Created via API" development certificate, and Apple's per-account limit fills up after a few dozen runs.
#
# Env: IOS_DIST_CERT_P12_BASE64, IOS_DIST_CERT_PASSWORD, IOS_PROFILE_{APP,WIDGETS,CLIP}_B64 (manual signing)
#      ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_P8 (contents of AuthKey_XXXX.p8)
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
  rm -f "$RUNNER_TEMP/dev-cert.p12" "$RUNNER_TEMP/dist-cert.p12" "${key_path:-}"
}
trap cleanup EXIT
manual=0
[ -n "${IOS_DIST_CERT_P12_BASE64:-}" ] && manual=1
if [ -n "${IOS_DEV_CERT_P12_BASE64:-}" ] || [ "$manual" = 1 ]; then
  keychain_password=$(uuidgen)
  security create-keychain -p "$keychain_password" "$keychain"
  security set-keychain-settings -lut 21600 "$keychain"
  security unlock-keychain -p "$keychain_password" "$keychain"
  if [ -n "${IOS_DEV_CERT_P12_BASE64:-}" ]; then
    printf '%s' "$IOS_DEV_CERT_P12_BASE64" | base64 --decode > "$RUNNER_TEMP/dev-cert.p12"
    security import "$RUNNER_TEMP/dev-cert.p12" -k "$keychain" -P "${IOS_DEV_CERT_PASSWORD:-}" \
      -T /usr/bin/codesign -T /usr/bin/security -T /usr/bin/productbuild
  fi
  if [ "$manual" = 1 ]; then
    printf '%s' "$IOS_DIST_CERT_P12_BASE64" | base64 --decode > "$RUNNER_TEMP/dist-cert.p12"
    security import "$RUNNER_TEMP/dist-cert.p12" -k "$keychain" -P "${IOS_DIST_CERT_PASSWORD:-}" \
      -T /usr/bin/codesign -T /usr/bin/security -T /usr/bin/productbuild
  fi
  security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$keychain_password" "$keychain" > /dev/null
  # Search our keychain first, then the existing ones.
  security list-keychains -d user -s "$keychain" $(security list-keychains -d user | tr -d '"')
  echo "Signing identities:"; security find-identity -v -p codesigning "$keychain"
else
  echo "::warning::IOS_DEV_CERT_P12_BASE64 is not set: Xcode will create a new development certificate on this runner (Apple's limit fills up after a few dozen runs)"
fi

key_path="$RUNNER_TEMP/AuthKey_${ASC_KEY_ID}.p8"
printf '%s\n' "$ASC_KEY_P8" > "$key_path"
auth=(-authenticationKeyPath "$key_path" -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID")
signing=()
mkdir -p build
if [ "$manual" = 1 ]; then
  echo "Manual signing: Apple Distribution + App Store profiles"
  python3 -I scripts/ci/signing_profiles.py build  # -I: scripts/ci/warnings.py would shadow the stdlib module
  signing=(-xcconfig build/Signing.xcconfig)
  # The checked-in entitlements say aps-environment=development (local Xcode runs); an App Store
  # profile only allows production, and the export would switch it anyway.
  /usr/libexec/PlistBuddy -c 'Set :aps-environment production' Attnd/Attnd.entitlements
else
  echo "::warning title=Signing::IOS_DIST_CERT_P12_BASE64 is not set: automatic signing, without the WeatherKit entitlement (no weather in this build)"
  for f in Attnd/Attnd.entitlements AttndWidgets/AttndWidgets.entitlements; do
    /usr/libexec/PlistBuddy -c 'Delete :com.apple.security.application-groups' "$f" 2>/dev/null || true
    /usr/libexec/PlistBuddy -c 'Delete :com.apple.developer.weatherkit' "$f" 2>/dev/null || true
  done
  auth=(-allowProvisioningUpdates "${auth[@]}")
fi

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
  -destination 'generic/platform=iOS' -archivePath build/Attnd.xcarchive "${auth[@]}" ${signing[@]+"${signing[@]}"} \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" MARKETING_VERSION="$MARKETING_VERSION" \
  ATTND_SERVER="${ATTND_SERVER:-attnd.app}" ATTND_API_KEY= COMPILER_INDEX_STORE_ENABLE=NO ${cache[@]+"${cache[@]}"} 2>&1 | tee -a "$log"

# dSYMs for every binary (app, App Clip, widgets), also with Dev's -Onone (DEBUG_INFORMATION_FORMAT =
# dwarf-with-dsym in both configurations).
ls build/Attnd.xcarchive/dSYMs/*.dSYM > /dev/null 2>&1 || echo "::warning::The archive has no dSYMs"

write_export_options() {
if [ "$manual" = 1 ]; then
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
  return
fi
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

# 1b. Size report (informational, never fails the build): what is in the .ipa and how big each part is,
#     plus Apple's App Thinning Size Report (per-device download/install sizes) from a thinned ad-hoc export.
python3 scripts/ci/size_report.py "$ipa" build/ipa-check/Payload "$configuration" || true
# Apple's per-device report needs an ad hoc (release-testing) export; with manual signing there is no ad hoc
# profile, so only the .ipa breakdown above is reported.
if [ "$manual" = 0 ]; then
cat > build/ThinningOptions.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>release-testing</string>
  <key>teamID</key><string>${APPLE_TEAM_ID:-GQQX4L6TE2}</string>
  <key>signingStyle</key><string>automatic</string>
  <key>thinning</key><string>&lt;thin-for-all-variants&gt;</string>
  <key>compileBitcode</key><false/>
</dict></plist>
PLIST
if xcodebuild -exportArchive -archivePath build/Attnd.xcarchive -exportPath build/export-thin \
     -exportOptionsPlist build/ThinningOptions.plist "${auth[@]}" > build/thinning.log 2>&1; then
  report="build/export-thin/App Thinning Size Report.txt"
  if [ -f "$report" ]; then
    echo "::group::App Thinning Size Report"; cat "$report"; echo "::endgroup::"
    { echo "### App Thinning Size Report ($configuration)"; echo '```'; head -c 60000 "$report"; echo '```'; } >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
  fi
else
  echo "::warning title=Size report::Thinned export failed (see build/thinning.log); the .ipa breakdown above still applies"
  tail -20 build/thinning.log
fi
fi

# 2. destination=upload sends the build straight to App Store Connect.
write_export_options upload
xcodebuild -exportArchive -archivePath build/Attnd.xcarchive -exportPath build/export \
  -exportOptionsPlist build/ExportOptions.plist "${auth[@]}" 2>&1 | tee -a "$log"
echo "Uploaded build $BUILD_NUMBER ($configuration)"
