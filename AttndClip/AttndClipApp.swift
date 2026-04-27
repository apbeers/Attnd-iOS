// AttndClipApp.swift
// AttndClip
//
// Entry point for the Attnd App Clip.
// The clip always opens via a Universal Link: https://attnd.app/join/<event_code>/
// It shares source files with the main app (see DEEPLINK_SETUP.md for target membership).

import SwiftUI

@main
struct AttndClipApp: App {

    @State private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            ClipRootView()
                .environment(appState)
                // App Clips receive their launch URL through NSUserActivity
                .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { userActivity in
                    guard let url = userActivity.webpageURL else { return }
                    Task { await appState.handleDeepLink(url) }
                }
        }
    }
}

/// Root view for the App Clip.
/// Since the whole app fits within the 15 MB App Clip limit, we show the full
/// event experience once joined. The clip auto-joins from the deep link URL.
private struct ClipRootView: View {
    @Environment(AppState.self) private var appState
    @State private var isJoining = true
    @State private var error: String? = nil

    var body: some View {
        Group {
            if isJoining {
                VStack(spacing: 16) {
                    ProgressView()
                    Text("Opening event…")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if appState.currentEvent != nil {
                // Full app experience — user can use it exactly like the installed app
                ContentView()
                    .transition(.opacity)
            } else {
                // Fallback: deep link missing or event not found
                VStack(spacing: 20) {
                    Image(systemName: "qrcode.viewfinder")
                        .font(.system(size: 56))
                        .foregroundStyle(.secondary)
                    Text("Couldn't load event")
                        .font(.title3.bold())
                    Text(error ?? "The event may have ended or the link is no longer valid.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .transition(.opacity)
            }
        }
        .animation(.easeInOut, value: isJoining)
        .animation(.easeInOut, value: appState.currentEvent?.id)
    }
}
