// WhyNot.swift
// Attnd (app + App Clip; unit tested in AssistantExtrasTests)
//
// "Why isn't X in my plan?" (assistant spec §7), a port of Android's `domain/WhyNot.kt`: the first
// reason that applies, in the planner's own terms — no plan; already planned; removed by the
// attendee; ended; started; another day; outside the day's window; the kid-friendly filter; "I
// already ate"; a score ≤ 0 (disliked); a clash with a planned item of its day (the first by
// (start, end, id) that `Planner.fitsWith` rejects: overlap, walk limit, or no time to walk);
// else the pace / score choice. Liked and pinned items skip the three filters, like the planner.
// "Swap it in" (`plan_edit add`) unless there is no plan, it is planned, started or ended.

import Foundation

enum WhyNotReason: Hashable, Sendable {
    case noPlan, inPlan, excluded, ended, started, otherDay, outsideWindow
    case kidFriendly(tag: String)
    case food, disliked
    case clash(withId: Int, liked: Bool, pinned: Bool, overlaps: Bool, walkLimit: Bool)
    case lowScore
}

struct WhyNotAnswer: Hashable, Sendable {
    var itemId: Int
    var reason: WhyNotReason
    var text: String
    var canSwapIn: Bool
}

enum WhyNot {

    static func explain(_ itemId: Int, _ plan: Plan?, _ bundle: EventBundle, _ likes: LikeSet, now: Date, locale: Locale) -> WhyNotAnswer? {
        guard let item = bundle.scheduleItem(itemId) else { return nil }
        let name = item.name
        func answer(_ reason: WhyNotReason, _ text: String, swap: Bool = true) -> WhyNotAnswer {
            WhyNotAnswer(itemId: itemId, reason: reason, text: text, canSwapIn: swap)
        }
        guard let plan else { return answer(.noPlan, "You don't have a plan yet.", swap: false) }
        if plan.itemIds.contains(itemId) { return answer(.inPlan, "\(name) is already in your plan.", swap: false) }
        let c = plan.constraints
        if c.excluded.contains(itemId) { return answer(.excluded, "You took \(name) out of your plan.") }
        guard let start = item.startTime, let end = ScheduleTiming.effectiveEnd(of: item) else {
            return answer(.otherDay, "\(name) has no time yet.", swap: false)
        }
        if end <= now { return answer(.ended, "\(name) has ended.", swap: false) }
        if start < now { return answer(.started, "\(name) has already started.", swap: false) }
        let zone = bundle.event.timeZone
        let date = PlanDate(start, in: PlanCalendar.calendar(zone))
        guard let day = plan.days.first(where: { $0.date == date }) else {
            var covered: [String] = []
            for d in plan.days {
                let n = AssistantText.weekdayName(d.date, locale: locale)
                if !covered.contains(n) { covered.append(n) }
            }
            return answer(.otherDay, "\(name) is on \(AssistantText.weekdayName(date, locale: locale)), and your plan covers \(covered.joined(separator: " and ")).")
        }
        if start < day.windowStart || end > day.windowEnd {
            let from = AssistantText.format(day.windowStart, "h:mm a", zone, locale)
            let to = AssistantText.format(day.windowEnd, "h:mm a", zone, locale)
            return answer(.outsideWindow, "\(name) is outside your plan's hours (\(from) – \(to)).")
        }
        let planner = Planner(bundle: bundle, preferences: plan.preferences, heartedItems: likes.scheduleItems,
                              heartedLocations: likes.locations, constraints: c)
        let kept = likes.scheduleItems.contains(item.id) || c.pinned.contains(item.id)
        if !kept && plan.preferences.kidFriendly, let tag = item.tags.first(where: { Planner.adultTags.contains($0.lowercased()) }) {
            return answer(.kidFriendly(tag: tag), "\(name) is \(tag), and you asked for kid-friendly.")
        }
        if planner.foodBlocked(item), let until = c.noFoodUntil {
            return answer(.food, "You said you already ate, so food waits until \(AssistantText.format(until, "h:mm a", zone, locale)).")
        }
        if !kept && planner.score(item) <= 0 { return answer(.disliked, "\(name) has something you said you don't like.") }
        let clash = day.items.compactMap { bundle.scheduleItem($0.itemId) }.stableSorted(by: Planner.itemOrder)
            .first { !planner.fitsWith($0, item) }
        if let clash, let otherStart = clash.startTime, let otherEnd = ScheduleTiming.effectiveEnd(of: clash) {
            let overlaps = start < otherEnd && end > otherStart
            let liked = likes.scheduleItems.contains(clash.id)
            let pinned = c.pinned.contains(clash.id)
            let walk = planner.walkBetween(clash, item)
            let limit = c.maxWalkMinutes
            let overLimit = !overlaps && walk != nil && limit != nil && walk! > limit!
            let qualifier = liked ? " (in your schedule)" : pinned ? " (you added it)" : ""
            let text: String
            if overlaps {
                text = "\(name) clashes with \(clash.name)\(qualifier)."
            } else if overLimit {
                text = "The walk between \(name) and \(clash.name)\(qualifier) is longer than your \(limit!)-minute limit."
            } else {
                text = "There isn't time to walk between \(name) and \(clash.name)\(qualifier)."
            }
            return answer(.clash(withId: clash.id, liked: liked, pinned: pinned, overlaps: overlaps, walkLimit: overLimit), text)
        }
        return answer(.lowScore, "\(name) fits, but your plan already has things you'd probably like more.")
    }

    /// The "Swap it in" chip, when offered.
    static func chip(_ answer: WhyNotAnswer, _ bundle: EventBundle) -> AssistantChip? {
        answer.canSwapIn ? AssistantChip(label: "Swap it in", action: .planEdit([.add(item: answer.itemId)], bundle)) : nil
    }
}
