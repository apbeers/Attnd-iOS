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
| Timestamps | ISO 8601 UTC | `"2026-06-15T18:00:00+00:00"` |
| Coordinates | Float (decimal degrees) | `32.754695` |
| File URLs | Absolute HTTPS URL or `null` | `"https://attnd.app/media/flyer.pdf"` |
| IDs | Integer | `42` |
| Device IDs | String (UUID recommended) | `"a1b2c3d4-..."` |

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
      "event": {
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
      },
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

**Response `200`**
```json
{
  "id": 1,
  "name": "Fort Worth Art Fair",
  "event_code": "fwartfair",
  "description": "...",
  "latitude": 32.754695,
  "longitude": -97.331605,
  "start_time": "2026-06-15T18:00:00+00:00",
  "paid": true,
  "flyer_url": "https://attnd.app/media/flyer_abc12.pdf",
  "address": "420 Main St, Fort Worth, TX 76102"
}
```

**Error responses**
- `404` — no exact match found

---

#### GET `/api/v1/events/event_by_code_or_name/?data=<query>`

Fuzzy search on event name or event code. Only returns **public** events. Use `/lookup/` instead for exact matching.

**Query parameters**
- `data` — partial name or code

**Response `200`** — same shape as single event above  
**Error responses**
- `404` — no close match found

---

#### GET `/api/v1/events/<event_id>/`

Fetch a single event by its integer ID.

**Response `200`** — single event object (same shape as above)  
**Error responses**
- `404` — event not found

---

### Locations

#### GET `/api/v1/events/<event_id>/locations/`

All locations for an event, sorted alphabetically by name.

**Response `200`**
```json
{
  "count": 3,
  "results": [
    {
      "id": 5,
      "name": "Main Stage",
      "snippet": "Live performances all day",
      "description": "Full description...",
      "website": "https://example.com",
      "image_url": "https://attnd.app/media/stage_abc12.jpg",
      "latitude": 32.754800,
      "longitude": -97.331700,
      "address": "420 Main St, Fort Worth, TX 76102"
    }
  ]
}
```

---

#### GET `/api/v1/events/<event_id>/locations/<location_id>/`

Single location detail.

**Response `200`** — single location object (same shape as above)  
**Error responses**
- `404` — location not found

---

### Notifications

#### GET `/api/v1/events/<event_id>/notifications/`

All sent notifications for an event, newest first. Only includes notifications that have already been delivered (`sent: true`).

**Response `200`**
```json
{
  "count": 1,
  "results": [
    {
      "id": 8,
      "title": "Gate B is now open",
      "body": "Head to Gate B for faster entry.",
      "send_time": "2026-06-15T17:45:00+00:00",
      "sent": true
    }
  ]
}
```

---

#### GET `/api/v1/events/<event_id>/notifications/<notification_id>/`

Single notification detail.

**Response `200`** — single notification object (same shape as above)  
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

**Response `200`**
```json
{ "status": "ok" }
```

**Error responses**
- `404` — event not found

---

#### POST `/api/v1/events/<event_id>/leave/<device_id>/`

Unregister a device from an event.

**Response `200`**
```json
{ "status": "ok" }
```

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

Every event has a QR code (visible in the organizer's admin panel) that encodes:

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

These files are served by the backend. To activate App Clips and App Links, provide the following to the backend team:

**iOS**: Apple Team ID, app Bundle ID, App Clip Bundle ID  
**Android**: app package name, SHA-256 signing certificate fingerprint

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
│
├── Locations tab
│   ├── GET /api/v1/events/<id>/locations/
│   └── On tap → GET /api/v1/events/<id>/locations/<location_id>/
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
| `400` | Bad request (e.g. invalid coordinates) |
| `401` | Missing or invalid API key |
| `404` | Resource not found |
