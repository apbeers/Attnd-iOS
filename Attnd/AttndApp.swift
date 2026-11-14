// AttndApp.swift
// Attnd

import SwiftUI

@main
struct AttndApp: App {

    /// Owns AppState and receives APNs callbacks.
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
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
        }
    }
}
