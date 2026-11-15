// AppState.swift
// Attnd
//
// Central main-actor state: the joined event, its bundle (display config,
// locations, schedule, notifications), the selected tab, device identity,
// push registration and user preferences.
//
// Content always comes from one `GET events/<id>/bundle/` call (ETag-cached).
// It is refetched on join, on foreground, on pull-to-refresh, when a
// `content_updated` push announces a newer content_version (after a random
// 0–10 s delay) or a notification push arrives, and by ContentView's slow poll
// while the scene is active (`LiveRefreshPolicy`: every 60 s without a push
// token, e.g. the App Clip; a 5-minute safety poll with one).
//
// Offline (API-007): every applied bundle is saved to Application Support
// (`EventStore`, raw JSON + ETag + last refresh) and restored at launch before
// any network, so the event opens offline. Its images, logo and flyer are
// prefetched into `ImageStore`. Only a 404 for the event, leaving or switching
// events deletes the saved copy; network and server errors never do.

import Foundation
import Observation
import SwiftUI
import UIKit
import UserNotifications

/// What the event screens present over the tabs. The tab bar holds only the event's own
/// tabs (`display.tabs`, at most `DisplayConfig.maxTabs`, so there is never a "More" tab);
/// search and Options are sheets opened from the floating search button and the Options
/// toolbar item (ContentView).
enum EventSheet: String, Identifiable, Hashable, Sendable {
    /// Local search across the event (EventSearchView), with its own navigation stack.
    case search
    /// SettingsView.
    case options
    /// The onboarding cards (OnboardingView): after the first join, and Options → Tour.
    case tour

    var id: String { rawValue }

    /// `ui.screen` name (LOG_EVENTS.md).
    var screenName: String {
        switch self {
        case .search:  return "search"
        case .options: return "options"
        case .tour:    return "onboarding"
        }
    }

    /// `tab_view` detail (API-005) counted when the sheet opens: "options" (the server
    /// accepts the event tabs and options). nil for search, which counts as `search`, and
    /// for the tour.
    var usageDetail: String? {
        switch self {
        case .options:       return "options"
        case .search, .tour: return nil
        }
    }
}

extension EventTab {
    /// `ui.screen` name (LOG_EVENTS.md): the tab's raw value, "updates" for notifications.
    var screenName: String { self == .notifications ? "updates" : rawValue }
}

extension AppTab {
    /// The display tab a `tab_view` count and `ui.screen` name stand for (Explore: its view;
    /// My plan: none, the server accepts only the event tabs).
    func eventTab(explore view: ExploreView) -> EventTab? {
        switch self {
        case .plan: return nil
        case .explore: return view.eventTab
        case .event(let tab): return tab
        }
    }
}

/// Why the bundle is refetched (`net.bundle.applied` / `not_modified` `source`).
enum RefreshSource: String, Sendable {
    case join, foreground, poll, push, pull
}

@MainActor
@Observable
final class AppState {

    // MARK: - Joined event content

    private(set) var currentEvent: Event? {
        didSet {
            guard oldValue?.id != currentEvent?.id else { return }
            // Logs carry the joined event's id; perf counts go with its usage batch.
            AppLog.setEventId(currentEvent?.id)
            usage.eventId = currentEvent?.id
        }
    }
    private(set) var display: DisplayConfig = .default
    private(set) var categories: [String] = []
    private(set) var locations: [Location] = []
    private(set) var schedule: [ScheduleItem] = []
    private(set) var notifications: [AppNotification] = []

    // MARK: - Loading

    private(set) var isLoading = false
    private(set) var loadError: String?
    /// Why the last refresh failed (nil after a success); drives the floating offline badge.
    private(set) var refreshProblem: RefreshProblem?
    /// The last successful refresh (restored from disk at launch).
    private(set) var lastRefreshed: Date?

    // MARK: - Navigation

    /// The selected tab (TabLayout: My plan, Explore, Flyer, Updates; the old tabs in screenshot mode).
    var selectedTab: AppTab = .explore {
        didSet {
            guard oldValue != selectedTab else { return }
            // The first tab is counted in `apply` once the bundle has chosen it.
            if hasAppliedDefaultTab, let tab = selectedTab.eventTab(explore: exploreView) {
                track(.tabView, detail: tab.rawValue)
            }
            let name = selectedTab.eventTab(explore: exploreView)?.screenName ?? "plan"
            AppLog.debug(.ui, "ui.screen", "Tab \(name)", ["name": .string(name)])
        }
    }

    /// The Explore tab's view (Map | Schedule | Places), remembered per event. Switching it counts
    /// a `tab_view` with the old tab names (map / schedule / locations) while Explore is shown.
    var exploreView: ExploreView = .map {
        didSet {
            guard oldValue != exploreView else { return }
            if let id = currentEvent?.id, !ScreenshotMode.isActive {
                UserDefaults.standard.set(exploreView.rawValue, forKey: Keys.exploreView(id))
            }
            if selectedTab == .explore {
                if hasAppliedDefaultTab { track(.tabView, detail: exploreView.eventTab.rawValue) }
                AppLog.debug(.ui, "ui.screen", "Explore \(exploreView.eventTab.screenName)", ["name": .string(exploreView.eventTab.screenName)])
            }
        }
    }

    /// My plan's navigation stack (details opened from the plan, its answer card and results).
    var planPath = NavigationPath()

    /// The search or Options sheet over the tabs (nil: none). Opening Options counts a
    /// `tab_view` "options", as the Options tab did.
    var presentedSheet: EventSheet? {
        didSet {
            if oldValue != presentedSheet, let detail = presentedSheet?.usageDetail {
                track(.tabView, detail: detail)
            }
            if oldValue != presentedSheet, let sheet = presentedSheet {
                AppLog.debug(.ui, "ui.screen", "Sheet \(sheet.screenName)", ["name": .string(sheet.screenName)])
            }
        }
    }

    /// Incremented when the Map tab is re-tapped; MapView re-centres on change.
    var mapCenterToken = 0

    /// Set by the map's secondary pane to focus a pin; MapView consumes it.
    var mapFocusLocationId: Int?

    // MARK: - Search and jumps

    /// The search sheet's query (Siri's "search in Attnd" can fill it). Never sent anywhere.
    var searchText = ""

    /// A question to put to the on-device model as soon as the search sheet shows it
    /// (onboarding's "What's on near me right now?"); consumed by EventSearchView.
    var autoAskQuery: String?

    /// The onboarding cards are due (first join); ContentView presents them once it is on screen.
    var pendingTour = false

    /// The search sheet's navigation stack: result details (`SearchTarget`), the locations they
    /// link to, and anything whose tab is hidden.
    var searchPath = NavigationPath()

    /// An item to show, consumed by the tab that shows it (Locations, Schedule, Updates).
    var focusRequest: SearchTarget?

    /// The joined event prepared for local search; rebuilt with every applied bundle.
    private(set) var searchIndex: EventSearchIndex?

    // MARK: - Glance (location, hearts, unread updates)

    /// The user's position and heading while a screen showing distances is visible.
    let userLocation = UserLocationTracker()
    /// Walking routes for the map card.
    let walkingRoutes = WalkingRouteProvider()
    /// Hearts and the Updates "seen" mark for the current event (UserDefaults, per event).
    private(set) var personal = EventPersonalState()
    @ObservationIgnored private var personalEventId: Int?

    #if !APP_CLIP
    /// A shared plan link (`/p/<code>/<payload>`, API-015) opened for the joined event, waiting
    /// for the assistant to show it read-only ("Use this plan" / "Merge with mine"). Cleared
    /// when the event is left or switched; the assistant clears it once shown.
    var pendingSharedPlan: PendingSharedPlan?

    /// "My plan" (spec §6): the current event's plan and the planner's progress (PlanStore.swift;
    /// the full app only, offered while Apple Intelligence's on-device model is available).
    let planner = PlanStore()

    /// The event assistant (AssistantController.swift, spec §1–8): the conversation, its actions
    /// and live hints. The floating button opens it (the search sheet in screenshot mode).
    let assistant = AssistantController()
    #endif

    // MARK: - Device

    let deviceId: String

    /// APNs device token (hex). Persisted so join requests can include it.
    private(set) var pushToken: String? {
        didSet { UserDefaults.standard.set(pushToken, forKey: Keys.pushToken) }
    }

    /// APNs registration failed this launch (simulator, no entitlement, no network);
    /// the live poll then runs every 60 s instead of relying on silent pushes.
    private(set) var pushRegistrationFailed = false

    /// The running Live Activity's ActivityKit push token (hex, API-011); nil when none runs.
    /// Sent with `POST devices/` as `live_activity_token` (`null` once it ends).
    @ObservationIgnored private var liveActivityToken: String?
    /// False while `liveActivityToken` hasn't reached the server yet.
    @ObservationIgnored private var liveActivityTokenSynced = true

    /// The App Clip can't receive pushes; it always uses the 60 s poll.
    static let isAppClip = Bundle.main.bundleIdentifier?.hasSuffix(".clip") ?? false

    /// How often ContentView re-checks the bundle while active (API-007).
    var liveRefreshInterval: Duration {
        LiveRefreshPolicy.interval(
            canReceivePush: LiveRefreshPolicy.canReceivePush(
                pushToken: pushToken,
                registrationFailed: pushRegistrationFailed,
                isAppClip: Self.isAppClip
            ),
            lastRefreshFailed: refreshProblem != nil
        )
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
    /// `content_version` of the applied bundle; compared with `content_updated` pushes.
    @ObservationIgnored private var contentVersion: Int?
    /// The raw JSON of the applied bundle, re-saved with a new `lastRefreshed` after a 304.
    @ObservationIgnored private var bundleData: Data?
    /// `lastRefreshed` as last written to disk (304s re-save at most every few minutes).
    @ObservationIgnored private var lastSavedRefresh: Date?
    /// The event the server has confirmed our `join/` for. A failed join (offline launch)
    /// is retried after the next successful refresh.
    @ObservationIgnored private var joinedEventId: Int?
    @ObservationIgnored private var joiningEventId: Int?
    /// Restoring the saved event runs once per process (launch, or a silent push that woke the app).
    @ObservationIgnored private var restoreTask: Task<Void, Never>?
    /// Serial chain of disk writes/deletes for `EventStore`, so they land in order.
    @ObservationIgnored private var diskTask: Task<Void, Never>?
    /// Serial chain of image prefetches / clears; a new prefetch cancels the previous one.
    @ObservationIgnored private var imageTask: Task<Void, Never>?
    /// The last prefetch left something missing (e.g. offline); retried after a successful refresh.
    @ObservationIgnored private var imagesIncomplete = false
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
        /// The onboarding cards were shown (or skipped) once on this device.
        static let onboardingSeen = "pref.onboardingSeen"
        /// `EventPersonalState` JSON (hearts, Updates seen) for one event.
        static func personal(_ eventId: Int) -> String { "pref.event.\(eventId)" }
        /// The Explore tab's last view (map / schedule / places) for one event.
        static func exploreView(_ eventId: Int) -> String { "pref.exploreView.\(eventId)" }
    }

    // MARK: - Init

    init() {
        usage = UsageReporter()
        usage.attachPerfMetrics()
        let defaults = UserDefaults.standard
        if let stored = defaults.string(forKey: Keys.deviceId) {
            deviceId = stored
        } else {
            let newId = UUID().uuidString
            defaults.set(newId, forKey: Keys.deviceId)
            deviceId = newId
        }
        // Screenshot mode: no blue dot and no push (property observers don't run in init,
        // so the stored preferences are left untouched).
        let isScreenshot = ScreenshotMode.isActive
        showUserLocation = isScreenshot ? false : defaults.object(forKey: Keys.showUserLocation) as? Bool ?? true
        notificationsEnabled = isScreenshot ? false : defaults.object(forKey: Keys.notificationsEnabled) as? Bool ?? false
        pushToken = defaults.string(forKey: Keys.pushToken)
        dismissedUpdateVersion = defaults.string(forKey: Keys.dismissedUpdateVersion)
        // Any API call answered with 410/426 means this build's API version is retired.
        NotificationCenter.default.addObserver(forName: .attndUpdateRequired, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.handleUpdateRequired() }
        }
        #if !APP_CLIP
        assistant.appState = self
        #endif
    }

    // MARK: - App updates

    /// Asks the server whether this build should update. Failures leave the last answer in place.
    func checkForUpdate() async {
        // Screenshot mode never shows the update banner.
        guard !ScreenshotMode.isActive else { return }
        do {
            let status = try await APIClient.shared.appStatus()
            appStatus = status
            AppLog.notice(.lifecycle, "lifecycle.update_prompt", "Update: \(status.update.rawValue)", [
                "update": .string(status.update.rawValue), "min_version": .string(status.minVersion ?? ""),
                "latest_version": .string(status.latestVersion ?? ""),
            ])
        } catch {
            AppLog.caught(error, .net, "app_status", level: .notice)
        }
    }

    func dismissUpdateBanner() {
        dismissedUpdateVersion = appStatus.latestVersion
    }

    private func handleUpdateRequired() async {
        AppLog.warning(.lifecycle, "lifecycle.update_prompt", "This build's API version is retired", ["update": "required"])
        var status = (try? await APIClient.shared.appStatus()) ?? appStatus
        status.update = .required
        appStatus = status
    }

    // MARK: - Derived

    var timeZone: TimeZone { currentEvent?.timeZone ?? .current }

    /// The tab bar (TabLayout.swift): My plan (full app, not in screenshot mode), Explore (Map |
    /// Schedule | Places; screenshot mode keeps the old separate tabs), Flyer, Updates.
    var tabLayout: TabLayout {
        TabLayout.resolve(display, hasFlyer: currentEvent?.flyerUrl != nil, plan: Self.hasPlanTab, explore: !ScreenshotMode.isActive)
    }

    var tabs: [AppTab] { tabLayout.tabs }

    /// The My plan tab exists: the full app, not in screenshot mode (with or without the model).
    static var hasPlanTab: Bool {
        #if APP_CLIP
        return false
        #else
        return !ScreenshotMode.isActive
        #endif
    }

    /// `tab` (Map, Schedule, Locations, Flyer, Updates) is reachable: a tab or an Explore view.
    func shows(_ tab: EventTab) -> Bool { tabLayout.place(of: tab) != nil }

    /// Shows `tab`: its own tab, or Explore on its view. Returns false when it is hidden.
    @discardableResult
    func select(_ tab: EventTab) -> Bool {
        guard let place = tabLayout.place(of: tab) else { return false }
        if let view = place.view { exploreView = view }
        selectedTab = place.tab
        return true
    }

    /// Whether `tab`'s view is on screen now.
    func isShowing(_ tab: EventTab) -> Bool {
        selectedTab.eventTab(explore: exploreView) == tab
    }

    /// `display.accent_color`, falling back to the event's. nil → views use the
    /// asset AccentColor (brand purple), never system blue.
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

    // MARK: - Launch

    /// Registers the device, then reopens the last event: from the copy saved on disk when
    /// there is one (shown immediately, even offline; join and refresh follow in the
    /// background), otherwise by looking the saved code up. Only a 404 forgets the event.
    func launch() async {
        if let screenshot = ScreenshotMode.current {
            await launchForScreenshots(screenshot)
            return
        }
        Task { await syncDevice() }
        Task { await checkForUpdate() }
        await restoreSavedEventIfNeeded()
        if currentEvent != nil {
            if let event = currentEvent {
                AppLog.notice(.lifecycle, "lifecycle.event.joined", "Reopened the saved event", ["event_id": .int(event.id), "via": "rejoin"])
            }
            track(.appOpen)
            Task { await self.ensureJoined() }
            Task { await self.refreshBundle(source: .foreground) }
            return
        }
        guard let code = savedEventCode else {
            AppLog.debug(.ui, "ui.screen", "Launch screen", ["name": "launch"])
            return
        }
        do {
            let event = try await APIClient.shared.lookupEvent(query: code)
            await joinEvent(event, via: "rejoin")
            track(.appOpen)
        } catch APIError.notFound {
            AppLog.notice(.lifecycle, "lifecycle.event.left", "The saved event is gone (404)", ["event_id": 0, "reason": "404"])
            savedEventCode = nil
        } catch {
            // Offline or server trouble with nothing saved on disk: show the launch screen
            // but keep the code, so the next launch tries again.
            AppLog.caught(error, .lifecycle, "rejoin_lookup")
        }
    }

    // MARK: - Offline copy (API-007)

    /// Restores the saved event from disk once per process. Called by `launch()` and by a
    /// push that may have woken the app in the background before any scene launched.
    func restoreSavedEventIfNeeded() async {
        if let restoreTask {
            await restoreTask.value
            return
        }
        let task = Task { await self.restoreSavedEvent() }
        restoreTask = task
        await task.value
    }

    private func restoreSavedEvent() async {
        guard !ScreenshotMode.isActive, currentEvent == nil else { return }
        let code = savedEventCode
        let started = ContinuousClock.now
        guard let restored = await EventStore.shared.load() else { return }
        let ms = (ContinuousClock.now - started).wholeMilliseconds
        AppLog.info(.storage, "storage.bundle.restored", "Saved event read in \(ms) ms", [
            "ms": .int(ms), "bytes": .int(restored.0.bundleJSON.count), "content_version": .int(restored.1.contentVersion),
            "age_s": .int(restored.0.lastRefreshed.map { Int(Date.now.timeIntervalSince($0)) } ?? -1),
        ])
        let (saved, bundle) = restored
        guard saved.belongs(toEventCode: code) else {
            // Left over from an event the user left or switched away from.
            enqueueDisk { await EventStore.shared.delete() }
            clearImages()
            return
        }
        // A deep link may have joined another event while we read the file.
        guard currentEvent == nil else { return }
        etag = saved.etag
        lastRefreshed = saved.lastRefreshed
        lastSavedRefresh = saved.lastRefreshed
        bundleData = saved.bundleJSON
        apply(bundle)
    }

    /// Saves the applied bundle (raw JSON) with its ETag and refresh time. Atomic, in order.
    private func saveEvent() {
        guard let event = currentEvent, let data = bundleData else { return }
        let saved = SavedEvent(
            eventId: event.id,
            eventCode: event.eventCode,
            etag: etag,
            lastRefreshed: lastRefreshed,
            bundleJSON: data
        )
        lastSavedRefresh = lastRefreshed
        let version = contentVersion ?? event.contentVersion
        enqueueDisk { await EventStore.shared.save(saved, contentVersion: version) }
    }

    /// Deletes the saved event and its cached images (leave, switch, 404).
    private func deleteSavedEvent() {
        enqueueDisk { await EventStore.shared.delete() }
        clearImages()
    }

    private func enqueueDisk(_ operation: @escaping @Sendable () async -> Void) {
        let previous = diskTask
        diskTask = Task {
            await previous?.value
            await operation()
        }
    }

    /// Prefetches every image the current content references; a newer call cancels the older one.
    private func scheduleImageSync() {
        let urls = MediaCache.referencedURLs(event: currentEvent, display: display, locations: locations)
        let previous = imageTask
        imagesIncomplete = false
        imageTask = Task {
            previous?.cancel()
            await previous?.value
            guard !Task.isCancelled else { return }
            let complete = await ImageStore.shared.sync(urls)
            if !complete, !Task.isCancelled { self.imagesIncomplete = true }
        }
    }

    /// Removes every cached image (after any running prefetch has stopped).
    private func clearImages() {
        let previous = imageTask
        imagesIncomplete = false
        ImageMemoryCache.shared.removeAll()
        imageTask = Task {
            previous?.cancel()
            await previous?.value
            await ImageStore.shared.removeAll()
        }
    }

    /// Screenshot mode (`ScreenshotMode`): joins the demo event through the normal
    /// lookup → join → bundle path, retrying while the dev server wakes up, then writes
    /// the ready marker once the content has had time to settle (map tiles, images).
    private func launchForScreenshots(_ screenshot: ScreenshotMode) async {
        ScreenshotMode.clearMarker()
        if screenshot.screen == .orientationProbe {
            // AppRootView shows the probe instead of any event; nothing to load.
            Task {
                try? await Task.sleep(for: .seconds(2))
                ScreenshotMode.writeMarker("ready \(screenshot.screen.rawValue) \(Self.keyWindowSize)")
            }
            return
        }
        for attempt in 1...8 {
            if currentEvent == nil {
                _ = await join(code: screenshot.eventCode)
            } else {
                await refreshBundle(source: .join)
            }
            if hasAppliedDefaultTab { break }
            if attempt < 8 { try? await Task.sleep(for: .seconds(5)) }
        }
        guard hasAppliedDefaultTab else {
            let reason = currentEvent == nil ? "no event for code \(screenshot.eventCode)" : (loadError ?? "bundle not loaded")
            ScreenshotMode.writeMarker("failed \(reason)")
            return
        }
        Task {
            try? await Task.sleep(for: .seconds(screenshot.settleSeconds))
            ScreenshotMode.writeMarker("ready \(screenshot.screen.rawValue) \(Self.keyWindowSize)")
        }
    }

    /// The key window's size in points ("669x951") for the screenshot ready marker, so the
    /// capture script can check which iPhone Duo display hosts the app. Diagnostics only.
    private static var keyWindowSize: String {
        let window = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }
        guard let size = window?.bounds.size else { return "unknown" }
        return "\(Int(size.width.rounded()))x\(Int(size.height.rounded()))"
    }

    // MARK: - Join / Leave

    /// `via` says how (`lifecycle.event.joined`): "qr", "link", "search", "nearby", "rejoin".
    func joinEvent(_ event: Event, via: String = "search") async {
        if currentEvent?.id != event.id {
            if let old = currentEvent {
                AppLog.notice(.lifecycle, "lifecycle.event.left", "Switching events", ["event_id": .int(old.id), "reason": "switch"])
            }
            // Send the old event's counts before switching.
            usage.flush()
            resetContent()
            deleteSavedEvent()
        }
        AppLog.notice(.lifecycle, "lifecycle.event.joined", "Joined event \(event.id)", ["event_id": .int(event.id), "via": .string(via)])
        savedEventCode = event.eventCode
        currentEvent = event
        loadPersonalState(for: event.id)
        Task { await self.ensureJoined() }
        await refreshBundle(source: .join)
    }

    /// `POST events/<id>/join/` until the server has accepted it once for this event.
    /// Failures (offline) are retried after the next successful bundle refresh.
    private func ensureJoined() async {
        guard let event = currentEvent, joinedEventId != event.id, joiningEventId != event.id else { return }
        joiningEventId = event.id
        defer { if joiningEventId == event.id { joiningEventId = nil } }
        do {
            _ = try await APIClient.shared.joinEvent(eventId: event.id, deviceId: deviceId, pushToken: pushToken)
            if currentEvent?.id == event.id { joinedEventId = event.id }
        } catch {
            // Retried later; the bundle works without it.
            AppLog.caught(error, .net, "join")
        }
    }

    func leaveEvent() async {
        AppLog.notice(.lifecycle, "lifecycle.event.left", "Left the event", ["event_id": .int(currentEvent?.id ?? 0), "reason": "user"])
        usage.flush()
        savedEventCode = nil
        if let event = currentEvent {
            Task { _ = try? await APIClient.shared.leaveEvent(eventId: event.id, deviceId: self.deviceId) }
        }
        currentEvent = nil
        resetContent()
        deleteSavedEvent()
    }

    /// The event is gone (404 from the bundle): forget it and return to the launch screen.
    private func forgetEvent() {
        AppLog.notice(.lifecycle, "lifecycle.event.left", "The event is gone (404): back to the launch screen",
                      ["event_id": .int(currentEvent?.id ?? 0), "reason": "404"])
        usage.flush()
        savedEventCode = nil
        currentEvent = nil
        resetContent()
        deleteSavedEvent()
    }

    private func resetContent() {
        inflightRefresh?.task.cancel()
        inflightRefresh = nil
        etag = nil
        contentVersion = nil
        bundleData = nil
        lastSavedRefresh = nil
        joinedEventId = nil
        display = .default
        categories = []
        locations = []
        schedule = []
        notifications = []
        loadError = nil
        refreshProblem = nil
        lastRefreshed = nil
        hasAppliedDefaultTab = false
        mapFocusLocationId = nil
        searchText = ""
        searchPath = NavigationPath()
        planPath = NavigationPath()
        focusRequest = nil
        presentedSheet = nil
        searchIndex = nil
        autoAskQuery = nil
        pendingTour = false
        #if !APP_CLIP
        pendingSharedPlan = nil
        #endif
        loadPersonalState(for: nil)
        #if !APP_CLIP
        EventEntityIndex.shared.update(with: nil)
        #endif
        // Ends the Live Activity and removes reminders (the server clears the token on leave).
        liveFollowNeedsUpdate()
    }

    // MARK: - Bundle

    /// Fetches the bundle for the current event. Concurrent calls for the same
    /// event share one request; a 304 just marks the content as fresh.
    /// `silent` (polls and pushes) doesn't toggle `isLoading`, so no spinners
    /// flash; errors are recorded the same way as any refresh.
    func refreshBundle(silent: Bool = false, source: RefreshSource = .foreground) async {
        guard let eventId = currentEvent?.id else { return }
        if let inflight = inflightRefresh, inflight.eventId == eventId {
            await inflight.task.value
            return
        }
        let token = UUID()
        let task = Task { await self.fetchBundle(eventId: eventId, silent: silent, source: source) }
        inflightRefresh = (eventId, token, task)
        await task.value
        if inflightRefresh?.token == token { inflightRefresh = nil }
    }

    /// A 304 re-saves `lastRefreshed` at most this often (the content itself is unchanged).
    private static let refreshSaveInterval: TimeInterval = 5 * 60

    private func fetchBundle(eventId: Int, silent: Bool, source: RefreshSource) async {
        if !silent { isLoading = true }
        defer { if !silent { isLoading = false } }
        let signpost = AppSignpost.begin(.bundleFetch)
        do {
            let result = try await APIClient.shared.bundle(eventId: eventId, etag: etag, deviceId: deviceId)
            let notModified: Bool
            if case .notModified = result { notModified = true } else { notModified = false }
            let ms = AppSignpost.end(signpost, ["cache": .string(notModified ? "304" : "none"), "source": .string(source.rawValue)])
            PerfMetrics.shared.record(notModified ? .perfBundle304 : .perfBundleFetch, detail: PerfBucket.bundleFetch(ms: ms))
            // The user may have left or switched events while we waited.
            guard currentEvent?.id == eventId, !Task.isCancelled else { return }
            let now = Date.now
            lastRefreshed = now
            // Avoid needless observation churn from the polls.
            if loadError != nil { loadError = nil }
            if refreshProblem != nil { refreshProblem = nil }
            switch result {
            case .updated(let bundle, let newEtag, let data):
                let previous = contentVersion
                etag = newEtag
                bundleData = data
                apply(bundle)
                saveEvent()
                AppLog.info(.net, "net.bundle.applied", "Bundle v\(bundle.contentVersion) applied", [
                    "content_version": .int(bundle.contentVersion), "previous_version": .int(previous ?? -1),
                    "source": .string(source.rawValue), "bytes": .int(data.count),
                    "locations": .int(bundle.locations.count), "items": .int(bundle.schedule.count),
                    "notifications": .int(bundle.notifications.count),
                ])
            case .notModified:
                AppLog.debug(.net, "net.bundle.not_modified", "Bundle unchanged (304)", [
                    "content_version": .int(contentVersion ?? -1), "source": .string(source.rawValue),
                ])
                if lastSavedRefresh.map({ now.timeIntervalSince($0) >= Self.refreshSaveInterval }) ?? true {
                    saveEvent()
                }
                if imagesIncomplete { scheduleImageSync() }
            }
            if joinedEventId != eventId {
                Task { await self.ensureJoined() }
            }
        } catch APIError.notFound {
            // The event was deleted or unpublished: the only error that drops the saved copy.
            AppSignpost.end(signpost, ["error": "not_found"])
            guard currentEvent?.id == eventId else { return }
            forgetEvent()
        } catch {
            AppSignpost.end(signpost, ["error": .string((error as? APIError)?.logKind ?? "other")])
            AppLog.caught(error, .net, "bundle_refresh", level: silent ? .notice : .warning)
            guard currentEvent?.id == eventId else { return }
            // Saved content stays on screen; the badge shows the last successful refresh.
            loadError = error.localizedDescription
            refreshProblem = RefreshProblem(error)
        }
    }

    private func apply(_ bundle: EventBundle) {
        let isFirstApply = !hasAppliedDefaultTab
        currentEvent = bundle.event
        loadPersonalState(for: bundle.event.id)
        contentVersion = bundle.contentVersion
        display = ScreenshotMode.current?.adjusted(bundle.display) ?? bundle.display
        categories = bundle.categories
        locations = bundle.locations
        schedule = bundle.schedule
        notifications = bundle.notifications

        let layout = tabLayout
        // Explore's view: the one remembered for this event, else default_tab's, else the first.
        let remembered = isFirstApply && !ScreenshotMode.isActive
            ? UserDefaults.standard.string(forKey: Keys.exploreView(bundle.event.id)).flatMap(ExploreView.init(rawValue:))
            : Optional(exploreView)
        if let view = layout.exploreView(remembered: remembered), view != exploreView {
            exploreView = view
        }
        if pendingNotificationsEventId == bundle.event.id, layout.tabs.contains(.event(.notifications)) {
            selectedTab = .event(.notifications)
            hasAppliedDefaultTab = true
        } else if !hasAppliedDefaultTab {
            selectedTab = layout.defaultTab
            hasAppliedDefaultTab = true
        } else if !layout.tabs.contains(selectedTab) {
            // The organizer hid the tab we were on.
            selectedTab = layout.defaultTab
        }
        pendingNotificationsEventId = nil
        if isFirstApply, hasAppliedDefaultTab, let tab = selectedTab.eventTab(explore: exploreView) {
            // The tab the event opens on (later changes are counted in selectedTab's didSet).
            track(.tabView, detail: tab.rawValue)
        }
        // New images download first; files the new content no longer uses are deleted after.
        scheduleImageSync()
        searchIndex = EventSearchIndex(bundle)
        #if !APP_CLIP
        // Spotlight / Siri (App Intents): the app's entities follow the shown content.
        EventEntityIndex.shared.update(with: currentBundle)
        #endif
        // The onboarding cards after the first join on this device (never in screenshot mode).
        if isFirstApply, !ScreenshotMode.isActive, !UserDefaults.standard.bool(forKey: Keys.onboardingSeen) {
            pendingTour = true
        }
        #if !APP_CLIP
        assistant.refreshLive()
        #endif
        liveFollowNeedsUpdate()
    }

    /// The content shown, as one bundle (nil outside an event). For search, Siri and Spotlight.
    var currentBundle: EventBundle? {
        guard let event = currentEvent, hasAppliedDefaultTab else { return nil }
        return EventBundle(
            contentVersion: contentVersion ?? event.contentVersion,
            event: event,
            display: display,
            categories: categories,
            locations: locations,
            schedule: schedule,
            notifications: notifications
        )
    }

    // MARK: - Jumps (search results, Siri, Spotlight)

    /// Shows one item: in its own tab when that tab is visible (Locations / Schedule select
    /// it, Updates scrolls to and highlights it; the event opens Options), closing any sheet;
    /// otherwise in the search sheet with the item pushed on its stack, so hidden tabs
    /// (`display.tabs`) work too (Back returns to the search results).
    func navigate(to target: SearchTarget) {
        guard currentEvent != nil else { return }
        let tab: EventTab
        switch target {
        case .location:     tab = .locations
        case .scheduleItem: tab = .schedule
        case .notification: tab = .notifications
        case .event:
            presentedSheet = .options
            return
        }
        #if !APP_CLIP
        assistant.closeOverlay()
        #endif
        if shows(tab) {
            presentedSheet = nil
            focusRequest = target
            select(tab)
        } else {
            searchPath = NavigationPath([target])
            presentedSheet = .search
        }
    }

    /// A tap on an item inside the app (cards, results, plan rows): on My plan its detail is
    /// pushed on My plan's own stack (the plan stays one Back away); elsewhere `navigate(to:)`.
    func open(_ target: SearchTarget) {
        if selectedTab == .plan, presentedSheet == nil, currentEvent != nil {
            if case .event = target {
                presentedSheet = .options
            } else {
                planPath.append(target)
            }
            return
        }
        navigate(to: target)
    }

    /// Opens the search sheet with `query` (Siri / Shortcuts). `ask`: also put it to the
    /// on-device model right away (onboarding's question example; its plan examples plan).
    func showSearch(_ query: String, ask: Bool = false) {
        guard currentEvent != nil else { return }
        searchPath = NavigationPath()
        searchText = query
        autoAskQuery = ask && Self.assistantAvailable ? query : nil
        #if !APP_CLIP
        // My plan's input bar is the full app's search: the text goes into it, or runs at once
        // when it was to be asked.
        if Self.hasPlanTab {
            autoAskQuery = nil
            showPlanTab()
            assistant.request(query, send: ask)
            return
        }
        #endif
        presentedSheet = .search
    }

    /// Whether "Ask" (Apple Intelligence's on-device model) can answer: never in the App Clip
    /// or screenshot mode. Onboarding's "Plan your day" card and the planner (spec §6, "My plan")
    /// are offered only when this is true.
    static var assistantAvailable: Bool {
        #if APP_CLIP
        return false
        #else
        return !ScreenshotMode.isActive && EventAssistant.isAvailable
        #endif
    }

    /// "Ask About This" on a location, schedule item or update detail (assistant spec §8): the
    /// assistant with the item as context ("Tell me about X": the model's answer, else the
    /// item's card and chips). The App Clip opens its search sheet with the item's name.
    func askAbout(_ target: SearchTarget) {
        guard currentEvent != nil, !ScreenshotMode.isActive else { return }
        let name: String?
        switch target {
        case .location(let id):     name = location(id: id)?.name
        case .scheduleItem(let id): name = schedule.first { $0.id == id }?.name
        case .notification(let id): name = notifications.first { $0.id == id }?.title
        case .event:                name = currentEvent?.name
        }
        guard let name, !name.isEmpty else { return }
        AppLog.debug(.ui, "ui.action", "Ask about this", ["name": "ask_about", "id": .string(target.reference)])
        #if !APP_CLIP
        if Self.hasPlanTab {
            let ref: EntityRef?
            switch target {
            case .location(let id):     ref = EntityRef(kind: .location, id: id)
            case .scheduleItem(let id): ref = EntityRef(kind: .schedule, id: id)
            case .notification(let id): ref = EntityRef(kind: .update, id: id)
            case .event:                ref = nil
            }
            showPlanTab()
            if let ref {
                assistant.askAbout(ref)
            } else {
                assistant.submit("Tell me about \(name)")
            }
            return
        }
        #endif
        showSearch(name)
    }

    /// The floating search button: opens the search sheet on its results (the last query
    /// stays, like the old search tab), with the field focused.
    func openSearch() {
        guard currentEvent != nil else { return }
        #if !APP_CLIP
        // The full app: the same input bar as My plan, over the current tab (search-only answers).
        if Self.hasPlanTab {
            assistant.openOverlay()
            return
        }
        #endif
        searchPath = NavigationPath()
        presentedSheet = .search
    }

    /// The My plan tab, back at its root, any sheet closed (no-op without it).
    func showPlanTab() {
        guard tabs.contains(.plan) else { return }
        presentedSheet = nil
        planPath = NavigationPath()
        #if !APP_CLIP
        assistant.closeOverlay()
        #endif
        selectedTab = .plan
    }

    /// "Show on Map" in a location's detail: the Map tab, focused on that pin (any sheet closes).
    func showOnMap(locationId: Int) {
        guard shows(.map) else { return }
        mapFocusLocationId = locationId
        presentedSheet = nil
        #if !APP_CLIP
        assistant.closeOverlay()
        #endif
        select(.map)
    }

    /// Pull to refresh: counted, then a normal bundle refresh.
    func pullToRefresh() async {
        track(.refresh)
        await refreshBundle(source: .pull)
    }

    // MARK: - Deep links

    /// Handles https://attnd.app/join/<event_code>/ and shared plan links
    /// https://attnd.app/p/<event_code>/<payload> (API-015; Universal Links, App Clip
    /// invocations). A shared plan link joins its event, then (full app only, readable payload)
    /// keeps the plan in `pendingSharedPlan` for the assistant. On failure the user stays where
    /// they are.
    func handleDeepLink(_ url: URL) async {
        if let shared = SharedPlanLink.parse(url) {
            AppLog.info(.lifecycle, "lifecycle.deep_link", "Opened by a shared plan link", ["kind": "open", "target": "/p/{code}/{payload}/"])
            guard await join(code: shared.eventCode, via: "link") else { return }
            #if !APP_CLIP
            if let payload = shared.payload {
                pendingSharedPlan = PendingSharedPlan(eventCode: shared.eventCode, payload: payload, receivedAt: .now)
                // My plan shows it as a proposal ("Use This Plan" / "Merge with Mine").
                showPlanTab()
            }
            #endif
            return
        }
        guard let code = DeepLink.eventCode(from: url) else { return }
        AppLog.info(.lifecycle, "lifecycle.deep_link", "Opened by a join link", ["kind": "join", "target": "/join/{id}/"])
        await join(code: code, via: "link")
    }

    /// Looks up an event by code (QR codes, deep links) and joins it, leaving any
    /// current event first. Returns false if no live event matches.
    @discardableResult
    func join(code: String, via: String = "search") async -> Bool {
        if let current = currentEvent, current.eventCode.caseInsensitiveCompare(code) == .orderedSame {
            return true
        }
        let event: Event
        do {
            event = try await APIClient.shared.lookupEvent(query: code)
        } catch {
            AppLog.caught(error, .net, "lookup", level: .notice)
            return false
        }
        if let current = currentEvent, current.id != event.id {
            Task { _ = try? await APIClient.shared.leaveEvent(eventId: current.id, deviceId: self.deviceId) }
        }
        await joinEvent(event, via: via)
        return true
    }

    // MARK: - Push notifications

    /// Turns alert notifications on (asking for permission if needed) or off and tells the
    /// server (`subscribed`). The APNs token is registered either way (silent
    /// `content_updated` pushes need no permission). Returns false if permission was denied.
    @discardableResult
    func setNotificationsEnabled(_ enabled: Bool) async -> Bool {
        guard enabled else {
            notificationsEnabled = false
            liveFollowNeedsUpdate()
            await syncDevice()
            return true
        }
        let granted = await Self.requestNotificationAuthorization()
        AppLog.notice(.push, "push.permission", "Alert permission \(granted ? "granted" : "denied")",
                      ["status": .string(granted ? "granted" : "denied"), "asked": true])
        notificationsEnabled = granted
        registerForRemoteNotifications()
        // Reminders before hearted items follow the opt-in.
        liveFollowNeedsUpdate()
        await syncDevice()
        return granted
    }

    /// Called at every launch of the full app (AppDelegate), whatever the notification
    /// opt-in: silent `content_updated` pushes keep the event live without polling (API-007).
    func registerForRemoteNotifications() {
        guard !ScreenshotMode.isActive, !Self.isAppClip else { return }
        UIApplication.shared.registerForRemoteNotifications()
    }

    /// Stores a new APNs token and sends it to the server.
    func updatePushToken(_ token: String) {
        pushRegistrationFailed = false
        // Never the token itself.
        AppLog.info(.push, "push.token", "APNs token received", ["kind": "apns", "changed": .bool(token != pushToken), "length": .int(token.count)])
        guard !token.isEmpty, token != pushToken else { return }
        pushToken = token
        Task { await syncDevice() }
    }

    /// APNs registration failed: no silent pushes this launch, so poll more often.
    func pushRegistrationDidFail(_ error: Error? = nil) {
        pushRegistrationFailed = true
        let ns = error.map { $0 as NSError }
        AppLog.warning(.push, "push.token.failed", "APNs registration failed: polling every 60 s", [
            "error": .string(ns?.localizedDescription ?? "unknown"), "domain": .string(ns?.domain ?? ""), "code": .int(ns?.code ?? 0),
        ])
    }

    /// `POST devices/` with the current token (omitted while there is none) and the alert
    /// preference as `subscribed`. The server keeps the token even when `subscribed` is false.
    /// Also carries the Live Activity's push token (`live_activity_token`, API-011) until the
    /// server has it: the hex token, or `null` once the activity ended.
    func syncDevice() async {
        guard !ScreenshotMode.isActive else { return }
        let token = liveActivityToken
        let change: LiveActivityTokenChange = liveActivityTokenSynced ? .unchanged : (token.map { LiveActivityTokenChange.set($0) } ?? .clear)
        do {
            _ = try await APIClient.shared.registerDevice(
                deviceId: deviceId,
                pushToken: pushToken,
                subscribed: notificationsEnabled,
                liveActivityToken: change
            )
            if change != .unchanged, liveActivityToken == token { liveActivityTokenSynced = true }
            AppLog.info(.net, "net.device.registered", "Device registered", [
                "status": 200, "has_push_token": .bool(pushToken != nil), "subscribed": .bool(notificationsEnabled),
                "has_live_activity_token": .bool(liveActivityToken != nil),
            ])
            if change != .unchanged {
                AppLog.info(.live, "live.token", "Live Activity token sent", ["action": .string(token == nil ? "cleared" : "sent"), "status": 200])
            }
        } catch {
            // Retried with the next registration (launch, token change, Live Activity update).
            AppLog.caught(error, .push, "device_registration")
        }
    }

    /// A new Live Activity push token (hex), or nil when the activity ended: sent to the server.
    func setLiveActivityToken(_ hex: String?) {
        let token = APIClient.nonEmpty(hex)
        guard token != liveActivityToken || !liveActivityTokenSynced else { return }
        AppLog.info(.live, "live.token", token == nil ? "Live Activity token cleared" : "Live Activity token received",
                    ["action": .string(token == nil ? "cleared" : "received")])
        liveActivityToken = token
        liveActivityTokenSynced = false
        Task { await syncDevice() }
    }

    /// A push arrived. `content_updated` refetches the bundle (after a random 0–10 s delay)
    /// only when it announces a newer content_version; other pushes refetch right away, and
    /// an opened notification switches to the Notifications tab. Returns whether a refresh
    /// ran (for the background fetch result). The saved copy is on disk before this returns,
    /// so a background wake leaves fresh content for the next launch.
    @discardableResult
    func handlePush(_ payload: PushPayload, opened: Bool) async -> Bool {
        let received = ContinuousClock.now
        AppLog.info(.push, opened ? "push.opened" : "push.received", "Push \(payload.kindName)\(opened ? " opened" : "")", {
            var fields: LogFields = ["type": .string(payload.kindName)]
            if let version = payload.contentVersion { fields["content_version"] = .int(version) }
            if let id = payload.notificationId { fields["notification_id"] = .int(id) }
            fields["state"] = .string(UIApplication.shared.applicationState == .active ? "fg" : "bg")
            return fields
        }())
        guard let eventId = payload.eventId else {
            AppLog.warning(.push, "push.dropped", "Push without an event", ["type": .string(payload.kindName), "reason": "no_event"])
            return false
        }
        if opened, currentEvent == nil || currentEvent?.id == eventId {
            // Counted against the push's event, so a tap that cold-launches the app counts too.
            usage.record(.notificationOpen, detail: payload.notificationId.map { String($0) }, eventId: eventId)
        }
        if currentEvent == nil {
            // A silent push may wake the app in the background before any scene launched.
            await restoreSavedEventIfNeeded()
        }
        guard let current = currentEvent else {
            // Cold launch with nothing saved: the event is still being rejoined. Apply once it loads.
            if opened { pendingNotificationsEventId = eventId }
            return false
        }
        guard current.id == eventId else {
            AppLog.info(.push, "push.handled", "Push for another event", ["type": .string(payload.kindName), "action": "ignored_other_event"])
            return false
        }
        if opened, shows(.notifications) {
            presentedSheet = nil
            select(.notifications)
        }
        if payload.kind == .contentUpdated, !opened {
            guard ContentUpdatePolicy.shouldRefresh(pushedVersion: payload.contentVersion, currentVersion: contentVersion) else {
                AppLog.info(.push, "push.handled", "content_updated: already current", [
                    "type": .string(payload.kindName), "action": "skipped_not_newer",
                    "ms": .int((ContinuousClock.now - received).wholeMilliseconds),
                ])
                return false
            }
            let delay = ContentUpdatePolicy.jitter()
            try? await Task.sleep(for: delay)
            guard currentEvent?.id == eventId else { return false }
            await refreshBundle(silent: true, source: .push)
            let ms = (ContinuousClock.now - received).wholeMilliseconds
            PerfMetrics.shared.record(.perfPushRefreshDelay, detail: PerfBucket.pushRefreshDelay(ms: ms))
            await diskTask?.value
            AppLog.info(.push, "push.handled", "content_updated: refreshed in \(ms) ms", [
                "type": .string(payload.kindName), "action": "refreshed", "ms": .int(ms), "delay_ms": .int(delay.wholeMilliseconds),
            ])
            return true
        } else {
            await refreshBundle(source: .push)
        }
        await diskTask?.value
        AppLog.info(.push, "push.handled", "Push handled", [
            "type": .string(payload.kindName), "action": .string(opened ? "shown" : "refreshed"),
            "ms": .int((ContinuousClock.now - received).wholeMilliseconds),
        ])
        return true
    }

    // MARK: - Hearts (API-009 usage) and unread updates

    /// Loads the event's hearts and Updates mark when the event changes (nil clears them).
    private func loadPersonalState(for eventId: Int?) {
        guard personalEventId != eventId else { return }
        personalEventId = eventId
        walkingRoutes.clear()
        // Screenshot mode starts clean and never writes.
        guard let eventId, !ScreenshotMode.isActive,
              let data = UserDefaults.standard.data(forKey: Keys.personal(eventId)),
              let saved = try? JSONDecoder().decode(EventPersonalState.self, from: data) else {
            personal = EventPersonalState()
            loadPlan(for: eventId)
            return
        }
        personal = saved
        loadPlan(for: eventId)
    }

    private func loadPlan(for eventId: Int?) {
        #if !APP_CLIP
        planner.load(eventId: eventId)
        assistant.load(eventId: eventId)
        #endif
    }

    private func savePersonalState() {
        guard let eventId = personalEventId, !ScreenshotMode.isActive,
              let data = try? JSONEncoder().encode(personal) else { return }
        UserDefaults.standard.set(data, forKey: Keys.personal(eventId))
    }

    func isHearted(_ target: SearchTarget) -> Bool {
        personal.isHearted(target)
    }

    /// Hearts or unhearts a location or schedule item of the current event, counted as
    /// `location_heart` / `schedule_item_unheart` … with the item's id (API-009).
    func setHeart(_ hearted: Bool, for target: SearchTarget) {
        guard currentEvent != nil, let metric = personal.setHeart(hearted, for: target) else { return }
        savePersonalState()
        // The Live Activity follows hearts; reminders are for hearted items.
        liveFollowNeedsUpdate()
        switch target {
        case .location(let id), .scheduleItem(let id):
            track(metric, id: id)
        case .notification, .event:
            break
        }
    }

    func toggleHeart(_ target: SearchTarget) {
        setHeart(!isHearted(target), for: target)
    }

    var hasHearts: Bool { personal.hasHearts }

    /// The Updates tab's badge: updates sent since the tab was last seen (0 in screenshot mode).
    var unreadUpdatesCount: Int {
        guard !ScreenshotMode.isActive else { return 0 }
        return UpdatesInbox.unreadCount(notifications, seenAt: personal.updatesSeenAt)
    }

    /// The newest unread update (≤ 24 h old, not dismissed) for the banner above the other tabs.
    func latestUpdateBanner(now: Date = .now) -> AppNotification? {
        guard !ScreenshotMode.isActive, currentEvent != nil else { return nil }
        return UpdatesInbox.banner(
            notifications,
            seenAt: personal.updatesSeenAt,
            dismissedId: personal.dismissedUpdateBannerId,
            now: now
        )
    }

    /// The Updates list is on screen: everything in it counts as seen.
    func markUpdatesSeen() {
        guard currentEvent != nil else { return }
        let unread = UpdatesInbox.unreadCount(notifications, seenAt: personal.updatesSeenAt)
        guard unread > 0 || personal.updatesSeenAt == nil else { return }
        personal.updatesSeenAt = UpdatesInbox.seenMark(notifications, now: .now)
        savePersonalState()
    }

    func dismissLatestUpdate(_ notificationId: Int) {
        personal.dismissedUpdateBannerId = notificationId
        savePersonalState()
    }

    // MARK: - Urgent announcements (API-011)

    /// The newest urgent announcement (≤ 12 h old, not dismissed) for the prominent banner above
    /// the tabs and the Live Activity.
    func urgentBanner(now: Date = .now) -> AppNotification? {
        guard !ScreenshotMode.isActive, currentEvent != nil else { return nil }
        return UpdatesInbox.urgent(notifications, dismissed: personal.dismissedUrgentIds, now: now)
    }

    /// Dismisses an urgent announcement everywhere (banner, Live Activity, newest-update banner).
    func dismissUrgent(_ notificationId: Int) {
        guard currentEvent != nil else { return }
        personal.dismissedUrgentIds.insert(notificationId)
        personal.dismissedUpdateBannerId = notificationId
        savePersonalState()
        liveFollowNeedsUpdate()
    }

    // MARK: - Follow on Lock Screen (Live Activity), reminders, onboarding

    /// "Follow on Lock Screen" for this event (default: on once something is hearted or planned).
    var followsOnLockScreen: Bool {
        #if APP_CLIP
        return personal.followsOnLockScreen
        #else
        return personal.followOnLockScreen ?? (personal.hasHearts || planner.hasPlan)
        #endif
    }

    func setFollowOnLockScreen(_ on: Bool) {
        guard currentEvent != nil, personal.followOnLockScreen != on else { return }
        AppLog.notice(.live, "live.follow.changed", on ? "Follow on Lock Screen on" : "Follow on Lock Screen off", ["on": .bool(on), "default": false])
        personal.followOnLockScreen = on
        savePersonalState()
        liveFollowNeedsUpdate()
    }

    /// "Tell me when I arrive" (needs Always location; LiveFollowController asks).
    var notifiesOnArrival: Bool { personal.notifyOnArrival }

    func setNotifyOnArrival(_ on: Bool) {
        guard currentEvent != nil, personal.notifyOnArrival != on else { return }
        personal.notifyOnArrival = on
        savePersonalState()
        liveFollowNeedsUpdate()
    }

    /// "Skip" in the Live Activity: it moves on to the item after this one.
    func skipActivityItem(_ itemId: Int) {
        guard currentEvent != nil, personal.skippedItems.insert(itemId).inserted else { return }
        savePersonalState()
        liveFollowNeedsUpdate()
    }

    /// The venue arrival notification was sent for this event day.
    func markArrivalPrompted(_ day: Date) {
        personal.arrivalPromptDay = day
        savePersonalState()
    }

    /// The user's position changed (walk minutes in the Live Activity).
    func userLocationDidChange() {
        #if !APP_CLIP
        // Position samples for auto check-off and running late (only while already tracked).
        assistant.onLocation(userLocation.isAuthorized ? userLocation.location : nil)
        #endif
        liveFollowNeedsUpdate()
    }

    /// The scene became active: the Live Activity can start now (foreground only).
    func sceneDidBecomeActive() {
        liveFollowNeedsUpdate()
    }

    /// Shows the onboarding cards (first join, or Options → Tour).
    func showTour() {
        guard currentEvent != nil, !ScreenshotMode.isActive else { return }
        pendingTour = false
        presentedSheet = .tour
    }

    /// The onboarding cards were shown: not again automatically.
    func markTourSeen() {
        pendingTour = false
        UserDefaults.standard.set(true, forKey: Keys.onboardingSeen)
    }

    #if !APP_CLIP
    /// Links from the Live Activity and the app's notifications (`attnd-live://…`): an item's
    /// detail, the map at a location (with the walking route), Updates at a notification, or
    /// "follow" (start the Live Activity). Links for another event are ignored.
    func openLiveActivityLink(_ url: URL) async {
        guard let parsed = LiveActivityLink.parse(url) else { return }
        await restoreSavedEventIfNeeded()
        guard currentEvent?.id == parsed.eventId else { return }
        switch parsed.link {
        case .item(let id):
            navigate(to: .scheduleItem(id))
        case .map(let locationId):
            if shows(.map) {
                showOnMap(locationId: locationId)
            } else {
                navigate(to: .location(locationId))
            }
        case .updates(let id?):
            navigate(to: .notification(id))
        case .updates(nil):
            if shows(.notifications) {
                presentedSheet = nil
                select(.notifications)
            }
        case .follow:
            LiveFollowController.shared.followNow()
        case .plan:
            showMyPlan()
        }
    }
    #endif

    /// Live Activity, reminders and the venue monitor follow the content (full app only).
    private func liveFollowNeedsUpdate() {
        #if !APP_CLIP
        LiveFollowController.shared.setNeedsUpdate()
        #endif
    }

    // MARK: - Usage (API-005)

    /// Counts one anonymous usage event for the joined event. No-op when not in an event.
    /// Never pass identifying data or search text as `detail`.
    func track(_ metric: UsageMetric, detail: String? = nil) {
        // Screenshot runs don't count as usage.
        guard !ScreenshotMode.isActive else { return }
        guard let eventId = currentEvent?.id else { return }
        switch metric {
        case .locationView, .scheduleItemView:
            // Detail screens (tabs and sheets log themselves).
            let name = metric == .locationView ? "location" : "schedule_item"
            AppLog.debug(.ui, "ui.screen", "\(name) \(detail ?? "")", ["name": .string(name), "id": .string(detail ?? "")])
        case .locationHeart, .scheduleItemHeart, .locationUnheart, .scheduleItemUnheart, .refresh:
            let name = metric == .refresh ? "refresh" : (metric == .locationHeart || metric == .scheduleItemHeart ? "heart" : "unheart")
            AppLog.debug(.ui, "ui.action", name, ["name": .string(name), "id": .string(detail ?? "")])
        default:
            break
        }
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
    /// The joined event: waiting perf counts (API-014, `PerfMetrics`) go into its batches.
    var eventId: Int? {
        didSet { if eventId != nil, !PerfMetrics.shared.isEmpty { scheduleFlush() } }
    }
    private var drainsPerfMetrics = false
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

    /// The app's reporter (not the tests') also sends the perf counts.
    func attachPerfMetrics() {
        drainsPerfMetrics = true
        PerfMetrics.shared.setObserver { [weak self] in
            Task { @MainActor in
                guard let self, self.eventId != nil else { return }
                self.scheduleFlush()
            }
        }
    }

    /// Sends everything pending in the background. Safe to call often.
    func flush() {
        timer?.cancel()
        timer = nil
        // Perf counts made outside an event wait for the next one (or are dropped after 6 days).
        if drainsPerfMetrics, let eventId {
            for entry in PerfMetrics.shared.drain() {
                aggregator.record(entry.metric, detail: entry.detail, eventId: eventId, at: entry.at, count: entry.count)
            }
        }
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
                        AppLog.debug(.net, "net.usage.flushed", "Usage batch sent", ["entries": .int(chunk.count), "status": 200])
                    } catch {
                        AppLog.debug(.net, "net.usage.flushed", "Usage batch failed (retried once)", [
                            "entries": .int(chunk.count), "status": 0, "retry": .bool(false),
                        ])
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

// MARK: - Offline event copy (API-007)

/// The joined event's bundle on disk: `Application Support/attnd-event/event.json`, one
/// `SavedEvent` written atomically. Application Support (not Caches) because the system
/// may purge Caches under storage pressure, and the point is that the event still opens
/// with no signal at the venue; the directory is excluded from backups (it's re-downloadable).
/// The App Clip has its own container, which the system may purge; that's fine.
actor EventStore {
    static let shared = EventStore()

    private let fileURL: URL?

    init(directoryName: String = "attnd-event") {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        fileURL = base?.appendingPathComponent(directoryName, isDirectory: true)
            .appendingPathComponent("event.json")
    }

    /// The saved event and its decoded bundle, or nil (none, unreadable or another format).
    /// An unreadable file is deleted.
    func load() -> (SavedEvent, EventBundle)? {
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return nil }
        do {
            let saved = try SavedEvent.decode(data)
            return (saved, try saved.decodedBundle())
        } catch {
            AppLog.error(.storage, "storage.bundle.failed", "The saved event could not be read", {
                var fields = LogRedaction.errorFields(error)
                fields["op"] = "restore"
                fields["error"] = .string(String(describing: type(of: error)))
                return fields
            }())
            try? FileManager.default.removeItem(at: fileURL)
            return nil
        }
    }

    func save(_ saved: SavedEvent, contentVersion: Int? = nil) {
        guard let fileURL else { return }
        let started = ContinuousClock.now
        do {
            let data = try SavedEvent.encode(saved)
            let directory = fileURL.deletingLastPathComponent()
            StorageDirectory.prepare(directory)
            try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            let ms = (ContinuousClock.now - started).wholeMilliseconds
            AppLog.debug(.storage, "storage.bundle.saved", "Saved event written (\(data.count) bytes, \(ms) ms)",
                         ["bytes": .int(data.count), "ms": .int(ms), "content_version": .int(contentVersion ?? -1)])
        } catch {
            AppLog.error(.storage, "storage.bundle.failed", "The saved event could not be written", {
                var fields = LogRedaction.errorFields(error)
                fields["op"] = "save"
                fields["error"] = .string(String(describing: type(of: error)))
                return fields
            }())
        }
    }

    func delete() {
        guard let fileURL else { return }
        try? FileManager.default.removeItem(at: fileURL)
    }
}

/// Creates an Application Support subdirectory (once) and excludes it from backups.
enum StorageDirectory {
    static func prepare(_ directory: URL) {
        guard !FileManager.default.fileExists(atPath: directory.path) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var url = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }
}

// MARK: - Offline images (API-007)

/// Location images, the event logo and the flyer (image or PDF), on disk in
/// `Application Support/attnd-images/<sha256(url)>.<ext>` (see `MediaCache` for the rules).
/// Application Support for the same reason as `EventStore`: Caches can be purged right when
/// the attendee is offline at the venue. Excluded from backups; capped at 300 MB.
///
/// `sync` prefetches everything the current bundle references (4 downloads at a time), and
/// only after all of them were attempted deletes files the bundle no longer references. A
/// failed download keeps the old file. Views load through `data(for:)` (disk first, then the
/// network, stored for next time). `removeAll` (leave / switch) bumps a generation so
/// downloads that were already running never land in the emptied directory.
actor ImageStore {
    static let shared = ImageStore()

    private let directory: URL?
    private let session: URLSession
    private var generation = 0
    /// The newest prefetch; an older one skips pruning so it can't delete the newer set.
    private var latestSync: UUID?
    private var inflight: [URL: (id: UUID, task: Task<Bool, Never>)] = [:]
    /// URLs that turned out larger than `MediaCache.maxFileBytes`, not retried this session.
    private var tooLarge: Set<URL> = []

    init(directoryName: String = "attnd-images") {
        directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent(directoryName, isDirectory: true)
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 120
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: config)
    }

    private func fileURL(for url: URL) -> URL? {
        directory?.appendingPathComponent(MediaCache.fileName(for: url))
    }

    /// The cached bytes for `url`, without touching the network.
    func cachedData(for url: URL) -> Data? {
        guard let file = fileURL(for: url) else { return nil }
        return try? Data(contentsOf: file, options: .mappedIfSafe)
    }

    /// Disk first; otherwise downloads (and keeps) the file. nil when neither works or the
    /// file is too large to cache.
    func data(for url: URL) async -> Data? {
        if let data = cachedData(for: url) { return data }
        _ = await fetch(url)
        return cachedData(for: url)
    }

    /// Prefetches `urls`, then prunes. Returns false when something referenced could not be
    /// fetched (offline, server error), so the caller can try again later.
    func sync(_ urls: [URL]) async -> Bool {
        guard let directory else { return false }
        let token = UUID()
        latestSync = token
        let startGeneration = generation
        let files = Dictionary(listFiles().map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        let total = files.values.reduce(0) { $0 + $1.bytes }
        let now = Date.now
        let todo = urls.filter { url in
            !tooLarge.contains(url)
                && MediaCache.needsDownload(existing: files[MediaCache.fileName(for: url)], now: now)
        }
        var allFetched = true
        let started = ContinuousClock.now
        await withTaskGroup(of: Bool.self) { group in
            var running = 0
            for url in todo {
                guard !Task.isCancelled, generation == startGeneration else { break }
                let isNew = files[MediaCache.fileName(for: url)] == nil
                // Over budget: keep re-checking what we have, but don't add new files.
                // (The budget is checked against the size at the start; pruning below
                // enforces it exactly once the downloads are done.)
                if isNew, total >= MediaCache.maxTotalBytes { allFetched = false; continue }
                if running >= MediaCache.maxConcurrentDownloads {
                    if await group.next() == false { allFetched = false }
                    running -= 1
                }
                running += 1
                group.addTask { await self.fetch(url) }
            }
            for await ok in group where !ok { allFetched = false }
        }
        guard !Task.isCancelled, generation == startGeneration, latestSync == token else { return false }
        // Prune: unreferenced files, then the largest referenced ones while over budget.
        let referenced = Set(urls.map(MediaCache.fileName(for:)))
        for name in MediaCache.filesToDelete(listFiles(), referenced: referenced) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
        let missing = urls.contains { url in
            guard !tooLarge.contains(url), let file = fileURL(for: url) else { return false }
            return !FileManager.default.fileExists(atPath: file.path)
        }
        AppLog.debug(.storage, "storage.images.prefetch", "Images: \(urls.count) referenced, \(todo.count) fetched", [
            "total": .int(urls.count), "fetched": .int(todo.count), "failed": .int(allFetched && !missing ? 0 : 1),
            "ms": .int((ContinuousClock.now - started).wholeMilliseconds),
        ])
        return allFetched && !missing
    }

    /// Deletes every cached file (leave / switch events).
    func removeAll() {
        generation += 1
        latestSync = nil
        inflight = [:]
        tooLarge = []
        guard let directory else { return }
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: Downloads

    /// One download per URL at a time; prefetch and views share it.
    private func fetch(_ url: URL) async -> Bool {
        if let existing = inflight[url] { return await existing.task.value }
        let id = UUID()
        let startGeneration = generation
        let task = Task { await self.download(url, generation: startGeneration) }
        inflight[url] = (id, task)
        let ok = await task.value
        if inflight[url]?.id == id { inflight[url] = nil }
        return ok
    }

    private func download(_ url: URL, generation startGeneration: Int) async -> Bool {
        guard let directory, let destination = fileURL(for: url) else { return false }
        let temporary: URL
        let response: URLResponse
        do {
            (temporary, response) = try await session.download(from: url)
        } catch {
            AppLog.warning(.net, "net.image.failed", "Image download failed", [
                "error": .string((error as? URLError).map(LogRedaction.urlErrorKind) ?? "other"), "status": 0,
            ])
            return false
        }
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            AppLog.warning(.net, "net.image.failed", "Image download failed (\((response as? HTTPURLResponse)?.statusCode ?? 0))",
                           ["error": "http", "status": .int((response as? HTTPURLResponse)?.statusCode ?? 0)])
            return false
        }
        let bytes = (try? temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard bytes > 0 else { return false }
        guard bytes <= MediaCache.maxFileBytes else {
            tooLarge.insert(url)
            return false
        }
        // Left or switched events while downloading: don't repopulate the emptied cache.
        guard generation == startGeneration else { return false }
        StorageDirectory.prepare(directory)
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
            } else {
                try FileManager.default.moveItem(at: temporary, to: destination)
            }
            return true
        } catch {
            return false
        }
    }

    private func listFiles() -> [MediaCache.CachedFile] {
        guard let directory else { return [] }
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys)) ?? []
        return urls.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { return nil }
            return MediaCache.CachedFile(
                name: url.lastPathComponent,
                bytes: values.fileSize ?? 0,
                modified: values.contentModificationDate ?? .distantPast
            )
        }
    }
}

/// Decoded images in memory (NSCache is thread-safe), so lists scroll without re-decoding.
final class ImageMemoryCache: @unchecked Sendable {
    static let shared = ImageMemoryCache()

    private let cache = NSCache<NSURL, UIImage>()

    init() {
        cache.totalCostLimit = 96 * 1024 * 1024
    }

    func image(for url: URL) -> UIImage? {
        cache.object(forKey: url as NSURL)
    }

    func insert(_ image: UIImage, for url: URL) {
        let cost = image.cgImage.map { $0.bytesPerRow * $0.height } ?? 0
        cache.setObject(image, forKey: url as NSURL, cost: cost)
    }

    func removeAll() {
        cache.removeAllObjects()
    }
}
