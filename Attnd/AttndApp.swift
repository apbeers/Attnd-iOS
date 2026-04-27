// AttndApp.swift
// Attnd

import SwiftUI

@main
struct AttndApp: App {

    @State private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appState)
        }
    }
}

/// Switches between the launch/join flow and the main event view.
/// On first appear, attempts to auto-rejoin a previously saved event code.
private struct RootView: View {
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
