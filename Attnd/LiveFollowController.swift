// LiveFollowController.swift
// Attnd (app + App Clip; not the widget extensions)
//
// "Follow on Lock Screen" (Live Activity, shared spec §8) and reminders before hearted items.
// The rules are in LiveFollowLogic.swift; this runs them.
//
// Live Activity (ActivityKit):
//   - Follows the user's plan (spec §6), else hearted items, else the event's own now / next, one activity per
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
//     `content_updated` push), hearts, location changes and the
//     activity's own buttons (LiveActivityIntents.swift).
//   - pushType `.token`: every token from `pushTokenUpdates` goes to `POST devices/` as
//     `live_activity_token` (API-011), and `null` when the activity ends, so the server can
//     put urgent announcements on the Lock Screen.
// Reminders: "Prairie Lights in 15 min · 8 min walk" before each hearted or planned item, only
//   with the notification opt-in, category `attnd.reminder`, rescheduled when hearts, the plan
//   or content change.
// No background app refresh and no venue arrival (both removed Nov 19, 2026: App Clips can't run
//   background tasks, and the app and the clip are the same): between foreground visits the
//   activity's timers tick on their own and silent pushes refresh it.
//
// Nothing here runs in screenshot mode.

import ActivityKit
import CoreLocation
import Foundation
import UIKit
import UserNotifications

/// Identifiers of the app's own local notifications.
enum LiveFollowKeys {
    static let reminderCategory = "attnd.reminder"
    static let followCategory = "attnd.follow"
    /// userInfo keys of the app's own local notifications (never `type` / `event_id`, so
    /// `PushPayload` ignores them).
    static let localKindKey = "attnd_local"
    static let localEventKey = "attnd_event"
    static let localItemKey = "attnd_item"
    static let localLocationKey = "attnd_location"
}

// ActivityKit's `Activity` is a final class Apple documents as safe to use from any thread, but the
// iOS 26/27 SDK doesn't mark it Sendable, so Swift 6 rejects awaiting its own `update`/`end` from the
// main actor ("sending 'activity' risks causing data races"). Remove this once the SDK declares it.
extension Activity: @retroactive @unchecked Sendable {}

@MainActor
final class LiveFollowController {

    static let shared = LiveFollowController()

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

    private init() {}

    // MARK: - Setup

    /// AppDelegate, at launch (also a background launch for a button tap).
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
    /// One instance (perf, batch 7: each `ActivityAuthorizationInfo()` cost ~4 ms on the main thread).
    var activitiesEnabled: Bool { Self.authorization.areActivitiesEnabled }
    private static let authorization = ActivityAuthorizationInfo()

    /// When following starts by itself today (2 h before the first followed item), for Options.
    func nextStart(now: Date = .now) -> Date? {
        guard let appState, let bundle = appState.currentBundle else { return nil }
        let inputs = LiveActivityPlanner.inputs(bundle.liveActivity, bundle: bundle, hearted: appState.personal.heartedScheduleItems,
                                                planned: appState.plannedItemIds, places: appState.followPlaces(bundle))
        let day = LiveActivityPlanner.followDay(
            schedule: inputs.schedule,
            hearted: inputs.hearted,
            planned: inputs.planned,
            places: inputs.places,
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

    /// Brings the activity, reminders and the "tap to follow" notification in line with the joined event. Safe in the background (it never starts an activity there).
    func update() async {
        guard let appState, !ScreenshotMode.isActive else { return }
        let activities = Activity<EventActivityAttributes>.activities
        for activity in activities {
            observe(activity)
        }
        // The full app is installed and took over (App Clip → app, AppHandover): the clip ends its
        // activities and reminders so only the app's own run.
        guard let bundle = appState.currentBundle, !AppHandover.clipSuperseded else {
            // Outside an event: nothing to follow.
            for activity in activities where Self.isRunning(activity) {
                await activity.end(nil, dismissalPolicy: .immediate)
                AppLog.notice(.live, "live.end", "Live Activity ended (no event)", ["reason": "left_event"])
            }
            await rescheduleReminders(nil)
            await setFollowPrompt(nil)
            return
        }

        let event = bundle.event
        let timeZone = event.timeZone
        let now = Date.now
        let personal = appState.personal
        let planned = appState.plannedItemIds
        let enabled = appState.followsOnLockScreen && activitiesEnabled && !event.isArchived
        // API-027: what the organizer chose the activity follows by default.
        let inputs = LiveActivityPlanner.inputs(bundle.liveActivity, bundle: bundle, hearted: personal.heartedScheduleItems,
                                                planned: planned, places: appState.followPlaces(bundle))
        let day = enabled
            ? LiveActivityPlanner.followDay(
                schedule: inputs.schedule,
                hearted: inputs.hearted,
                planned: inputs.planned,
                places: inputs.places,
                eventStart: event.startTime,
                now: now,
                timeZone: timeZone
            )
            : nil
        let forced = day.map { forcedDay?.eventId == event.id && forcedDay?.dayStart == $0.dayStart } ?? false
        let decision = LiveActivityPlanner.decision(for: day, now: now, timeZone: timeZone, forced: forced)
        let foreground = UIApplication.shared.applicationState == .active

        func state(at date: Date, existing: EventActivityAttributes.Urgent?, for day: FollowDay) -> EventActivityAttributes.ContentState {
            var content = baseState(at: date, existing: existing, for: day)
            // Running late for the next planned item (assistant spec §6): "Leave now".
            if day.followsPlan, let plan = appState.planner.plan, !plan.isEmpty,
               let late = LiveAssist.runningLate(plan, bundle, now: date, user: appState.userLocation.location,
                                                 skipped: personal.skippedItems),
               content.next?.id == late.itemId {
                content.leaveBy = late.leaveBy
                content.lateState = late.state == .leaveNow ? "leave_now" : "cant_make_it"
                content.walkMinutesToNext = late.walkMinutes
            }
            return content
        }

        func baseState(at date: Date, existing: EventActivityAttributes.Urgent?, for day: FollowDay) -> EventActivityAttributes.ContentState {
            var content = LiveActivityPlanner.content(
                day: day,
                locations: bundle.locations,
                hearted: personal.heartedScheduleItems,
                skipped: personal.skippedItems,
                // No direction, distance or walk from the user's position (batch 7, owner): the
                // activity can't refresh them between app visits, so they were stale on the Lock Screen.
                user: nil,
                urgent: LiveActivityPlanner.urgent(
                    notifications: bundle.notifications,
                    dismissed: personal.dismissedUrgentIds,
                    existing: existing,
                    now: date
                ),
                now: date
            )
            // API-027: the organizer's buttons and stale text.
            let settings = bundle.liveActivity ?? .defaults
            content.buttons = settings.buttons == nil ? nil : settings.activityButtons
            content.staleText = settings.staleText
            // Started on join (batch 7): until something is in My schedule, say how to fill it.
            if !personal.hasHearts, !appState.planner.hasPlan, content.dayComplete != true {
                content.hint = LiveActivityPlanner.emptyHint
            }
            return content
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
                        followsPlan: activity.content.state.followsPlan,
                        dayComplete: true
                    )
                    let calendar = EventTimeFormat.calendar(in: timeZone)
                    let dayItems = bundle.schedule.filter { item in
                        item.startTime.map { calendar.isDate($0, inSameDayAs: activity.attributes.dayStart) } ?? false
                    }
                    let followed = summary.followsPlan == true
                        ? dayItems.filter { planned.contains($0.id) }
                        : summary.followsHearts == true
                            ? dayItems.filter { personal.heartedScheduleItems.contains($0.id) }
                            : dayItems
                    summary.completedCount = followed.filter { ScheduleTiming.hasEnded($0, at: now) }.count
                    await end(activity, final: summary, dismissal: .after(now.addingTimeInterval(LiveActivityPlanner.summaryLinger)), reason: "day_over")
                } else {
                    await end(activity, final: nil, reason: enabled && activity.attributes.eventId == event.id ? "day_over" : "unfollowed")
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
            } else if live == nil, foreground, Self.lookChanged(activity, theme: appState.liveActivityTheme, accent: appState.liveActivityAccentHex) {
                // Attributes are fixed for an activity: a changed theme needs a new one (foreground only).
                await end(activity, final: nil, reason: "system")
            } else if live == nil {
                live = activity
            } else {
                await end(activity, final: nil)
            }
        }

        if let activity = live, let day {
            let content = state(at: now, existing: activity.content.state.urgent, for: day)
            if content.dayComplete == true {
                await end(activity, final: content, dismissal: .after(now.addingTimeInterval(LiveActivityPlanner.summaryLinger)), reason: "day_over")
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
            case .schedule(_) where foreground:
                // Batch 7 (owner): the activity starts as soon as someone joins (a way back into
                // the App Clip after a force quit), showing the day ahead until it begins.
                if let pending { await end(pending, final: nil) }
                start(day: day, bundle: bundle, state: state(at: now, existing: nil, for: day), at: nil)
                await setFollowPrompt(nil)
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
                // More than 36 h ahead: started now too while the app is open (batch 7).
                if foreground, now < day.endAt {
                    start(day: day, bundle: bundle, state: state(at: now, existing: nil, for: day), at: nil)
                }
                await setFollowPrompt(nil)
            }
        } else {
            await setFollowPrompt(nil)
        }
        if forcedDay != nil, forcedDay?.eventId != event.id || day == nil { forcedDay = nil }

        await rescheduleReminders(bundle)
    }

    /// The event's look changed since the activity started (theme or accent).
    private static func lookChanged(_ activity: Activity<EventActivityAttributes>,
                                    theme: EventActivityAttributes.ActivityTheme?, accent: String?) -> Bool {
        activity.attributes.theme != theme || activity.attributes.accentHex != accent
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
            accentHex: appState?.liveActivityAccentHex,
            timeZoneIdentifier: event.timeZone.identifier,
            dayStart: day.dayStart,
            theme: appState?.liveActivityTheme
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
                AppLog.notice(.live, "live.start", "Live Activity scheduled", Self.startFields(state, scheduled: true, items: day.items.count))
            } else {
                var withPush = true
                do {
                    activity = try Activity.request(attributes: attributes, content: content, pushType: .token)
                } catch {
                    // No push support (e.g. APNs unavailable): local updates only.
                    AppLog.caught(error, .live, "live_start_push", level: .notice)
                    withPush = false
                    activity = try Activity.request(attributes: attributes, content: content, pushType: nil)
                }
                AppLog.notice(.live, "live.start", "Live Activity started",
                              Self.startFields(state, scheduled: false, items: day.items.count).merging(["push": .bool(withPush)]) { _, new in new })
            }
        } catch {
            let reason = Self.startFailureReason(error)
            let ns = error as NSError
            AppLog.warning(.live, "live.start.failed", "Live Activity didn't start (\(reason))", [
                "reason": .string(reason), "domain": .string(ns.domain), "code": .int(ns.code), "scheduled": .bool(at != nil),
            ])
            PerfMetrics.shared.record(.perfLiveStartFail, detail: reason)
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
        AppLog.debug(.live, "live.update", "Live Activity updated", [
            "mode": .string(Self.mode(state)), "has_current": .bool(state.current != nil), "has_next": .bool(state.next != nil),
            "pending": .bool(activity.activityState == .pending),
        ])
    }

    private func end(
        _ activity: Activity<EventActivityAttributes>,
        final state: EventActivityAttributes.ContentState?,
        dismissal: ActivityUIDismissalPolicy = .immediate,
        reason: String = "unfollowed"
    ) async {
        lastContent[activity.id] = nil
        let content = state.map { ActivityContent(state: $0, staleDate: nil) }
        await activity.end(content, dismissalPolicy: dismissal)
        AppLog.notice(.live, "live.end", "Live Activity ended (\(reason))", ["reason": .string(reason), "summary": .bool(state != nil)])
        forgetScheduledStart(of: activity)
    }

    // MARK: Log fields (LOG_EVENTS.md)

    /// `live.start` / `live.update` mode: before, active, end_of_day or urgent.
    private static func mode(_ state: EventActivityAttributes.ContentState) -> String {
        if state.urgent != nil { return "urgent" }
        if state.dayComplete == true { return "end_of_day" }
        return state.current != nil ? "active" : "before"
    }

    private static func startFields(_ state: EventActivityAttributes.ContentState, scheduled: Bool, items: Int) -> LogFields {
        let source = state.followsPlan == true ? "plan" : (state.followsHearts == true ? "hearts" : "event")
        return ["mode": .string(mode(state)), "source": .string(source), "scheduled": .bool(scheduled), "items": .int(items)]
    }

    /// `live.start.failed` reason and the `perf_live_start_fail` detail: disabled (Live Activities
    /// turned off for Attnd), limit (too many activities) or error.
    private static func startFailureReason(_ error: Error) -> String {
        guard let error = error as? ActivityAuthorizationError else { return "error" }
        switch error {
        case .denied:                                         return "disabled"
        case .globalMaximumExceeded, .targetMaximumExceeded:  return "limit"
        default:                                              return "error"
        }
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
                    if state == .dismissed {
                        AppLog.notice(.live, "live.end", "Live Activity dismissed", ["reason": "user"])
                    }
                    self?.activityDidEnd(id)
                    break
                }
            }
        }
    }

    private func register(_ token: Data, for activityId: String) {
        AppLog.debug(.live, "live.token", "Live Activity push token", ["action": "received"])
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
        let name: String
        switch action {
        case .skip:          name = "skip"
        case .dismissUrgent: name = "dismiss_urgent"
        }
        AppLog.info(.live, "live.action", "Live Activity button: \(name)", ["action": .string(name)])
        switch action {
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
        } else if let locationId = info.locationId {
            appState.navigate(to: .location(locationId))
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
                // Hearted and planned items (spec §6), like Android.
                hearted: appState.personal.heartedScheduleItems.union(appState.plannedItemIds),
                locations: bundle.locations,
                user: appState.userLocation.location,
                now: .now,
                timeZone: bundle.event.timeZone,
                leadMinutes: Dictionary(
                    appState.mySchedule.entries.filter { $0.kind == .item && $0.reminder != nil }.map { ($0.id, $0.reminderMinutes) },
                    uniquingKeysWith: { a, _ in a }
                ),
                places: appState.mySchedule.entries.filter { $0.kind == .place && $0.at != nil }
            )
        }
        guard planned != lastReminders else { return }
        lastReminders = planned
        AppLog.debug(.live, "live.reminder.scheduled", "\(planned.count) reminders scheduled", ["count": .int(planned.count)])
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
            var info: [String: Any] = [LiveFollowKeys.localKindKey: LiveFollowKeys.reminderCategory, LiveFollowKeys.localEventKey: eventId]
            if let locationId = reminder.locationId {
                info[LiveFollowKeys.localLocationKey] = locationId
            } else {
                info[LiveFollowKeys.localItemKey] = reminder.itemId
            }
            content.userInfo = info
            let interval = max(1, reminder.fireDate.timeIntervalSinceNow)
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
            do {
                try await center.add(UNNotificationRequest(identifier: reminder.id, content: content, trigger: trigger))
            } catch {
                AppLog.caught(error, .live, "reminder_add")
            }
        }
    }

    struct FollowPrompt: Hashable, Sendable {
        var eventId: Int
        var itemId: Int?
        var title: String
        var body: String
        var at: Date
    }

    /// Schedules (or with nil removes) the "tap to follow on your Lock Screen" notification.
    private func setFollowPrompt(_ prompt: FollowPrompt?) async {
        if followPromptSynced {
            if let prompt, lastFollowPrompt?.eventId == prompt.eventId, lastFollowPrompt?.at == prompt.at { return }
            if prompt == nil, lastFollowPrompt == nil { return }
        }
        followPromptSynced = true
        lastFollowPrompt = prompt.map { (eventId: $0.eventId, at: $0.at) }
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
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, prompt.at.timeIntervalSinceNow), repeats: false)
        do {
            try await center.add(UNNotificationRequest(identifier: "attnd.follow.\(prompt.eventId)", content: content, trigger: trigger))
            AppLog.debug(.live, "live.wake.scheduled", "Tap-to-follow notification set", ["at": .string(ISODate.string(from: prompt.at)), "reason": "follow_prompt"])
        } catch {
            AppLog.caught(error, .live, "follow_prompt_add")
        }
    }

    nonisolated private static func allowsAlerts() async -> Bool {
        switch await UNUserNotificationCenter.current().notificationSettings().authorizationStatus {
        case .authorized, .provisional, .ephemeral: return true
        default: return false
        }
    }
}

/// The parts of one of the app's own notifications needed to act on a tap.
struct LocalNotificationInfo: Hashable, Sendable {
    var kind: String
    var eventId: Int
    var itemId: Int?
    /// A place entry's reminder (My schedule).
    var locationId: Int?

    init?(userInfo: [AnyHashable: Any]) {
        guard let kind = userInfo[LiveFollowKeys.localKindKey] as? String,
              let eventId = Self.int(userInfo[LiveFollowKeys.localEventKey]) else { return nil }
        self.kind = kind
        self.eventId = eventId
        itemId = Self.int(userInfo[LiveFollowKeys.localItemKey])
        locationId = Self.int(userInfo[LiveFollowKeys.localLocationKey])
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
