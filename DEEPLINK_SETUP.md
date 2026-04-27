# Deep Linking & App Clip Setup

All Swift source code and web backend changes are done. The two remaining steps require Xcode UI because they involve code signing and target creation, which Xcode must manage.

---

## Step 1 — Link the entitlements to the main app target

1. Open `Attnd.xcodeproj` in Xcode
2. Select the **Attnd** project in the navigator → select the **Attnd** target → **Build Settings**
3. Search for `CODE_SIGN_ENTITLEMENTS`
4. Set it to `Attnd/Attnd.entitlements` for both Debug and Release

Alternatively, go to **Signing & Capabilities** → click **+ Capability** → add **Associated Domains** → add:
```
applinks:attnd.app
```
(Xcode will create and link the entitlements file automatically — you can then delete the one already at `Attnd/Attnd.entitlements` if Xcode creates its own.)

---

## Step 2 — Create the App Clip target

1. In Xcode: **File → New → Target → App Clip** → Next
2. Set:
   - **Product Name**: `AttndClip`
   - **Bundle Identifier**: `com.arcu.attnd-ios.Clip`  
     *(must be the main app bundle ID + `.Clip`)*
   - **Team**: GQQX4L6TE2
   - **Language**: Swift
   - **Interface**: SwiftUI

3. Delete the placeholder files Xcode creates (ContentView, Assets, etc.)

4. **Add source files** to the AttndClip target — in the file inspector, enable AttndClip membership for:
   - `AttndClip/AttndClipApp.swift` ← already in repo, just register it
   - `Attnd/APIClient.swift`
   - `Attnd/AppState.swift`
   - `Attnd/Helpers.swift`
   - `Attnd/ContentView.swift`
   - `Attnd/MapView.swift`
   - `Attnd/LocationsView.swift`
   - `Attnd/NotificationsView.swift`
   - `Attnd/FlyerView.swift`
   - `Attnd/SettingsView.swift`
   - `Attnd/LaunchScreen.swift`
   - `Attnd/LocationPermissionManager.swift`
   - `Attnd/Assets.xcassets`

5. Set the **Info.plist** for AttndClip to `AttndClip/Info.plist` in Build Settings → `INFOPLIST_FILE`

6. Set the **entitlements** to `AttndClip/AttndClip.entitlements` in Build Settings → `CODE_SIGN_ENTITLEMENTS`

7. In **Signing & Capabilities** for the AttndClip target → **+ Capability → Associated Domains** → add:
   ```
   appclips:attnd.app
   ```

8. Under **Build Settings**, set `ATTND_API_KEY = $(ATTND_API_KEY)` (same as main app)

9. Set `IPHONEOS_DEPLOYMENT_TARGET = 17.0`

---

## Step 3 — Set Heroku env vars

The AASA endpoint reads these:

```
APPLE_TEAM_ID=GQQX4L6TE2
APPLE_BUNDLE_ID=com.arcu.attnd-ios
```

Set them with:
```bash
heroku config:set APPLE_TEAM_ID=GQQX4L6TE2 APPLE_BUNDLE_ID=com.arcu.attnd-ios
```

The AASA will then serve:
```json
{
  "applinks": {
    "details": [{
      "appIDs": ["GQQX4L6TE2.com.arcu.attnd-ios"],
      "components": [{ "/": "/join/*" }]
    }]
  },
  "appclips": {
    "apps": ["GQQX4L6TE2.com.arcu.attnd-ios.Clip"]
  }
}
```

Verify it live at: `https://attnd.app/.well-known/apple-app-site-association`

---

## Step 4 — Register the App Clip experience in App Store Connect

1. Go to [appstoreconnect.apple.com](https://appstoreconnect.apple.com)
2. Open the Attnd app → **App Clips**
3. Add a new App Clip experience:
   - **URL**: `https://attnd.app/join/`  (prefix — covers all `/join/*` paths)
   - **Header image**, **subtitle**, **call to action**: fill in as desired
4. Submit with your next TestFlight / App Store build

---

## How it works end-to-end

```
User scans QR code → https://attnd.app/join/FWFM2026/
│
├── Full app installed?
│   └── YES → OS intercepts URL, opens Attnd.app, fires onContinueUserActivity
│              → AppState.handleDeepLink() → lookupEvent("FWFM2026") → joinEvent()
│              → ContentView appears
│
└── Full app NOT installed?
    └── iOS checks attnd.app AASA → finds App Clip entry
        → Downloads AttndClip (< 15 MB, instant)
        → ClipRootView auto-joins from the URL
        → Full event experience in the clip
        → "Get Full App" banner offered by iOS automatically
```
