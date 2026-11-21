// MySchedule.swift
// Attnd (app and App Clip; pure, unit tested in MyScheduleTests)
//
// "My schedule" (iOS, owner Nov 21, 2026; iOS diverges from Android, which still has likes and a
// separate AI plan): one personal list per event that replaces likes (hearts) and the stored plan.
//
//   - Entries: schedule items (their time is the item's), places at a chosen time ("Dinner at Taco
//     Row, 7:00 PM", default 45 min) and places saved without a time ("Saved places").
//   - Each entry has a reminder: nil = the default (15 min before), 0 = off, else 5…60 min.
//   - Storage keys, prefs and the API-009 metric names keep "heart": the hearted sets of
//     `EventPersonalState` mirror the entries (`heartedScheduleItems` = item entries,
//     `heartedLocations` = place entries), so everything that read hearts follows My schedule.
//   - Adding or removing an item or place returns the API-009 metric (`schedule_item_heart` …)
//     only when membership really changes (never for a time / reminder change, a restore, the
//     migration or a rejoin: those don't go through `add` / `remove`).
//   - Migration (`migrate`, once per event): hearted items and the stored plan's items become item
//     entries, hearted places saved places, planned meal breaks with a suggested food place become
//     place entries at the break's time. The old keys stay readable.

import Foundation

/// The words of My schedule shared by the pure rules and the UI.
enum MyScheduleTitle {
    static let title = "My Schedule"

    /// "5 min before", "1 hour before".
    static func reminder(_ minutes: Int) -> String {
        minutes == 60 ? "1 hour before" : "\(minutes) min before"
    }
}

enum ScheduleEntryKind: String, Codable, Hashable, Sendable {
    case item, place
}

/// One entry of My schedule.
struct ScheduleEntry: Hashable, Sendable {
    var kind: ScheduleEntryKind
    var id: Int
    /// Places only: the chosen start; nil = a saved place without a time.
    var at: Date? = nil
    /// Places only: how long (minutes), nil = `MySchedule.defaultMinutes`.
    var minutes: Int? = nil
    /// Minutes before the start; nil = `MySchedule.defaultReminder`, 0 = off.
    var reminder: Int? = nil
    /// Items: `Planner.fingerprint` when added (or last kept), to notice organizer changes.
    var fingerprint: String? = nil

    var target: SearchTarget { kind == .item ? .scheduleItem(id) : .location(id) }
    var reminderMinutes: Int { reminder ?? MySchedule.defaultReminder }
}

extension ScheduleEntry: Codable {
    private enum CodingKeys: String, CodingKey { case kind, id, at, minutes, reminder, fingerprint }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let kind = c.lenient(ScheduleEntryKind.self, .kind), let id = c.lenient(Int.self, .id) else {
            throw DecodingError.dataCorruptedError(forKey: .id, in: c, debugDescription: "entry without kind or id")
        }
        self.kind = kind
        self.id = id
        at = kind == .place ? c.lenient(Date.self, .at) : nil
        minutes = c.lenient(Int.self, .minutes).map { min(max($0, 5), 12 * 60) }
        reminder = c.lenient(Int.self, .reminder).flatMap { MySchedule.reminderChoices.contains($0) ? $0 : nil }
        fingerprint = kind == .item ? c.lenient(String.self, .fingerprint) : nil
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kind, forKey: .kind)
        try c.encode(id, forKey: .id)
        try c.encodeIfPresent(at, forKey: .at)
        try c.encodeIfPresent(minutes, forKey: .minutes)
        try c.encodeIfPresent(reminder, forKey: .reminder)
        try c.encodeIfPresent(fingerprint, forKey: .fingerprint)
    }
}

/// A timed row of My schedule, resolved against the bundle.
struct MyScheduleRow: Hashable, Sendable, Identifiable {
    var entry: ScheduleEntry
    var start: Date
    var end: Date
    var name: String
    /// The place's name (an item's location, or the place itself).
    var placeName: String?
    var locationId: Int?
    var ended: Bool

    var id: String { "\(entry.kind.rawValue)\(entry.id)" }
    var target: SearchTarget { entry.target }
}

/// What changed, for the caller to count (API-009) and to refresh what follows My schedule.
struct MyScheduleChange: Hashable, Sendable {
    /// The metric to send, nil when membership didn't change (a time or reminder change).
    var metric: UsageMetric?
    var target: SearchTarget
}

struct MySchedule: Hashable, Sendable {
    static let defaultMinutes = 45
    static let defaultReminder = 15
    /// The reminder choices of an entry's menu; 0 = off.
    static let reminderChoices = [5, 10, 15, 30, 60, 0]
    static let maxEntries = 300

    /// The places of My schedule on the map and in Places' My Schedule chip: saved and timed
    /// places plus the places of its schedule items (build 169: hearting an item showed nothing).
    static func placeIds(heartedLocations: Set<Int>, heartedItems: Set<Int>, schedule: [ScheduleItem]) -> Set<Int> {
        var ids = heartedLocations
        for item in schedule where heartedItems.contains(item.id) {
            if let location = item.locationId { ids.insert(location) }
        }
        return ids
    }

    var entries: [ScheduleEntry] = []

    init(entries: [ScheduleEntry] = []) {
        var seen = Set<String>()
        self.entries = Array(entries.filter { seen.insert("\($0.kind.rawValue)\($0.id)").inserted }.prefix(Self.maxEntries))
    }

    var isEmpty: Bool { entries.isEmpty }
    var itemIds: Set<Int> { Set(entries.filter { $0.kind == .item }.map(\.id)) }
    var placeIds: Set<Int> { Set(entries.filter { $0.kind == .place }.map(\.id)) }
    /// Places saved without a time.
    var savedPlaceIds: [Int] { entries.filter { $0.kind == .place && $0.at == nil }.map(\.id) }

    func entry(_ kind: ScheduleEntryKind, _ id: Int) -> ScheduleEntry? {
        entries.first { $0.kind == kind && $0.id == id }
    }

    func contains(_ target: SearchTarget) -> Bool { Self.key(target).map { entry($0.0, $0.1) != nil } ?? false }

    func entry(for target: SearchTarget) -> ScheduleEntry? { Self.key(target).flatMap { entry($0.0, $0.1) } }

    static func key(_ target: SearchTarget) -> (ScheduleEntryKind, Int)? {
        switch target {
        case .scheduleItem(let id): return (.item, id)
        case .location(let id): return (.place, id)
        case .notification, .event: return nil
        }
    }

    // MARK: Changes

    /// Adds an item, or a place (at a time, or saved without one). A place already in My schedule
    /// gets the new time (no metric); an item already there changes nothing (nil).
    @discardableResult
    mutating func add(_ target: SearchTarget, at: Date? = nil, minutes: Int? = nil) -> MyScheduleChange? {
        guard let (kind, id) = Self.key(target) else { return nil }
        if let index = entries.firstIndex(where: { $0.kind == kind && $0.id == id }) {
            guard kind == .place, at != nil || minutes != nil else { return nil }
            if let at { entries[index].at = at }
            if let minutes { entries[index].minutes = minutes }
            return MyScheduleChange(metric: nil, target: target)
        }
        guard entries.count < Self.maxEntries else { return nil }
        entries.append(ScheduleEntry(kind: kind, id: id, at: kind == .place ? at : nil, minutes: kind == .place ? minutes : nil))
        return MyScheduleChange(metric: kind == .item ? .scheduleItemHeart : .locationHeart, target: target)
    }

    @discardableResult
    mutating func remove(_ target: SearchTarget) -> MyScheduleChange? {
        guard let (kind, id) = Self.key(target), let index = entries.firstIndex(where: { $0.kind == kind && $0.id == id }) else { return nil }
        entries.remove(at: index)
        return MyScheduleChange(metric: kind == .item ? .scheduleItemUnheart : .locationUnheart, target: target)
    }

    /// A place entry's time (nil = "just save it"). Items have the organizer's time: nil.
    @discardableResult
    mutating func move(_ target: SearchTarget, to at: Date?) -> MyScheduleChange? {
        guard case .location(let id) = target, let index = entries.firstIndex(where: { $0.kind == .place && $0.id == id }) else { return nil }
        guard entries[index].at != at else { return nil }
        entries[index].at = at
        return MyScheduleChange(metric: nil, target: target)
    }

    /// The reminder of an entry (minutes before; 0 = off; nil = the default).
    @discardableResult
    mutating func setReminder(_ target: SearchTarget, minutes: Int?) -> MyScheduleChange? {
        guard let (kind, id) = Self.key(target), let index = entries.firstIndex(where: { $0.kind == kind && $0.id == id }) else { return nil }
        let value = minutes.flatMap { Self.reminderChoices.contains($0) ? $0 : Self.nearestReminder($0) }
        guard entries[index].reminder != value else { return nil }
        entries[index].reminder = value
        return MyScheduleChange(metric: nil, target: target)
    }

    /// "remind me 20 min before" → the nearest choice (15); negative → off.
    static func nearestReminder(_ minutes: Int) -> Int {
        if minutes <= 0 { return 0 }
        return reminderChoices.filter { $0 > 0 }.min { abs($0 - minutes) < abs($1 - minutes) } ?? defaultReminder
    }

    // MARK: Organizer changes

    /// An item in My schedule the organizer moved, changed or removed since it was added.
    struct OrganizerChange: Hashable, Sendable, Identifiable {
        enum Kind: Hashable, Sendable { case moved(Date), changed, cancelled }
        var itemId: Int
        var name: String
        var kind: Kind
        var id: Int { itemId }
    }

    /// Items whose fingerprint no longer matches (moved to a new start, otherwise changed) or that
    /// left the schedule (cancelled). Entries without a fingerprint (migrated) are taken as they are.
    func organizerChanges(_ bundle: EventBundle, names: [Int: String] = [:]) -> [OrganizerChange] {
        entries.compactMap { entry -> OrganizerChange? in
            guard entry.kind == .item, let print = entry.fingerprint else { return nil }
            guard let item = bundle.scheduleItem(entry.id) else {
                let name = names[entry.id] ?? print.split(separator: "|").first.map(String.init) ?? "An item"
                return OrganizerChange(itemId: entry.id, name: name, kind: .cancelled)
            }
            guard Planner.fingerprint(item) != print else { return nil }
            let oldStart = print.split(separator: "|", omittingEmptySubsequences: false).dropFirst().first.map(String.init)
            if let start = item.startTime, oldStart != ISODate.string(from: start) {
                return OrganizerChange(itemId: entry.id, name: item.name, kind: .moved(start))
            }
            return OrganizerChange(itemId: entry.id, name: item.name, kind: .changed)
        }
    }

    /// "Keep": the item as it is now (its new fingerprint); a cancelled one leaves My schedule.
    mutating func keepChange(_ itemId: Int, _ bundle: EventBundle) {
        guard let index = entries.firstIndex(where: { $0.kind == .item && $0.id == itemId }) else { return }
        if let item = bundle.scheduleItem(itemId) {
            entries[index].fingerprint = Planner.fingerprint(item)
        } else {
            entries.remove(at: index)
        }
    }

    /// Fingerprints for item entries that have none (after the migration or an add without the bundle).
    mutating func fillFingerprints(_ bundle: EventBundle) -> Bool {
        var changed = false
        for index in entries.indices where entries[index].kind == .item && entries[index].fingerprint == nil {
            if let item = bundle.scheduleItem(entries[index].id) {
                entries[index].fingerprint = Planner.fingerprint(item)
                changed = true
            }
        }
        return changed
    }

    // MARK: Views

    /// Timed rows: item entries with a start, and places with a time; by start (then name, id).
    func rows(_ bundle: EventBundle, now: Date) -> [MyScheduleRow] {
        entries.compactMap { row($0, bundle, now: now) }.stableSorted(by: Self.rowOrder)
    }

    func row(_ entry: ScheduleEntry, _ bundle: EventBundle, now: Date) -> MyScheduleRow? {
        switch entry.kind {
        case .item:
            guard let item = bundle.scheduleItem(entry.id), let start = item.startTime else { return nil }
            let end = ScheduleTiming.effectiveEnd(of: item) ?? start.addingTimeInterval(3600)
            let place = bundle.location(item.locationId)
            return MyScheduleRow(entry: entry, start: start, end: end, name: item.name,
                                 placeName: place?.name ?? item.locationName, locationId: place?.id, ended: end <= now)
        case .place:
            guard let location = bundle.location(entry.id), let start = entry.at else { return nil }
            let end = start.addingTimeInterval(TimeInterval((entry.minutes ?? Self.defaultMinutes) * 60))
            return MyScheduleRow(entry: entry, start: start, end: end, name: location.name,
                                 placeName: location.name, locationId: location.id, ended: end <= now)
        }
    }

    static func rowOrder(_ a: MyScheduleRow, _ b: MyScheduleRow) -> Bool {
        if a.start != b.start { return a.start < b.start }
        if a.name != b.name { return a.name < b.name }
        return a.id < b.id
    }

    /// The Schedule tab's section: upcoming (and in progress) rows first, ended ones at the end.
    func sectionRows(_ bundle: EventBundle, now: Date) -> [MyScheduleRow] {
        let all = rows(bundle, now: now)
        return all.filter { !$0.ended } + all.filter(\.ended)
    }

    /// Home's "Up next in my schedule": the next rows that haven't ended (in progress first).
    func upNext(_ bundle: EventBundle, now: Date, limit: Int = 5) -> [MyScheduleRow] {
        Array(rows(bundle, now: now).filter { !$0.ended }.prefix(max(1, limit)))
    }

    /// Rows of one event day (event zone).
    func rows(on day: PlanDate, _ bundle: EventBundle, now: Date) -> [MyScheduleRow] {
        let calendar = PlanCalendar.calendar(bundle.event.timeZone)
        return rows(bundle, now: now).filter { PlanDate($0.start, in: calendar) == day }
    }

    /// Timed rows overlapping `start…end` (the clash check before an add), not `excluding`.
    func clashes(start: Date, end: Date, excluding: SearchTarget? = nil, _ bundle: EventBundle, now: Date) -> [MyScheduleRow] {
        rows(bundle, now: now).filter { row in
            !row.ended && row.target != excluding && row.start < end && start < row.end
        }
    }

    /// When a target would be in My schedule: an item's own time, a place's chosen time.
    func span(of target: SearchTarget, at: Date? = nil, minutes: Int? = nil, _ bundle: EventBundle) -> (start: Date, end: Date)? {
        switch target {
        case .scheduleItem(let id):
            guard let item = bundle.scheduleItem(id), let start = item.startTime else { return nil }
            return (start, ScheduleTiming.effectiveEnd(of: item) ?? start.addingTimeInterval(3600))
        case .location:
            guard let start = at ?? entry(for: target)?.at else { return nil }
            return (start, start.addingTimeInterval(TimeInterval((minutes ?? entry(for: target)?.minutes ?? Self.defaultMinutes) * 60)))
        case .notification, .event:
            return nil
        }
    }

    /// Times offered by the place sheet's "When?": from now + the walk + 5 min, rounded up to the
    /// quarter hour, every 30 min until midnight (event zone), ≤ 8. The default is the first one
    /// that overlaps nothing in My schedule (else the first).
    func suggestedTimes(for placeId: Int, _ bundle: EventBundle, now: Date, walkMinutes: Int?) -> (times: [Date], suggested: Date?) {
        let zone = bundle.event.timeZone
        let calendar = PlanCalendar.calendar(zone)
        let earliest = now.addingTimeInterval(TimeInterval(((walkMinutes ?? 0) + 5) * 60))
        let quarter: TimeInterval = 15 * 60
        var start = Date(timeIntervalSince1970: (earliest.timeIntervalSince1970 / quarter).rounded(.up) * quarter)
        let midnight = PlanDate(now, in: calendar).adding(days: 1).at(.midnight, in: calendar)
        var times: [Date] = []
        while start < midnight && times.count < 8 {
            times.append(start)
            start = start.addingTimeInterval(30 * 60)
        }
        let minutes = TimeInterval(Self.defaultMinutes * 60)
        let free = times.first { clashes(start: $0, end: $0.addingTimeInterval(minutes), excluding: .location(placeId), bundle, now: now).isEmpty }
        return (times, free ?? times.first)
    }

    /// A clock time ("8", "7:30 pm") as a date: on the day of `near` when given (an entry being
    /// moved), else today in the event's zone (tomorrow when that is more than 30 min past).
    static func date(_ clock: PlanClock, near: Date?, now: Date, timeZone: TimeZone) -> Date {
        let calendar = PlanCalendar.calendar(timeZone)
        let day = PlanDate(near ?? now, in: calendar)
        let date = day.at(clock, in: calendar)
        if near == nil, date < now.addingTimeInterval(-30 * 60) { return day.adding(days: 1).at(clock, in: calendar) }
        return date
    }

    // MARK: Migration

    /// My schedule from the likes and the plan of an older build (once per event).
    static func migrate(heartedItems: Set<Int>, heartedLocations: Set<Int>, plan: Plan?) -> MySchedule {
        var entries: [ScheduleEntry] = heartedItems.sorted().map { ScheduleEntry(kind: .item, id: $0) }
        let planned = plan?.items.map(\.itemId) ?? []
        for id in planned where !heartedItems.contains(id) && !entries.contains(where: { $0.kind == .item && $0.id == id }) {
            entries.append(ScheduleEntry(kind: .item, id: id))
        }
        var places = heartedLocations.sorted().map { ScheduleEntry(kind: .place, id: $0) }
        for day in plan?.days ?? [] {
            for meal in day.meals {
                guard let locationId = meal.locationId else { continue }
                let minutes = max(5, PlanCalendar.minutes(from: meal.start, to: meal.end))
                if let index = places.firstIndex(where: { $0.id == locationId }) {
                    if places[index].at == nil {
                        places[index].at = meal.start
                        places[index].minutes = minutes
                    }
                } else {
                    places.append(ScheduleEntry(kind: .place, id: locationId, at: meal.start, minutes: minutes))
                }
            }
        }
        return MySchedule(entries: entries + places)
    }

    // MARK: Plans (the planner fills My schedule)

    /// What applying a plan does to My schedule: its items are added; items of the previous plan
    /// that the new one dropped (on the new plan's days) are removed; meal breaks with a
    /// suggested food place become place entries at the break's time. Returns the changes.
    mutating func apply(plan: Plan?, replacing previous: Plan?) -> [MyScheduleChange] {
        var changes: [MyScheduleChange] = []
        let newIds = Set(plan?.itemIds ?? [])
        let newDays = Set(plan?.days.map(\.date) ?? [])
        // Clearing the plan ("New plan") keeps My schedule as it is.
        for day in previous?.days ?? [] where plan != nil && newDays.contains(day.date) {
            for item in day.items where !newIds.contains(item.itemId) {
                if let change = remove(.scheduleItem(item.itemId)) { changes.append(change) }
            }
            for meal in day.meals {
                guard let locationId = meal.locationId, entry(.place, locationId)?.at == meal.start else { continue }
                let stays = plan?.days.flatMap(\.meals).contains { $0.locationId == locationId && $0.start == meal.start } ?? false
                if !stays, let change = remove(.location(locationId)) { changes.append(change) }
            }
        }
        for id in plan?.itemIds ?? [] {
            if let change = add(.scheduleItem(id)) { changes.append(change) }
        }
        for meal in plan?.days.flatMap(\.meals) ?? [] {
            guard let locationId = meal.locationId else { continue }
            let minutes = max(5, PlanCalendar.minutes(from: meal.start, to: meal.end))
            if entry(.place, locationId)?.at == nil || previous?.days.flatMap(\.meals).contains(where: { $0.locationId == locationId }) == true {
                if let change = add(.location(locationId), at: meal.start, minutes: minutes) { changes.append(change) }
            }
        }
        return changes
    }

    /// The plan kept in line with My schedule after a change made elsewhere: items no longer in
    /// My schedule leave it, items added on one of its days join it ("In your schedule"), meal
    /// breaks whose place entry was removed lose the place. nil stays nil.
    func reconcile(_ plan: Plan?, _ bundle: EventBundle) -> Plan? {
        guard var plan else { return nil }
        let calendar = PlanCalendar.calendar(bundle.event.timeZone)
        let items = itemIds
        let planned = Set(plan.itemIds)
        plan.days = plan.days.map { day in
            var day = day
            var entries: [PlanEntry] = day.entries.compactMap { entry in
                switch entry {
                case .item(let item):
                    return items.contains(item.itemId) ? entry : nil
                case .meal(var meal):
                    if let id = meal.locationId, self.entry(.place, id) == nil { meal.locationId = nil }
                    return .meal(meal)
                }
            }
            for id in items.subtracting(planned).sorted() {
                guard let item = bundle.scheduleItem(id), let start = item.startTime, PlanDate(start, in: calendar) == day.date else { continue }
                let end = ScheduleTiming.effectiveEnd(of: item) ?? start.addingTimeInterval(3600)
                entries.append(.item(PlannedItem(itemId: id, start: start, end: end, reason: Self.inScheduleReason,
                                                 walkMinutes: nil, alternatives: [], orInstead: [])))
            }
            day.entries = entries.stableSorted { $0.start < $1.start }
            return day
        }
        return plan
    }

    static let inScheduleReason = "In your schedule"

    /// Meal breaks the planner shouldn't add: a timed food place in My schedule during lunch
    /// (12:00–13:30) or dinner (18:00–19:30) of that day covers it.
    func mealsCovered(_ bundle: EventBundle) -> Set<MealSlot> {
        let calendar = PlanCalendar.calendar(bundle.event.timeZone)
        var slots = Set<MealSlot>()
        for entry in entries where entry.kind == .place {
            guard let at = entry.at, let location = bundle.location(entry.id) else { continue }
            let food = ([location.category ?? ""] + location.tags).contains { $0.lowercased().contains("food") }
            guard food else { continue }
            let day = PlanDate(at, in: calendar)
            let minute = calendar.component(.hour, from: at) * 60 + calendar.component(.minute, from: at)
            if (11 * 60 + 30)...(13 * 60 + 30) ~= minute { slots.insert(MealSlot(date: day, kind: .lunch)) }
            if (17 * 60 + 30)...(19 * 60 + 30) ~= minute { slots.insert(MealSlot(date: day, kind: .dinner)) }
        }
        return slots
    }
}

extension MySchedule: Codable {
    private enum CodingKeys: String, CodingKey { case entries }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let lossy = c.lenient([LossyEntry].self, .entries) ?? []
        self.init(entries: lossy.compactMap(\.entry))
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(entries, forKey: .entries)
    }

    /// One entry that may fail to decode on its own (dropped, the rest kept).
    private struct LossyEntry: Decodable {
        var entry: ScheduleEntry?
        init(from decoder: Decoder) throws { entry = try? ScheduleEntry(from: decoder) }
    }
}
