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
private struct RootView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        if appState.currentEvent != nil {
            ContentView()
                .transition(.opacity)
        } else {
            LaunchScreen()
                .transition(.opacity)
        }
    }
}
