# Simulator helpers

Sample pushes and a walking route for trying Attnd in the iOS Simulator with the **DEMO** event
(attnd-web `load_demo_event`, Panther Island, Fort Worth). Nothing here is used by the build.

## Pushes (`*.apns`)

| File | What it shows |
|------|---------------|
| `organizer-notification.apns` | An organizer update (`type: notification`): banner, tap → Updates |
| `urgent-notification.apns` | An urgent update (API-011, `priority: urgent`, time-sensitive) |
| `content-updated.apns` | A silent `content_updated` push: the app refetches the bundle (`jitter_ms: 0`, so at once) |

Set `event_id` (and `notification_id` for the first two) to the DEMO event's ids on the server you
use: Options → About & support shows the event id. Pushes for another event are ignored. Then,
with the app installed on a booted simulator:

```bash
xcrun simctl push booted com.arcu.Attnd tools/simulator/urgent-notification.apns
# App Clip: use com.arcu.Attnd.clip (and change "Simulator Target Bundle"); a clip gets no silent pushes.
```

Or drag an `.apns` file onto the Simulator window. The simulator delivers silent pushes only while
the app runs; tapping a banner exercises the same path as a real notification.

## Walking route (`demo-festival-walk.gpx`)

A walk through the DEMO event's places (Info Booth → Main Stage → Kids Zone → … → Taco Row → Info
Booth) at about 1.3 m/s with two minutes at each stop: distances, compass arrows, walk times, the
map's walking route and the Live Activity's "Leave now" follow it.

- Xcode: Debug → Simulate Location → Add GPX File to Project…, or edit the scheme (Run → Options →
  Default Location) and pick the file.
- Simulator alone: Features → Location → Custom Location… takes one point (e.g. Main Stage,
  32.750039, -97.332027); `xcrun simctl location booted set 32.750039,-97.332027` does the same.
