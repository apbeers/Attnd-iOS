// PlanPage.swift
// Attnd (app target only — not in the App Clip; pure, unit tested in PlanPageTests)
//
// The rules behind the plan page (attnd-web docs/specs/planner_view_spec.md, iOS, Nov 19, 2026):
// a trip-style itinerary that replaced the snapping plan panel. Everything here is pure and
// works offline from the bundle, the plan and the cached forecast:
//   - `PlanPage.model`: the page's sections — one per plan day with a header (date, item count,
//     forecast) and its rows on a timeline rail: item cards, walk legs between items ("Main Stage
//     → Taco Row · 6 min walk"), meal breaks, gap rows ("45 min free · 3 ideas nearby") and the
//     shown proposal's dashed suggested rows (`PlanPreview`). Each row carries the sticky chip it
//     belongs to: days ("1 Sat", "2 Sun") when the plan spans days, else Morning (< 12:00) /
//     Afternoon (12–17) / Evening (≥ 17:00) in the event's zone.
//   - `PlanPage.gapIdeas`: ≤ 3 unplanned candidates that fit a gap of ≥ 30 min (after the earlier
//     entry, before the later one, walk ≤ 10 min from the earlier place), by score, start, id —
//     `LiveAssist.gaps`' rule for any day and more than one idea.
//   - `PlanPage.changeOptions`: the Change sheet of a planned item: the planner's swap
//     alternatives first, then the day's other candidates that fit between its neighbours (score,
//     start, id), not started, not planned, ≤ 6; each with its reason, start difference ("45 min
//     later") and walking difference ("3 min more walking") against the planned item.
//   - `PlanPage.legOptions` ("a closer option": the next stop swapped for an option with a shorter
//     walk; "leave earlier": the stop before swapped for one that ends earlier) and
//     `PlanPage.mealOptions` (food items around the break, food places by walk) for walk legs and
//     meal breaks.
//   - `PlanPage.stats`: the bottom bar ("8 items · 10 AM – 11 PM · 2.1 mi walking").
//   - Weather (WeatherKit, cached on disk by `WeatherStore`): `PlanForecast` (Codable, the cache
//     format), the day chip ("72°/58° · 40%"), the "as of 2:14 PM" line, the model's forecast line
//     ("Sat Nov 14: 72°F / 58°F, partly cloudy, 40% rain after 3 PM"), the coordinate (the event's,
//     else the locations' centre) and the hourly refresh rule.
//   - The day summary's cache key, prompt and fallback (`Planner.summary` of that day).

import Foundation

// MARK: - Sections and chips

enum DayPart: String, CaseIterable, Hashable, Sendable {
    case morning, afternoon, evening

    var label: String {
        switch self {
        case .morning: return "Morning"
        case .afternoon: return "Afternoon"
        case .evening: return "Evening"
        }
    }

    /// Morning before 12:00, afternoon 12:00–17:00, evening from 17:00 (the event's zone).
    static func of(_ date: Date, in calendar: Calendar) -> DayPart {
        let hour = calendar.component(.hour, from: date)
        if hour < 12 { return .morning }
        return hour < 17 ? .afternoon : .evening
    }
}

/// A sticky chip at the top of the page; tapping scrolls to `anchor` (a row id).
struct PlanPageChip: Identifiable, Hashable, Sendable {
    var id: String
    var label: String
    var anchor: String
}

/// A walk leg between two planned items.
struct PlanPageLeg: Hashable, Sendable {
    var leg: RouteLeg
    /// "Main Stage → Taco Row".
    var title: String
    /// "6 min walk · 0.3 mi" ("about …" for the straight-line estimate).
    var detail: String
}

/// A free stretch between two entries with ideas for it.
struct PlanPageGap: Hashable, Sendable {
    var date: PlanDate
    var start: Date
    var end: Date
    var minutes: Int
    /// ≤ 3 schedule item ids, best first.
    var ideas: [Int]
    /// The entry before (an item id; nil after a meal break).
    var afterItem: Int?

    /// "45 min free · 3 ideas nearby", "1 h 15 min free · 1 idea nearby", "45 min free".
    var text: String {
        let free = "\(AssistantText.duration(minutes * 60)) free"
        switch ideas.count {
        case 0: return free
        case 1: return free + " · 1 idea nearby"
        default: return free + " · \(ideas.count) ideas nearby"
        }
    }
}

enum PlanPageRowKind: Hashable, Sendable {
    case item(PlannedItem, PreviewMark?)
    case leg(PlanPageLeg)
    case meal(MealBreak, PreviewMark?)
    case gap(PlanPageGap)
    case suggestion(ProposalSuggestion)
}

struct PlanPageRow: Identifiable, Hashable, Sendable {
    var id: String
    var kind: PlanPageRowKind
    /// The chip this row is under.
    var chip: String
}

struct PlanPageDay: Identifiable, Hashable, Sendable {
    var date: PlanDate
    /// Planned items that day.
    var itemCount: Int
    var rows: [PlanPageRow]

    var id: String { "day-\(date)" }
    /// "1 item", "5 items".
    var countText: String { itemCount == 1 ? "1 item" : "\(itemCount) items" }
}

struct PlanPageModel: Hashable, Sendable {
    var chips: [PlanPageChip]
    var days: [PlanPageDay]

    var rows: [PlanPageRow] { days.flatMap(\.rows) }

    /// The chip of `rowId` (the topmost row on screen); the first chip when unknown.
    func chip(for rowId: String?) -> String? {
        if let rowId {
            if let day = days.first(where: { $0.id == rowId }) { return day.rows.first?.chip ?? chips.first { $0.anchor == day.id }?.id }
            if let row = rows.first(where: { $0.id == rowId }) { return row.chip }
        }
        return chips.first?.id
    }
}

// MARK: - Change options

/// One alternative in the Change sheet.
struct PlanChangeOption: Identifiable, Hashable, Sendable {
    var itemId: Int
    var reason: String
    /// Start difference in minutes (positive: later).
    var startDelta: Int
    /// Walking difference in minutes against the planned item (nil: no coordinates).
    var walkDelta: Int?
    /// One of the planner's own swap alternatives.
    var isAlternative: Bool

    var id: Int { itemId }

    /// "Same time", "45 min later", "1 h earlier".
    var timeText: String { PlanPage.deltaText(startDelta, same: "Same time", more: "later", less: "earlier") }

    /// "Same walk", "3 min more walking", "2 min less walking"; nil without coordinates.
    var walkText: String? {
        walkDelta.map { PlanPage.deltaText($0, same: "Same walk", more: "more walking", less: "less walking") }
    }
}

/// A walk leg's Change sheet.
struct PlanLegOptions: Hashable, Sendable {
    /// The next stop swapped for one closer to the previous stop (shorter walk), best first.
    var closer: [PlanChangeOption]
    /// The previous stop swapped for one that ends earlier (more time to walk), best first.
    var leaveEarlier: [PlanChangeOption]
    /// Leave the previous stop by this time to arrive 5 min early.
    var leaveBy: Date?
}

/// A meal break's Change sheet.
struct PlanMealOptions: Hashable, Sendable {
    /// Unplanned food items around the break that fit the plan (adds).
    var foodItems: [Int]
    /// Food places by walk from the stop before (location id, walk minutes or nil).
    var places: [PlanMealPlace]
}

struct PlanMealPlace: Hashable, Sendable {
    var locationId: Int
    var walkMinutes: Int?
}

// MARK: - Bottom bar

struct PlanPageStats: Hashable, Sendable {
    var items: Int
    var days: Int
    var first: Date?
    var last: Date?
    var walkedMeters: Double

    /// "8 items · 10 AM – 11 PM · 2.1 mi walking" (one day) or "5 items over 2 days · 3.4 mi
    /// walking"; "No walking" is left out.
    func text(zone: TimeZone, units: DistanceUnits, locale: Locale) -> String {
        let count = items == 1 ? "1 item" : "\(items) items"
        var parts: [String] = []
        if days > 1 {
            parts.append("\(count) over \(days) days")
        } else {
            parts.append(count)
            if let first, let last { parts.append("\(PlanPage.shortTime(first, zone, locale)) – \(PlanPage.shortTime(last, zone, locale))") }
        }
        if walkedMeters > 0 { parts.append("\(AssistantText.distance(walkedMeters, units, locale: locale)) walking") }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Weather (the cache format of WeatherStore)

struct PlanDayForecast: Codable, Hashable, Sendable {
    var date: String
    /// °C.
    var high: Double
    var low: Double
    /// 0…1.
    var precipitationChance: Double
    /// An SF Symbol name from WeatherKit.
    var symbol: String
    /// "Partly cloudy".
    var condition: String

    var planDate: PlanDate? { PlanDate.parse(date) }
}

struct PlanHourForecast: Codable, Hashable, Sendable {
    var date: Date
    /// °C.
    var temperature: Double
    var precipitationChance: Double
    var symbol: String
}

/// The last forecast for an event (Application Support, per event; shown offline with "as of").
struct PlanForecast: Codable, Hashable, Sendable {
    var eventId: Int
    var fetchedAt: Date
    var latitude: Double
    var longitude: Double
    var days: [PlanDayForecast]
    var hours: [PlanHourForecast] = []

    func day(_ date: PlanDate) -> PlanDayForecast? { days.first { $0.planDate == date } }

    static func decode(_ data: Data?) -> PlanForecast? {
        guard let data else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try? decoder.decode(PlanForecast.self, from: data)
    }

    func encoded() -> Data? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(self)
    }
}

enum PlanWeather {
    /// Rain chances from this are shown on the chip and in the model's line.
    static let rainShown = 0.3
    /// Fetched at most this often while the plan is shown (and online).
    static let refreshInterval: TimeInterval = 3600

    /// The forecast's place: the event's coordinate, else the centre of its locations' (nil: none).
    static func coordinate(_ bundle: EventBundle) -> Coordinate? {
        if let point = bundle.event.coordinate { return point }
        let points = bundle.locations.compactMap(\.coordinate)
        guard !points.isEmpty else { return nil }
        let lat = points.map(\.latitude).reduce(0, +) / Double(points.count)
        let lng = points.map(\.longitude).reduce(0, +) / Double(points.count)
        return Coordinate.valid(latitude: lat, longitude: lng)
    }

    /// Fetch when there is no forecast, it is for another place (> ~1 km), or it is an hour old.
    static func needsFetch(_ cached: PlanForecast?, at point: Coordinate, now: Date) -> Bool {
        guard let cached else { return true }
        if abs(cached.latitude - point.latitude) > 0.01 || abs(cached.longitude - point.longitude) > 0.01 { return true }
        return now.timeIntervalSince(cached.fetchedAt) >= refreshInterval || now < cached.fetchedAt
    }

    static func degrees(_ celsius: Double, fahrenheit: Bool) -> Int {
        let value = fahrenheit ? celsius * 9 / 5 + 32 : celsius
        return Int(value.rounded(.toNearestOrAwayFromZero))
    }

    /// The day header's chip: "72°/58°" (+ " · 40%" when rain is likely, ≥ 30 %).
    static func chipText(_ day: PlanDayForecast, fahrenheit: Bool) -> String {
        var text = "\(degrees(day.high, fahrenheit: fahrenheit))°/\(degrees(day.low, fahrenheit: fahrenheit))°"
        if day.precipitationChance >= rainShown { text += " · \(percent(day.precipitationChance))%" }
        return text
    }

    /// VoiceOver: "Partly cloudy, high 72°, low 58°, 40% chance of rain".
    static func spokenText(_ day: PlanDayForecast, fahrenheit: Bool) -> String {
        var text = "\(day.condition), high \(degrees(day.high, fahrenheit: fahrenheit))°, low \(degrees(day.low, fahrenheit: fahrenheit))°"
        if day.precipitationChance >= rainShown { text += ", \(percent(day.precipitationChance))% chance of rain" }
        return text
    }

    /// "as of 2:14 PM" (the device's zone: when this phone fetched it); "as of Sat 2:14 PM" on another day.
    static func asOfText(_ fetchedAt: Date, now: Date, zone: TimeZone = .current, locale: Locale = .current) -> String {
        let calendar = PlanCalendar.calendar(zone)
        let pattern = calendar.isDate(fetchedAt, inSameDayAs: now) ? "h:mm a" : "EEE h:mm a"
        return "as of " + AssistantText.format(fetchedAt, pattern, zone, locale)
    }

    /// The first hour of `date` (event zone, 08:00–23:00) with rain likely: "after 3 PM".
    static func rainStart(_ forecast: PlanForecast, _ date: PlanDate, zone: TimeZone, locale: Locale) -> String? {
        let calendar = PlanCalendar.calendar(zone)
        let hour = forecast.hours
            .filter { PlanDate($0.date, in: calendar) == date && $0.precipitationChance >= rainShown }
            .filter { (8...23).contains(calendar.component(.hour, from: $0.date)) }
            .min { $0.date < $1.date }
        return hour.map { "after " + AssistantText.format($0.date, "h a", zone, locale) }
    }

    /// One line per event day in the forecast for the model: "Sat Nov 14: 72°F / 58°F, partly
    /// cloudy, 40% rain after 3 PM".
    static func promptLines(_ forecast: PlanForecast?, days: [PlanDate], zone: TimeZone, fahrenheit: Bool, locale: Locale) -> [String] {
        guard let forecast else { return [] }
        let unit = fahrenheit ? "°F" : "°C"
        let utc = PlanCalendar.calendar(TimeZone(identifier: "UTC") ?? zone)
        return days.compactMap { date in
            guard let day = forecast.day(date) else { return nil }
            let label = AssistantText.format(date.at(PlanClock(hour: 12, minute: 0), in: utc), "EEE MMM d", utc.timeZone, locale)
            var text = "\(label): \(degrees(day.high, fahrenheit: fahrenheit))\(unit) / \(degrees(day.low, fahrenheit: fahrenheit))\(unit), \(day.condition.lowercased())"
            if day.precipitationChance >= rainShown {
                text += ", \(percent(day.precipitationChance))% rain"
                if let start = rainStart(forecast, date, zone: zone, locale: locale) { text += " " + start }
            }
            return text
        }
    }

    private static func percent(_ chance: Double) -> Int { Int((chance * 100).rounded(.toNearestOrAwayFromZero)) }
}

// MARK: - Rules

enum PlanPage {
    static let gapMinutes = 30
    static let gapMaxWalk = 10
    static let maxIdeas = 3
    static let maxOptions = 6
    /// Arrive this early when leaving earlier.
    static let arriveEarly = 5

    /// The page for `plan` (nil: no plan) with `preview` marked in place. `routes`: the days'
    /// routes with real legs where known (else straight-line estimates).
    static func model(
        plan: Plan?,
        _ bundle: EventBundle,
        likes: LikeSet,
        now: Date,
        preview: PlanPreview? = nil,
        routes: [PlanDate: DayRoute] = [:],
        units: DistanceUnits = .imperial,
        locale: Locale = Locale(identifier: "en_US")
    ) -> PlanPageModel {
        let calendar = PlanCalendar.calendar(bundle.event.timeZone)
        let ownDays = (plan?.days ?? []).filter { !$0.entries.isEmpty }.map(\.date)
        let suggested = preview.map { Array($0.suggestions.keys) } ?? []
        let dates = Array(Set(ownDays + suggested)).sorted()
        let byDay = dates.count > 1
        let planner = plan.map {
            Planner(bundle: bundle, preferences: $0.preferences, heartedItems: likes.scheduleItems,
                    heartedLocations: likes.locations, constraints: $0.constraints)
        }
        var days: [PlanPageDay] = []
        var chips: [PlanPageChip] = []
        for (index, date) in dates.enumerated() {
            let day = plan?.days.first { $0.date == date }
            let route = routes[date] ?? plan.flatMap { DayRoutes.of($0, bundle, date: date) }
            let dayId = "day-\(date)"
            var rows: [PlanPageRow] = []
            func chipId(_ start: Date) -> String { byDay ? dayId : "part-\(DayPart.of(start, in: calendar).rawValue)" }
            func add(_ id: String, _ kind: PlanPageRowKind, _ start: Date) { rows.append(PlanPageRow(id: id, kind: kind, chip: chipId(start))) }
            let suggestions = preview?.suggestions[date] ?? []
            for s in suggestions where s.after == nil { add("suggestion-\(s.option)-\(s.itemId)", .suggestion(s), s.start) }
            let entries = day?.entries ?? []
            for (position, entry) in entries.enumerated() {
                switch entry {
                case .item(let planned):
                    if let leg = route?.legs.first(where: { $0.toItem == planned.itemId }) {
                        add("leg-\(leg.toItem)", .leg(pageLeg(leg, bundle, units: units, locale: locale)), planned.start)
                    }
                    add("item-\(planned.itemId)", .item(planned, preview?.marks[planned.itemId]), planned.start)
                    for s in suggestions where s.after == planned.itemId { add("suggestion-\(s.option)-\(s.itemId)", .suggestion(s), s.start) }
                case .meal(let meal):
                    add("meal-\(date)-\(meal.kind.rawValue)", .meal(meal, preview?.mealMarks[MealSlot(date: date, kind: meal.kind)]), meal.start)
                }
                if position + 1 < entries.count, let planner, let plan, let day,
                   let gap = gap(after: position, day, plan, bundle, planner, now: now) {
                    add("gap-\(date)-\(position)", .gap(gap), gap.start)
                }
            }
            let count = day?.items.count ?? 0
            days.append(PlanPageDay(date: date, itemCount: count, rows: rows))
            if byDay {
                let label = "\(index + 1) " + AssistantText.format(date.at(PlanClock(hour: 12, minute: 0), in: calendar), "EEE", calendar.timeZone, locale)
                chips.append(PlanPageChip(id: dayId, label: label, anchor: dayId))
            }
        }
        if !byDay {
            for part in DayPart.allCases {
                let id = "part-\(part.rawValue)"
                guard let first = days.first?.rows.first(where: { $0.chip == id }) else { continue }
                chips.append(PlanPageChip(id: id, label: part.label, anchor: first.id))
            }
        }
        return PlanPageModel(chips: chips, days: days)
    }

    static func pageLeg(_ leg: RouteLeg, _ bundle: EventBundle, units: DistanceUnits, locale: Locale) -> PlanPageLeg {
        let from = bundle.location(leg.from.locationId)?.name ?? "Here"
        let to = bundle.location(leg.to.locationId)?.name ?? "there"
        return PlanPageLeg(leg: leg, title: "\(from) → \(to)", detail: DayRoutes.legText(leg, units, locale: locale))
    }

    // MARK: Gaps

    /// The gap after entry `position` of `day` (nil: < 30 min, already over).
    static func gap(after position: Int, _ day: PlanDay, _ plan: Plan, _ bundle: EventBundle, _ planner: Planner, now: Date) -> PlanPageGap? {
        let entries = day.entries
        guard position + 1 < entries.count else { return nil }
        let a = entries[position], b = entries[position + 1]
        guard b.start > now else { return nil }
        let start = max(a.end, PlanCalendar.truncatedToMinute(now))
        let free = PlanCalendar.minutes(from: start, to: b.start)
        guard free >= gapMinutes else { return nil }
        let ideas = gapIdeas(a, b, from: start, day, plan, bundle, planner)
        var after: Int?
        if case .item(let p) = a { after = p.itemId }
        return PlanPageGap(date: day.date, start: start, end: b.start, minutes: free, ideas: ideas, afterItem: after)
    }

    /// See the file comment.
    static func gapIdeas(_ a: PlanEntry, _ b: PlanEntry, from start: Date, _ day: PlanDay, _ plan: Plan, _ bundle: EventBundle, _ planner: Planner) -> [Int] {
        let planned = Set(plan.itemIds)
        var itemA: ScheduleItem?, itemB: ScheduleItem?, placeId: Int?
        switch a {
        case .item(let p): itemA = bundle.scheduleItem(p.itemId); placeId = itemA?.locationId
        case .meal(let m): placeId = m.locationId
        }
        if case .item(let p) = b { itemB = bundle.scheduleItem(p.itemId) }
        let place = bundle.location(placeId)
        func walk(_ c: ScheduleItem) -> Int? {
            if let id = c.locationId, id == placeId { return 0 }
            guard let from = place?.coordinate, let to = bundle.location(c.locationId)?.coordinate else { return nil }
            return Planner.walkMinutes(meters: Planner.distance(from, to))
        }
        return planner.dayCandidates(day).filter { c in
            guard !planned.contains(c.id), let cs = c.startTime, let ce = ScheduleTiming.effectiveEnd(of: c) else { return false }
            return cs >= start
                && (itemA.map { planner.canFollow($0, c) } ?? (cs >= a.end))
                && (itemB.map { planner.canFollow(c, $0) } ?? (ce <= b.start))
                && (walk(c).map { $0 <= gapMaxWalk } ?? true)
        }
        .stableSorted { x, y in byScore(x, y, planner) }
        .prefix(maxIdeas)
        .map(\.id)
    }

    private static func byScore(_ x: ScheduleItem, _ y: ScheduleItem, _ planner: Planner) -> Bool {
        let sx = planner.score(x), sy = planner.score(y)
        if sx != sy { return sx > sy }
        if x.startTime != y.startTime { return (x.startTime ?? .distantPast) < (y.startTime ?? .distantPast) }
        return x.id < y.id
    }

    // MARK: Change options

    /// The planned items around `itemId` on its day (nil when it isn't planned).
    private static func neighbours(_ itemId: Int, _ plan: Plan) -> (day: PlanDay, before: PlannedItem?, after: PlannedItem?, planned: PlannedItem)? {
        for day in plan.days {
            let items = day.items
            guard let index = items.firstIndex(where: { $0.itemId == itemId }) else { continue }
            return (day, index > 0 ? items[index - 1] : nil, index + 1 < items.count ? items[index + 1] : nil, items[index])
        }
        return nil
    }

    static func planner(_ plan: Plan, _ bundle: EventBundle, _ likes: LikeSet) -> Planner {
        Planner(bundle: bundle, preferences: plan.preferences, heartedItems: likes.scheduleItems,
                heartedLocations: likes.locations, constraints: plan.constraints)
    }

    /// See the file comment.
    static func changeOptions(_ itemId: Int, _ plan: Plan, _ bundle: EventBundle, _ likes: LikeSet, now: Date) -> [PlanChangeOption] {
        guard let around = neighbours(itemId, plan), let old = bundle.scheduleItem(itemId) else { return [] }
        let planner = planner(plan, bundle, likes)
        let planned = Set(plan.itemIds)
        let before = around.before.flatMap { bundle.scheduleItem($0.itemId) }
        let after = around.after.flatMap { bundle.scheduleItem($0.itemId) }
        func usable(_ c: ScheduleItem) -> Bool {
            c.id != itemId && !planned.contains(c.id) && (c.startTime ?? .distantPast) > now
        }
        func fits(_ c: ScheduleItem) -> Bool {
            (before.map { planner.canFollow($0, c) } ?? true) && (after.map { planner.canFollow(c, $0) } ?? true)
        }
        let alternatives = around.planned.alternatives.compactMap { bundle.scheduleItem($0) }.filter(usable)
        let taken = Set(alternatives.map(\.id))
        let fitting = planner.dayCandidates(around.day)
            .filter { usable($0) && !taken.contains($0.id) && fits($0) }
            .stableSorted { byScore($0, $1, planner) }
        func walks(_ item: ScheduleItem) -> Int? {
            var total = 0
            if let before {
                guard let w = planner.walkBetween(before, item) else { return nil }
                total += w
            }
            if let after {
                guard let w = planner.walkBetween(item, after) else { return nil }
                total += w
            }
            return total
        }
        let oldWalk = walks(old)
        return (alternatives + fitting).prefix(maxOptions).map { c in
            let start = c.startTime ?? around.planned.start
            let delta = Int((start.timeIntervalSince(around.planned.start) / 60).rounded(.towardZero))
            let walk = walks(c)
            return PlanChangeOption(
                itemId: c.id,
                reason: planner.reason(c),
                startDelta: delta,
                walkDelta: zip2(walk, oldWalk).map { $0 - $1 },
                isAlternative: taken.contains(c.id)
            )
        }
    }

    private static func zip2(_ a: Int?, _ b: Int?) -> (Int, Int)? {
        guard let a, let b else { return nil }
        return (a, b)
    }

    /// A walk leg's options (see the file comment).
    static func legOptions(_ leg: RouteLeg, _ plan: Plan, _ bundle: EventBundle, _ likes: LikeSet, now: Date) -> PlanLegOptions {
        let current = Planner.walkMinutes(meters: leg.straightMeters)
        let closer = changeOptions(leg.toItem, plan, bundle, likes, now: now).filter { option in
            guard let item = bundle.scheduleItem(option.itemId) else { return false }
            if item.locationId == leg.from.locationId { return true }
            guard let to = bundle.location(item.locationId)?.coordinate else { return false }
            return Planner.walkMinutes(meters: Planner.distance(leg.from.point, to)) < current
        }
        let fromPlanned = plan.items.first { $0.itemId == leg.fromItem }
        let earlier = changeOptions(leg.fromItem, plan, bundle, likes, now: now).filter { option in
            guard let fromPlanned, let end = bundle.scheduleItem(option.itemId).flatMap(ScheduleTiming.effectiveEnd) else { return false }
            return end < fromPlanned.end
        }
        let next = plan.items.first { $0.itemId == leg.toItem }
        let leaveBy = next.map { $0.start.addingTimeInterval(-TimeInterval((AssistantText.minutes(leg.route.durationSeconds) + arriveEarly) * 60)) }
        return PlanLegOptions(closer: closer, leaveEarlier: earlier, leaveBy: leaveBy)
    }

    /// A meal break's options: unplanned food items starting within an hour of the break that the
    /// plan can take (an add keeps the plan valid), and food places by walk from the stop before.
    static func mealOptions(_ meal: MealBreak, _ plan: Plan, _ bundle: EventBundle, _ likes: LikeSet, now: Date) -> PlanMealOptions {
        let planner = planner(plan, bundle, likes)
        let planned = Set(plan.itemIds)
        let window = meal.start.addingTimeInterval(-3600)...meal.start.addingTimeInterval(3600)
        let plannedItems = plan.items.compactMap { bundle.scheduleItem($0.itemId) }
        let food = bundle.schedule.filter { item in
            guard !planned.contains(item.id), let start = item.startTime, start > now, window.contains(start),
                  Planner.isFood(bundle, item) else { return false }
            return plannedItems.allSatisfy { planner.fitsWith($0, item) }
        }
        .stableSorted { byScore($0, $1, planner) }
        .prefix(maxIdeas)
        .map(\.id)
        let day = plan.days.first { $0.meals.contains(meal) }
        let previous = day?.items.last { $0.end <= meal.start }.flatMap { bundle.scheduleItem($0.itemId) }
        let origin = bundle.location(previous?.locationId)?.coordinate ?? bundle.location(meal.locationId)?.coordinate
        let places = bundle.locations.filter { location in
            func isFood(_ text: String?) -> Bool { text.map { PlanText.normalize($0).contains("food") } ?? false }
            return isFood(location.category) || location.tags.contains { isFood($0) }
        }
        .map { location -> PlanMealPlace in
            let walk = zip2c(origin, location.coordinate).map { Planner.walkMinutes(meters: Planner.distance($0, $1)) }
            return PlanMealPlace(locationId: location.id, walkMinutes: walk)
        }
        .stableSorted { a, b in
            switch (a.walkMinutes, b.walkMinutes) {
            case let (x?, y?) where x != y: return x < y
            case (.some, nil): return true
            case (nil, .some): return false
            default: return a.locationId < b.locationId
            }
        }
        return PlanMealOptions(foodItems: Array(food), places: Array(places.prefix(4)))
    }

    private static func zip2c(_ a: Coordinate?, _ b: Coordinate?) -> (Coordinate, Coordinate)? {
        guard let a, let b else { return nil }
        return (a, b)
    }

    // MARK: Remove → "Also fill this gap?"

    /// A proposal that only removes one planned item (a row's Remove): the item and the preview.
    static func removal(_ proposal: PlanProposal, _ bundle: EventBundle, now: Date) -> (itemId: Int, edit: PlanEdit)? {
        guard proposal.options.count == 1, let option = proposal.options.first,
              case .action(let action) = option.apply, let ops = action.ops(bundle, now: now),
              ops.count == 1, case .remove(let item) = ops[0] else { return nil }
        return (item, option.edit)
    }

    /// The ideas for the gap the removed item leaves in the previewed plan (≤ 3; empty when no
    /// gap of ≥ 30 min opens or nothing fits it).
    static func fillIdeas(_ edit: PlanEdit, removed: Int, _ bundle: EventBundle, _ likes: LikeSet, now: Date) -> [Int] {
        guard let old = edit.before.items.first(where: { $0.itemId == removed }) else { return [] }
        let after = edit.after
        let calendar = PlanCalendar.calendar(bundle.event.timeZone)
        guard let day = after.days.first(where: { $0.date == PlanDate(old.start, in: calendar) }) else { return [] }
        let planner = planner(after, bundle, likes)
        for position in day.entries.indices {
            guard let gap = gap(after: position, day, after, bundle, planner, now: now) else { continue }
            if gap.start <= old.start && gap.end >= old.end { return gap.ideas.filter { $0 != removed } }
        }
        return []
    }

    // MARK: Texts

    /// "Same time" / "45 min later" / "1 h earlier" (minutes; `more` for positive).
    static func deltaText(_ minutes: Int, same: String, more: String, less: String) -> String {
        if minutes == 0 { return same }
        return "\(AssistantText.duration(abs(minutes) * 60)) \(minutes > 0 ? more : less)"
    }

    /// "10 AM", "10:30 AM".
    static func shortTime(_ date: Date, _ zone: TimeZone, _ locale: Locale) -> String {
        let minute = PlanCalendar.calendar(zone).component(.minute, from: date)
        return AssistantText.format(date, minute == 0 ? "h a" : "h:mm a", zone, locale)
    }

    /// The bottom bar. `routes`: the days' routes with real legs where known.
    static func stats(_ plan: Plan, _ bundle: EventBundle, routes: [PlanDate: DayRoute] = [:]) -> PlanPageStats {
        let days = plan.days.filter { !$0.items.isEmpty }
        let meters = days.reduce(0.0) { total, day in
            total + ((routes[day.date] ?? DayRoutes.of(plan, bundle, date: day.date))?.totalMeters ?? 0)
        }
        let items = plan.items
        return PlanPageStats(items: items.count, days: days.count, first: items.map(\.start).min(), last: items.map(\.end).max(), walkedMeters: meters)
    }

    /// The header's date: "Saturday, Nov 14".
    static func dayTitle(_ date: PlanDate, locale: Locale) -> String {
        let utc = TimeZone(identifier: "UTC") ?? .current
        return AssistantText.format(date.at(PlanClock(hour: 12, minute: 0), in: PlanCalendar.calendar(utc)), "EEEE, MMM d", utc, locale)
    }

    // MARK: Day summary (on-device AI, cached)

    /// Changes whenever the day's entries change (the summary is generated again then).
    static func summaryKey(_ plan: Plan, _ date: PlanDate) -> String {
        let entries = plan.days.first { $0.date == date }?.entries ?? []
        let parts = entries.map { entry -> String in
            switch entry {
            case .item(let p): return "s\(p.itemId)@\(Int(p.start.timeIntervalSince1970))"
            case .meal(let m): return "\(m.kind.rawValue)@\(Int(m.start.timeIntervalSince1970))-\(m.locationId ?? 0)"
            }
        }
        return "\(plan.eventId):\(date):" + parts.joined(separator: ",")
    }

    /// The day's one-line fallback: `Planner.summary` of that day alone.
    static func fallbackSummary(_ plan: Plan, _ date: PlanDate, timeZone: TimeZone, locale: Locale) -> String {
        var day = plan
        day.days = plan.days.filter { $0.date == date }
        return Planner.summary(day, timeZone: timeZone, locale: locale)
    }

    /// What the on-device model reads to write the day's summary (short and long).
    static func summaryPrompt(_ plan: Plan, _ date: PlanDate, _ bundle: EventBundle, forecast: String?, locale: Locale) -> String {
        let zone = bundle.event.timeZone
        var lines = ["EVENT: \(bundle.event.name)", "DAY: \(dayTitle(date, locale: locale))"]
        if let forecast { lines.append("WEATHER: \(forecast)") }
        if let weatherPlan = bundle.event.context?.weatherPlan, !weatherPlan.isEmpty {
            lines.append("WEATHER PLAN: \(String(weatherPlan.prefix(200)))")
        }
        lines.append("PLAN:")
        for entry in plan.days.first(where: { $0.date == date })?.entries ?? [] {
            switch entry {
            case .item(let p):
                guard let item = bundle.scheduleItem(p.itemId) else { continue }
                let place = bundle.location(item.locationId)?.name ?? item.locationName ?? "General"
                var line = "- \(AssistantText.format(p.start, "h:mm a", zone, locale)) \(item.name) at \(place)"
                if !item.tags.isEmpty { line += " (\(item.tags.prefix(4).joined(separator: ", ")))" }
                if let genres = item.context?.genres, !genres.isEmpty { line += " — \(genres.prefix(3).joined(separator: ", "))" }
                lines.append(line)
            case .meal(let m):
                let place = bundle.location(m.locationId).map { " near \($0.name)" } ?? ""
                lines.append("- \(AssistantText.format(m.start, "h:mm a", zone, locale)) \(m.kind.label)\(place)")
            }
        }
        return lines.joined(separator: "\n")
    }
}
