# App Clip — Temporarily Unlinked

The App Clip target (`AttndAppClip`) and all its code remain in the project but are not embedded in the distributed app. It was unlinked to avoid App Review issues while the main app ships.

## What was changed

In `Attnd.xcodeproj/project.pbxproj`, two things were removed from the **Attnd** native target:

1. `4943C6AE2FA026630036D9E7 /* Embed App Clips */` from `buildPhases`
2. `49DD95312FA559F8002F90DE /* PBXTargetDependency */` from `dependencies`

Nothing was deleted — the `AttndAppClip` target, its source files, entitlements, and Info.plist are all still in the project.

## How to re-enable it

The easiest way is through Xcode:

1. Open `Attnd.xcodeproj`
2. Select the **Attnd** target in the project navigator
3. Go to the **Build Phases** tab
4. Click **+** → **New Copy Files Phase**
5. Set Destination to **App Clips**
6. Drag `AttndAppClip.app` from the Products group into the phase

Xcode will also prompt you to re-add the target dependency automatically.

Alternatively, ask Claude to restore the two lines above into `project.pbxproj` and reference this file for the exact IDs.

## App Clip bundle ID

`com.arcu.Attnd.clip`

## Entitlements

- App Clip entitlements: `AttndAppClip/AttndAppClip.entitlements`
- Parent app identifier: `$(AppIdentifierPrefix)com.arcu.Attnd`
- Associated domain (AASA): `attnd.app/join/*` — already configured in the web repo

## AASA

The web repo (`Attnd-Web`) serves the Apple App Site Association file at `/.well-known/apple-app-site-association`. The App Clip entry uses bundle ID `com.arcu.Attnd.clip`. When re-enabling, verify the AASA is still correct by checking `Attnd-Web/join/views.py` → `AppleAppSiteAssociation` view.
