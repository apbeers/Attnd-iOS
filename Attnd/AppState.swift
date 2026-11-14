// AppState.swift
// Attnd
//
// Central main-actor state: the joined event, its bundle (display config,
// locations, schedule, notifications), the selected tab, device identity,
// push registration and user preferences.
//
// Content always comes from one `GET events/<id>/bundle/` call (ETag-cached).
// It is refetched on join, on foreground, on pull-to-refresh, every 5 minutes
// while foregrounded on event days (ContentView drives those), and when a
// `content_updated` or notification push arrives.

import Foundation
import Observation
import UIKit
import UserNotifications

/// The app's tabs: the server-driven event tabs plus the app's own Options tab.
enum MainTab: Hashable, Sendable {
    case event(EventTab)
    case options
}

@MainActor
@Observable
final class AppState {

    // MARK: - Joined event content

    private(set) var currentEvent: Event?
    private(set) var display: DisplayConfig = .default
    private(set) var categories: [String] = []
    private(set) var locations: [Location] = []
    private(set) var schedule: [ScheduleItem] = []
    private(set) var notifications: [AppNotification] = []

    // MARK: - Loading

    private(set) var isLoading = false
    private(set) var loadError: String?
    private(set) var lastRefreshed: Date?

    // MARK: - Navigation

    var selectedTab: MainTab = .event(.map)

    /// Incremented when the Map tab is re-tapped; MapView re-centres on change.
    var mapCenterToken = 0

    /// Set by the map's secondary pane to focus a pin; MapView consumes it.
    var mapFocusLocationId: Int?

    // MARK: - Device

    let deviceId: String

    /// APNs device token (hex). Persisted so join requests can include it.
    private(set) var pushToken: String? {
        didSet { UserDefaults.standard.set(pushToken, forKey: Keys.pushToken) }
    }

    // MARK: - Preferences (persisted)

    /// Show the user's blue dot on the map.
    var showUserLocation: Bool {
        didSet { UserDefaults.standard.set(showUserLocation, forKey: Keys.showUserLocation) }
    }

    /// Whether the user opted into push notifications. Use `setNotificationsEnabled(_:)`
    /// to change it, so permission is requested and the server is told.
    private(set) var notificationsEnabled: Bool {
        didSet { UserDefaults.standard.set(notificationsEnabled, forKey: Keys.notificationsEnabled) }
    }

    /// The event code of the last joined event, for silent rejoin on launch.
    private var savedEventCode: String? {
        get { UserDefaults.standard.string(forKey: Keys.savedEventCode) }
        set { UserDefaults.standard.set(newValue, forKey: Keys.savedEventCode) }
    }

    // MARK: - Private bookkeeping

    @ObservationIgnored private var etag: String?
    @ObservationIgnored private var hasAppliedDefaultTab = false
    /// A notification tap that arrived before its event finished loading (cold launch).
    @ObservationIgnored private var pendingNotificationsEventId: Int?
    @ObservationIgnored private var inflightRefresh: (eventId: Int, token: UUID, task: Task<Void, Never>)?

    private enum Keys {
        static let deviceId = "com.arcu.attnd.deviceId"
        static let savedEventCode = "pref.savedEventCode"
        static let showUserLocation = "pref.showUserLocation"
        static let notificationsEnabled = "pref.notificationsEnabled"
        static let pushToken = "pref.pushToken"
    }

    // MARK: - Init

    init() {
        let defaults = UserDefaults.standard
        if let stored = defaults.string(forKey: Keys.deviceId) {
            deviceId = stored
        } else {
            let newId = UUID().uuidString
            defaults.set(newId, forKey: Keys.deviceId)
            deviceId = newId
        }
        showUserLocation = defaults.object(forKey: Keys.showUserLocation) as? Bool ?? true
        notificationsEnabled = defaults.object(forKey: Keys.notificationsEnabled) as? Bool ?? false
        pushToken = defaults.string(forKey: Keys.pushToken)
    }

    // MARK: - Derived

    var timeZone: TimeZone { currentEvent?.timeZone ?? .current }

    var tabs: [EventTab] { display.resolvedTabs(hasFlyer: currentEvent?.flyerUrl != nil) }

    var defaultTab: EventTab { display.resolvedDefaultTab(hasFlyer: currentEvent?.flyerUrl != nil) }

    /// `display.accent_color`, falling back to the event's.
    var accentHex: String? { display.accentColor ?? currentEvent?.accentColor }

    var logoUrl: URL? { display.logoUrl ?? currentEvent?.logoUrl }

    /// Categories for the filter chips (empty unless `group_by_category`).
    var filterCategories: [String] {
        guard display.groupByCategory else { return [] }
        return LocationGrouping.categories(categories, locations: locations)
    }

    func location(id: Int?) -> Location? {
        guard let id else { return nil }
        return locations.first { $0.id == id }
    }

    func scheduleItems(at locationId: Int) -> [ScheduleItem] {
        schedule.filter { $0.locationId == locationId }
    }

    func isEventDay(_ now: Date = .now) -> Bool {
        guard let event = currentEvent else { return false }
        return ScheduleTiming.isEventDay(now: now, start: event.startTime, end: event.endTime, timeZone: event.timeZone)
    }

    // MARK: - Launch

    /// Registers the device, then silently rejoins the last event if there was one.
    /// On lookup failure the saved code is cleared and the user lands on the launch screen.
    func launch() async {
        Task { await syncDevice() }
        guard let code = savedEventCode else { return }
        do {
            let event = try await APIClient.shared.lookupEvent(query: code)
            await joinEvent(event)
        } catch APIError.notFound {
            savedEventCode = nil
        } catch {
            // Offline or server trouble: forget nothing, but show the launch screen.
        }
    }

    // MARK: - Join / Leave

    func joinEvent(_ event: Event) async {
        if currentEvent?.id != event.id {
            resetContent()
        }
        savedEventCode = event.eventCode
        currentEvent = event
        Task {
            _ = try? await APIClient.shared.joinEvent(eventId: event.id, deviceId: self.deviceId, pushToken: self.pushToken)
        }
        await refreshBundle()
    }

    func leaveEvent() async {
        savedEventCode = nil
        if let event = currentEvent {
            Task { _ = try? await APIClient.shared.leaveEvent(eventId: event.id, deviceId: self.deviceId) }
        }
        currentEvent = nil
        resetContent()
    }

    private func resetContent() {
        inflightRefresh?.task.cancel()
        inflightRefresh = nil
        etag = nil
        display = .default
        categories = []
        locations = []
        schedule = []
        notifications = []
        loadError = nil
        lastRefreshed = nil
        hasAppliedDefaultTab = false
        mapFocusLocationId = nil
    }

    // MARK: - Bundle

    /// Fetches the bundle for the current event. Concurrent calls for the same
    /// event share one request; a 304 just marks the content as fresh.
    func refreshBundle() async {
        guard let eventId = currentEvent?.id else { return }
        if let inflight = inflightRefresh, inflight.eventId == eventId {
            await inflight.task.value
            return
        }
        let token = UUID()
        let task = Task { await self.fetchBundle(eventId: eventId) }
        inflightRefresh = (eventId, token, task)
        await task.value
        if inflightRefresh?.token == token { inflightRefresh = nil }
    }

    private func fetchBundle(eventId: Int) async {
        isLoading = true
        defer { isLoading = false }
        do {
            let result = try await APIClient.shared.bundle(eventId: eventId, etag: etag, deviceId: deviceId)
            // The user may have left or switched events while we waited.
            guard currentEvent?.id == eventId, !Task.isCancelled else { return }
            if case .updated(let bundle, let newEtag) = result {
                apply(bundle)
                etag = newEtag
            }
            loadError = nil
            lastRefreshed = .now
        } catch {
            guard currentEvent?.id == eventId else { return }
            loadError = error.localizedDescription
        }
    }

    private func apply(_ bundle: EventBundle) {
        currentEvent = bundle.event
        display = bundle.display
        categories = bundle.categories
        locations = bundle.locations
        schedule = bundle.schedule
        notifications = bundle.notifications

        if pendingNotificationsEventId == bundle.event.id, tabs.contains(.notifications) {
            selectedTab = .event(.notifications)
            hasAppliedDefaultTab = true
        } else if !hasAppliedDefaultTab {
            selectedTab = .event(defaultTab)
            hasAppliedDefaultTab = true
        } else if case .event(let tab) = selectedTab, !tabs.contains(tab) {
            // The organizer hid the tab we were on.
            selectedTab = .event(defaultTab)
        }
        pendingNotificationsEventId = nil
    }

    // MARK: - Deep links

    /// Handles https://attnd.app/join/<event_code>/ (Universal Links, App Clip invocations).
    /// On failure the user stays where they are.
    func handleDeepLink(_ url: URL) async {
        guard let code = DeepLink.eventCode(from: url) else { return }
        await join(code: code)
    }

    /// Looks up an event by code (QR codes, deep links) and joins it, leaving any
    /// current event first. Returns false if no live event matches.
    @discardableResult
    func join(code: String) async -> Bool {
        if let current = currentEvent, current.eventCode.caseInsensitiveCompare(code) == .orderedSame {
            return true
        }
        guard let event = try? await APIClient.shared.lookupEvent(query: code) else { return false }
        if let current = currentEvent, current.id != event.id {
            Task { _ = try? await APIClient.shared.leaveEvent(eventId: current.id, deviceId: self.deviceId) }
        }
        await joinEvent(event)
        return true
    }

    // MARK: - Push notifications

    /// Turns notifications on (asking for permission if needed) or off, registers
    /// with APNs and tells the server. Returns false if permission was denied.
    @discardableResult
    func setNotificationsEnabled(_ enabled: Bool) async -> Bool {
        guard enabled else {
            notificationsEnabled = false
            await syncDevice()
            return true
        }
        let granted = await Self.requestNotificationAuthorization()
        notificationsEnabled = granted
        if granted {
            UIApplication.shared.registerForRemoteNotifications()
        }
        await syncDevice()
        return granted
    }

    /// Called at launch: refreshes the APNs token if the user has opted in.
    func registerForPushIfEnabled() {
        guard notificationsEnabled else { return }
        UIApplication.shared.registerForRemoteNotifications()
    }

    /// Stores a new APNs token and sends it to the server.
    func updatePushToken(_ token: String) {
        guard token != pushToken else { return }
        pushToken = token
        Task { await syncDevice() }
    }

    /// `POST devices/` with the current token and preference.
    func syncDevice() async {
        _ = try? await APIClient.shared.registerDevice(
            deviceId: deviceId,
            pushToken: pushToken,
            subscribed: notificationsEnabled
        )
    }

    /// A push arrived. Refetches the bundle for our event; when the user opened a
    /// notification, switches to the Notifications tab.
    func handlePush(_ payload: PushPayload, opened: Bool) async {
        guard let eventId = payload.eventId else { return }
        guard let current = currentEvent else {
            // Cold launch: the event is still being rejoined. Apply once it loads.
            if opened { pendingNotificationsEventId = eventId }
            return
        }
        guard current.id == eventId else { return }
        if opened, tabs.contains(.notifications) {
            selectedTab = .event(.notifications)
        }
        await refreshBundle()
    }

    /// Asks for alert permission if it hasn't been decided yet.
    /// Runs off the main actor so only the Sendable result crosses back.
    nonisolated private static func requestNotificationAuthorization() async -> Bool {
        let center = UNUserNotificationCenter.current()
        switch await center.notificationSettings().authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .notDetermined:
            return (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        default:
            return false
        }
    }
}
