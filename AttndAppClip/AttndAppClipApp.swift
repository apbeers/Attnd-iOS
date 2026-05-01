// AttndAppClipApp.swift
// AttndAppClip
//
// App Clip entry point. Shares all source files with the main Attnd target —
// no code is duplicated. The only difference is this entry point vs AttndApp.swift.

import SwiftUI

@main
struct AttndAppClipApp: App {

    @State private var appState = AppState()

    init() {
        AttestationManager.shared.warmup()
    }

    var body: some Scene {
        WindowGroup {
            ClipRootView()
                .environment(appState)
                // Clips are always launched via a Universal Link — handle it here.
                .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { userActivity in
                    guard let url = userActivity.webpageURL else { return }
                    Task { await appState.handleDeepLink(url) }
                }
        }
    }
}

/// Mirrors RootView in AttndApp.swift. Defined here separately because
/// AttndApp.swift is not compiled into the App Clip target.
private struct ClipRootView: View {
    @Environment(AppState.self) private var appState
    @State private var isAutoJoining = true

    var body: some View {
        Group {
            if isAutoJoining {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if appState.currentEvent != nil {
                ContentView()
                    .transition(.opacity)
            } else {
                LaunchScreen()
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut, value: isAutoJoining)
        .animation(.easeInOut, value: appState.currentEvent?.id)
        .task {
            await appState.autoJoin()
            isAutoJoining = false
        }
    }
}
