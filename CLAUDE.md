# Attnd iOS

SwiftUI app that lets attendees discover and follow live events. Consumes the Attnd REST API v2 served by **[attnd-web](https://github.com/apbeers/Attnd-Web)** (contract: `API_V2.md`).

## Dependency Policy

**Apple frameworks only; no third-party packages.** No SPM, CocoaPods or Carthage dependencies, no Firebase. Push uses APNs directly via `UIApplication` / `UserNotifications`.

## Tech Stack

- **Swift 6 / SwiftUI** — iOS 26+, Swift 6 language mode, `@Observable` + `@MainActor` state
- **URLSession** — networking
- **Apple App Attest** — device attestation for API authentication in production
- **APNs** (`UserNotifications`) — organizer notifications and silent `content_updated` pushes
- **DataScannerViewController** (VisionKit) — QR code scanning
- **MapKit** — map view
- **Xcode project**: `Attnd.xcodeproj` (latest Xcode; required for iPhone Duo layouts)
- **Targets**: `Attnd` (iPhone + iPad, all orientations), `AttndAppClip`, `AttndTests`

## Source Structure (`Attnd/`)

| File | Purpose |
|------|---------|
| `AttndApp.swift` | App entry point; installs `AppDelegate`, wires Universal Links |
| `AppDelegate.swift` | Owns `AppState`; APNs token registration, silent pushes, notification taps |
| `AppState.swift` | `@MainActor @Observable` state: event, bundle content, display config, selected tab, device ID, push token, preferences; bundle refresh with ETag |
| `APIClient.swift` | Stateless, `Sendable` v2 client; async/await; 401 → re-attest → retry once |
| `Models.swift` | v2 models (`Event`, `Location`, `ScheduleItem`, `AppNotification`, `DisplayConfig`, `EventBundle`, request bodies, `PushPayload`) with lenient decoding |
| `DisplayLogic.swift` | Pure, unit-tested logic: schedule grouping (timeline/by day/by location/now-next), location grouping, search, map clustering & framing, fold-avoiding insets |
| `Helpers.swift` | ISO 8601 parsing, event-time-zone formatting, hex colours, deep-link/QR parsing |
| `AttestationManager.swift` | Apple App Attest key generation, attestation, and JWT token caching |
| `KeychainHelper.swift` | Keychain read/write wrapper |
| `LocationPermissionManager.swift` | One-shot async location request |
| `ContentView.swift` | `AppRootView` (launch vs. event) and the server-driven `TabView`; refresh triggers; demo / ended banners; accent tint |
| `LaunchScreen.swift` | Nearby events, system search for a code/exact name, QR scanner |
| `MapArrangement.swift` | Map tab: map + secondary pane via `ArrangementView` on regular width |
| `MapView.swift` | Map with clustering, fit-all, category chips, fold-aware overlays |
| `FoldableLayout.swift` | Wrappers for foldable-era APIs (`reservedRegions`, pinned toolbar placement) |
| `LocationsView.swift` | Locations tab (`NavigationSplitView`), cards/list/grouped styles, detail view |
| `ScheduleView.swift` | Schedule tab (`NavigationSplitView`), styles, filter menu, item detail |
| `NotificationsView.swift` | Organizer updates from the bundle |
| `FlyerView.swift` | Event flyer (image/PDF) from `flyer_url` |
| `QRScannerView.swift` | `DataScannerViewController` sheet; pauses/restarts across scene and size changes |
| `SettingsView.swift` | Options tab: event header (logo), location dot, notifications, leave event |

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
└── Bundle refetched on: foreground, pull-to-refresh, every 5 min on event days,
    content_updated / notification pushes (304 when unchanged)
│
Leave event
└── POST events/<id>/leave/ {device_id}
```

## API v2 Notes

- Base URL `https://attnd.app/api/v2/`. Attestation endpoints remain at `/api/v1/attest/`.
- Models must ignore unknown keys and default missing ones (see `API_V2.md` → Display defaults). Decoding helpers in `Models.swift` (`lenient`, `lossyArray`) enforce this; add new fields the same way.
- Coordinates may be `null`; `0,0` is treated as unknown. Never drop a pin without a valid coordinate.
- Schedule items may have no location — shown under "General".
- All times are displayed in the **event's** `timezone` (`EventTimeFormat`), never the device's.
- `is_demo` → "Demo Event" banner. `status == "archived"` → "This event has ended" banner.
- `display.accent_color` (or the event's) tints the app.

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

Follow Apple's "Preparing your app for iPhone Duo":
- Build with the latest Xcode; support all orientations; never use `UIScreen` bounds, `userInterfaceIdiom` or interface orientation for layout — use size classes and container geometry.
- Use system bars only. Toolbar items always have an icon **and** a title (`Label`), so they work in vertical bars. Keep must-see items pinned (`.pinnedTrailing`).
- Floating overlays go through `ReservedRegionAvoiding` so they avoid the fold and camera housings.
- `ArrangementView` only at the top of a tab (never inside `NavigationSplitView`, `List` or `ScrollView`).
- Hero images use `.backgroundExtensionEffect()`.
- New-SDK symbols live in `FoldableLayout.swift` / `MapArrangement.swift` behind `#available`.
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

- **[attnd-web](https://github.com/apbeers/Attnd-Web)** — Django backend + REST API (`API_V2.md`)
- **[attnd-android](https://github.com/apbeers/Attnd-Android)** — Kotlin/Compose Android client

## CI/CD (`.github/workflows/ios.yml`)

| Trigger | What happens |
|---------|--------------|
| Any push / PR | Newest Xcode on `macos-latest`, unit tests on the newest iPhone simulator (`scripts/ci/test.sh`). Live API tests run only if the `ATTND_API_KEY` secret is set. |
| Push to `develop` | Archive with the `dev` environment's `ATTND_SERVER` (the Heroku dev app), upload, add to the TestFlight group in `TESTFLIGHT_GROUP`. |
| Push to `main` | Archive against `attnd.app`, upload, submit for App Review (`scripts/ci/asc.py release`); releases after approval. |

- Version = contents of `VERSION` + `.` + run number (e.g. `2.0.57`); build number = run number. Bump `VERSION` for a new major/minor line.
- Signing is cloud-managed via the App Store Connect API key (`ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_P8` secrets; the key needs the **Admin** role). No certificates or profiles are stored anywhere.
- Server host: `ATTND_SERVER` build setting → `Info.plist` → `APIClient.serverHost` (default `attnd.app`).
- Full setup checklist: `DEPLOYMENT.md` in attnd-web.
