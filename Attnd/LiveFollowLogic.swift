// LiveFollowLogic.swift
// Attnd (app only; unit tested in LiveFollowTests)
//
// Pure rules behind "Follow on Lock Screen" (Live Activity, shared spec §8), heart reminders
// and the venue region. LiveFollowController runs them; nothing here touches ActivityKit's
// runtime, UserNotifications or Core Location.
//
//   - FollowDay / LiveActivityPlanner.followDay: which day to follow (today while something
//     is left, else the next event day), what it follows (the plan's items, else hearted items,
//     else the event's own schedule) and when the activity starts (2 h before the first item
//     or the gates opening).
//   - LiveActivityPlanner.content: current / next / after, walk minutes, urgent block,
//     "gates open", end-of-day summary; staleDate.
//   - LiveActivityPlanner.decision: start now, schedule for later, or nothing.
//   - ReminderPlanner: "Prairie Lights in 15 min · 8 min walk" before hearted and planned items.
//   - FollowPromptText: the "tap to follow on your Lock Screen" notification.
//   - VenueRegion: the circle around the venue for arrival.

import Foundation

// MARK: - The followed day

struct FollowDay: Hashable, Sendable {
    /// Start of the day in the event's time zone.
    var dayStart: Date
    /// True: the user's hearted items; false: the plan's or the event's own schedule for that day.
    var followsHearts: Bool
    /// The day's items (by start, then id), including ones already over.
    var items: [ScheduleItem]
    /// The event's own start when it falls on this day ("gates open").
    var gatesOpen: Date?
    /// When the activity should appear: 2 h before the first item (or the gates opening).
    var startAt: Date
    /// When the last item ends.
    var endAt: Date
    /// True: the user's plan (spec §6), which wins over hearts.
    var followsPlan = false
}

enum LiveActivityPlanner {
    /// The activity starts this long before the day's first item or the gates opening.
    static let leadTime: TimeInterval = 2 * 3600
    /// Scheduled starts (ActivityKit `start:`) only this far ahead; a later app open schedules the rest.
    static let maxScheduleAhead: TimeInterval = 36 * 3600
    /// An ended day's summary stays on the Lock Screen this long.
    static let summaryLinger: TimeInterval = 30 * 60
    /// Without a coming change, content is considered stale after this long.
    static let defaultStaleInterval: TimeInterval = 60 * 60
    /// Stale this long after the next change (the countdown reaches zero first).
    static let staleGrace: TimeInterval = 60

    /// The day to follow: today while one of its items hasn't ended, otherwise the next day
    /// of the event with items. The plan's items (`planned`) when some of that day's haven't
    /// ended, else hearted items when the user hearted any that day that haven't ended, else
    /// every item of the day (plan > hearts > the event's own day, as Android). nil: nothing left.
    static func followDay(
        schedule: [ScheduleItem],
        hearted: Set<Int>,
        planned: Set<Int> = [],
        eventStart: Date?,
        now: Date,
        timeZone: TimeZone
    ) -> FollowDay? {
        let calendar = EventTimeFormat.calendar(in: timeZone)
        let today = calendar.startOfDay(for: now)
        let timed = schedule
            .filter { $0.startTime != nil }
            .sorted { ($0.startTime!, $0.id) < ($1.startTime!, $1.id) }
        // Group by the day each item starts on (event time zone); items still running from an
        // earlier day count for today.
        var days: [Date: [ScheduleItem]] = [:]
        for item in timed {
            var day = calendar.startOfDay(for: item.startTime!)
            if day < today, ScheduleTiming.isHappening(item, at: now) { day = today }
            days[day, default: []].append(item)
        }
        for day in days.keys.sorted() where day >= today {
            let all = days[day] ?? []
            let open = all.filter { !ScheduleTiming.hasEnded($0, at: now) }
            guard !open.isEmpty else { continue }
            let followsPlan = open.contains { planned.contains($0.id) }
            let followsHearts = !followsPlan && open.contains { hearted.contains($0.id) }
            let items = followsPlan
                ? all.filter { planned.contains($0.id) }
                : followsHearts ? all.filter { hearted.contains($0.id) } : all
            let gates = eventStart.flatMap { calendar.isDate($0, inSameDayAs: day) ? $0 : nil }
            let first = items.compactMap(\.startTime).min() ?? day
            let startAt = min(first, gates ?? first).addingTimeInterval(-leadTime)
            let endAt = items.compactMap(ScheduleTiming.effectiveEnd(of:)).max() ?? first
            return FollowDay(
                dayStart: day,
                followsHearts: followsHearts,
                items: items,
                gatesOpen: gates,
                startAt: startAt,
                endAt: endAt,
                followsPlan: followsPlan
            )
        }
        return nil
    }

    enum Decision: Hashable, Sendable {
        /// Nothing to follow (or too far ahead to schedule).
        case nothing
        /// Start the activity now (the app must be in the foreground).
        case startNow
        /// Start it at this date (ActivityKit scheduled start, or the "tap to follow" notification).
        case schedule(Date)
    }

    /// `forced`: the user asked to follow now (Options, the "tap to follow" notification), so
    /// the 2 h lead doesn't apply on the followed day if that day is today.
    static func decision(for day: FollowDay?, now: Date, timeZone: TimeZone, forced: Bool = false) -> Decision {
        guard let day, now < day.endAt else { return .nothing }
        let isToday = EventTimeFormat.calendar(in: timeZone).isDate(day.dayStart, inSameDayAs: now)
        if now >= day.startAt || (forced && isToday) { return .startNow }
        guard day.startAt.timeIntervalSince(now) <= maxScheduleAhead else { return .nothing }
        return .schedule(day.startAt)
    }

    /// The activity's content for `day` at `now`.
    /// - current: the item in progress that started last (ties: lowest id);
    /// - next / after: the first two items not started yet, skipping `skipped`;
    /// - walk minutes to the next item's location from `user` (within walking range);
    /// - `opensAt`: the gates while they haven't opened; `dayComplete` once nothing is left.
    static func content(
        day: FollowDay,
        locations: [Location],
        hearted: Set<Int>,
        skipped: Set<Int>,
        user: Coordinate?,
        urgent: EventActivityAttributes.Urgent?,
        now: Date
    ) -> EventActivityAttributes.ContentState {
        let items = day.items
        let current = items
            .filter { ScheduleTiming.isHappening($0, at: now) }
            .min { a, b in
                let sa = a.startTime!, sb = b.startTime!
                return sa != sb ? sa > sb : a.id < b.id
            }
        let upcoming = items.filter { item in
            guard let start = item.startTime else { return false }
            return start > now && !skipped.contains(item.id) && item.id != current?.id
        }
        let next = upcoming.first
        let after = upcoming.dropFirst().first
        let byId = Dictionary(locations.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

        func slot(_ item: ScheduleItem?) -> EventActivityAttributes.Slot? {
            guard let item else { return nil }
            let location = item.locationId.flatMap { byId[$0] }
            return EventActivityAttributes.Slot(
                id: item.id,
                name: item.name,
                location: location?.name ?? item.locationName ?? ScheduleGrouping.generalTitle,
                locationId: location?.id ?? item.locationId,
                start: item.startTime,
                end: ScheduleTiming.effectiveEnd(of: item),
                hearted: hearted.contains(item.id)
            )
        }

        var walk: Int?
        if let user, let target = next?.locationId.flatMap({ byId[$0]?.coordinate }) {
            let meters = Compass.distance(user, target)
            if WalkTime.isWithinWalkingRange(meters) {
                walk = WalkTime.minutes(WalkTime.estimatedSeconds(straightMeters: meters))
            }
        }

        let complete = current == nil && next == nil
        let completed = items.filter { ScheduleTiming.hasEnded($0, at: now) }.count
        return EventActivityAttributes.ContentState(
            current: slot(current),
            next: slot(next),
            after: slot(after),
            walkMinutesToNext: walk,
            urgent: urgent,
            opensAt: day.gatesOpen.flatMap { $0 > now ? $0 : nil },
            followsHearts: day.followsHearts,
            followsPlan: day.followsPlan ? true : nil,
            dayComplete: complete ? true : nil,
            completedCount: complete ? completed : nil
        )
    }

    /// When the content goes out of date: just after the next change (current ends, next
    /// starts, gates open), otherwise an hour from now.
    static func staleDate(_ state: EventActivityAttributes.ContentState, now: Date) -> Date {
        let changes = [state.current?.effectiveEnd, state.next?.start, state.opensAt]
            .compactMap { $0 }
            .filter { $0 > now }
        guard let first = changes.min() else { return now.addingTimeInterval(defaultStaleInterval) }
        return first.addingTimeInterval(staleGrace)
    }

    /// The urgent block: the newest urgent announcement of the bundle (sent within 12 h, not
    /// dismissed), else the one an ActivityKit push put in the activity while it is still
    /// within 12 h and not dismissed, else nil.
    static func urgent(
        notifications: [AppNotification],
        dismissed: Set<Int>,
        existing: EventActivityAttributes.Urgent?,
        now: Date
    ) -> EventActivityAttributes.Urgent? {
        if let newest = UpdatesInbox.urgent(notifications, dismissed: dismissed, now: now) {
            return EventActivityAttributes.Urgent(
                id: newest.id,
                title: newest.title,
                body: newest.body,
                sentAt: newest.sendTime.map(ISODate.string(from:))
            )
        }
        guard let existing, let id = existing.id, !dismissed.contains(id),
              let sent = existing.sentAt.flatMap(ISODate.parse),
              now.timeIntervalSince(sent) < UpdatesInbox.urgentWindow else { return nil }
        return existing
    }
}

// MARK: - Reminders before hearted and planned items

struct PlannedReminder: Hashable, Sendable {
    /// Notification request id ("attnd.reminder.<event>.<item>").
    var id: String
    var itemId: Int
    var fireDate: Date
    var title: String
    var body: String
}

enum ReminderPlanner {
    /// Reminders fire this long before a hearted item starts.
    static let leadTime: TimeInterval = 15 * 60
    /// iOS keeps at most 64 pending local notifications per app; leave room for the rest.
    static let maxReminders = 40
    static let idPrefix = "attnd.reminder."

    /// One reminder per hearted schedule item (the controller passes hearted ∪ planned items)
    /// whose reminder time is still ahead:
    /// "Prairie Lights in 15 min · 8 min walk" (walk from `user` when within walking range and
    /// more than 20 m away), body "Main Stage · 7:30 PM". Soonest first, at most `maxReminders`.
    static func reminders(
        eventId: Int,
        schedule: [ScheduleItem],
        hearted: Set<Int>,
        locations: [Location],
        user: Coordinate?,
        now: Date,
        timeZone: TimeZone,
        locale: Locale = .current
    ) -> [PlannedReminder] {
        let byId = Dictionary(locations.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let minutes = Int(leadTime / 60)
        return schedule
            .filter { hearted.contains($0.id) }
            .compactMap { item -> PlannedReminder? in
                guard let start = item.startTime else { return nil }
                let fire = start.addingTimeInterval(-leadTime)
                guard fire > now else { return nil }
                let location = item.locationId.flatMap { byId[$0] }
                var title = "\(item.name) in \(minutes) min"
                if let user, let target = location?.coordinate {
                    let meters = Compass.distance(user, target)
                    if meters >= DistanceText.hereMeters, WalkTime.isWithinWalkingRange(meters) {
                        title += " · " + WalkTime.rowText(straightMeters: meters)
                    }
                }
                let time = EventTimeFormat.time(start, in: timeZone, locale: locale)
                let place = location?.name ?? item.locationName
                let body = place.map { "\($0) · \(time)" } ?? time
                return PlannedReminder(
                    id: "\(idPrefix)\(eventId).\(item.id)",
                    itemId: item.id,
                    fireDate: fire,
                    title: title,
                    body: body
                )
            }
            .sorted { ($0.fireDate, $0.itemId) < ($1.fireDate, $1.itemId) }
            .prefix(maxReminders)
            .map { $0 }
    }
}

// MARK: - "Tap to follow" notification

enum FollowPromptText {
    static let followHint = "tap to follow on your Lock Screen"

    /// "Prairie Lights in 2 h" (relative to `date`, when it is shown); "Gates open in 2 h" when
    /// the gates open before the first item; "Follow your day" when nothing is left.
    static func headline(day: FollowDay, at date: Date, timeZone: TimeZone, locale: Locale = .current) -> String {
        let first = day.items.first { item in
            ScheduleTiming.effectiveEnd(of: item).map { $0 > date } ?? false
        }
        if let gates = day.gatesOpen, gates > date, first?.startTime.map({ gates < $0 }) ?? true {
            return "Gates open " + RelativeTimeText.start(gates, end: nil, now: date, timeZone: timeZone, locale: locale)
        }
        guard let first, let text = RelativeTimeText.item(first, now: date, timeZone: timeZone, locale: locale) else {
            return "Follow your day"
        }
        // "Now" / "Started 5 min ago" read as a sentence after the name.
        let relative = text.hasPrefix("in ") || text.hasPrefix("today") || text.hasPrefix("tomorrow") ? text : text.lowercased()
        return "\(first.name) \(relative)"
    }

    /// The "tap to follow" notification: "Prairie Lights in 2 h · tap to follow on your Lock Screen".
    static func body(day: FollowDay, at date: Date, timeZone: TimeZone, locale: Locale = .current) -> String {
        "\(headline(day: day, at: date, timeZone: timeZone, locale: locale)) · \(followHint)"
    }
}

// MARK: - Venue region (arrival)

struct VenueRegion: Hashable, Sendable {
    var center: Coordinate
    var radius: Double

    static let minRadius = 150.0
    static let maxRadius = 3_000.0
    /// Added to the farthest location so arriving at the edge counts.
    static let margin = 150.0

    /// Around the event's coordinate (else the centre of its locations), wide enough to hold
    /// every location plus a margin, 150 m – 3 km. nil without any coordinate.
    static func make(event: Coordinate?, locations: [Location]) -> VenueRegion? {
        let points = locations.compactMap(\.coordinate)
        let center: Coordinate
        if let event {
            center = event
        } else if !points.isEmpty {
            let lat = points.map(\.latitude).reduce(0, +) / Double(points.count)
            let lng = points.map(\.longitude).reduce(0, +) / Double(points.count)
            guard let c = Coordinate.valid(latitude: lat, longitude: lng) else { return nil }
            center = c
        } else {
            return nil
        }
        let farthest = points.map { Compass.distance(center, $0) }.max() ?? 0
        let radius = min(max(farthest + margin, minRadius), maxRadius)
        return VenueRegion(center: center, radius: radius)
    }
}
