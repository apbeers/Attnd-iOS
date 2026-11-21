// LiveFollowLogic.swift
// Attnd (app + App Clip; unit tested in LiveFollowTests)
//
// Pure rules behind "Follow on Lock Screen" (Live Activity, shared spec §8) and heart reminders.
// LiveFollowController runs them; nothing here touches ActivityKit's runtime or
// UserNotifications.
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
    /// My schedule's places with a time on this day (they are part of "my" day).
    var places: [FollowPlace] = []
    /// Every timed item of the day: what's on at the event when My schedule has nothing on.
    var eventItems: [ScheduleItem] = []
}

/// A place of My schedule at a time ("Dinner at Taco Row, 7:00 PM").
struct FollowPlace: Hashable, Sendable {
    var locationId: Int
    var name: String
    var start: Date
    var end: Date
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
        places: [FollowPlace] = [],
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
        var placeDays: [Date: [FollowPlace]] = [:]
        for place in places.sorted(by: { ($0.start, $0.locationId) < ($1.start, $1.locationId) }) {
            var day = calendar.startOfDay(for: place.start)
            if day < today, place.start <= now, place.end > now { day = today }
            placeDays[day, default: []].append(place)
        }
        for day in Set(days.keys).union(placeDays.keys).sorted() where day >= today {
            let all = days[day] ?? []
            let open = all.filter { !ScheduleTiming.hasEnded($0, at: now) }
            let dayPlaces = placeDays[day] ?? []
            let openPlaces = dayPlaces.filter { $0.end > now }
            guard !open.isEmpty || !openPlaces.isEmpty else { continue }
            let followsPlan = open.contains { planned.contains($0.id) }
            let followsHearts = !followsPlan && (open.contains { hearted.contains($0.id) } || !openPlaces.isEmpty)
            let mine = followsPlan || followsHearts
            let items = followsPlan
                ? all.filter { planned.contains($0.id) }
                : followsHearts ? all.filter { hearted.contains($0.id) } : all
            let followedPlaces = mine ? dayPlaces : []
            let gates = eventStart.flatMap { calendar.isDate($0, inSameDayAs: day) ? $0 : nil }
            let starts = items.compactMap(\.startTime) + followedPlaces.map(\.start)
            let first = starts.min() ?? day
            let startAt = min(first, gates ?? first).addingTimeInterval(-leadTime)
            let ends = items.compactMap(ScheduleTiming.effectiveEnd(of:)) + followedPlaces.map(\.end)
            let endAt = ends.max() ?? first
            return FollowDay(
                dayStart: day,
                followsHearts: followsHearts,
                items: items,
                gatesOpen: gates,
                startAt: startAt,
                endAt: endAt,
                followsPlan: followsPlan,
                places: followedPlaces,
                eventItems: all
            )
        }
        return nil
    }

    /// What `followDay` gets under the organizer's choice (API-027 `live_activity.follows`):
    /// `my_schedule` today's rule; `everything` every item of the day (no hearts, plan or places);
    /// `location` only the items at that place (an unknown place → My schedule's rule).
    struct FollowInputs: Hashable, Sendable {
        var schedule: [ScheduleItem]
        var hearted: Set<Int>
        var planned: Set<Int>
        var places: [FollowPlace]
    }

    static func inputs(
        _ settings: LiveActivitySettings?, bundle: EventBundle,
        hearted: Set<Int>, planned: Set<Int>, places: [FollowPlace]
    ) -> FollowInputs {
        let settings = settings ?? .defaults
        if let location = settings.followedLocation(in: bundle) {
            return FollowInputs(schedule: bundle.schedule.filter { $0.locationId == location }, hearted: [], planned: [], places: [])
        }
        if settings.follows == .everything {
            return FollowInputs(schedule: bundle.schedule, hearted: [], planned: [], places: [])
        }
        return FollowInputs(schedule: bundle.schedule, hearted: hearted, planned: planned, places: places)
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

    /// The user's last position is used for walk, direction and distance only this long.
    static let maxPositionAge: TimeInterval = 30 * 60

    /// One row of the activity: a schedule item or a timed place of My schedule.
    private struct Entry {
        var item: ScheduleItem?
        var place: FollowPlace?
        var start: Date
        var end: Date
        var locationId: Int?
        var itemId: Int? { item?.id }
    }

    /// The activity's content for `day` at `now` (Now and Next always filled while anything is on):
    /// - current: My schedule's entry in progress (the one that started last; ties lowest id),
    ///   else what's on at the event ("At the event", `nowSource` "event"): the item in progress
    ///   nearest to the user, else the earliest started;
    /// - next / after: My schedule's next two entries not started yet (skipping `skipped`), else
    ///   the event's own next items; `freeUntil` = Next's start while My schedule has a gap;
    /// - walk minutes, compass point and distance to Next from `user` (≤ 30 min old by
    ///   `userAt`, within walking range; no direction under 20 m);
    /// - `opensAt`: the gates while they haven't opened; `dayComplete` once nothing is left.
    static func content(
        day: FollowDay,
        locations: [Location],
        hearted: Set<Int>,
        skipped: Set<Int>,
        user: Coordinate?,
        userAt: Date? = nil,
        urgent: EventActivityAttributes.Urgent?,
        now: Date,
        imperial: Bool = DistanceText.usesImperial(),
        locale: Locale = .current
    ) -> EventActivityAttributes.ContentState {
        let byId = Dictionary(locations.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        // A position older than 30 min is not used (no background location).
        let position = userAt.map { now.timeIntervalSince($0) <= maxPositionAge } ?? true ? user : nil
        func itemEntry(_ item: ScheduleItem) -> Entry? {
            guard let start = item.startTime, let end = ScheduleTiming.effectiveEnd(of: item) else { return nil }
            return Entry(item: item, start: start, end: end, locationId: item.locationId)
        }
        let mine = day.followsPlan || day.followsHearts
        let order: (Entry, Entry) -> Bool = { a, b in
            if a.start != b.start { return a.start < b.start }
            if (a.item == nil) != (b.item == nil) { return a.item != nil }
            return (a.itemId ?? a.locationId ?? 0) < (b.itemId ?? b.locationId ?? 0)
        }
        let mineEntries = mine
            ? (day.items.compactMap(itemEntry) + day.places.map {
                Entry(place: $0, start: $0.start, end: $0.end, locationId: $0.locationId)
            }).sorted(by: order)
            : []
        let eventEntries = (day.eventItems.isEmpty ? day.items : day.eventItems).compactMap(itemEntry).sorted(by: order)
        func happening(_ e: Entry) -> Bool { e.start <= now && now < e.end }
        func distance(_ e: Entry) -> Double {
            guard let position, let c = e.locationId.flatMap({ byId[$0]?.coordinate }) else { return .infinity }
            return Compass.distance(position, c)
        }

        var current = mineEntries.filter(happening).min { a, b in
            a.start != b.start ? a.start > b.start : (a.itemId ?? 0) < (b.itemId ?? 0)
        }
        var nowSource: String? = current != nil ? "schedule" : nil
        if current == nil {
            current = eventEntries.filter(happening).min { a, b in
                let da = distance(a), db = distance(b)
                if da != db { return da < db }
                return a.start != b.start ? a.start < b.start : (a.itemId ?? 0) < (b.itemId ?? 0)
            }
            if current != nil { nowSource = "event" }
        }
        func upcoming(_ list: [Entry]) -> [Entry] {
            list.filter { e in
                guard e.start > now else { return false }
                if let id = e.itemId, skipped.contains(id) || id == current?.itemId { return false }
                return true
            }
        }
        let mineNext = upcoming(mineEntries)
        let useMine = !mineNext.isEmpty
        let nextList = useMine ? mineNext : upcoming(eventEntries)
        let next = nextList.first
        let after = nextList.dropFirst().first
        let nextSource: String? = next == nil ? nil : (useMine ? "schedule" : "event")
        let freeUntil = useMine && !mineEntries.contains(where: happening) ? next?.start : nil

        func slot(_ entry: Entry?) -> EventActivityAttributes.Slot? {
            guard let entry else { return nil }
            if let place = entry.place {
                return EventActivityAttributes.Slot(
                    name: place.name, location: place.name, locationId: place.locationId,
                    start: place.start, end: place.end, hearted: true, kind: "place"
                )
            }
            guard let item = entry.item else { return nil }
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
        var point: Int?
        var distanceText: String?
        var directionLabel: String?
        if let position, let target = next?.locationId.flatMap({ byId[$0]?.coordinate }) {
            let direction = TargetDirection(from: position, to: target)
            if WalkTime.isWithinWalkingRange(direction.meters) {
                walk = WalkTime.minutes(WalkTime.estimatedSeconds(straightMeters: direction.meters))
                if !direction.isHere {
                    point = direction.point.rawValue
                    distanceText = direction.text(imperial: imperial, locale: locale)
                    directionLabel = direction.accessibilityText(imperial: imperial, locale: locale)
                }
            }
        }

        let complete = current == nil && next == nil
        let completed = day.items.filter { ScheduleTiming.hasEnded($0, at: now) }.count
            + day.places.filter { $0.end <= now }.count
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
            completedCount: complete ? completed : nil,
            nowSource: nowSource,
            nextSource: nextSource,
            freeUntil: freeUntil,
            nextPoint: point,
            nextDistance: distanceText,
            nextDirectionLabel: directionLabel
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

// MARK: - Theme (API-023)
/// `event.theme` → the Live Activity's attributes (pure; LiveFollowTests).
enum LiveThemeMapping {
    static func activityTheme(_ theme: EventTheme?) -> EventActivityAttributes.ActivityTheme? {
        guard let theme, !theme.isEmpty else { return nil }
        func roles(dark: Bool) -> EventActivityAttributes.ActivityTheme.Roles? {
            let r = EventActivityAttributes.ActivityTheme.Roles(
                primary: theme.hex(\.primary, dark: dark),
                secondary: theme.hex(\.secondary, dark: dark),
                tertiary: theme.hex(\.tertiary, dark: dark)
            )
            return r.isEmpty ? nil : r
        }
        let result = EventActivityAttributes.ActivityTheme(light: roles(dark: false), dark: roles(dark: true))
        return result.light == nil && result.dark == nil ? nil : result
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
    /// A place entry of My schedule ("Dinner at Taco Row"): its location; `itemId` is then 0.
    var locationId: Int? = nil
}

enum ReminderPlanner {
    /// Reminders fire this long before a hearted item starts.
    static let leadTime: TimeInterval = 15 * 60
    /// iOS keeps at most 64 pending local notifications per app; leave room for the rest.
    static let maxReminders = 40
    static let idPrefix = "attnd.reminder."

    /// One reminder per schedule item in My schedule (the controller passes My schedule's items)
    /// whose reminder time is still ahead, `leadMinutes[id]` before (default 15, 0 = none), and
    /// one per timed place entry ("Taco Row in 15 min · 3 min walk", "In your schedule · 7:00 PM"):
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
        locale: Locale = .current,
        leadMinutes: [Int: Int] = [:],
        places: [ScheduleEntry] = []
    ) -> [PlannedReminder] {
        let byId = Dictionary(locations.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let defaultMinutes = Int(leadTime / 60)
        func walk(to location: Location?) -> String? {
            guard let user, let target = location?.coordinate else { return nil }
            let meters = Compass.distance(user, target)
            guard meters >= DistanceText.hereMeters, WalkTime.isWithinWalkingRange(meters) else { return nil }
            return WalkTime.rowText(straightMeters: meters)
        }
        let items = schedule
            .filter { hearted.contains($0.id) }
            .compactMap { item -> PlannedReminder? in
                let minutes = leadMinutes[item.id] ?? defaultMinutes
                guard minutes > 0, let start = item.startTime else { return nil }
                let fire = start.addingTimeInterval(-TimeInterval(minutes * 60))
                guard fire > now else { return nil }
                let location = item.locationId.flatMap { byId[$0] }
                var title = "\(item.name) in \(minutes) min"
                if let walk = walk(to: location) { title += " · " + walk }
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
        let timedPlaces = places.compactMap { entry -> PlannedReminder? in
            guard let location = byId[entry.id], let start = entry.at, entry.reminderMinutes > 0 else { return nil }
            let minutes = entry.reminderMinutes
            let fire = start.addingTimeInterval(-TimeInterval(minutes * 60))
            guard fire > now else { return nil }
            var title = "\(location.name) in \(minutes) min"
            if let walk = walk(to: location) { title += " · " + walk }
            return PlannedReminder(
                id: "\(idPrefix)\(eventId).p\(location.id)",
                itemId: 0,
                fireDate: fire,
                title: title,
                body: "In your schedule · " + EventTimeFormat.time(start, in: timeZone, locale: locale),
                locationId: location.id
            )
        }
        return (items + timedPlaces)
            .sorted { ($0.fireDate, $0.itemId, $0.locationId ?? 0) < ($1.fireDate, $1.itemId, $1.locationId ?? 0) }
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
