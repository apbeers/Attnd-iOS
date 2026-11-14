# Attnd iOS

SwiftUI app that lets attendees discover and follow live events. Consumes the Attnd REST API v2 served by **[attnd-web](https://github.com/apbeers/Attnd-Web)** (contract: [`API_V2.md`](https://github.com/apbeers/Attnd-Web/blob/develop/API_V2.md) in attnd-web).


## Branching (initial development)

- `main` = production (default branch), `develop` = dev/beta. Pushing to `develop` deploys to the dev server / TestFlight / Play internal testing; pushing to `main` deploys to production.
- **While there are no real users yet, commit and push straight to `develop`** — no feature branches or PRs needed. Merge `develop` → `main` to release. Revisit this once the apps have users.


## API changes start in attnd-web

attnd-web is the coordinating repo. The API contract ([`API_V2.md`](https://github.com/apbeers/Attnd-Web/blob/develop/API_V2.md)) and the cross-repo tracker ([`API_CHANGES.md`](https://github.com/apbeers/Attnd-Web/blob/develop/API_CHANGES.md)) live there only; this repo has no copy.
- Don't build against API behaviour that isn't in `API_V2.md`. If a feature needs an API change, add it in attnd-web first (tracker entry, server, contract), then implement the app part here.
- Implement what the tracker entry's app section says. Put its ID in the commit message (e.g. `API-003: …`), then tick this app's column in attnd-web's `API_CHANGES.md`.
- Keep decoding lenient: ignore unknown keys and default missing ones, so additive server changes never break shipped builds.

## Dependency Policy

**Apple frameworks only; no third-party packages.** No SPM, CocoaPods or Carthage dependencies, no Firebase. Push uses APNs directly via `UIApplication` / `UserNotifications`.

## Tech Stack

- **Swift 6 / SwiftUI** — iOS 26+, Swift 6 language mode, `@Observable` + `@MainActor` state
- **URLSession** — networking
- **Apple App Attest** — device attestation for API authentication in production
- **APNs** (`UserNotifications`) — organizer notifications and silent `content_updated` pushes
- **DataScannerViewController** (VisionKit) — QR code scanning
- **MapKit** — map view
- **Xcode project**: `Attnd.xcodeproj` in Xcode 27.2's JSON format (`project.xcproj`, converted on Nov 14, 2026 with `xcodebuild -convert-project "Xcode Project"` on Xcode 27.2; JSON with trailing commas — edit carefully or in Xcode; `-convert-project pbxproj` converts back). **Xcode 27.2** (build 27B52) is required: the JSON project format needs 27.2 and the iPhone Duo APIs need 27.1. CI pins it with `XCODE_VERSION` (repo variable, default `27.2`) on the `xcode-27` runner; bump it when a newer release lands on the image. Xcode Cloud is not used (it would number builds independently and collide with CI's).
- **Targets**: `Attnd` (iPhone only, including iPhone Duo; all orientations; no iPad), `AttndAppClip`, `AttndTests`

## Source Structure (`Attnd/`)

| File | Purpose |
|------|---------|
| `AttndApp.swift` | App entry point; installs `AppDelegate`, wires Universal Links |
| `AppDelegate.swift` | Owns `AppState`; APNs token registration, silent pushes, notification taps |
| `AppState.swift` | `@MainActor @Observable` state: event, bundle content, display config, selected tab, device ID, push token, preferences; bundle refresh with ETag; `track(_:detail:)` and `UsageReporter` (API-005) |
| `APIClient.swift` | Stateless, `Sendable` v2 client; async/await; 401 → re-attest → retry once |
| `Models.swift` | v2 models (`Event`, `Location`, `ScheduleItem`, `AppNotification`, `DisplayConfig`, `EventBundle`, request bodies, `PushPayload`) with lenient decoding; usage types (`UsageMetric`, `UsageEntry`, `UsageRequest`, pure `UsageAggregator`) |
| `DisplayLogic.swift` | Pure, unit-tested logic: schedule grouping (timeline/by day/by location/now-next), location grouping, search, map clustering & framing, fold-avoiding insets |
| `Helpers.swift` | ISO 8601 parsing, event-time-zone formatting, hex colours, deep-link/QR parsing, `SupportInfo` (support code, copyable support text, device model), `ScreenshotMode` (App Store screenshots, see Store listing) |
| `AttestationManager.swift` | Apple App Attest key generation, attestation, and JWT token caching |
| `KeychainHelper.swift` | Keychain read/write wrapper |
| `LocationPermissionManager.swift` | One-shot async location request |
| `ContentView.swift` | `AppRootView` (launch vs. event) and the server-driven `TabView`; refresh triggers (incl. 5 s live poll); floating demo / ended badge; accent tint |
| `LaunchScreen.swift` | Nearby events, system search for a code/exact name, QR scanner |
| `MapArrangement.swift` | Map tab: map + secondary pane via `ArrangementView` on regular width |
| `MapView.swift` | Map with clustering, fit-all, category chips, fold-aware overlays |
| `FoldableLayout.swift` | Wrappers for foldable-era APIs (`reservedRegions`, pinned toolbar placement) |
| `LocationsView.swift` | Locations tab (`NavigationSplitView`), cards/list/grouped styles, detail view |
| `ScheduleView.swift` | Schedule tab (`NavigationSplitView`), styles, filter menu, item detail |
| `NotificationsView.swift` | Organizer updates from the bundle |
| `FlyerView.swift` | Event flyer (image/PDF) from `flyer_url` |
| `QRScannerView.swift` | `DataScannerViewController` sheet; pauses/restarts across scene and size changes |
| `SettingsView.swift` | Options tab: internal-test-build warning, event header (logo), location dot, notifications, About & support, leave event |

## App Flow

```
Launch
├── POST devices/ (registration, push token, subscribed)
├── Saved event code? → GET events/lookup/?q=<code> → join silently
│   └── On failure / none saved → LaunchScreen
│
LaunchScreen
├── GET events/nearby/?lat=&lng=
├── QR scan / search → GET events/lookup/?q=<code or exact name>
│
Join event
├── POST events/<id>/join/ {device_id, platform: "ios", push_token, app_version}
└── GET events/<id>/bundle/ (If-None-Match, X-Device-Id)
│
ContentView (tabs and default tab from bundle.display; Options always last)
├── Map / Locations / Schedule / Flyer / Updates
├── Bundle refetched on: foreground, pull-to-refresh, every 5 s while the scene is
│   active (silent live updates; also how the App Clip stays live), every 5 min on
│   event days, content_updated / notification pushes (304 when unchanged)
└── POST events/<id>/usage/ (anonymous counts): every ~60 s with pending data, on background
│
Leave event
├── Pending usage counts flushed first
└── POST events/<id>/leave/ {device_id}
```

## Usage reporting (API-005)

- Anonymous counts only: `POST events/<id>/usage/` with `{"platform": "ios", "events": [{name, detail?, count, at}]}`. **Never** a device ID, any identifier, or search text.
- Call sites use `appState.track(.metric, detail:)` / `track(.metric, id:)`; it is a no-op outside an event. `UsageReporter` (main actor, in `AppState.swift`) aggregates in a pure `UsageAggregator` (`Models.swift`) keyed by (event, name, detail, UTC 5-minute bucket; `at` = start of the bucket, e.g. `2026-11-14T16:05:00Z`) and flushes at most every 60 s, when the scene goes to the background (`AppRootView`) and before leaving or switching events. A failed batch is retried once on the next flush, then dropped; errors are never shown. Max 200 entries per request.
- Instrumented: `app_open` (silent rejoin at launch; scene becomes active in `ContentView`), `tab_view` (`selectedTab` didSet; the opening tab when the first bundle is applied), `location_view` / `schedule_item_view` (`.task(id:)` on `LocationDetailView` / `ScheduleItemDetailView`, so every route counts), `notification_open` (`handlePush(opened: true)`), `search` (`SearchableIf`: on submit, or once a non-empty query settles for 1.5 s), `refresh` (`AppState.pullToRefresh()` from every `.refreshable` in an event).

## Support info (API-004)

- Options shows an orange **Internal test build** warning when `APIClient.serverHost != "attnd.app"`.
- **About & support** (`SupportInfo` in `Helpers.swift`): support code (first 8 characters of the device ID, no dashes, upper case; selectable), app version and build, App Clip, server, API version, iOS version, device model (`utsname` machine, e.g. `iPhone17,2`), current event (name, code, id, content version) and last refresh. **Copy Support Info** puts all of that plus the full device ID on the pasteboard.

## API v2 Notes

- Base URL `https://attnd.app/api/v2/`. Attestation endpoints remain at `/api/v1/attest/`.
- Models must ignore unknown keys and default missing ones (see attnd-web `API_V2.md` → Display defaults). Decoding helpers in `Models.swift` (`lenient`, `lossyArray`) enforce this; add new fields the same way.
- Coordinates may be `null`; `0,0` is treated as unknown. Never drop a pin without a valid coordinate.
- Schedule items may have no location — shown under "General".
- All times are displayed in the **event's** `timezone` (`EventTimeFormat`), never the device's.
- `is_demo` / `status == "archived"` → a small floating capsule badge ("Demo event" / "Event ended") at the top of each tab's content (`eventStatusBanners()` in `ContentView.swift`): an overlay, so content scrolls under it; touches pass through; kept clear of reserved regions. Map chips move down by `EventStatusBadgeKind.reservedHeight`.
- `display.accent_color` (or the event's) tints the app. Otherwise the tint is the asset `AccentColor` (brand purple `#431F86`, `#9D7BEA` in dark mode; same in the App Clip's asset catalog), never system blue.
- Live updates: `ContentView` calls `refreshBundle(silent: true)` every 5 s while the scene is active (no `isLoading` spinners; a failed poll retries next tick). Lives in shared code so the App Clip gets it too.

## Display Config (`bundle.display`)

| Key | Where |
|-----|-------|
| `tabs`, `default_tab` | `ContentView` / `AppState.apply` |
| `locations_style` | `LocationsView` |
| `schedule_style` | `ScheduleView` via `ScheduleGrouping` |
| `map_clustering`, `map_fit_all` | `MapView` via `MapClustering`, `MapRegionMath` |
| `show_location_images`, `enable_search`, `group_by_category` | Locations, Schedule, Map |
| `secondary_pane` | `MapArrangement` (regular width only) |

## Push Notifications

- Enabling notifications in Options requests authorization, calls `registerForRemoteNotifications()`, and sends the hex token with `POST devices/`.
- `type = "notification"` → alert; tapping opens the Updates tab for that event.
- `type = "content_updated"` → silent (`content-available`); refetches the bundle. Requires the `remote-notification` background mode (in `Info.plist`).
- `aps-environment` is `development` in `Attnd.entitlements`; distribution signing switches it to production.

## iPhone Duo / Foldables

**iPhone Duo is brand new (released late Oct 2026): always check online for the latest Apple docs,
Xcode/simulator release notes and App Store Connect behaviour before working on anything Duo-related —
don't rely on model training data.** As of Nov 14, 2026: Duo screenshots (inner 2007×2853, outer 1398×2034)
are accepted in App Store Connect and via the API as `APP_IPHONE_DUO` (not yet in Apple's API reference),
show a "made for iPhone Duo" badge, and become required in April 2027 for apps on the iOS 27.1 SDK or later;
Xcode still has no public way to unfold the simulator; captures need `simctl io … screenshot --display=…`.

Follow Apple's "Preparing your app for iPhone Duo":
- Build with the latest Xcode; support all orientations; never use `UIScreen` bounds, `userInterfaceIdiom` or interface orientation for layout — use size classes and container geometry.
- Use system bars only. Toolbar items always have an icon **and** a title (`Label`), so they work in vertical bars. Keep must-see items pinned (`.pinnedTrailing`).
- Floating overlays go through `ReservedRegionAvoiding` so they avoid the fold and camera housings.
- `ArrangementView` only at the top of a tab (never inside `NavigationSplitView`, `List` or `ScrollView`).
- Hero images use `.backgroundExtensionEffect()`.
- New-SDK symbols live in `FoldableLayout.swift` / `MapArrangement.swift`, compiled only with the 27.1+ SDK (`IOS27_SDK`) and behind `#available(iOS 27.1, *)`. Reserved regions are queried per kind (`.division` fold, `.occlusion` cameras); there is no "all" kind.
- Manual test matrix: `IPHONE_DUO_CHECKLIST.md`.

## App Clip

`AttndAppClip` compiles the same sources (see its Sources build phase) with its own entry point, `AttndAppClipApp.swift`, which shows the shared `AppRootView`. It has no app delegate and doesn't register for pushes. New shared `.swift` files in `Attnd/` must be added to both the `Attnd` and `AttndAppClip` targets (the `Attnd` group is not file-system synchronized).

## API Key Configuration

`ATTND_API_KEY` (static key for simulators / CI) reaches `Info.plist` as `$(ATTND_API_KEY)` from `Config/Debug.xcconfig` / `Release.xcconfig`, which define it empty and `#include? "Secrets.xcconfig"`. Copy `Config/Secrets.xcconfig.example` to `Config/Secrets.xcconfig` (gitignored) and add your key, or pass `ATTND_API_KEY=…` to `xcodebuild`. **Never commit a key.** Production builds use App Attest.

## Deep Linking (Universal Links)

`https://attnd.app/join/<event_code>/` → `AppState.handleDeepLink(_:)` → `join(code:)`: looks the event up, leaves any current event, then joins. The App Clip uses the same URL.

## Device Identity

A UUID is generated on first launch and stored in `UserDefaults` under `com.arcu.attnd.deviceId`.

## Persistent Preferences (UserDefaults)

| Key | Description |
|-----|-------------|
| `pref.savedEventCode` | Last joined event code; used for silent rejoin on launch |
| `pref.showUserLocation` | Map blue-dot toggle |
| `pref.notificationsEnabled` | Push opt-in; changes are sent with `POST devices/` |
| `pref.pushToken` | Last APNs token (hex) |

## Building

Open `Attnd.xcodeproj` in the latest Xcode. For simulator builds, create `Config/Secrets.xcconfig` (see above).

## Running Tests

In Xcode: **Product → Test** (`⌘U`), or `./run_tests.command`. Unit tests (`ModelDecodingTests`, `DisplayLogicTests`, `BusinessLogicTests`) need no network; `APIClientIntegrationTests` hit the live v2 API and need the static key on a simulator.

## Related Repos

- **[attnd-web](https://github.com/apbeers/Attnd-Web)** — Django backend + REST API, and the **coordinating repo**: `API_V2.md` (contract), `API_CHANGES.md` (tracker)
- **[attnd-android](https://github.com/apbeers/Attnd-Android)** — Kotlin/Compose Android client

## CI/CD (`.github/workflows/ios.yml`)

| Trigger | What happens |
|---------|--------------|
| Pull request | Xcode `XCODE_VERSION` (default 27.2) on the `xcode-27` runner, unit tests on the newest iPhone simulator (`scripts/ci/test.sh`, which shuts the simulator down afterwards so the archive in the same job runs at full speed). Live API tests only if `LIVE_API_TESTS` is set. |
| Push to `develop` | One Mac job: unit tests, then archive with the `dev` environment's `ATTND_SERVER` and upload; a Linux job waits for TestFlight processing (internal testers get every build). |
| Push to `main` | The same against `attnd.app`; the Linux job sets the store listing text (`asc.py metadata`) and submits for App Review (`scripts/ci/asc.py release`), released after approval. What's New comes from `store/en-US/release_notes.txt` unless the `WHATS_NEW` repo variable is set. |

- Docs-only commits (`*.md`) don't run; a newer push to `develop` cancels the older run (`main` never cancels). Anything that only waits on Apple runs on Linux (Mac minutes cost ~10×).
- Version = contents of `VERSION` + `.` + run number (e.g. `2.0.57`); build number = run number. Bump `VERSION` for a new major/minor line.
- Signing is automatic via the App Store Connect API key (`ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_P8` secrets; the key needs the **Admin** role): Xcode manages the profiles and the upload uses a cloud-managed distribution certificate. The archive step reuses one stored **Apple Development** certificate (`IOS_DEV_CERT_P12_BASE64`, `IOS_DEV_CERT_PASSWORD` secrets, imported into a throwaway keychain by `scripts/ci/archive_upload.sh`); without it every fresh runner mints a new "Created via API" certificate and Apple's limit fills up. Renew yearly (attnd-web `SETUP.md` step 3d).
- Server host: `ATTND_SERVER` build setting → `Info.plist` → `APIClient.serverHost` (default `attnd.app`).
- Full setup checklist: `SETUP.md` in attnd-web.

## Store listing (`store-text.yml`, `store-screenshots.yml`)

App Store text and screenshots are generated and set on the **editable** App Store version (e.g. "1.1 Prepare for Submission"); nothing goes live until that version is submitted by `ios.yml` on `main`.

Two **manual-only** workflows (they never run with normal builds), plus the release:

| Workflow | What it does | Time |
|----------|--------------|------|
| `store-text.yml` ("Store listing text") | Validates `store/en-US` and (input **upload**, default on) runs `asc.py metadata` | ~1 min, Linux |
| `store-screenshots.yml` ("Store screenshots") | Mac: capture + compose → `store-screenshots` artifact; Linux: (input **upload**, default on) `asc.py screenshots` | ~20–30 min |
| `ios.yml` on `main` | Sets the listing text on the version (`asc.py metadata`), then submits it for App Review; screenshots stay as last uploaded | — |

- **When the user asks Claude to "update the store listing / screenshots"**: dispatch the workflow(s) on ref `main` (or `develop`) with the GitHub MCP `actions_run_trigger` (`run_workflow`, `workflow_id` `store-text.yml` / `store-screenshots.yml`, inputs `upload: true`), follow the run, download the `store-screenshots` artifact and show the user the images. Uploads only change the editable version (live after the next release). Manual runs need the workflow file on the default branch (`main`).
- **Temporary**: `store-screenshots.yml` also runs (and uploads) on pushes to `develop` that touch it, while it is being made to work. Remove that push trigger once the screenshots come out right.
- **Text**: `store/en-US/*.txt` — `name`, `subtitle` (≤30), `promotional_text` (≤170), `description` (≤4000), `keywords` (≤100, comma-separated, no spaces after commas, not the app name), `release_notes` (sent as What's New, skipped for an app's first version), `support_url`, `marketing_url`, `privacy_url`, `review_notes` (App Review notes; no demo account), `captions.txt` (`<screen>=<caption>`, ≤2 lines, `|` forces the break). `python3 scripts/ci/asc.py metadata --dry-run` validates locally. Keep claims accurate to what the app does.
- **Screenshot mode** (`ScreenshotMode` in `Helpers.swift`; launch arguments only, never persisted): `-AttndScreenshotMode YES -AttndScreen <map|map-pane|locations|location|schedule|updates|orientation-probe>` joins event `DEMO` through the normal lookup/join path, skips the launch screen, update check, device registration, usage counts, demo badge, blue dot and push, forces fit-all/no clustering/now-next, opens the screen (`location` = "Main Stage" detail; `map-pane` = map + side pane) and writes `Documents/attnd-screenshot-ready` (`ready <screen> <W>x<H>` window points, or `failed <reason>`). Needs a simulator Debug build with `ATTND_API_KEY` + `ATTND_SERVER` = the dev server (the static key only works there).
- **`scripts/ci/screenshots.sh`** (macOS): builds once; picks the newest `iPhone NN Pro Max` (6.9", 1320×2868), `iPhone NN Pro` (6.3", 1206×2622) and `iPhone Duo` from `simctl list … -j`, creates/boots them, light mode, 9:41 status bar, captures each screen into `build/screenshots/raw/<device>/<n>-<screen>.png`. The iPhone Duo is captured **folded** (cover display → `raw/iphone-duo-cover/`: map, schedule, location, updates; window < 600 pt wide) and **unfolded** (inner display → `raw/iphone-duo/`: map-pane, location, schedule, updates). It boots folded and Xcode has no public hinge control: `scripts/ci/duo_hinge.m` (private SPI, run inside the simulator with `simctl spawn`) unfolds it; the app's reported window size confirms the inner display (≥600 pt wide, portrait), captures use `--display=<active display>` (devicectl), and an orientation probe lets the composer rotate sideways captures. If folding or unfolding fails, that Duo set is skipped with a warning (repo variable `DUO_SCREENSHOTS_REQUIRED=true` makes it fatal).
- **`scripts/ci/compose_screenshots.py`** (Pillow): purple gradient `#431F86 → #7B4FD6`, bold white caption (SF from the macOS runner, fallbacks), rounded/shadowed capture; outputs exactly 1320×2868, 1206×2622, 2007×2853 (Duo unfolded) and 1398×2034 (Duo folded) RGB PNG in `build/screenshots/composed/`.
- **`asc.py metadata`** / **`asc.py screenshots`**: version localization, app info localization (name, subtitle, privacy URL), App Review details; screenshot sets `APP_IPHONE_67` (6.9"), `APP_IPHONE_61` (Dynamic Island medium display, 1206×2622) and `APP_IPHONE_DUO` (unfolded screenshots first, then folded, ≤10 in total; accepted by the live API, not yet in Apple's reference; if it is ever rejected, the accepted values are printed and the run continues). Existing screenshots in those sets are replaced.
- **Repo variables** (optional): `REVIEW_CONTACT_FIRST_NAME`, `REVIEW_CONTACT_LAST_NAME`, `REVIEW_CONTACT_PHONE`, `REVIEW_CONTACT_EMAIL` (App Review contact; left unchanged when unset), `SCREENSHOT_SERVER` (default the dev server), `DUO_SCREENSHOTS_REQUIRED`. Secrets: `ATTND_API_KEY` (repo) and the environments' `ASC_*`.
