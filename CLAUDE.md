# Attnd iOS

SwiftUI app that lets attendees discover and follow live events. Consumes the Attnd REST API served by **[attnd-web](https://github.com/apbeers/Attnd-Web)**.

## Tech Stack

- **Swift / SwiftUI** — iOS 17+ (`@Observable` macro throughout)
- **URLSession** — no third-party networking libraries
- **Apple App Attest** — device attestation for API authentication in production
- **DataScannerViewController** — built-in QR code scanning
- **MapKit** — map view
- **Xcode project**: `Attnd.xcodeproj`
- **Targets**: `Attnd` (main app), `AttndAppClip`

## Source Structure (`Attnd/`)

| File | Purpose |
|------|---------|
| `AttndApp.swift` | App entry point; sets up `AppState`, wires Universal Link handler |
| `AppState.swift` | Central `@Observable` state: current event, locations, schedule, notifications, device ID, preferences |
| `APIClient.swift` | `URLSession`-based API client singleton; async/await; handles 401 retry with re-attestation |
| `AttestationManager.swift` | Apple App Attest key generation, attestation, and JWT token caching |
| `KeychainHelper.swift` | Keychain read/write wrapper |
| `ContentView.swift` | Tab bar container shown after joining an event |
| `LaunchScreen.swift` | Home screen: nearby events list, manual search, QR scanner button |
| `LocationsView.swift` | Locations tab with detail drill-down |
| `ScheduleView.swift` | Schedule tab; filterable by location |
| `NotificationsView.swift` | Notifications tab; polls the API |
| `MapView.swift` | Full map view with location pins |
| `FlyerView.swift` | Loads and displays the event flyer PDF/image from `flyer_url` |
| `QRScannerView.swift` | Wraps `DataScannerViewController` for QR code scanning |
| `SettingsView.swift` | User preferences (show location dot, notification opt-in/out) |
| `Helpers.swift` | Shared utilities (date formatting, etc.) |

## App Flow

```
Launch
├── autoJoin() — looks up saved event code and rejoins silently
│   ├── On success → ContentView (tab bar)
│   └── On failure / none saved → LaunchScreen
│
LaunchScreen
├── GET /nearby_events/<lat>/<lng>/
├── QR scan → GET /lookup/?q=<code>
└── Manual search → /lookup/ then /event_by_code_or_name/
│
Join event
├── POST /join/<deviceId>/ { platform: "ios" }
└── Load locations, schedule, notifications in parallel (TaskGroup)
│
ContentView (tab bar)
├── Locations     → GET /locations/
├── Schedule      → GET /schedule/
├── Map           → shows location pins from locations data
├── Flyer         → loads flyer_url
└── Notifications → GET /notifications/
│
Leave event
└── POST /leave/<deviceId>/
```

## Authentication

`APIClient` resolves the bearer token in priority order:
1. Attestation JWT from `AttestationManager` (production devices)
2. Static `ATTND_API_KEY` from `Info.plist` (simulator / CI / dev builds)

On a 401, the stored JWT is invalidated and the request retries once after re-attesting. Token rotation is transparent to callers.

`AttestationManager.shared.warmup()` is called at app init to pre-fetch the JWT so it's ready before the first API call.

## API Key Configuration

`ATTND_API_KEY` is injected into `Info.plist` at build time via xcconfig files in `Config/`. Do not hardcode it in source.

## Deep Linking (Universal Links)

The app handles `https://attnd.app/join/<event_code>/` Universal Links. `AppState.handleDeepLink(_:)` parses the code, calls `/lookup/` to resolve the event, gracefully leaves any current event, then joins the new one.

The `AttndAppClip` target uses the same URL scheme so users can join events without installing the full app.

## Device Identity

A UUID is generated on first launch and stored in `UserDefaults` under `com.arcu.attnd.deviceId`. This stable ID is sent to all join/leave/push subscription endpoints.

## Persistent Preferences (UserDefaults)

| Key | Description |
|-----|-------------|
| `pref.savedEventCode` | Last joined event code; used for auto-rejoin on launch |
| `pref.showUserLocation` | Map blue-dot toggle |
| `pref.notificationsEnabled` | Push opt-in; toggling calls subscribe/unsubscribe API |

## Demo Event Banner

When `event.paid == false` the event is a demo/trial created by the scraper. Always show a prominent banner so attendees know it is not a live production event.

## Building

Open `Attnd.xcodeproj` in Xcode. Ensure `Config/Debug.xcconfig` has `ATTND_API_KEY` set for local development.

## Running Tests

In Xcode: **Product → Test** (`⌘U`)

Or from the command line:
```bash
./run_tests.command
```

## Related Repos

- **[attnd-web](https://github.com/apbeers/Attnd-Web)** — Django backend + REST API (see `API.md` for full endpoint reference)
- **[attnd-android](https://github.com/apbeers/Attnd-Android)** — Kotlin/Compose Android client
