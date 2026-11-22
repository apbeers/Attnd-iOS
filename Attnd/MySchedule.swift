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
//   - Migration (`migrate`, once per event): hearted items become item entries, hearted places
//     saved places. The stored plan of an older build is absorbed once (`absorb(legacy:)`).
//   - One list (owner, Nov 22, 2026; Attnd-Web docs/specs/one_list_spec.md): My schedule is the
//     only stored list. Each entry knows who added it (`source`: you / planner / assistant /
//     shared) and why (`reason`). The planner is a function: its plan is diffed against My
//     schedule into a `ScheduleProposal` (adds and removes with reasons; it only removes its own
//     entries unless asked), previewed, applied, and kept on one `ScheduleHistory` (≤ 20
//     snapshots, hearts included). The `Plan` the chat and the Live Activity read is derived from
//     My schedule (`dayPlan`), never stored. `SchedulePreferences` keeps what the planner was told.

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

/// Who put an entry into My schedule (one list, §1). Unknown or missing → `you`.
enum ScheduleEntrySource: String, Codable, Hashable, Sendable, CaseIterable {
    case you, planner, assistant, shared

    static func of(_ value: String?) -> ScheduleEntrySource {
        value.flatMap { ScheduleEntrySource(rawValue: $0.lowercased()) } ?? .you
    }
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
    /// Who added it (one list): only `planner` entries may be removed by a new plan unasked.
    var source: ScheduleEntrySource = .you
    /// Why ("Because you like jazz", "Lunch break"), ≤ 80 characters.
    var reason: String? = nil

    static let maxReason = 80

    static func cleanReason(_ text: String?) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return String(text.prefix(maxReason))
    }

    var target: SearchTarget { kind == .item ? .scheduleItem(id) : .location(id) }
    var reminderMinutes: Int { reminder ?? MySchedule.defaultReminder }
}

extension ScheduleEntry: Codable {
    private enum CodingKeys: String, CodingKey { case kind, id, at, minutes, reminder, fingerprint, source, reason }

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
        source = ScheduleEntrySource.of(c.lenient(String.self, .source))
        reason = Self.cleanReason(c.lenient(String.self, .reason))
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kind, forKey: .kind)
        try c.encode(id, forKey: .id)
        try c.encodeIfPresent(at, forKey: .at)
        try c.encodeIfPresent(minutes, forKey: .minutes)
        try c.encodeIfPresent(reminder, forKey: .reminder)
        try c.encodeIfPresent(fingerprint, forKey: .fingerprint)
        if source != .you { try c.encode(source, forKey: .source) }
        try c.encodeIfPresent(reason, forKey: .reason)
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

    /// My schedule from the likes of an older build (once per event); an older build's stored
    /// plan, when given, is absorbed too (`absorb(legacy:)`).
    static func migrate(heartedItems: Set<Int>, heartedLocations: Set<Int>, plan: Plan?) -> MySchedule {
        var schedule = MySchedule(entries: heartedItems.sorted().map { ScheduleEntry(kind: .item, id: $0) }
            + heartedLocations.sorted().map { ScheduleEntry(kind: .place, id: $0) })
        if let plan { schedule.absorb(legacy: plan) }
        return schedule
    }

    /// One list §6: the stored plan of an older build becomes entries: every planned item not in
    /// My schedule (`source: planner`, the plan's reason), each meal break with a food place not
    /// in it (a timed place, "Lunch break" / "Dinner break"); a saved place without a time gets
    /// the break's time. Idempotent: a second run finds nothing. True when something changed.
    @discardableResult
    mutating func absorb(legacy plan: Plan) -> Bool {
        var changed = false
        for item in plan.items where entry(.item, item.itemId) == nil && entries.count < Self.maxEntries {
            entries.append(ScheduleEntry(kind: .item, id: item.itemId, source: .planner, reason: ScheduleEntry.cleanReason(item.reason)))
            changed = true
        }
        for meal in plan.days.flatMap(\.meals) {
            guard let locationId = meal.locationId else { continue }
            let minutes = max(5, PlanCalendar.minutes(from: meal.start, to: meal.end))
            if let index = entries.firstIndex(where: { $0.kind == .place && $0.id == locationId }) {
                guard entries[index].at == nil else { continue }
                entries[index].at = meal.start
                entries[index].minutes = minutes
                changed = true
            } else if entries.count < Self.maxEntries {
                entries.append(ScheduleEntry(kind: .place, id: locationId, at: meal.start, minutes: minutes,
                                             source: .planner, reason: meal.kind.label))
                changed = true
            }
        }
        return changed
    }

    static let inScheduleReason = "In your schedule"

    /// The planner's input (one list §2): a timed food place in My schedule during lunch
    /// (11:30–13:30) or dinner (17:30–19:30) of that day covers that meal break.
    func mealsCovered(_ bundle: EventBundle) -> Set<MealSlot> {
        let calendar = PlanCalendar.calendar(bundle.event.timeZone)
        var slots = Set<MealSlot>()
        for entry in entries where entry.kind == .place {
            guard let at = entry.at, let location = bundle.location(entry.id), Self.isFood(location) else { continue }
            let day = PlanDate(at, in: calendar)
            if let kind = Self.mealKind(at, calendar) { slots.insert(MealSlot(date: day, kind: kind)) }
        }
        return slots
    }

    static func isFood(_ location: Location) -> Bool {
        ([location.category ?? ""] + location.tags).contains { $0.lowercased().contains("food") }
    }

    /// The meal a time belongs to: lunch 11:30–13:30, dinner 17:30–19:30, else none.
    static func mealKind(_ at: Date, _ calendar: Calendar) -> MealKind? {
        let minute = calendar.component(.hour, from: at) * 60 + calendar.component(.minute, from: at)
        if (11 * 60 + 30)...(13 * 60 + 30) ~= minute { return .lunch }
        if (17 * 60 + 30)...(19 * 60 + 30) ~= minute { return .dinner }
        return nil
    }

    // MARK: One list: proposals (the planner proposes edits to My schedule)

    /// One list §2: a plan (the planner's result, an edit's re-solve, a version, a shared plan)
    /// as edits to My schedule. Adds: its items not in My schedule (with the planner's reason) and
    /// its meal breaks with a place not there at that time. Removes: on the plan's days, entries the
    /// planner added that the plan no longer has, and anything in `explicit` (the request asked:
    /// "drop the BBQ"); never what the person added unasked. nil plan: nothing.
    func proposal(for plan: Plan?, explicit: Set<Int> = [], _ bundle: EventBundle) -> ScheduleProposal {
        guard let plan else { return ScheduleProposal() }
        let calendar = PlanCalendar.calendar(bundle.event.timeZone)
        let days = Set(plan.days.map(\.date))
        let planned = Set(plan.itemIds)
        var proposal = ScheduleProposal()
        for item in plan.items where entry(.item, item.itemId) == nil {
            proposal.adds.append(.init(target: .scheduleItem(item.itemId), reason: ScheduleEntry.cleanReason(item.reason)))
        }
        let meals = plan.days.flatMap(\.meals)
        for meal in meals {
            guard let locationId = meal.locationId, entry(.place, locationId)?.at != meal.start,
                  !proposal.adds.contains(where: { $0.target == .location(locationId) }) else { continue }
            proposal.adds.append(.init(target: .location(locationId), at: meal.start,
                                       minutes: max(5, PlanCalendar.minutes(from: meal.start, to: meal.end)), reason: meal.kind.label, meal: meal.kind))
        }
        for entry in entries {
            switch entry.kind {
            case .item:
                guard !planned.contains(entry.id) else { continue }
                if explicit.contains(entry.id) {
                    proposal.removes.append(.init(target: .scheduleItem(entry.id)))
                } else if entry.source == .planner, let start = bundle.scheduleItem(entry.id)?.startTime,
                          days.contains(PlanDate(start, in: calendar)) {
                    proposal.removes.append(.init(target: .scheduleItem(entry.id)))
                }
            case .place:
                guard entry.source == .planner, let at = entry.at, days.contains(PlanDate(at, in: calendar)),
                      !meals.contains(where: { $0.locationId == entry.id }) else { continue }
                proposal.removes.append(.init(target: .location(entry.id), meal: Self.mealKind(at, calendar)))
            }
        }
        proposal.summary = Planner.summary(plan, timeZone: bundle.event.timeZone)
        return proposal
    }

    /// Applies a proposal: adds get `source` and the proposal's reason (an entry already there
    /// keeps who added it; a place gets the new time), removes leave. The API-009 changes.
    mutating func apply(_ proposal: ScheduleProposal, source: ScheduleEntrySource = .planner) -> [MyScheduleChange] {
        var changes: [MyScheduleChange] = []
        for remove in proposal.removes {
            if let change = self.remove(remove.target) { changes.append(change) }
        }
        for add in proposal.adds {
            let existed = contains(add.target)
            guard let change = self.add(add.target, at: add.at, minutes: add.minutes) else { continue }
            changes.append(change)
            if !existed, let (kind, id) = Self.key(add.target), let index = entries.firstIndex(where: { $0.kind == kind && $0.id == id }) {
                entries[index].source = source
                entries[index].reason = add.reason
            }
        }
        return changes
    }

    // MARK: One list: the derived day view (never stored)

    /// The `Plan` the chat (Your Day, proposals' previews, plan edits), the Live Activity, live
    /// hints, WhyNot and sharing read: My schedule's items per event day, laid out by the planner's
    /// rules (`Planner.dayView`: walks, swap alternatives), its timed food places at meal times as
    /// meal breaks, the entries' own reasons. nil without a timed item.
    func dayPlan(_ bundle: EventBundle, preferences: SchedulePreferences = SchedulePreferences(),
                 checkedOff: Set<Int> = [], now: Date) -> Plan? {
        let calendar = PlanCalendar.calendar(bundle.event.timeZone)
        var itemsByDay: [PlanDate: [Int]] = [:]
        var spans: [PlanDate: (start: Date, end: Date)] = [:]
        func widen(_ day: PlanDate, _ start: Date, _ end: Date) {
            let old = spans[day]
            spans[day] = (min(old?.start ?? start, start), max(old?.end ?? end, end))
        }
        for entry in entries where entry.kind == .item {
            guard let item = bundle.scheduleItem(entry.id), let start = item.startTime else { continue }
            let day = PlanDate(start, in: calendar)
            itemsByDay[day, default: []].append(entry.id)
            widen(day, start, ScheduleTiming.effectiveEnd(of: item) ?? start.addingTimeInterval(3600))
        }
        guard !itemsByDay.isEmpty else { return nil }
        var mealsByDay: [PlanDate: [MealBreak]] = [:]
        for entry in entries where entry.kind == .place {
            guard let at = entry.at, let location = bundle.location(entry.id), Self.isFood(location),
                  let kind = Self.mealKind(at, calendar) else { continue }
            let day = PlanDate(at, in: calendar)
            guard itemsByDay[day] != nil, mealsByDay[day]?.contains(where: { $0.kind == kind }) != true else { continue }
            let end = at.addingTimeInterval(TimeInterval((entry.minutes ?? Self.defaultMinutes) * 60))
            mealsByDay[day, default: []].append(MealBreak(kind: kind, start: at, end: end, locationId: entry.id))
            widen(day, at, end)
        }
        var planning = preferences.planPreferences
        planning.includeMeals = false
        let planner = Planner(bundle: bundle, preferences: planning, heartedItems: itemIds, heartedLocations: placeIds,
                              constraints: preferences.constraints)
        let reasons = Dictionary(entries.filter { $0.kind == .item }.compactMap { e in e.reason.map { (e.id, $0) } },
                                 uniquingKeysWith: { first, _ in first })
        let days: [PlanDay] = itemsByDay.keys.sorted().map { day in
            let span = spans[day]!
            let windowStart = preferences.earliest.map { min(day.at($0, in: calendar), span.start) } ?? span.start
            let windowEnd = preferences.latest.map { max(day.at($0, in: calendar), span.end) } ?? span.end
            var built = planner.dayView(day, items: itemsByDay[day]!, meals: mealsByDay[day] ?? [],
                                        windowStart: windowStart, windowEnd: windowEnd)
            built.entries = built.entries.map { entry in
                guard case .item(var item) = entry, let reason = reasons[item.itemId] else { return entry }
                item.reason = reason
                return .item(item)
            }
            return built
        }
        var prints: [Int: String] = [:]
        for day in days {
            for item in day.items { if let current = bundle.scheduleItem(item.itemId) { prints[item.itemId] = Planner.fingerprint(current) } }
        }
        return Plan(eventId: bundle.event.id, createdAt: Date(timeIntervalSince1970: 0), request: "",
                    preferences: preferences.planPreferences, days: days, fingerprints: prints,
                    constraints: preferences.constraints, checkedOff: checkedOff.intersection(Set(itemsByDay.values.flatMap { $0 })))
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

// MARK: - One list (owner, Nov 22, 2026; Attnd-Web docs/specs/one_list_spec.md)

/// Edits to My schedule the planner (or an edit, version, swap, sequence, shared plan) proposes:
/// previewed, then applied as one entry on `ScheduleHistory`.
struct ScheduleProposal: Hashable, Sendable {
    struct Add: Hashable, Sendable {
        var target: SearchTarget
        /// Places only: the time (a meal break); nil keeps / saves without one.
        var at: Date? = nil
        var minutes: Int? = nil
        var reason: String? = nil
        /// The meal break a place add covers (for the pill).
        var meal: MealKind? = nil
    }

    struct Remove: Hashable, Sendable {
        var target: SearchTarget
        var meal: MealKind? = nil
    }

    var adds: [Add] = []
    var removes: [Remove] = []
    /// `Planner.summary` of the plan it came from ("8 items, 10:00 AM – 11:00 PM, with a lunch break").
    var summary: String = ""

    var isEmpty: Bool { adds.isEmpty && removes.isEmpty }

    /// "+5 items, +1 lunch break, −2 items" (U+2212 minus); "No change" when empty.
    var pillText: String {
        func count(_ n: Int, _ one: String, _ many: String) -> String { "\(n) \(n == 1 ? one : many)" }
        var parts: [String] = []
        let addedItems = adds.filter { $0.meal == nil }.count
        if addedItems > 0 { parts.append("+" + count(addedItems, "item", "items")) }
        for kind in MealKind.allCases {
            let n = adds.filter { $0.meal == kind }.count
            if n > 0 { parts.append("+" + count(n, kind.label.lowercased(), kind.label.lowercased() + "s")) }
        }
        let removedItems = removes.filter { $0.meal == nil }.count
        if removedItems > 0 { parts.append("\u{2212}" + count(removedItems, "item", "items")) }
        for kind in MealKind.allCases {
            let n = removes.filter { $0.meal == kind }.count
            if n > 0 { parts.append("\u{2212}" + count(n, kind.label.lowercased(), kind.label.lowercased() + "s")) }
        }
        return parts.isEmpty ? "No change" : parts.joined(separator: ", ")
    }

    /// The proposal card's sentence: "Add 6 things to your schedule" (one list §7).
    var title: String {
        let things = adds.count
        if removes.isEmpty { return things == 1 ? "Add 1 thing to your schedule" : "Add \(things) things to your schedule" }
        if adds.isEmpty { return removes.count == 1 ? "Remove 1 thing from your schedule" : "Remove \(removes.count) things from your schedule" }
        return "Change your schedule: \(pillText)"
    }
}

/// One Undo history over My schedule (one list §3): ≤ 20 snapshots, newest last. Plans, edits,
/// versions, swaps, shared plans and hearts all push one; "undo", the Undo card and the toast pop.
struct ScheduleHistory: Hashable, Sendable {
    static let max = 20

    var snapshots: [MySchedule] = []

    var canUndo: Bool { !snapshots.isEmpty }

    func push(_ previous: MySchedule) -> ScheduleHistory {
        ScheduleHistory(snapshots: Array((snapshots + [previous]).suffix(Self.max)))
    }

    func pop() -> (schedule: MySchedule, rest: ScheduleHistory)? {
        guard let last = snapshots.last else { return nil }
        return (last, ScheduleHistory(snapshots: Array(snapshots.dropLast())))
    }

    func encode() -> String? {
        guard let data = try? JSONEncoder().encode(snapshots) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Lenient: unreadable text is an empty history.
    static func decode(_ text: String?) -> ScheduleHistory {
        guard let data = text?.data(using: .utf8), let list = try? JSONDecoder().decode([MySchedule].self, from: data) else {
            return ScheduleHistory()
        }
        return ScheduleHistory(snapshots: Array(list.suffix(max)))
    }
}

/// What the planner was told for this event (one list §1), kept with the personal state.
struct SchedulePreferences: Hashable, Sendable {
    var pace: PlanPace = .balanced
    var kidFriendly = false
    var maxWalkMinutes: Int? = nil
    var likedTags: Set<String> = []
    var dislikedTags: Set<String> = []
    /// Meal breaks wanted (lunch / dinner).
    var meals: Set<MealKind> = []
    var earliest: PlanClock? = nil
    var latest: PlanClock? = nil

    init() {}

    init(pace: PlanPace = .balanced, kidFriendly: Bool = false, maxWalkMinutes: Int? = nil, likedTags: Set<String> = [],
         dislikedTags: Set<String> = [], meals: Set<MealKind> = [], earliest: PlanClock? = nil, latest: PlanClock? = nil) {
        self.pace = pace
        self.kidFriendly = kidFriendly
        self.maxWalkMinutes = maxWalkMinutes
        self.likedTags = likedTags
        self.dislikedTags = dislikedTags
        self.meals = meals
        self.earliest = earliest
        self.latest = latest
    }

    /// From a request's preferences and an edit's constraints (a new plan, a migrated one).
    init(_ preferences: PlanPreferences, constraints: PlanConstraints = .none) {
        pace = constraints.pace ?? preferences.pace
        kidFriendly = preferences.kidFriendly
        maxWalkMinutes = constraints.maxWalkMinutes
        likedTags = preferences.likedTags
        dislikedTags = preferences.dislikedTags
        meals = preferences.includeMeals ? Set(MealKind.allCases) : []
        earliest = preferences.earliest
        latest = preferences.latest
    }

    var planPreferences: PlanPreferences {
        var p = PlanPreferences()
        p.likedTags = likedTags
        p.dislikedTags = dislikedTags
        p.earliest = earliest
        p.latest = latest
        p.pace = pace
        p.includeMeals = !meals.isEmpty
        p.kidFriendly = kidFriendly
        return p
    }

    var constraints: PlanConstraints {
        var c = PlanConstraints()
        c.maxWalkMinutes = maxWalkMinutes
        return c
    }
}

extension SchedulePreferences: Codable {
    private enum CodingKeys: String, CodingKey {
        case pace, kidFriendly = "kid_friendly", maxWalkMinutes = "max_walk_minutes", likedTags = "liked_tags"
        case dislikedTags = "disliked_tags", meals, earliest, latest
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pace = PlanPace.of(c.lenient(String.self, .pace))
        kidFriendly = c.lenient(Bool.self, .kidFriendly) ?? false
        maxWalkMinutes = c.lenient(Int.self, .maxWalkMinutes).flatMap { $0 > 0 ? $0 : nil }
        likedTags = Set((c.lenient([String].self, .likedTags) ?? []).map { $0.lowercased() })
        dislikedTags = Set((c.lenient([String].self, .dislikedTags) ?? []).map { $0.lowercased() })
        meals = Set((c.lenient([String].self, .meals) ?? []).compactMap { MealKind(rawValue: $0) })
        earliest = c.lenient(String.self, .earliest).flatMap(PlanClock.parse)
        latest = c.lenient(String.self, .latest).flatMap(PlanClock.parse)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(pace.rawValue, forKey: .pace)
        if kidFriendly { try c.encode(true, forKey: .kidFriendly) }
        try c.encodeIfPresent(maxWalkMinutes, forKey: .maxWalkMinutes)
        if !likedTags.isEmpty { try c.encode(likedTags.sorted(), forKey: .likedTags) }
        if !dislikedTags.isEmpty { try c.encode(dislikedTags.sorted(), forKey: .dislikedTags) }
        if !meals.isEmpty { try c.encode(meals.map(\.rawValue).sorted(), forKey: .meals) }
        try c.encodeIfPresent(earliest?.description, forKey: .earliest)
        try c.encodeIfPresent(latest?.description, forKey: .latest)
    }
}

extension Planner {
    /// One list §2: the planner as a function. Plans from `now` with `request` (else the stored
    /// preferences), My schedule's items as the must-includes (rule 7) and its timed food places
    /// covering their meal breaks, then diffs the result against My schedule. Rules 1–20 and the
    /// fixture's numbers are unchanged; only the output is a proposal. `plan` is the planner's
    /// result (its reasons, walks and alternatives, for the preview).
    static func propose(_ schedule: MySchedule, preferences: SchedulePreferences, request: PlanPreferences? = nil,
                        text: String = "", constraints: PlanConstraints = .none, bundle: EventBundle,
                        now: Date) -> (plan: Plan, proposal: ScheduleProposal) {
        var constraints = constraints
        constraints.mealsDone.formUnion(schedule.mealsCovered(bundle))
        if constraints.maxWalkMinutes == nil { constraints.maxWalkMinutes = preferences.maxWalkMinutes }
        let planner = Planner(bundle: bundle, preferences: request ?? preferences.planPreferences,
                              heartedItems: schedule.itemIds, heartedLocations: schedule.placeIds, constraints: constraints)
        let plan = planner.plan(from: now, request: text, createdAt: Date(timeIntervalSince1970: now.timeIntervalSince1970.rounded(.down)))
        return (plan, schedule.proposal(for: plan, bundle))
    }
}
