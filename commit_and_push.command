#!/bin/bash
cd "$(dirname "$0")"
rm -f .git/index.lock
git config user.email "apbeers@icloud.com"
git config user.name "Andrew"
git add -A
git commit -m "Add AttndTests integration tests + GitHub Actions iOS CI

Integration tests (AttndTests/APIClientIntegrationTests.swift):
- 25 tests hitting live attnd.app API using fixture data
- Event lookup by code and name for all 3 events
- Fetch by ID, 404 error cases
- Locations list (count=10 per event), single location detail
- Notifications: only sent=true returned (2 per event), correct titles
- Device join/leave round-trip with unique UUID
- Nearby events returns correct event near each citys coordinates
- APIList envelope count matches results

GitHub Actions (/.github/workflows/ios.yml):
- Triggers on push to main only
- Runs on macos-latest with xcodebuild test
- Uses Attnd shared scheme targeting AttndTests
- ATTND_API_KEY injected from GitHub secrets
- Uploads TestResults.xcresult as artifact (14-day retention)

Shared scheme (Attnd.xcodeproj/xcshareddata/xcschemes/Attnd.xcscheme):
- Required for xcodebuild to find test target in CI"
git push origin develop
echo ""
echo "Done! You can now open a PR from develop -> main to trigger the iOS CI pipeline."
echo "Press any key to close."
read -n 1
