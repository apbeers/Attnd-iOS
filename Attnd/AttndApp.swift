// AttndApp.swift
// Attnd + AttndAppClip
//
// The entry point of both the app and the App Clip (the same sources since Nov 19, 2026: the App
// Clip is launched by a Universal Link, which arrives through `onContinueUserActivity` like the
// app's).

import SwiftUI

@main
struct AttndApp: App {

    /// Owns AppState and receives APNs callbacks.
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        // Logging first, so everything after it is captured (AppLog.swift).
        AppLog.start()
        LaunchTiming.appDidInit()
        // Start attestation in the background immediately so the JWT is ready
        // before the first API call, avoiding extra latency on the first screen load.
        AttestationManager.shared.warmup()
    }

    var body: some Scene {
        WindowGroup {
            AppRootView()
                .environment(appDelegate.appState)
                // Universal Links: https://attnd.app/join/<code>/ when the app is installed
                .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { userActivity in
                    guard let url = userActivity.webpageURL else { return }
                    Task { await appDelegate.appState.handleDeepLink(url) }
                }
                // Live Activity regions and buttons that open the app (attnd-live://…).
                .onOpenURL { url in
                    Task { await appDelegate.appState.openLiveActivityLink(url) }
                }
        }
    }
}
