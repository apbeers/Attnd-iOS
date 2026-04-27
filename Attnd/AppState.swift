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
    var notifications: [AppNotification] = []

    // MARK: - Loading / Error

    var isLoadingLocations = false
    var isLoadingNotifications = false
    var locationsError: String? = nil
    var notificationsError: String? = nil

    // MARK: - User Preferences (persisted)

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
        currentEvent = event
        Task { try? await APIClient.shared.joinEvent(eventId: event.id, deviceId: deviceId) }
        await loadEventData(event: event)
    }

    func loadEventData(event: Event) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.loadLocations(eventId: event.id) }
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
        if let event = currentEvent {
            Task { try? await APIClient.shared.leaveEvent(eventId: event.id, deviceId: deviceId) }
        }
        currentEvent = nil
        locations = []
        notifications = []
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
