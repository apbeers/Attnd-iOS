// SettingsView.swift  (Options tab)
// Attnd

import SwiftUI
import UserNotifications

struct SettingsView: View {

    @Environment(AppState.self) private var appState
    @State private var showLeaveConfirmation = false
    @State private var notificationPermissionDenied = false

    var body: some View {
        // @Observable requires a local binding helper
        @Bindable var state = appState

        Form {
            // MARK: - Location
            Section("Location") {
                Toggle("Show My Location on Map", isOn: $state.showUserLocation)
            }

            // MARK: - Notifications
            Section("Notifications") {
                Toggle("Event Notifications", isOn: Binding(
                    get: { appState.notificationsEnabled },
                    set: { newValue in
                        if newValue {
                            Task { await requestAndEnableNotifications() }
                        } else {
                            appState.notificationsEnabled = false
                        }
                    }
                ))

                if notificationPermissionDenied {
                    Text("Notification permission was denied. Enable it in Settings → Attnd.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // MARK: - Leave Event
            Section {
                Button(role: .destructive) {
                    showLeaveConfirmation = true
                } label: {
                    HStack {
                        Spacer()
                        Text("Leave Event")
                        Spacer()
                    }
                }
            }
        }
        .navigationTitle("Options")
        .confirmationDialog(
            "Leave this event?",
            isPresented: $showLeaveConfirmation,
            titleVisibility: .visible
        ) {
            Button("Leave", role: .destructive) {
                Task { await appState.leaveEvent() }
            }
        } message: {
            Text("You'll return to the event discovery screen.")
        }
    }

    // MARK: - Notification Permission

    private func requestAndEnableNotifications() async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()

        switch settings.authorizationStatus {
        case .authorized, .provisional:
            appState.notificationsEnabled = true
        case .notDetermined:
            let granted = (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
            appState.notificationsEnabled = granted
            if !granted { notificationPermissionDenied = true }
        case .denied:
            notificationPermissionDenied = true
        default:
            break
        }
    }
}

#Preview {
    NavigationStack {
        SettingsView()
            .environment(AppState())
    }
}
