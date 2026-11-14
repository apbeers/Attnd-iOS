# Attnd API v2

v2 is what the current iOS and Android apps use. The v1 endpoints in `API.md` stay available, unchanged in shape, for older app builds.

- **Base URL:** `https://attnd.app/api/v2/`
- **Authentication:** the same as v1. Send `Authorization: Bearer <attestation JWT>`. In dev and CI builds you can send the static key instead. When you get a `401`, invalidate the JWT, re-attest, and retry once.
- **Timestamps:** ISO 8601 with a UTC offset. Display times in the **event's** `timezone`, not the device's.
- **Coordinates:** may be `null`, meaning unknown. Never drop a pin for a `null` coordinate, and never treat `0,0` as a real location.
- **Forward compatibility:** clients **must ignore unknown keys** and **must fall back to defaults for missing keys**, in every object, and especially in `display`.

---

## Endpoints

### `GET events/nearby/?lat=<float>&lng=<float>`
Returns published, listed events within roughly 35 miles that start between 3 days ago and 7 days from now. Results are sorted by relevance.
```json
{ "count": 1, "results": [ { "event": <Event>, "distance_miles": 1.2, "starts_in_hours": 5.0 } ] }
```

### `GET events/lookup/?q=<event code or exact name>`
Finds an event by exact code, case-insensitive, then by exact name. Unlisted events are included, so this is what QR codes and deep links use. Drafts are never returned.
```json
{ "event": <Event> }
```
`404` means no live event matches.

### `GET events/<id>/bundle/`
Returns everything the app shows, in one response.
- **Caching:** send `If-None-Match: <ETag from last response>`. You get `304 Not Modified` if nothing changed.
- **Device tracking:** optionally send `X-Device-Id: <device id>`, which updates the device's last-seen time for organizer stats.
- **When to call it:**
  - on join
  - when the app comes to the foreground
  - on pull-to-refresh
  - when a `content_updated` push arrives
  - every 5 minutes while the app is in the foreground on event days
```json
{
  "schema_version": 2,
  "content_version": 15,
  "updated_at": "2026-11-14T13:29:44+00:00",
  "event": <Event>,
  "display": <Display>,
  "categories": ["Food", "Stage"],
  "locations": [<Location>],
  "schedule": [<ScheduleItem>],
  "notifications": [<Notification>]
}
```
Hidden locations and items are already filtered out. `locations` are already in the organizer's order, and `schedule` is sorted by `start_time`. `notifications` are newest first.

### `POST events/<id>/join/`
```json
{ "device_id": "uuid", "platform": "ios" | "android", "push_token": "…", "app_version": "2.0.0" }
```
→ `{ "status": "ok", "content_version": 15 }`. Only `device_id` is required.

### `POST events/<id>/leave/`
```json
{ "device_id": "uuid" }
```
→ `{ "status": "ok" }`

### `POST devices/`
Registers or updates a device. Call it on launch, and whenever the push token or the notification preference changes.
```json
{ "device_id": "uuid", "platform": "ios", "push_token": "…", "app_version": "2.0.0", "subscribed": true }
```
→ `{ "status": "ok", "subscribed": true, "event_id": 1 }`. `event_id` is `null` if the device hasn't joined an event.

---

## Objects

### Event
```json
{
  "id": 1, "name": "…", "event_code": "FWFM2026", "description": "…", "address": "…",
  "latitude": 32.75, "longitude": -97.33,
  "start_time": "…", "end_time": "…" | null, "timezone": "America/Chicago",
  "status": "published" | "archived",
  "paid": false, "is_demo": true,
  "flyer_url": "https://…" | null,
  "accent_color": "#FF5A1F" | null, "logo_url": "https://…" | null,
  "content_version": 15,
  "join_url": "https://attnd.app/join/FWFM2026/"
}
```
- `is_demo == true`: show the prominent **Demo Event** banner.
- `status == "archived"`: show an "This event has ended" banner. The content is still viewable.

### Location
```json
{ "id": 5, "name": "…", "snippet": "…", "description": "…", "category": "Food" | null,
  "website": "https://…" | null, "image_url": "https://…" | null, "address": "…",
  "latitude": 32.74 | null, "longitude": -97.36 | null, "sort_order": 0 }
```

### ScheduleItem
```json
{ "id": 1, "name": "…", "description": "…", "start_time": "…", "end_time": "…" | null,
  "location_id": 5 | null, "location_name": "…" | null, "tags": ["Music"] }
```
An item may have no location. Show it under "General" or "No location".

### Notification
```json
{ "id": 1, "title": "…", "body": "…", "send_time": "…" }
```

### Display
This object holds the organizer's layout choices, already resolved by the server for this event's size. Clients render from it; they don't recompute it.

| Key | Values | Meaning |
|---|---|---|
| `tabs` | ordered subset of `map`, `locations`, `schedule`, `flyer`, `notifications` | The visible tabs, in order. Unknown values are ignored. |
| `default_tab` | one of `tabs` | The tab selected after joining. |
| `locations_style` | `cards` \| `list` \| `grouped` | `cards`: large image cards. `list`: compact rows with a thumbnail. `grouped`: sections by `category`. |
| `schedule_style` | `timeline` \| `by_day` \| `by_location` \| `now_next` | `timeline`: one chronological list. `by_day`: sections per day in the event's time zone. `by_location`: sections per location. `now_next`: a "Happening now" section, then "Up next" (the next 2 hours), then "Later". |
| `map_clustering` | bool | Group nearby pins into clusters. |
| `map_fit_all` | bool | On open, zoom to fit all pins (`true`), or centre on the event at street level (`false`). |
| `show_location_images` | bool | Show location images in lists and cards. |
| `enable_search` | bool | Show a search field on the Locations and Schedule tabs. |
| `group_by_category` | bool | Show category filter chips on Locations and the Map. |
| `secondary_pane` | `locations` \| `schedule` \| `now_next` \| `none` | On an unfolded foldable (iPhone Duo inner display, Android foldable inner display), what sits beside the map. |
| `accent_color` | `#RRGGBB` \| null | The app's tint colour for this event. `null` means the default brand colour. |
| `logo_url` | URL \| null | Shown in the event header. |
| `preset`, `resolved_preset`, `reason`, `stats`, `schema_version` | — | Informational only. Clients may ignore them. |

Client defaults when `display` or a key is missing:
- `tabs`: `[map, locations, schedule, notifications]`, plus `flyer` if `flyer_url` is set
- `default_tab`: `map`
- `locations_style`: `list`
- `schedule_style`: `by_day`
- `map_clustering`: `false`
- `map_fit_all`: `true`
- `show_location_images`: `true`
- `enable_search`: `true`
- `group_by_category`: `false`
- `secondary_pane`: `locations`

---

## Push notifications

The server sends pushes through APNs (iOS) and FCM HTTP v1 (Android) to devices that meet all of these:
- they joined the event
- they have `subscribed == true`
- they have a `push_token`

### Payloads
- **Organizer notification:**
  - Visible alert with `title` and `body`.
  - Custom data: `type = "notification"`, `event_id`, `notification_id`.
  - iOS: the custom keys are top-level in the APNs payload, next to `aps`.
  - Android: they're in the FCM `data` map, as strings.
- **Content updated:**
  - Silent push, sent when the organizer publishes changes and has chosen to notify attendees.
  - Custom data: `type = "content_updated"`, `event_id`, `content_version`.
  - iOS: `content-available: 1`, with no alert.
  - Android: data-only message.
  - The app should refetch the bundle.

When the app is opened from a notification, it should open the Notifications tab for that event.
