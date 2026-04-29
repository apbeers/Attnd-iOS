// AppState.swift
// Attnd
//
// Central state object for the app. Holds the joined event and all loaded data.
// Uses @Observable (iOS 17+).

import Foundation
import Observation

@Observable
final class AppState {

    // MARK: - Joined Event State

    var currentEvent: Event? = nil
    var locations: [Location] = []
    var scheduledItems: [ScheduledItem] = []
    var notifications: [AppNotification] = []

    // MARK: - Loading / Error

    var isLoadingLocations = false
    var isLoadingSchedule = false
    var isLoadingNotifications = false
    var locationsError: String? = nil
    var scheduleError: String? = nil
    var notificationsError: String? = nil

    // MARK: - Map Reset

    /// Incremented each time the Map tab is tapped; MapView observes this to re-center.
    var mapCenterToken: Int = 0

    // MARK: - User Preferences (persisted)

    // MARK: - Persisted Event Code

    /// The event code of the last successfully joined event. Cleared on leave.
    private(set) var savedEventCode: String? {
        get { UserDefaults.standard.string(forKey: "pref.savedEventCode") }
        set { UserDefaults.standard.set(newValue, forKey: "pref.savedEventCode") }
    }

    /// Show the user's blue dot on the map.
    var showUserLocation: Bool {
        didSet { UserDefaults.standard.set(showUserLocation, forKey: "pref.showUserLocation") }
    }

    /// Whether the user has opted into push notifications for this device.
    var notificationsEnabled: Bool {
        didSet {
            UserDefaults.standard.set(notificationsEnabled, forKey: "pref.notificationsEnabled")
            Task { await syncNotificationSubscription() }
        }
    }

    // MARK: - Device

    let deviceId: String

    init() {
        let defaults = UserDefaults.standard

        // Stable device UUID
        let key = "com.arcu.attnd.deviceId"
        if let stored = defaults.string(forKey: key) {
            deviceId = stored
        } else {
            let newId = UUID().uuidString
            defaults.set(newId, forKey: key)
            deviceId = newId
        }

        // Load persisted preferences (default location on, notifications off until granted)
        showUserLocation = defaults.object(forKey: "pref.showUserLocation") as? Bool ?? true
        notificationsEnabled = defaults.object(forKey: "pref.notificationsEnabled") as? Bool ?? false
    }

    // MARK: - Event Actions

    func joinEvent(_ event: Event) async {
        savedEventCode = event.eventCode
        currentEvent = event
        Task { try? await APIClient.shared.joinEvent(eventId: event.id, deviceId: deviceId) }
        await loadEventData(event: event)
    }

    /// Called on launch. If a saved event code exists, tries to look it up and rejoin.
    /// On any API failure the saved code is cleared and the user lands on the launch screen.
    func autoJoin() async {
        guard let code = savedEventCode else { return }
        do {
            let event = try await APIClient.shared.lookupEvent(query: code)
            currentEvent = event
            Task { try? await APIClient.shared.joinEvent(eventId: event.id, deviceId: deviceId) }
            await loadEventData(event: event)
        } catch {
            savedEventCode = nil
        }
    }

    func loadEventData(event: Event) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.loadLocations(eventId: event.id) }
            group.addTask { await self.loadSchedule(eventId: event.id) }
            group.addTask { await self.loadNotifications(eventId: event.id) }
        }
    }

    func loadLocations(eventId: Int) async {
        isLoadingLocations = true
        locationsError = nil
        do {
            let result = try await APIClient.shared.locations(eventId: eventId)
            locations = result.results
        } catch {
            locationsError = error.localizedDescription
        }
        isLoadingLocations = false
    }

    func loadSchedule(eventId: Int) async {
        isLoadingSchedule = true
        scheduleError = nil
        do {
            let result = try await APIClient.shared.schedule(eventId: eventId)
            scheduledItems = result.results
        } catch {
            scheduleError = error.localizedDescription
        }
        isLoadingSchedule = false
    }

    func loadNotifications(eventId: Int) async {
        isLoadingNotifications = true
        notificationsError = nil
        do {
            let result = try await APIClient.shared.notifications(eventId: eventId)
            notifications = result.results
        } catch {
            notificationsError = error.localizedDescription
        }
        isLoadingNotifications = false
    }

    func leaveEvent() async {
        savedEventCode = nil
        if let event = currentEvent {
            Task { try? await APIClient.shared.leaveEvent(eventId: event.id, deviceId: deviceId) }
        }
        currentEvent = nil
        locations = []
        scheduledItems = []
        notifications = []
    }

    // MARK: - Deep Link Handling

    /// Called when the app or App Clip is opened via a Universal Link.
    /// URL pattern: https://attnd.app/join/<event_code>/
    /// On any API failure the method returns silently; the caller decides what to show.
    func handleDeepLink(_ url: URL) async {
        guard let code = eventCode(from: url) else { return }
        // No-op if already in this event
        if let current = currentEvent, current.eventCode.lowercased() == code.lowercased() { return }
        do {
            let event = try await APIClient.shared.lookupEvent(query: code)
            // Leave current event gracefully before joining the new one
            if let current = currentEvent {
                Task { try? await APIClient.shared.leaveEvent(eventId: current.id, deviceId: deviceId) }
            }
            await joinEvent(event)
        } catch {
            // Silently fail — user stays on whatever screen they were on
        }
    }

    private func eventCode(from url: URL) -> String? {
        // pathComponents for /join/FWFM2026/ → ["/", "join", "FWFM2026"]
        let parts = url.pathComponents
        guard parts.count >= 3, parts[1] == "join", !parts[2].isEmpty else { return nil }
        return parts[2]
    }

    // MARK: - Notification Subscription

    private func syncNotificationSubscription() async {
        if notificationsEnabled {
            try? await APIClient.shared.subscribePush(deviceId: deviceId)
        } else {
            try? await APIClient.shared.unsubscribePush(deviceId: deviceId)
        }
    }
}
