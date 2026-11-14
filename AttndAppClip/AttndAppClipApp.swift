// AttndAppClipApp.swift
// AttndAppClip
//
// App Clip entry point. Shares every view and model with the main Attnd target
// (see the AttndAppClip Sources build phase); only this entry point differs.
// The clip has no app delegate, so it doesn't register for pushes.

import SwiftUI

@main
struct AttndAppClipApp: App {

    @State private var appState = AppState()

    init() {
        AttestationManager.shared.warmup()
    }

    var body: some Scene {
        WindowGroup {
            AppRootView()
                .environment(appState)
                // Clips are always launched via a Universal Link — handle it here.
                .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { userActivity in
                    guard let url = userActivity.webpageURL else { return }
                    Task { await appState.handleDeepLink(url) }
                }
        }
    }
}
