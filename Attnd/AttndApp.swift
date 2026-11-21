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
                // Universal Links (https://attnd.app/join/<code>/, /p/…, dev.attnd.app too). With an
                // `onOpenURL` in the scene, SwiftUI hands Universal Links to it rather than to this
                // handler, so both route https links to `handleDeepLink` (which ignores a repeat).
                .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { userActivity in
                    guard let url = userActivity.webpageURL else { return }
                    Task { await appDelegate.appState.handleDeepLink(url) }
                }
                // Live Activity regions and buttons (attnd-live://…), Universal Links, and the website's
                // "Open in Attnd" button (attnd://join/<code>, attnd://p/<code>/<payload>; the app only).
                .onOpenURL { url in
                    if url.scheme == "https" || url.scheme == "http" {
                        Task { await appDelegate.appState.handleDeepLink(url) }
                    } else if url.scheme?.lowercased() == "attnd" {
                        if let link = DeepLink.httpsURL(fromAppScheme: url) {
                            Task { await appDelegate.appState.handleDeepLink(link) }
                        }
                    } else {
                        Task { await appDelegate.appState.openLiveActivityLink(url) }
                    }
                }
        }
    }
}
