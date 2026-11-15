// SettingsView.swift  (Options)
// Attnd
//
// Options for the joined event, shown as a sheet (`OptionsSheet`) from the "Options" item
// in the navigation bar of every tab's root screen (ContentView `optionsToolbarItem`).

import SwiftUI
import UIKit

/// Options in its own navigation stack, with a Close button. Leaving the event dismisses it
/// with the event screens.
struct OptionsSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            SettingsView()
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close", systemImage: "xmark", role: .close) {
                            dismiss()
                        }
                    }
                }
        }
        .presentationDetents([.large])
    }
}

struct SettingsView: View {

    @Environment(AppState.self) private var appState
    @State private var showLeaveConfirmation = false
    @State private var notificationPermissionDenied = false
    @State private var isUpdatingNotifications = false
    /// Mirrors appState.notificationsEnabled; changes go through setNotifications.
    @State private var wantsNotifications = false
    /// "Copy support info" shows "Copied" briefly.
    @State private var didCopySupportInfo = false

    var body: some View {
        @Bindable var state = appState
        let info = supportInfo

        Form {
            // MARK: - Internal test build (API-004)
            if !info.isProductionServer {
                Section {
                    InternalBuildWarning(host: info.serverHost)
                }
                .listRowBackground(Color.orange.opacity(0.18))
            }

            // MARK: - Event
            if let event = appState.currentEvent {
                Section {
                    EventHeader(event: event, logoUrl: appState.logoUrl)
                        // Siri on-screen awareness: "share this event", "where is it?".
                        .onScreenEntity(.event(event.id))
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

            // MARK: - About & support (API-004)
            Section {
                LabeledContent("Support code") {
                    Text(info.supportCode)
                        .font(.body.monospaced())
                        .textSelection(.enabled)
                }
                LabeledContent("App version", value: "\(info.appVersion) (\(info.buildNumber))")
                if info.isAppClip {
                    LabeledContent("Edition", value: "App Clip")
                }
                LabeledContent("Server", value: info.serverHost)
                LabeledContent("API version", value: String(info.apiVersion))
                LabeledContent("iOS", value: info.osVersion)
                LabeledContent("Device", value: info.deviceModel)
                if let eventId = info.eventId {
                    LabeledContent("Event", value: info.eventName ?? "")
                    LabeledContent("Event code", value: info.eventCode ?? "")
                    LabeledContent("Event ID", value: String(eventId))
                    if let contentVersion = info.contentVersion {
                        LabeledContent("Content version", value: String(contentVersion))
                    }
                }
                LabeledContent("Last refresh") {
                    if let refreshed = info.lastRefreshed {
                        Text(refreshed, format: .dateTime.month(.abbreviated).day().hour().minute().second())
                    } else {
                        Text("Never")
                    }
                }
                Button {
                    copySupportInfo(info)
                } label: {
                    Label(
                        didCopySupportInfo ? "Copied" : "Copy Support Info",
                        systemImage: didCopySupportInfo ? "checkmark" : "doc.on.doc"
                    )
                }
            } header: {
                Text("About & Support")
            } footer: {
                Text("If you contact support, share the support code or the copied info. It identifies this device's app install, not you.")
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

    // MARK: - Support info

    private var supportInfo: SupportInfo {
        let bundle = Bundle.main
        let event = appState.currentEvent
        return SupportInfo(
            appVersion: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            buildNumber: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
            serverHost: APIClient.serverHost,
            apiVersion: APIClient.apiVersion,
            osVersion: UIDevice.current.systemVersion,
            deviceModel: Self.deviceModel,
            isAppClip: bundle.bundleIdentifier?.hasSuffix(".clip") ?? false,
            deviceId: appState.deviceId,
            eventName: event?.name,
            eventCode: event?.eventCode,
            eventId: event?.id,
            contentVersion: event?.contentVersion,
            lastRefreshed: appState.lastRefreshed
        )
    }

    private static let deviceModel = SupportInfo.deviceModelIdentifier()

    private func copySupportInfo(_ info: SupportInfo) {
        UIPasteboard.general.string = info.plainText
        didCopySupportInfo = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            didCopySupportInfo = false
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

// MARK: - Internal test build warning

/// Shown at the top of Options when the build talks to a server other than attnd.app.
private struct InternalBuildWarning: View {
    let host: String

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text("Internal test build")
                    .font(.headline)
                Text("This build uses the dev server (\(host)). Events and data here are separate from the live app.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Event header

/// Logo (from `display.logo_url`), name, dates and address of the joined event.
struct EventHeader: View {
    let event: Event
    let logoUrl: URL?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if let logoUrl {
                CachedImage(url: logoUrl) { image in
                    image.resizable().scaledToFit()
                } placeholder: { _ in
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
