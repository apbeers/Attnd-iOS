# Links, App Clip and AASA checklist (batch 7, Nov 22, 2026)

One run before a release, on a phone with the TestFlight build and one without Attnd installed.

## Checked from the server (Nov 22, 2026)

| Check | attnd.app | dev.attnd.app |
|---|---|---|
| `/.well-known/apple-app-site-association` 200, `application/json`, no redirect | ✅ | ✅ |
| `applinks` appIDs `GQQX4L6TE2.com.arcu.Attnd` + `.clip`; `/join/*` and `/p/*` claimed, `qr.svg` excluded | ✅ | ✅ |
| `appclips.apps` = `GQQX4L6TE2.com.arcu.Attnd.clip` | ✅ | ✅ |
| Join and shared-plan pages carry the Smart App Banner `apple-itunes-app` with `app-clip-bundle-id=com.arcu.Attnd.clip, app-clip-display=card` | ✅ | ✅ |
| Apple's AASA CDN (`app-site-association.cdn-apple.com/a/v1/<host>`) | not reachable from CI; check by hand | same |

Entitlements: the app has `applinks:attnd.app`, `applinks:dev.attnd.app`; the clip `appclips:attnd.app`, `appclips:dev.attnd.app`.

## By hand (phone)

1. **Apple's CDN**: open `https://app-site-association.cdn-apple.com/a/v1/attnd.app` (and `dev.attnd.app`) in Safari: it must show the same JSON (the CDN can lag a day after a change).
2. **App installed**, from Messages / Notes (not Safari on the same domain):
   - `https://attnd.app/join/DEMO/` opens the app on DEMO.
   - A shared schedule link (`/p/<CODE>/<payload>`, from Schedule → My Schedule → Share) opens the app with "Use This Plan" / "Merge with Mine" (with Apple Intelligence; else it just joins).
   - `attnd://join/DEMO` (the console's Open in Attnd button on a phone) opens the app.
   - The QR scanner in the app reads a join QR, a `/p/` QR and a preview QR (`?preview=`).
3. **Only the App Clip** (delete the app; Settings → App Clips → remove Attnd's):
   - Scan a join QR with the Camera: the App Clip card appears, Open joins the event.
   - A `/p/` link from Messages: the clip opens and joins (the plan proposal needs Apple Intelligence).
   - The Smart App Banner on `https://attnd.app/join/DEMO/` in Safari shows the clip card.
4. **Not installed and no clip yet**: `https://attnd.app/p/<CODE>/<payload>` in Safari shows the web page with the items and the App Store / App Clip buttons.
5. **App Clip → app**: use the clip on an event, install the TestFlight app: the app opens on that event with My schedule and the chat; the clip's Live Activity ends.
6. **Android ↔ iOS**: a `/p/` link made on Android opens on iOS (app and clip), and one made on iOS opens on Android (App Links are verified for attnd.app only; dev.attnd.app links open in the browser on Android).
7. **Default App Clip experience** (App Store Connect → the app → App Clip): the card's title, subtitle, image and "Open" action are set and the advanced experience for `https://attnd.app/join/` is approved.
