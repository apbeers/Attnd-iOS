// SettingsView.swift  (Options tab)
// Attnd

import SwiftUI

struct SettingsView: View {

    @Environment(AppState.self) private var appState
    @State private var showLeaveConfirmation = false
    @State private var notificationPermissionDenied = false
    @State private var isUpdatingNotifications = false
    /// Mirrors appState.notificationsEnabled; changes go through setNotifications.
    @State private var wantsNotifications = false

    var body: some View {
        @Bindable var state = appState

        Form {
            // MARK: - Event
            if let event = appState.currentEvent {
                Section {
                    EventHeader(event: event, logoUrl: appState.logoUrl)
                }
            }

            // MARK: - Location
            Section("Location") {
                Toggle("Show My Location on Map", isOn: $state.showUserLocation)
            }

            // MARK: - Notifications
            Section {
                Toggle("Event Notifications", isOn: $wantsNotifications)
                    .disabled(isUpdatingNotifications)
            } header: {
                Text("Notifications")
            } footer: {
                if notificationPermissionDenied {
                    Text("Notification permission was denied. Enable it in Settings → Attnd.")
                }
            }

            // MARK: - Leave Event
            Section {
                Button(role: .destructive) {
                    showLeaveConfirmation = true
                } label: {
                    Text("Leave Event")
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .navigationTitle("Options")
        .onAppear { wantsNotifications = appState.notificationsEnabled }
        .onChange(of: wantsNotifications) { _, wanted in
            guard wanted != appState.notificationsEnabled, !isUpdatingNotifications else { return }
            Task { await setNotifications(wanted) }
        }
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

    private func setNotifications(_ enabled: Bool) async {
        isUpdatingNotifications = true
        let granted = await appState.setNotificationsEnabled(enabled)
        notificationPermissionDenied = enabled && !granted
        wantsNotifications = appState.notificationsEnabled
        isUpdatingNotifications = false
    }
}

// MARK: - Event header

/// Logo (from `display.logo_url`), name, dates and address of the joined event.
private struct EventHeader: View {
    let event: Event
    let logoUrl: URL?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if let logoUrl {
                AsyncImage(url: logoUrl) { image in
                    image.resizable().scaledToFit()
                } placeholder: {
                    Color(.systemGray5)
                }
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(event.name).font(.headline)
                if let start = event.startTime {
                    Text(EventTimeFormat.dateTime(start, in: event.timeZone))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                if !event.address.isEmpty {
                    Text(event.address)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("Code: \(event.eventCode)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
    }
}

#Preview {
    NavigationStack {
        SettingsView()
            .environment(AppState())
    }
}
