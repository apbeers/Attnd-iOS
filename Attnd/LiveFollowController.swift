// LiveFollowController.swift
// Attnd (app only: not the App Clip, not the widget extension)
//
// "Follow on Lock Screen" (Live Activity, shared spec §8), reminders before hearted items and
// the venue arrival notification. The rules are in LiveFollowLogic.swift; this runs them.
//
// Live Activity (ActivityKit):
//   - Follows the user's hearted items, else the event's own now / next, one activity per
//     event day (`EventActivityAttributes.dayStart`; ActivityKit ends an activity after 8 h,
//     so it is restarted each day).
//   - Starts by itself while the app is in the foreground, on an event day, from 2 h before
//     the first followed item (or the gates opening). Before that, while in the foreground,
//     it is scheduled with ActivityKit's scheduled start (iOS 26 `request(…start:)`: the
//     system starts it at that time even when the app is in the background, with an alert).
//     When that isn't possible (the app is in the background, or scheduling failed) a local
//     notification at that time says "Prairie Lights in 2 h · tap to follow on your Lock
//     Screen"; tapping it opens the app, which starts the activity. iOS doesn't let apps
//     start one from the background otherwise (only from a LiveActivityIntent or a push).
//   - Updated (never started) from the background too: a refreshed bundle (silent
//     `content_updated` push, background app refresh), hearts, location changes and the
//     activity's own buttons (LiveActivityIntents.swift).
//   - pushType `.token`: every token from `pushTokenUpdates` goes to `POST devices/` as
//     `live_activity_token` (API-011), and `null` when the activity ends, so the server can
//     put urgent announcements on the Lock Screen.
// Reminders: "Prairie Lights in 15 min · 8 min walk" before each hearted item, only with the
//   notification opt-in, category `attnd.reminder`, rescheduled when hearts or content change.
// Arrival: with "Tell me when I arrive" (Always location), a CLMonitor circle around the venue
//   sends the "tap to follow" notification once per event day.
// Background app refresh (`com.arcu.Attnd.refresh`, AttndApp `.backgroundTask`): refreshes the
//   bundle and the activity while one is running or reminders are pending.
//
// Nothing here runs in screenshot mode.

import ActivityKit
import BackgroundTasks
import CoreLocation
import Foundation
import UIKit
import UserNotifications

/// Identifiers of the background task and the app's own local notifications.
enum LiveFollowKeys {
    /// Background app refresh task (Info.plist BGTaskSchedulerPermittedIdentifiers).
    static let refreshTaskIdentifier = "com.arcu.Attnd.refresh"
    static let reminderCategory = "attnd.reminder"
    static let followCategory = "attnd.follow"
    /// userInfo keys of the app's own local notifications (never `type` / `event_id`, so
    /// `PushPayload` ignores them).
    static let localKindKey = "attnd_local"
    static let localEventKey = "attnd_event"
    static let localItemKey = "attnd_item"
}

@MainActor
final class LiveFollowController {

    static let shared = LiveFollowController()

    private static let monitorName = "attnd-venue"
    private static let monitoredKeyDefaults = "pref.venueMonitorKey"
    private static let scheduledStartsDefaults = "pref.liveActivity.scheduledStarts"

    private weak var appState: AppState?

    /// Activities whose push token and state we observe.
    private var observed: Set<String> = []
    /// The last content sent to each activity (skip identical updates).
    private var lastContent: [String: EventActivityAttributes.ContentState] = [:]
    /// The activity whose push token the server has (cleared with null when it ends).
    private var registeredActivityId: String?
    /// The user asked to follow now (Options, the "tap to follow" notification): skips the 2 h lead.
    private var forcedDay: (eventId: Int, dayStart: Date)?
    private var pendingUpdate: Task<Void, Never>?
    private var lastReminders: [PlannedReminder]?
    /// The scheduled "tap to follow" notification (event, time), to avoid re-adding it.
    private var lastFollowPrompt: (eventId: Int, at: Date)?
    /// False until the pending "tap to follow" notification was set once this launch.
    private var followPromptSynced = false
    private var monitor: CLMonitor?
    private var monitorTask: Task<Void, Never>?
    private var serviceSession: CLServiceSession?
    private let locationManager = CLLocationManager()

    private init() {}

    // MARK: - Setup

    /// AppDelegate, at launch (also a background launch for a region event or a button tap).
    func install(appState: AppState) {
        self.appState = appState
        guard !ScreenshotMode.isActive else { return }
        LiveActivityActionRelay.handler = { [weak self] action in
            await self?.handle(action)
        }
        UNUserNotificationCenter.current().setNotificationCategories([
            UNNotificationCategory(identifier: LiveFollowKeys.reminderCategory, actions: [], intentIdentifiers: [], options: []),
            UNNotificationCategory(identifier: LiveFollowKeys.followCategory, actions: [], intentIdentifiers: [], options: []),
        ])
        for activity in Activity<EventActivityAttributes>.activities {
            observe(activity)
        }
        resumeVenueMonitor()
    }

    /// Something changed (bundle, hearts, settings, scene, location): update soon, coalesced.
    func setNeedsUpdate() {
        guard !ScreenshotMode.isActive, appState != nil else { return }
        pendingUpdate?.cancel()
        pendingUpdate = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await self?.update()
        }
    }

    /// "Start now" in Options: follow today even before the 2 h lead.
    func followNow() {
        guard let appState, let event = appState.currentEvent else { return }
        let calendar = EventTimeFormat.calendar(in: event.timeZone)
        forcedDay = (event.id, calendar.startOfDay(for: .now))
        setNeedsUpdate()
    }

    /// Whether a Live Activity for the joined event is on the Lock Screen (or scheduled).
    var isFollowing: Bool {
        guard let eventId = appState?.currentEvent?.id else { return false }
        return Activity<EventActivityAttributes>.activities.contains { $0.attributes.eventId == eventId && Self.isRunning($0) }
    }

    /// Live Activities are allowed for the app (Settings → Attnd → Live Activities).
    var activitiesEnabled: Bool { ActivityAuthorizationInfo().areActivitiesEnabled }

    /// When following starts by itself today (2 h before the first followed item), for Options.
    func nextStart(now: Date = .now) -> Date? {
        guard let appState, let bundle = appState.currentBundle else { return nil }
        let day = LiveActivityPlanner.followDay(
            schedule: bundle.schedule,
            hearted: appState.personal.heartedScheduleItems,
            eventStart: bundle.event.startTime,
            now: now,
            timeZone: bundle.event.timeZone
        )
        if case .schedule(let at) = LiveActivityPlanner.decision(for: day, now: now, timeZone: bundle.event.timeZone) {
            return at
        }
        return nil
    }

    // MARK: - Update

    /// Brings the activity, reminders, the "tap to follow" notification and the venue monitor
    /// in line with the joined event. Safe in the background (it never starts an activity there).
    func update() async {
        guard let appState, !ScreenshotMode.isActive else { return }
        let activities = Activity<EventActivityAttributes>.activities
        for activity in activities {
            observe(activity)
        }
        guard let bundle = appState.currentBundle else {
            // Outside an event: nothing to follow.
            for activity in activities where Self.isRunning(activity) {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
            await rescheduleReminders(nil)
            await setFollowPrompt(nil)
            updateVenueMonitor(nil)
            return
        }

        let event = bundle.event
        let timeZone = event.timeZone
        let now = Date.now
        let personal = appState.personal
        let enabled = personal.followsOnLockScreen && activitiesEnabled && !event.isArchived
        let day = enabled
            ? LiveActivityPlanner.followDay(
                schedule: bundle.schedule,
                hearted: personal.heartedScheduleItems,
                eventStart: event.startTime,
                now: now,
                timeZone: timeZone
            )
            : nil
        let forced = day.map { forcedDay?.eventId == event.id && forcedDay?.dayStart == $0.dayStart } ?? false
        let decision = LiveActivityPlanner.decision(for: day, now: now, timeZone: timeZone, forced: forced)
        let foreground = UIApplication.shared.applicationState == .active

        func state(at date: Date, existing: EventActivityAttributes.Urgent?, for day: FollowDay) -> EventActivityAttributes.ContentState {
            LiveActivityPlanner.content(
                day: day,
                locations: bundle.locations,
                hearted: personal.heartedScheduleItems,
                skipped: personal.skippedItems,
                user: appState.userLocation.location,
                urgent: LiveActivityPlanner.urgent(
                    notifications: bundle.notifications,
                    dismissed: personal.dismissedUrgentIds,
                    existing: existing,
                    now: date
                ),
                now: date
            )
        }

        // Existing activities: keep one for the followed day, end the rest.
        var live: Activity<EventActivityAttributes>?
        var pending: Activity<EventActivityAttributes>?
        for activity in activities where Self.isRunning(activity) {
            guard let day, activity.attributes.eventId == event.id, activity.attributes.dayStart == day.dayStart else {
                // The day it followed is over (the followed day moved on): the end-of-day summary
                // for a while when that was today. Another event or following off: gone now.
                let sameEvent = enabled && activity.attributes.eventId == event.id && activity.activityState != .pending
                if sameEvent, EventTimeFormat.calendar(in: timeZone).isDate(activity.attributes.dayStart, inSameDayAs: now) {
                    var summary = EventActivityAttributes.ContentState(
                        urgent: activity.content.state.urgent,
                        followsHearts: activity.content.state.followsHearts,
                        dayComplete: true
                    )
                    let calendar = EventTimeFormat.calendar(in: timeZone)
                    let dayItems = bundle.schedule.filter { item in
                        item.startTime.map { calendar.isDate($0, inSameDayAs: activity.attributes.dayStart) } ?? false
                    }
                    let followed = summary.followsHearts == true
                        ? dayItems.filter { personal.heartedScheduleItems.contains($0.id) }
                        : dayItems
                    summary.completedCount = followed.filter { ScheduleTiming.hasEnded($0, at: now) }.count
                    await end(activity, final: summary, dismissal: .after(now.addingTimeInterval(LiveActivityPlanner.summaryLinger)))
                } else {
                    await end(activity, final: nil)
                }
                continue
            }
            if activity.activityState == .pending {
                // Scheduled for a start that no longer fits (hearts or the schedule changed), or
                // it should start right now: replace it.
                let scheduled = scheduledStart(of: activity)
                let fits: Bool
                if case .schedule(let at) = decision, let scheduled { fits = abs(scheduled.timeIntervalSince(at)) < 10 * 60 } else { fits = false }
                if pending == nil, fits {
                    pending = activity
                } else if pending == nil, decision == .startNow, !foreground {
                    // Can't start now from the background: let the scheduled one stand.
                    pending = activity
                } else {
                    await end(activity, final: nil)
                }
            } else if live == nil {
                live = activity
            } else {
                await end(activity, final: nil)
            }
        }

        if let activity = live, let day {
            let content = state(at: now, existing: activity.content.state.urgent, for: day)
            if content.dayComplete == true {
                await end(activity, final: content, dismissal: .after(now.addingTimeInterval(LiveActivityPlanner.summaryLinger)))
            } else {
                await send(content, to: activity, now: now)
            }
            await setFollowPrompt(nil)
        } else if let day {
            switch decision {
            case .startNow:
                if foreground {
                    if let pending { await end(pending, final: nil) }
                    start(day: day, bundle: bundle, state: state(at: now, existing: nil, for: day), at: nil)
                    await setFollowPrompt(nil)
                }
            case .schedule(let at):
                if let pending {
                    await send(state(at: at, existing: pending.content.state.urgent, for: day), to: pending, now: now)
                    await setFollowPrompt(nil)
                } else if foreground, start(day: day, bundle: bundle, state: state(at: at, existing: nil, for: day), at: at) {
                    await setFollowPrompt(nil)
                } else {
                    // The notification approach: "… tap to follow on your Lock Screen" at that time.
                    await setFollowPrompt(FollowPrompt(
                        eventId: event.id,
                        itemId: day.items.first?.id,
                        title: event.name,
                        body: FollowPromptText.body(day: day, at: at, timeZone: timeZone),
                        at: at
                    ))
                }
            case .nothing:
                await setFollowPrompt(nil)
            }
        } else {
            await setFollowPrompt(nil)
        }
        if forcedDay != nil, forcedDay?.eventId != event.id || day == nil { forcedDay = nil }

        await rescheduleReminders(bundle)
        updateVenueMonitor(bundle)
        scheduleBackgroundRefresh()
    }

    private static func isRunning(_ activity: Activity<EventActivityAttributes>) -> Bool {
        switch activity.activityState {
        case .active, .stale, .pending: return true
        case .ended, .dismissed:        return false
        @unknown default:               return false
        }
    }

    /// Starts (or, with `at`, schedules) the activity. Returns whether ActivityKit accepted it.
    @discardableResult
    private func start(day: FollowDay, bundle: EventBundle, state: EventActivityAttributes.ContentState, at: Date?) -> Bool {
        // Nothing left to show (everything skipped): don't start one just to end it.
        guard state.dayComplete != true else { return false }
        let event = bundle.event
        let attributes = EventActivityAttributes(
            eventId: event.id,
            eventName: event.name,
            accentHex: appState?.accentHex,
            timeZoneIdentifier: event.timeZone.identifier,
            dayStart: day.dayStart
        )
        let now = at ?? .now
        let content = ActivityContent(
            state: state,
            staleDate: LiveActivityPlanner.staleDate(state, now: now),
            relevanceScore: state.urgent != nil ? 100 : 50
        )
        let activity: Activity<EventActivityAttributes>
        do {
            if let at {
                // iOS 26: the system starts it at `at`, also while the app is in the background,
                // and alerts the user.
                let headline = FollowPromptText.headline(day: day, at: at, timeZone: event.timeZone)
                let alert = AlertConfiguration(
                    title: "\(event.name)",
                    body: "\(headline) · now on your Lock Screen",
                    sound: .default
                )
                activity = try Activity.request(
                    attributes: attributes, content: content, pushType: .token,
                    style: .standard, alertConfiguration: alert, start: at
                )
                rememberScheduledStart(at, of: activity)
            } else {
                do {
                    activity = try Activity.request(attributes: attributes, content: content, pushType: .token)
                } catch {
                    // No push support (e.g. APNs unavailable): local updates only.
                    activity = try Activity.request(attributes: attributes, content: content, pushType: nil)
                }
            }
        } catch {
            return false
        }
        lastContent[activity.id] = state
        observe(activity)
        if at == nil, forcedDay?.eventId == event.id { forcedDay = nil }
        return true
    }

    private func send(_ state: EventActivityAttributes.ContentState, to activity: Activity<EventActivityAttributes>, now: Date) async {
        guard lastContent[activity.id] != state else { return }
        let previousUrgentId = activity.content.state.urgent?.id
        lastContent[activity.id] = state
        let content = ActivityContent(
            state: state,
            staleDate: LiveActivityPlanner.staleDate(state, now: now),
            relevanceScore: state.urgent != nil ? 100 : 50
        )
        if let urgent = state.urgent, urgent.id != previousUrgentId, activity.activityState != .pending {
            // A new urgent announcement lights up the screen / expands the Dynamic Island
            // (unless the server's push already put it there).
            let alert = AlertConfiguration(
                title: "\(urgent.title ?? "Urgent update")",
                body: "\(urgent.body ?? "")",
                sound: .default
            )
            await activity.update(content, alertConfiguration: alert)
        } else {
            await activity.update(content)
        }
    }

    private func end(
        _ activity: Activity<EventActivityAttributes>,
        final state: EventActivityAttributes.ContentState?,
        dismissal: ActivityUIDismissalPolicy = .immediate
    ) async {
        lastContent[activity.id] = nil
        let content = state.map { ActivityContent(state: $0, staleDate: nil) }
        await activity.end(content, dismissalPolicy: dismissal)
        forgetScheduledStart(of: activity)
    }

    // MARK: Push tokens (API-011)

    private func observe(_ activity: Activity<EventActivityAttributes>) {
        guard !observed.contains(activity.id) else { return }
        observed.insert(activity.id)
        let id = activity.id
        if let token = activity.pushToken, Self.isRunning(activity) {
            register(token, for: id)
        }
        Task { [weak self] in
            for await token in activity.pushTokenUpdates {
                self?.register(token, for: id)
            }
        }
        Task { [weak self] in
            for await state in activity.activityStateUpdates {
                if state == .ended || state == .dismissed {
                    self?.activityDidEnd(id)
                    break
                }
            }
        }
    }

    private func register(_ token: Data, for activityId: String) {
        registeredActivityId = activityId
        appState?.setLiveActivityToken(token.map { String(format: "%02x", $0) }.joined())
    }

    private func activityDidEnd(_ activityId: String) {
        lastContent[activityId] = nil
        observed.remove(activityId)
        guard registeredActivityId == activityId else { return }
        registeredActivityId = nil
        appState?.setLiveActivityToken(nil)
    }

    // MARK: Scheduled starts (remembered so a changed start time replaces the pending one)

    private func scheduledStart(of activity: Activity<EventActivityAttributes>) -> Date? {
        let starts = UserDefaults.standard.dictionary(forKey: Self.scheduledStartsDefaults) as? [String: Double]
        return starts?[activity.id].map(Date.init(timeIntervalSince1970:))
    }

    private func rememberScheduledStart(_ date: Date, of activity: Activity<EventActivityAttributes>) {
        var starts = UserDefaults.standard.dictionary(forKey: Self.scheduledStartsDefaults) as? [String: Double] ?? [:]
        starts[activity.id] = date.timeIntervalSince1970
        UserDefaults.standard.set(starts, forKey: Self.scheduledStartsDefaults)
    }

    private func forgetScheduledStart(of activity: Activity<EventActivityAttributes>) {
        guard var starts = UserDefaults.standard.dictionary(forKey: Self.scheduledStartsDefaults) as? [String: Double],
              starts[activity.id] != nil else { return }
        starts[activity.id] = nil
        UserDefaults.standard.set(starts, forKey: Self.scheduledStartsDefaults)
    }

    // MARK: - Buttons (LiveActivityIntents.swift; the system runs them in this process)

    private func handle(_ action: LiveActivityAction) async {
        guard let appState else { return }
        await appState.restoreSavedEventIfNeeded()
        switch action {
        case .heart(let eventId, let itemId):
            guard appState.currentEvent?.id == eventId else { return }
            appState.setHeart(true, for: .scheduleItem(itemId))
        case .skip(let eventId, let itemId):
            guard appState.currentEvent?.id == eventId else { return }
            appState.skipActivityItem(itemId)
        case .dismissUrgent(let eventId, let notificationId):
            guard appState.currentEvent?.id == eventId else { return }
            appState.dismissUrgent(notificationId)
        }
        pendingUpdate?.cancel()
        await update()
    }

    // MARK: - Local notifications (reminders, "tap to follow")

    /// A tap on one of the app's own notifications. Returns false for anything else (pushes).
    func handleNotificationTap(_ info: LocalNotificationInfo) async -> Bool {
        guard let appState else { return false }
        await appState.restoreSavedEventIfNeeded()
        guard appState.currentEvent?.id == info.eventId else { return true }
        if info.kind == LiveFollowKeys.followCategory, let event = appState.currentEvent {
            // Started once the scene is active (ActivityKit needs the foreground).
            forcedDay = (event.id, EventTimeFormat.calendar(in: event.timeZone).startOfDay(for: .now))
            lastFollowPrompt = nil
        }
        if let itemId = info.itemId {
            appState.navigate(to: .scheduleItem(itemId))
        }
        setNeedsUpdate()
        return true
    }

    private func rescheduleReminders(_ bundle: EventBundle?) async {
        guard let appState else { return }
        var planned: [PlannedReminder] = []
        if let bundle, appState.notificationsEnabled, !bundle.event.isArchived {
            planned = ReminderPlanner.reminders(
                eventId: bundle.event.id,
                schedule: bundle.schedule,
                hearted: appState.personal.heartedScheduleItems,
                locations: bundle.locations,
                user: appState.userLocation.location,
                now: .now,
                timeZone: bundle.event.timeZone
            )
        }
        guard planned != lastReminders else { return }
        lastReminders = planned
        await Self.replaceReminders(planned, eventId: bundle?.event.id)
    }

    nonisolated private static func replaceReminders(_ planned: [PlannedReminder], eventId: Int?) async {
        let center = UNUserNotificationCenter.current()
        let old = await center.pendingNotificationRequests()
            .map(\.identifier)
            .filter { $0.hasPrefix(ReminderPlanner.idPrefix) }
        if !old.isEmpty { center.removePendingNotificationRequests(withIdentifiers: old) }
        guard let eventId, !planned.isEmpty, await allowsAlerts() else { return }
        for reminder in planned {
            let content = UNMutableNotificationContent()
            content.title = reminder.title
            content.body = reminder.body
            content.sound = .default
            content.categoryIdentifier = LiveFollowKeys.reminderCategory
            content.threadIdentifier = "attnd.reminders.\(eventId)"
            // The user asked for it by hearting the item.
            content.interruptionLevel = .timeSensitive
            content.userInfo = [LiveFollowKeys.localKindKey: LiveFollowKeys.reminderCategory, LiveFollowKeys.localEventKey: eventId, LiveFollowKeys.localItemKey: reminder.itemId]
            let interval = max(1, reminder.fireDate.timeIntervalSinceNow)
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
            try? await center.add(UNNotificationRequest(identifier: reminder.id, content: content, trigger: trigger))
        }
    }

    struct FollowPrompt: Hashable, Sendable {
        var eventId: Int
        var itemId: Int?
        var title: String
        var body: String
        /// nil: now (arrival).
        var at: Date?
    }

    /// Schedules (or with nil removes) the "tap to follow on your Lock Screen" notification.
    private func setFollowPrompt(_ prompt: FollowPrompt?) async {
        if followPromptSynced {
            if let prompt, let at = prompt.at, lastFollowPrompt?.eventId == prompt.eventId, lastFollowPrompt?.at == at { return }
            if prompt == nil, lastFollowPrompt == nil { return }
        }
        followPromptSynced = true
        if let prompt, let at = prompt.at {
            lastFollowPrompt = (prompt.eventId, at)
        } else {
            lastFollowPrompt = nil
        }
        await Self.postFollowPrompt(prompt)
    }

    nonisolated private static func postFollowPrompt(_ prompt: FollowPrompt?) async {
        let center = UNUserNotificationCenter.current()
        let old = await center.pendingNotificationRequests()
            .map(\.identifier)
            .filter { $0.hasPrefix("attnd.follow.") }
        if !old.isEmpty { center.removePendingNotificationRequests(withIdentifiers: old) }
        guard let prompt, await allowsAlerts() else { return }
        let content = UNMutableNotificationContent()
        content.title = prompt.title
        content.body = prompt.body
        content.sound = .default
        content.categoryIdentifier = LiveFollowKeys.followCategory
        content.threadIdentifier = "attnd.follow.\(prompt.eventId)"
        var info: [String: Any] = [LiveFollowKeys.localKindKey: LiveFollowKeys.followCategory, LiveFollowKeys.localEventKey: prompt.eventId]
        if let itemId = prompt.itemId { info[LiveFollowKeys.localItemKey] = itemId }
        content.userInfo = info
        let trigger = prompt.at.map { at in
            UNTimeIntervalNotificationTrigger(timeInterval: max(1, at.timeIntervalSinceNow), repeats: false)
        }
        try? await center.add(UNNotificationRequest(identifier: "attnd.follow.\(prompt.eventId)", content: content, trigger: trigger))
    }

    nonisolated private static func allowsAlerts() async -> Bool {
        switch await UNUserNotificationCenter.current().notificationSettings().authorizationStatus {
        case .authorized, .provisional, .ephemeral: return true
        default: return false
        }
    }

    // MARK: - Venue arrival (CLMonitor)

    /// "Tell me when I arrive" needs Always location; this asks for the upgrade.
    func requestAlwaysLocation() {
        locationManager.requestAlwaysAuthorization()
    }

    var hasAlwaysLocation: Bool { locationManager.authorizationStatus == .authorizedAlways }

    /// At launch (possibly in the background for a region event): reopen the monitor so its
    /// events are delivered, and hold the Always session it needs.
    private func resumeVenueMonitor() {
        guard UserDefaults.standard.string(forKey: Self.monitoredKeyDefaults) != nil, hasAlwaysLocation else { return }
        serviceSession = CLServiceSession(authorization: .always)
        Task { await self.openMonitor() }
    }

    private func openMonitor() async {
        guard monitor == nil else { return }
        let monitor = await CLMonitor(Self.monitorName)
        self.monitor = monitor
        monitorTask = Task { [weak self] in
            do {
                for try await event in await monitor.events {
                    let identifier = event.identifier
                    let satisfied = event.state == .satisfied
                    await self?.venueEvent(identifier: identifier, satisfied: satisfied)
                }
            } catch {
                // The monitor stopped; it is reopened at the next launch.
            }
        }
    }

    private func updateVenueMonitor(_ bundle: EventBundle?) {
        var wanted: (key: String, region: VenueRegion)?
        if let bundle, let appState, appState.personal.notifyOnArrival, appState.personal.followsOnLockScreen,
           hasAlwaysLocation, !bundle.event.isArchived,
           (bundle.event.endTime ?? .distantFuture) > .now,
           let region = VenueRegion.make(event: bundle.event.coordinate, locations: bundle.locations) {
            let center = String(format: "%.5f,%.5f", region.center.latitude, region.center.longitude)
            let key = "venue-\(bundle.event.id)-\(center)-\(Int(region.radius.rounded()))"
            wanted = (key, region)
        }
        let current = UserDefaults.standard.string(forKey: Self.monitoredKeyDefaults)
        guard wanted?.key != current || (wanted != nil && monitor == nil) else { return }
        UserDefaults.standard.set(wanted?.key, forKey: Self.monitoredKeyDefaults)
        serviceSession = wanted == nil ? nil : (serviceSession ?? CLServiceSession(authorization: .always))
        Task { await self.configureMonitor(wanted) }
    }

    private func configureMonitor(_ wanted: (key: String, region: VenueRegion)?) async {
        if wanted == nil, monitor == nil { return }
        await openMonitor()
        guard let monitor else { return }
        let existing = await monitor.identifiers
        if let wanted, existing == [wanted.key] { return }
        for identifier in existing {
            await monitor.remove(identifier)
        }
        guard let wanted else { return }
        let condition = CLMonitor.CircularGeographicCondition(
            center: CLLocationCoordinate2D(latitude: wanted.region.center.latitude, longitude: wanted.region.center.longitude),
            radius: wanted.region.radius
        )
        await monitor.add(condition, identifier: wanted.key, assuming: .unsatisfied)
    }

    /// Arrived at the venue: "… tap to follow on your Lock Screen", once per event day, unless
    /// the activity is already running (in the foreground it simply starts).
    private func venueEvent(identifier: String, satisfied: Bool) async {
        guard satisfied, let appState else { return }
        await appState.restoreSavedEventIfNeeded()
        guard let bundle = appState.currentBundle,
              identifier.hasPrefix("venue-\(bundle.event.id)-"),
              appState.personal.followsOnLockScreen else { return }
        let event = bundle.event
        let now = Date.now
        let today = EventTimeFormat.calendar(in: event.timeZone).startOfDay(for: now)
        guard ScheduleTiming.isEventDay(now: now, start: event.startTime, end: event.endTime, timeZone: event.timeZone),
              appState.personal.arrivalPromptDay != today, !isFollowing else { return }
        appState.markArrivalPrompted(today)
        forcedDay = (event.id, today)
        if UIApplication.shared.applicationState == .active {
            await update()
            return
        }
        guard let day = LiveActivityPlanner.followDay(
            schedule: bundle.schedule,
            hearted: appState.personal.heartedScheduleItems,
            eventStart: event.startTime,
            now: now,
            timeZone: event.timeZone
        ), EventTimeFormat.calendar(in: event.timeZone).isDate(day.dayStart, inSameDayAs: now) else { return }
        lastFollowPrompt = nil
        await Self.postFollowPrompt(FollowPrompt(
            eventId: event.id,
            itemId: day.items.first { !ScheduleTiming.hasEnded($0, at: now) }?.id,
            title: "Welcome to \(event.name)",
            body: FollowPromptText.body(day: day, at: now, timeZone: event.timeZone),
            at: nil
        ))
    }

    // MARK: - Background app refresh

    /// AttndApp's `.backgroundTask(.appRefresh(…))`: fresh content for the activity and reminders.
    static func performBackgroundRefresh() async {
        guard let appState = shared.appState, !ScreenshotMode.isActive else { return }
        await appState.restoreSavedEventIfNeeded()
        await appState.refreshBundle(silent: true)
        shared.pendingUpdate?.cancel()
        await shared.update()
    }

    /// Asks for a background refresh in ~15 min while something on the Lock Screen depends on it.
    private func scheduleBackgroundRefresh() {
        let needed = isFollowing || !(lastReminders ?? []).isEmpty
        guard needed else {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: LiveFollowKeys.refreshTaskIdentifier)
            return
        }
        let request = BGAppRefreshTaskRequest(identifier: LiveFollowKeys.refreshTaskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        // Fails in the simulator and when background refresh is off; nothing else to do then.
        try? BGTaskScheduler.shared.submit(request)
    }
}

/// The parts of one of the app's own notifications needed to act on a tap.
struct LocalNotificationInfo: Hashable, Sendable {
    var kind: String
    var eventId: Int
    var itemId: Int?

    init?(userInfo: [AnyHashable: Any]) {
        guard let kind = userInfo[LiveFollowKeys.localKindKey] as? String,
              let eventId = Self.int(userInfo[LiveFollowKeys.localEventKey]) else { return nil }
        self.kind = kind
        self.eventId = eventId
        itemId = Self.int(userInfo[LiveFollowKeys.localItemKey])
    }

    private static func int(_ value: Any?) -> Int? {
        switch value {
        case let n as Int:      return n
        case let n as NSNumber: return n.intValue
        case let s as String:   return Int(s)
        default:                return nil
        }
    }
}
