// LiveAssist.swift
// Attnd (app + App Clip; unit tested in AssistantExtrasTests)
//
// Live plan rules (assistant spec §6), a port of Android's `domain/LiveAssist.kt`; all local and
// pure, time and location are inputs:
// - Next planned item: the first planned item (all days, plan order) starting after `now`, not
//   checked off, not skipped.
// - Running late: user position known, the next item's location with coordinates, straight
//   line d > 100 m and ≤ 8 km: walk = estimate in whole minutes rounded up; leaveBy = start −
//   walk − 5 min. From leaveBy: LEAVE_NOW when now + walk ≤ start (chip Directions), else
//   CANT_MAKE_IT (chips "Swap for Y" for ≤ 3 swap alternatives not planned that start ≥ now +
//   the walk to them, then "Remove X").
// - Check-off: samples within 150 m of the item's location span ≥ 10 min in one unbroken run
//   while it ran. Skipped: ended, not checked off, samples while it ran and none within 150 m.
// - Gap filler: today's plan day, gaps ≥ 30 min (from max(a.end, now) to b.start), the best
//   candidate (score desc, start, id) that fits after a and before b with a walk ≤ 10 min.
// - Like clash: a liked item not planned that overlaps planned items → "Add to plan instead of X?".
// - Recap: checked-off items of the day, liked count, the walk through their stops.

import Foundation

/// A position fix with its time (only when location is already permitted).
struct LocationSample: Hashable, Sendable {
    var point: Coordinate
    var at: Date
}

enum LateState: Hashable, Sendable { case leaveNow, cantMakeIt }

struct RunningLate: Hashable, Sendable {
    var itemId: Int
    var state: LateState
    var walkMinutes: Int
    /// next.start − walk − 5 min.
    var leaveBy: Date
    var text: String
    var chips: [AssistantChip]
}

/// "40 free minutes near Trinity Stage: Kolache masterclass is 3 min away".
struct GapSuggestion: Hashable, Sendable {
    var date: PlanDate
    var gapStart: Date
    var gapEnd: Date
    var freeMinutes: Int
    var itemId: Int
    var walkMinutes: Int?
    var text: String
    var chip: AssistantChip
}

struct Recap: Hashable, Sendable {
    var date: PlanDate
    var checkedOff: [Int]
    var likedCount: Int
    var walkedMeters: Double
    var text: String
    var chips: [AssistantChip]
}

/// Chip labels stay short: the name is cut (with "…") so the label fits 60 characters.
enum ChipText {
    static func fit(_ prefix: String, _ name: String, _ suffix: String = "") -> String {
        let room = BlockValidator.maxChipLabel - prefix.count - suffix.count
        let cut = name.count <= room ? name : String(name.prefix(max(room - 1, 1))).trimmingTrailingSpaces() + "…"
        return prefix + cut + suffix
    }
}

enum LiveAssist {
    static let thereMeters = 100.0
    static let checkoffMeters = 150.0
    static let checkoffDwell: TimeInterval = 10 * 60
    static let gapMinutes = 30
    static let gapMaxWalk = 10
    static let maxSwaps = 3

    private static func walkMinutes(_ meters: Double) -> Int { AssistantText.minutes(AssistantText.estimateSeconds(meters)) }

    static func nextPlanned(_ plan: Plan, _ bundle: EventBundle, now: Date, skipped: Set<Int> = []) -> ScheduleItem? {
        plan.items.filter { $0.start > now && !plan.checkedOff.contains($0.itemId) && !skipped.contains($0.itemId) }
            .lazy.compactMap { bundle.scheduleItem($0.itemId) }.first
    }

    static func runningLate(_ plan: Plan, _ bundle: EventBundle, now: Date, user: Coordinate?, skipped: Set<Int> = []) -> RunningLate? {
        guard let user, let next = nextPlanned(plan, bundle, now: now, skipped: skipped),
              let location = bundle.location(next.locationId), let target = location.coordinate,
              let start = next.startTime else { return nil }
        let meters = Planner.distance(user, target)
        if meters <= thereMeters || meters > AssistantText.nearbyMeters { return nil }
        let walk = walkMinutes(meters)
        let leaveBy = start.addingTimeInterval(-TimeInterval((walk + Planner.bufferMinutes) * 60))
        if now < leaveBy { return nil }
        if now.addingTimeInterval(TimeInterval(walk * 60)) <= start {
            return RunningLate(itemId: next.id, state: .leaveNow, walkMinutes: walk, leaveBy: leaveBy,
                               text: "Leave now for \(next.name) · \(walk) min walk",
                               chips: [AssistantChip(label: "Directions", action: .directions(location.id))])
        }
        let planned = Set(plan.itemIds)
        let alternatives = (plan.items.first { $0.itemId == next.id }?.alternatives ?? [])
            .compactMap { bundle.scheduleItem($0) }
            .filter { alt in
                guard let altStart = alt.startTime else { return false }
                let altWalk = bundle.location(alt.locationId)?.coordinate.map { walkMinutes(Planner.distance(user, $0)) } ?? 0
                return !planned.contains(alt.id) && altStart >= now.addingTimeInterval(TimeInterval(altWalk * 60))
            }
            .prefix(maxSwaps)
        let chips = alternatives.map {
            AssistantChip(label: ChipText.fit("Swap for ", $0.name), action: .planEdit([.replace(item: next.id, with: $0.id)], bundle))
        } + [AssistantChip(label: ChipText.fit("Remove ", next.name), action: .planEdit([.remove(item: next.id)], bundle))]
        return RunningLate(itemId: next.id, state: .cantMakeIt, walkMinutes: walk, leaveBy: leaveBy,
                           text: "You can't make \(next.name) in time · \(walk) min walk", chips: chips)
    }

    static func autoCheck(_ item: ScheduleItem, _ bundle: EventBundle, samples: [LocationSample]) -> Bool {
        guard let point = bundle.location(item.locationId)?.coordinate, let start = item.startTime,
              let end = ScheduleTiming.effectiveEnd(of: item) else { return false }
        var runStart: Date?
        for sample in samples.filter({ $0.at >= start && $0.at <= end }).stableSorted(by: { $0.at < $1.at }) {
            if Planner.distance(sample.point, point) <= checkoffMeters {
                let first = runStart ?? sample.at
                runStart = first
                if sample.at.timeIntervalSince(first) >= checkoffDwell { return true }
            } else {
                runStart = nil
            }
        }
        return false
    }

    /// Planned items (started, not checked off) that the samples check off.
    static func checkOffs(_ plan: Plan, _ bundle: EventBundle, samples: [LocationSample], now: Date) -> Set<Int> {
        Set(plan.items.filter { !plan.checkedOff.contains($0.itemId) && $0.start <= now }
            .compactMap { bundle.scheduleItem($0.itemId) }
            .filter { autoCheck($0, bundle, samples: samples) }
            .map(\.id))
    }

    static func skipped(_ plan: Plan, _ bundle: EventBundle, samples: [LocationSample], now: Date) -> [Int] {
        plan.items.filter { $0.end <= now && !plan.checkedOff.contains($0.itemId) }.filter { planned in
            guard let point = bundle.scheduleItem(planned.itemId).flatMap({ bundle.location($0.locationId)?.coordinate }) else { return false }
            let during = samples.filter { $0.at >= planned.start && $0.at <= planned.end }
            return !during.isEmpty && !during.contains { Planner.distance($0.point, point) <= checkoffMeters }
        }.map(\.itemId)
    }

    static func skippedChip(_ itemId: Int, _ bundle: EventBundle) -> AssistantChip? {
        guard let item = bundle.scheduleItem(itemId) else { return nil }
        return AssistantChip(label: ChipText.fit("You skipped ", item.name, " — fill the gap?"), action: .planEdit([.remove(item: itemId)], bundle))
    }

    static func gaps(_ plan: Plan, _ bundle: EventBundle, _ likes: LikeSet, now: Date) -> [GapSuggestion] {
        let calendar = PlanCalendar.calendar(bundle.event.timeZone)
        let today = PlanDate(now, in: calendar)
        guard let day = plan.days.first(where: { $0.date == today }) else { return [] }
        let planner = Planner(bundle: bundle, preferences: plan.preferences, heartedItems: likes.scheduleItems,
                              heartedLocations: likes.locations, constraints: plan.constraints)
        let planned = Set(plan.itemIds)
        let candidates = planner.dayCandidates(day).filter { !planned.contains($0.id) }
        var suggestions: [GapSuggestion] = []
        var taken = Set<Int>()
        for (a, b) in zip(day.entries, day.entries.dropFirst()) {
            if b.start <= now { continue }
            let gapStart = max(a.end, now)
            let free = PlanCalendar.minutes(from: gapStart, to: b.start)
            if free < gapMinutes { continue }
            var itemA: ScheduleItem?, itemB: ScheduleItem?, placeId: Int?
            switch a {
            case .item(let p): itemA = bundle.scheduleItem(p.itemId); placeId = itemA?.locationId
            case .meal(let m): placeId = m.locationId
            }
            if case .item(let p) = b { itemB = bundle.scheduleItem(p.itemId) }
            let place = bundle.location(placeId)
            func walkFrom(_ c: ScheduleItem) -> Int? {
                if let id = c.locationId, id == placeId { return 0 }
                guard let from = place?.coordinate, let to = bundle.location(c.locationId)?.coordinate else { return nil }
                return walkMinutes(Planner.distance(from, to))
            }
            let best = candidates.filter { c in
                guard let cs = c.startTime, let ce = ScheduleTiming.effectiveEnd(of: c) else { return false }
                return !taken.contains(c.id) && cs >= gapStart
                    && (itemA.map { planner.canFollow($0, c) } ?? (cs >= a.end))
                    && (itemB.map { planner.canFollow(c, $0) } ?? (ce <= b.start))
                    && (walkFrom(c).map { $0 <= gapMaxWalk } ?? true)
            }.stableSorted { x, y in
                let sx = planner.score(x), sy = planner.score(y)
                if sx != sy { return sx > sy }
                if x.startTime != y.startTime { return (x.startTime ?? .distantPast) < (y.startTime ?? .distantPast) }
                return x.id < y.id
            }.first
            guard let best else { continue }
            taken.insert(best.id)
            let walk = walkFrom(best)
            let whereText = place.map { " near \($0.name)" } ?? ""
            let distance: String
            switch walk {
            case nil: distance = "fits"
            case 0?: distance = "is right here"
            case let minutes?: distance = "is \(minutes) min away"
            }
            suggestions.append(GapSuggestion(
                date: day.date, gapStart: gapStart, gapEnd: b.start, freeMinutes: free, itemId: best.id, walkMinutes: walk,
                text: "\(free) free minutes\(whereText): \(best.name) \(distance)",
                chip: AssistantChip(label: ChipText.fit("Add ", best.name), action: .planEdit([.add(item: best.id)], bundle))
            ))
        }
        return suggestions
    }

    static func likeClash(_ itemId: Int, _ plan: Plan, _ bundle: EventBundle) -> AssistantChip? {
        guard !plan.itemIds.contains(itemId), let item = bundle.scheduleItem(itemId), let start = item.startTime,
              let end = ScheduleTiming.effectiveEnd(of: item) else { return nil }
        let other = plan.items.filter { $0.start < end && $0.end > start }
            .compactMap { bundle.scheduleItem($0.itemId) }
            .min(by: Planner.itemOrder)
        guard let other else { return nil }
        return AssistantChip(label: ChipText.fit("Add to plan instead of ", other.name, "?"),
                             action: .planEdit([.replace(item: other.id, with: itemId)], bundle))
    }

    /// Planned items the organizer changed or removed since planning (the inline "Re-plan" card).
    static func changedItems(_ plan: Plan, _ bundle: EventBundle) -> [Int] {
        plan.itemIds.filter { id in
            guard let item = bundle.scheduleItem(id) else { return true }
            guard let print = plan.fingerprints[id] else { return false }
            return Planner.fingerprint(item) != print
        }
    }

    static func recap(_ plan: Plan, _ bundle: EventBundle, _ likes: LikeSet, date: PlanDate, now: Date, units: DistanceUnits, locale: Locale) -> Recap {
        let day = plan.days.first { $0.date == date }
        let checked = (day?.items ?? []).map(\.itemId).filter { plan.checkedOff.contains($0) }
        let liked = likes.scheduleItems.count + likes.locations.count
        let walked = DayRoutes.of(plan, bundle, date: date, only: Set(checked))?.totalMeters ?? 0
        let things = checked.count == 1 ? "1 thing" : "\(checked.count) things"
        let text = "You saw \(things), added \(liked) and walked \(AssistantText.distance(walked, units, locale: locale))."
        var chips: [AssistantChip] = []
        let laterPlanned = plan.days.contains { $0.date > date && !$0.items.isEmpty }
        let laterDay = PlanCalendar.eventDays(bundle, now: now).first { $0 > date }
        if laterPlanned {
            chips.append(AssistantChip(label: "Tomorrow's plan is ready", action: .open("plan")))
        } else if let laterDay {
            chips.append(AssistantChip(label: "Plan tomorrow", action: .planMake("Plan my \(laterDay.weekdayName)")))
        }
        return Recap(date: date, checkedOff: checked, likedCount: liked, walkedMeters: walked, text: text, chips: chips)
    }
}
