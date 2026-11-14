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

    /// `tab_view` detail (API-005): map, locations, schedule, flyer, notifications or options.
    var usageDetail: String {
        switch self {
        case .event(let tab): return tab.rawValue
        case .options:        return "options"
        }
    }
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

    var selectedTab: MainTab = .event(.map) {
        didSet {
            // The first tab is counted in `apply` once the bundle has chosen it.
            if hasAppliedDefaultTab, oldValue != selectedTab {
                track(.tabView, detail: selectedTab.usageDetail)
            }
        }
    }

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

    // MARK: App updates (API-003)

    /// From GET /api/app-status/. `.required` replaces the whole UI with the update screen.
    private(set) var appStatus = AppStatus()

    /// The `latest_version` whose "update available" banner the user closed.
    private var dismissedUpdateVersion: String? {
        didSet { UserDefaults.standard.set(dismissedUpdateVersion, forKey: Keys.dismissedUpdateVersion) }
    }

    var mustUpdate: Bool { appStatus.update == .required }

    var showUpdateBanner: Bool {
        appStatus.update == .available && appStatus.latestVersion != dismissedUpdateVersion
    }

    @ObservationIgnored private var etag: String?
    @ObservationIgnored private var hasAppliedDefaultTab = false
    /// A notification tap that arrived before its event finished loading (cold launch).
    @ObservationIgnored private var pendingNotificationsEventId: Int?
    @ObservationIgnored private var inflightRefresh: (eventId: Int, token: UUID, task: Task<Void, Never>)?
    /// Anonymous usage counts (API-005).
    private let usage: UsageReporter

    private enum Keys {
        static let deviceId = "com.arcu.attnd.deviceId"
        static let savedEventCode = "pref.savedEventCode"
        static let showUserLocation = "pref.showUserLocation"
        static let notificationsEnabled = "pref.notificationsEnabled"
        static let pushToken = "pref.pushToken"
        static let dismissedUpdateVersion = "pref.dismissedUpdateVersion"
    }

    // MARK: - Init

    init() {
        usage = UsageReporter()
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
        dismissedUpdateVersion = defaults.string(forKey: Keys.dismissedUpdateVersion)
        // Any API call answered with 410/426 means this build's API version is retired.
        NotificationCenter.default.addObserver(forName: .attndUpdateRequired, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.handleUpdateRequired() }
        }
    }

    // MARK: - App updates

    /// Asks the server whether this build should update. Failures leave the last answer in place.
    func checkForUpdate() async {
        guard let status = try? await APIClient.shared.appStatus() else { return }
        appStatus = status
    }

    func dismissUpdateBanner() {
        dismissedUpdateVersion = appStatus.latestVersion
    }

    private func handleUpdateRequired() async {
        var status = (try? await APIClient.shared.appStatus()) ?? appStatus
        status.update = .required
        appStatus = status
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
        Task { await checkForUpdate() }
        guard let code = savedEventCode else { return }
        do {
            let event = try await APIClient.shared.lookupEvent(query: code)
            await joinEvent(event)
            track(.appOpen)
        } catch APIError.notFound {
            savedEventCode = nil
        } catch {
            // Offline or server trouble: forget nothing, but show the launch screen.
        }
    }

    // MARK: - Join / Leave

    func joinEvent(_ event: Event) async {
        if currentEvent?.id != event.id {
            // Send the old event's counts before switching.
            usage.flush()
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
        usage.flush()
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
        let isFirstApply = !hasAppliedDefaultTab
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
        if isFirstApply, hasAppliedDefaultTab {
            // The tab the event opens on (later changes are counted in selectedTab's didSet).
            track(.tabView, detail: selectedTab.usageDetail)
        }
    }

    /// Pull to refresh: counted, then a normal bundle refresh.
    func pullToRefresh() async {
        track(.refresh)
        await refreshBundle()
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
        if opened, currentEvent == nil || currentEvent?.id == eventId {
            // Counted against the push's event, so a tap that cold-launches the app counts too.
            usage.record(.notificationOpen, detail: payload.notificationId.map { String($0) }, eventId: eventId)
        }
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

    // MARK: - Usage (API-005)

    /// Counts one anonymous usage event for the joined event. No-op when not in an event.
    /// Never pass identifying data or search text as `detail`.
    func track(_ metric: UsageMetric, detail: String? = nil) {
        guard let eventId = currentEvent?.id else { return }
        usage.record(metric, detail: detail, eventId: eventId)
    }

    /// `track(.locationView, id: location.id)`
    func track(_ metric: UsageMetric, id: Int) {
        track(metric, detail: String(id))
    }

    /// Sends pending counts now (the app is going to the background).
    func flushUsage() {
        usage.flush()
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

// MARK: - Usage reporter (API-005)

/// Aggregates anonymous usage counts in memory (`UsageAggregator`) and sends them with
/// `POST events/<id>/usage/` at most every ~60 s while there is pending data, when the
/// app goes to the background and before leaving or switching events. A batch that fails
/// is retried once on the next flush, then dropped. Never blocks, never surfaces errors.
@MainActor
final class UsageReporter {

    typealias Sender = @Sendable (_ eventId: Int, _ entries: [UsageEntry]) async throws -> Void

    private struct Batch {
        var eventId: Int
        var entries: [UsageEntry]
    }

    static let flushInterval: Duration = .seconds(60)

    private var aggregator = UsageAggregator()
    /// Batches whose first send failed; sent once more on the next flush.
    private var retryBatches: [Batch] = []
    private var timer: Task<Void, Never>?
    private let sender: Sender

    init(sender: @escaping Sender = { eventId, entries in
        try await APIClient.shared.sendUsage(eventId: eventId, entries: entries)
    }) {
        self.sender = sender
    }

    func record(_ metric: UsageMetric, detail: String? = nil, eventId: Int) {
        aggregator.record(metric, detail: detail, eventId: eventId, at: .now)
        scheduleFlush()
    }

    /// Sends everything pending in the background. Safe to call often.
    func flush() {
        timer?.cancel()
        timer = nil
        let retries = retryBatches
        retryBatches = []
        let fresh = aggregator.drain()
        guard !retries.isEmpty || !fresh.isEmpty else { return }
        let sender = self.sender
        Task { [weak self] in
            for batch in retries {
                // Second attempt: on failure the batch is dropped.
                try? await sender(batch.eventId, batch.entries)
            }
            var failed: [Batch] = []
            for (eventId, entries) in fresh {
                for chunk in UsageAggregator.chunks(entries) {
                    do {
                        try await sender(eventId, chunk)
                    } catch {
                        failed.append(Batch(eventId: eventId, entries: chunk))
                    }
                }
            }
            guard let self, !failed.isEmpty else { return }
            self.retryBatches.append(contentsOf: failed)
            self.scheduleFlush()
        }
    }

    private func scheduleFlush() {
        guard timer == nil else { return }
        timer = Task { [weak self] in
            try? await Task.sleep(for: UsageReporter.flushInterval)
            guard !Task.isCancelled, let self else { return }
            self.timer = nil
            self.flush()
        }
    }
}
