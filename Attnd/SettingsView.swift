// SettingsView.swift  (Options)
// Attnd
//
// Options for the joined event, shown as a sheet (`OptionsSheet`) from the "Options" item
// in the navigation bar of the Updates tab's root screen, or the first tab's when the event hides
// Updates (ContentView `optionsToolbarItem(for:)`, `TabLayout.optionsTab`).

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
            // API-024: the event's `options_event` layout (header, website, the info page link).
            if let event = appState.currentEvent {
                Section {
                    OptionsEventRows(event: event)
                }
            }

            // MARK: - Status (what the swiped-away pills said)
            if appState.currentEvent != nil {
                Section("Status") {
                    if let refresh = EventStatusBadgeKind.refresh(appState) {
                        Label(refresh.title, systemImage: refresh.systemImage)
                    } else {
                        Label(appState.lastRefreshed.map { "Up to date · Updated \(LastUpdatedText.time($0))" } ?? "Up to date",
                              systemImage: "checkmark.icloud")
                    }
                    if appState.instantUpdates {
                        Label("Instant updates on: the organizer's changes appear as they make them", systemImage: "bolt.fill")
                            .foregroundStyle(.green)
                    }
                    if let ended = EventStatusBadgeKind.current(appState) {
                        Label(ended.title, systemImage: ended.systemImage)
                    }
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
                } else {
                    Text("Organizer updates, and a reminder before anything in your schedule (15 minutes unless you change it).")
                }
            }

            // MARK: - Follow on Lock Screen (Live Activity)
            LiveFollowSection()

            // MARK: - Tour (onboarding)
            Section {
                Button {
                    appState.showTour()
                } label: {
                    Label("Tour", systemImage: "sparkles.rectangle.stack")
                }
            } footer: {
                Text("What Attnd can do at this event.")
            }

            // MARK: - About & support (API-004)
            // Copy Support Info always visible right under the header; the details folded (owner,
            // Nov 21, 2026: saves space).
            Section {
                Button {
                    copySupportInfo(info)
                } label: {
                    Label(
                        didCopySupportInfo ? "Copied" : "Copy Support Info",
                        systemImage: didCopySupportInfo ? "checkmark" : "doc.on.doc"
                    )
                }
                DisclosureGroup("Details") {
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
                    if ServerSwitch.isSwitchable {
                        ServerSwitchRow()
                    }
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
                    // Logs viewer and debug logging (API-013; not in screenshot mode).
                    DiagnosticsRows()
                }
            } header: {
                Text("About & Support")
            } footer: {
                Text("If you contact support, share the support code or the copied info. It identifies this device's app install, not you. A debug code identifies only one debug-logging session.")
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

// MARK: - Follow on Lock Screen

/// "Follow on Lock Screen" (the event's Live Activity) for this event, "Start Now" before it
/// starts by itself.
private struct LiveFollowSection: View {
    @Environment(AppState.self) private var appState
    @Environment(\.scenePhase) private var scenePhase
    /// Re-read on appear / activation (ActivityKit isn't observable).
    @State private var refreshToken = 0

    var body: some View {
        let controller = LiveFollowController.shared
        let _ = refreshToken
        Section {
            Toggle("Follow on Lock Screen", isOn: Binding(
                get: { appState.followsOnLockScreen },
                set: { appState.setFollowOnLockScreen($0) }
            ))
            if appState.followsOnLockScreen {
                if !controller.activitiesEnabled {
                    Label("Live Activities are off for Attnd. Turn them on in Settings → Attnd.", systemImage: "exclamationmark.circle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else if controller.isFollowing {
                    Label("On your Lock Screen", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    if let start = controller.nextStart() {
                        LabeledContent("Starts by itself", value: EventTimeFormat.shortDayTime(start, in: appState.timeZone))
                    }
                    Button {
                        controller.followNow()
                        Task {
                            try? await Task.sleep(for: .seconds(1))
                            refreshToken += 1
                        }
                    } label: {
                        Label("Start Now", systemImage: "play.circle")
                    }
                }
            }
        } header: {
            Text("Lock Screen")
        } footer: {
            Text("Shows what's on now and next from your schedule (or the whole event's) on the Lock Screen and in the Dynamic Island, from 2 hours before your first item.")
        }
        .onAppear { refreshToken += 1 }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { refreshToken += 1 }
        }
    }
}

// MARK: - Server switch (test installs)

/// TestFlight / Xcode installs only (`ServerSwitch.isSwitchable`): Production or Dev for the next
/// launch. Switching leaves the current event, because events live on one server.
private struct ServerSwitchRow: View {
    @Environment(AppState.self) private var appState
    private let current = ServerSwitch.current(host: APIClient.serverHost)
    @State private var selection = ServerSwitch.current(host: APIClient.serverHost)
    @State private var pending: ServerSwitch.Choice?
    @State private var switchedTo: ServerSwitch.Choice?

    var body: some View {
        Picker(selection: $selection) {
            ForEach(ServerSwitch.Choice.allCases, id: \.self) { Text($0.title).tag($0) }
        } label: {
            Label("Test server", systemImage: "server.rack")
        }
        .onChange(of: selection) { _, new in
            if new != (switchedTo ?? current) { pending = new }
        }
        .confirmationDialog(
            "Switch to the \(pending?.title ?? "") server?",
            isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
            titleVisibility: .visible
        ) {
            Button("Switch and Leave Event", role: .destructive) {
                guard let choice = pending else { return }
                pending = nil
                Task {
                    await appState.switchServer(to: choice)
                    switchedTo = choice
                }
            }
            Button("Cancel", role: .cancel) {
                selection = switchedTo ?? current
                pending = nil
            }
        } message: {
            Text("Events live on one server, so you'll leave the current event. Close Attnd from the app switcher and open it again to use the other server.")
        }
        if let switchedTo, switchedTo != current {
            Text("Close Attnd and open it again to use \(switchedTo.host).")
                .font(.footnote)
                .foregroundStyle(.orange)
        }
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

// MARK: - Event rows (API-024 `options_event`)

/// Options' event section: the rows of the event's `options_event` layout (header, website, the
/// info page link), or the built-in default.
private struct OptionsEventRows: View {
    let event: Event

    @Environment(AppState.self) private var appState

    var body: some View {
        let sections = appState.screenSections(.optionsEvent, now: .now) { bundle, state in
            ScreenFacts.event(bundle, state)
        }
        ForEach(sections, id: \.type) { section in
            row(section)
        }
    }

    @ViewBuilder
    private func row(_ section: LayoutSection) -> some View {
        switch section.type {
        case "header":
            EventHeader(event: event, logoUrl: appState.logoUrl)
        case "website":
            if let website = event.websiteUrl {
                EventWebsiteLink(url: website)
            }
        case "event_info_link":
            // API-018: FAQ, amenities, getting there… (the event's info page).
            if event.context != nil {
                NavigationLink {
                    EventInfoView()
                } label: {
                    Label(section.title ?? "FAQ, Amenities & Getting There", systemImage: "info.circle")
                }
            }
        default:
            EmptyView()
        }
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

/// API-016: the event's Attnd Studio website, opened in Safari (`Link` → `openURL`, never an in-app
/// web view), so no device id, token or cookie of the app goes to it.
struct EventWebsiteLink: View {
    let url: URL

    var body: some View {
        Link(destination: url) {
            Label("Website", systemImage: "safari")
        }
        .accessibilityHint("Opens the event's website in Safari")
    }
}

#Preview {
    NavigationStack {
        SettingsView()
            .environment(AppState())
    }
}
