# Attnd API Reference

Base URL: `https://attnd.app`  
API Base: `https://attnd.app/api/v1/events/`

---

## Authentication

Every API request must include the API key as a Bearer token:

```
Authorization: Bearer <API_KEY>
```

Requests missing or with an invalid key receive `401 Unauthorized`.

The API key is hardcoded into the Android and iOS app builds. Do not expose it publicly.

---

## Data Types

| Type | Format | Example |
|------|--------|---------|
| Timestamps | ISO 8601 with offset | `"2026-06-15T18:00:00+00:00"` |
| Coordinates | Float (decimal degrees) | `32.754695` |
| File URLs | Absolute HTTPS URL or `null` | `"https://attnd.app/media/flyer.pdf"` |
| IDs | Integer | `42` |
| Device IDs | String (UUID recommended) | `"a1b2c3d4-..."` |

---

## Object Shapes

### Event object

```json
{
  "id": 1,
  "name": "Fort Worth Art Fair",
  "event_code": "fwartfair",
  "description": "Annual outdoor art fair...",
  "latitude": 32.754695,
  "longitude": -97.331605,
  "start_time": "2026-06-15T18:00:00+00:00",
  "paid": true,
  "flyer_url": "https://attnd.app/media/flyer_abc12.pdf",
  "address": "420 Main St, Fort Worth, TX 76102"
}
```

> **`paid`** — `false` for demo/trial events created via the "Try It Now" scraper. Show a prominent banner ("This is a demo event") when `paid` is `false` so attendees know it is not a live production event.

---

### Location object

Returned individually and in list responses. Includes a nested list of scheduled items at that location, sorted by `start_time`.

```json
{
  "id": 5,
  "name": "Main Stage",
  "snippet": "Live performances all day",
  "description": "Full description...",
  "website": "https://example.com",
  "image_url": "https://example.com/stage.jpg",
  "latitude": 32.754800,
  "longitude": -97.331700,
  "address": "420 Main St, Fort Worth, TX 76102",
  "scheduled_items": [
    {
      "id": 12,
      "name": "Opening Act",
      "description": "Kick off the fair with live music.",
      "start_time": "2026-06-15T18:00:00+00:00",
      "location_id": 5,
      "location_name": "Main Stage"
    }
  ]
}
```

> `image_url` is sourced from the event website during scraping, or from the Google Places photo API, or manually uploaded by the organizer. May be `null`.

---

### Scheduled item object

```json
{
  "id": 12,
  "name": "Opening Act",
  "description": "Kick off the fair with live music.",
  "start_time": "2026-06-15T18:00:00+00:00",
  "location_id": 5,
  "location_name": "Main Stage"
}
```

---

### Notification object

```json
{
  "id": 8,
  "title": "Gate B is now open",
  "body": "Head to Gate B for faster entry.",
  "send_time": "2026-06-15T17:45:00+00:00",
  "sent": true
}
```

---

## Endpoints

### Events

#### GET `/api/v1/events/nearby_events/<latitude>/<longitude>/`

Returns public events near the given coordinates, sorted by relevance (60% time proximity, 40% distance). Only returns events active within a ±3–7 day window of the current time.

**Path parameters**
- `latitude` — decimal latitude (e.g. `32.754695`)
- `longitude` — decimal longitude (e.g. `-97.331605`)

**Response `200`**
```json
{
  "count": 2,
  "results": [
    {
      "event": { "...event object..." },
      "distance_miles": 0.3,
      "starts_in_hours": 2.5
    }
  ]
}
```

**Error responses**
- `400` — invalid coordinates
- `401` — missing or invalid API key

---

#### GET `/api/v1/events/lookup/?q=<query>`

Exact case-insensitive match on event name **or** event code. Does **not** filter by `public` — intended for organizers to verify their event during setup before it goes live.

**Query parameters**
- `q` — exact event name or event code

**Response `200`** — single event object  
**Error responses**
- `400` — missing `q` parameter
- `404` — no exact match found

---

#### GET `/api/v1/events/event_by_code_or_name/?data=<query>`

Fuzzy search on event name or event code. Only returns **public** events. Use `/lookup/` for exact matching (e.g. when handling a scanned QR code).

**Query parameters**
- `data` — partial name or code

**Response `200`** — single event object  
**Error responses**
- `404` — no close match found

---

#### GET `/api/v1/events/<event_id>/`

Fetch a single event by its integer ID.

**Response `200`** — single event object  
**Error responses**
- `404` — event not found

---

### Locations

#### GET `/api/v1/events/<event_id>/locations/`

All locations for an event, sorted alphabetically by name. Each location includes its nested `scheduled_items`.

**Response `200`**
```json
{
  "count": 3,
  "results": [ { "...location object..." } ]
}
```

---

#### GET `/api/v1/events/<event_id>/locations/<location_id>/`

Single location detail, including all scheduled items at that location sorted by `start_time`.

**Response `200`** — single location object  
**Error responses**
- `404` — location not found

---

### Schedule

Scheduled items represent activities, sessions, performances, or any timed occurrence happening at a specific location during the event.

#### GET `/api/v1/events/<event_id>/schedule/`

All scheduled items for an event, sorted by `start_time`. Use this for a full event schedule view. Each item includes `location_id` and `location_name` for display and filtering without a separate locations fetch.

**Response `200`**
```json
{
  "count": 5,
  "results": [
    {
      "id": 12,
      "name": "Opening Act",
      "description": "Kick off the fair with live music.",
      "start_time": "2026-06-15T18:00:00+00:00",
      "location_id": 5,
      "location_name": "Main Stage"
    }
  ]
}
```

---

#### GET `/api/v1/events/<event_id>/schedule/<item_id>/`

Single scheduled item detail.

**Response `200`** — single scheduled item object  
**Error responses**
- `404` — item not found

---

### Notifications

#### GET `/api/v1/events/<event_id>/notifications/`

All sent notifications for an event, newest first. Only includes notifications that have already been delivered (`sent: true`).

**Response `200`**
```json
{
  "count": 1,
  "results": [ { "...notification object..." } ]
}
```

---

#### GET `/api/v1/events/<event_id>/notifications/<notification_id>/`

Single notification detail.

**Response `200`** — single notification object  
**Error responses**
- `404` — notification not found

---

### Device Registration

Device registration ties a physical device to an event and enables push notifications.

#### POST `/api/v1/events/<event_id>/join/<device_id>/`

Register a device as attending an event. Call this when the user opens an event. Creates the device record if it doesn't exist; updates it if it does.

**Path parameters**
- `event_id` — integer event ID
- `device_id` — unique device identifier (generate a UUID on first launch and persist it)

**Request body (JSON)**
```json
{
  "platform": "android"
}
```
`platform` must be `"android"` or `"ios"`.

**Response `200`** — `{ "status": "ok" }`  
**Error responses**
- `404` — event not found

---

#### POST `/api/v1/events/<event_id>/leave/<device_id>/`

Unregister a device from an event.

**Response `200`** — `{ "status": "ok" }`

---

### Push Notifications

#### POST `/api/v1/events/pushnotifications/subscribe/<device_id>/`

Opt a device into push notifications. Call after the user grants notification permission.

**Response `200`** — `{ "status": "ok" }`

---

#### POST `/api/v1/events/pushnotifications/unsubscribe/<device_id>/`

Opt a device out of push notifications.

**Response `200`** — `{ "status": "ok" }`

---

## Deep Linking & App Distribution

### QR Code Join Flow

Every event has a QR code (visible in the organizer's admin panel and shown after the "Try It Now" scraper) that encodes:

```
https://attnd.app/join/<event_code>/
```

When scanned, this URL:
1. Detects the device OS via User-Agent
2. **Android** → redirects to Google Play Store with `referrer=event_code%3D<code>` so the app can open the correct event on first launch
3. **iOS** → redirects to the App Store
4. **Desktop/unknown** → shows a landing page with both store links and the event code for manual entry

When the **app is already installed**, the OS intercepts the URL before the browser loads it:
- **Android**: App Links (`assetlinks.json`) route the URL directly into the app
- **iOS**: Universal Links + App Clips (`apple-app-site-association`) route the URL directly into the app or App Clip

### Handling the Referrer on Android

On first install via the Play Store referrer link, read the install referrer using the [Play Install Referrer API](https://developer.android.com/google/play/installreferrer) and parse the `event_code` parameter to deep link the user into the correct event on first launch.

### Well-Known Files

| URL | Purpose |
|-----|---------|
| `/.well-known/apple-app-site-association` | iOS Universal Links + App Clips config |
| `/.well-known/assetlinks.json` | Android App Links config |

---

## Typical Android App Flow

```
App launch
│
├── First launch
│   ├── Generate UUID → store as device_id
│   ├── Check Play Install Referrer for event_code
│   └── If event_code found → skip to "Load event"
│
├── Home screen
│   ├── GET /api/v1/events/nearby_events/<lat>/<lng>/
│   └── Display list sorted by relevance (use distance_miles + starts_in_hours)
│
├── User taps event (or deep links via QR scan)
│   ├── POST /api/v1/events/<id>/join/<device_id>/ { "platform": "android" }
│   └── Load event detail
│       └── Show "Demo Event" banner if paid == false
│
├── Locations tab
│   ├── GET /api/v1/events/<id>/locations/
│   └── On tap → location detail (scheduled_items already in response)
│
├── Schedule tab
│   ├── GET /api/v1/events/<id>/schedule/
│   ├── Display all items sorted by start_time
│   └── Filter by location_id client-side
│
├── Notifications tab
│   └── GET /api/v1/events/<id>/notifications/  (poll or use push)
│
├── Flyer tab
│   └── Load flyer_url (PDF or image) from the event object
│
└── User leaves event
    └── POST /api/v1/events/<id>/leave/<device_id>/
```

---

## Typical iOS App Flow

```
App launch
│
├── Home screen (LaunchScreen)
│   ├── Request location permission
│   ├── GET /api/v1/events/nearby_events/<lat>/<lng>/
│   ├── Display nearby events list
│   └── Toolbar: QR scanner button (DataScannerViewController)
│       └── On scan → parse /join/<code>/ URL → GET /lookup/?q=<code>
│
├── Manual search
│   ├── Try GET /lookup/?q=<query>  (exact match)
│   └── Fall back to GET /event_by_code_or_name/?data=<query>  (fuzzy)
│
├── User joins event
│   ├── POST /api/v1/events/<id>/join/<device_id>/ { "platform": "ios" }
│   └── Load event detail
│       └── Show "Demo Event" banner if paid == false
│
├── Locations tab
│   ├── GET /api/v1/events/<id>/locations/
│   └── On tap → location detail (scheduled_items already in response)
│
├── Schedule tab
│   ├── GET /api/v1/events/<id>/schedule/
│   ├── Display all items sorted by start_time
│   └── Filter by location_id client-side
│
├── Notifications tab
│   └── GET /api/v1/events/<id>/notifications/  (poll or use push)
│
├── Flyer tab
│   └── Load flyer_url (PDF or image) from the event object
│
└── User leaves event
    └── POST /api/v1/events/<id>/leave/<device_id>/
```

---

## Error Response Format

All errors return JSON:

```json
{ "error": "Description of the problem" }
```

| Status | Meaning |
|--------|---------|
| `400` | Bad request (e.g. invalid coordinates, missing parameter) |
| `401` | Missing or invalid API key |
| `404` | Resource not found |
