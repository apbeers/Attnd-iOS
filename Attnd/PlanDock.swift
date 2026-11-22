// PlanDock.swift
// Attnd (app + App Clip; pure, unit tested in PlanDockTests)
//
// The plan rules that outlived the plan page and its dock (both retired for the My plan chat, Nov 21,
// 2026; the pane and the results' inline actions went with them).
//   - `PlanDock.addToPlan` / `planAround`: those actions as in-place proposals (PlanProposal.swift):
//     an item that clashes with a planned one → a replace ("instead of X", the clashing row crossed
//     out), else an add; a place → its next unplanned items (≤ 4) as add options. Without a plan
//     both propose a new plan built around the item (pinned) or the place (counted as liked).
//   - `PlanDock.summaryLine`: the My plan button's peek ("Now: …", "Next: … · 7:00 PM · …").

import Foundation

/// The result of an inline plan action.
enum DockPlanChange: Hashable, Sendable {
    case proposal(PlanProposal)
    case message(String)
}

enum PlanDock {

    /// "Add to plan" on a schedule item.
    static func addToPlan(_ itemId: Int, _ ctx: RouterContext) -> DockPlanChange {
        guard let item = ctx.bundle.scheduleItem(itemId) else { return .message("That item isn't on the schedule any more.") }
        guard let start = item.startTime, start > ctx.now else { return .message("\(item.name) has already started.") }
        guard let plan = ctx.plan else {
            let calendar = PlanCalendar.calendar(ctx.bundle.event.timeZone)
            let made = planner(ctx, PlanPreferences(similarTo: [itemId], days: [PlanDate(start, in: calendar)]),
                               constraints: PlanConstraints(pinned: [itemId]))
                .plan(from: ctx.now, request: "Plan around \(item.name)", createdAt: createdAt(ctx.now))
            guard made.itemIds.contains(itemId) else { return .message("\(item.name) doesn't fit a plan.") }
            return .proposal(newPlan(made, text: "A plan around \(item.name): \(Planner.summary(made, timeZone: ctx.bundle.event.timeZone, locale: ctx.locale)).", ctx))
        }
        if plan.itemIds.contains(itemId) { return .message("\(item.name) is already in your plan.") }
        if let clash = LiveAssist.likeClash(itemId, plan, ctx.bundle),
           let other = replacedId(clash.action, ctx), let otherName = ctx.bundle.scheduleItem(other)?.name {
            let chip = AssistantChip(label: "Instead of \(otherName)", action: clash.action)
            if let proposal = PlanProposals.from(chips: [chip], text: "Add \(item.name) instead of \(otherName)?", ctx) {
                return .proposal(proposal)
            }
        }
        guard let proposal = PlanProposals.from(action: .planEdit([.add(item: itemId)], ctx.bundle), ctx) else {
            return .message("\(item.name) doesn't fit your plan.")
        }
        return .proposal(proposal)
    }

    /// "Plan around this" on a place.
    static func planAround(_ locationId: Int, _ ctx: RouterContext) -> DockPlanChange {
        guard let location = ctx.bundle.location(locationId) else { return .message("That place isn't on the map any more.") }
        let coming = upcoming(at: locationId, ctx)
        guard let first = coming.first, let start = first.startTime else {
            return .message("Nothing else is on at \(location.name).")
        }
        guard let plan = ctx.plan else {
            let calendar = PlanCalendar.calendar(ctx.bundle.event.timeZone)
            let made = planner(ctx, PlanPreferences(days: [PlanDate(start, in: calendar)]), extraLocation: locationId)
                .plan(from: ctx.now, request: "Plan around \(location.name)", createdAt: createdAt(ctx.now))
            guard !made.isEmpty else { return .message("Nothing on the schedule fits a plan around \(location.name).") }
            return .proposal(newPlan(made, text: "A plan around \(location.name): \(Planner.summary(made, timeZone: ctx.bundle.event.timeZone, locale: ctx.locale)).", ctx))
        }
        let planned = Set(plan.itemIds)
        let options = coming.filter { !planned.contains($0.id) }.prefix(PlanProposal.maxOptions)
        guard !options.isEmpty else { return .message("Everything still to come at \(location.name) is in your plan.") }
        let chips = options.map { AssistantChip(label: $0.name, action: .planEdit([.add(item: $0.id)], ctx.bundle)) }
        guard let proposal = PlanProposals.from(chips: chips, text: "Add from \(location.name):", ctx) else {
            return .message("Nothing at \(location.name) fits your plan.")
        }
        return .proposal(proposal)
    }

    /// The My plan button's peek and the plan page's title line.
    static func summaryLine(plan: Plan?, _ bundle: EventBundle, now: Date, locale: Locale = .current) -> String {
        guard let plan, !plan.isEmpty else { return "No plan yet · type to plan or search" }
        func place(_ item: ScheduleItem) -> String {
            let name = bundle.location(item.locationId)?.name ?? item.locationName
            return name.map { " · \($0)" } ?? ""
        }
        if let current = plan.items.first(where: { $0.start <= now && $0.end > now && !plan.checkedOff.contains($0.itemId) }),
           let item = bundle.scheduleItem(current.itemId) {
            return "Now: \(item.name)\(place(item))"
        }
        if let next = LiveAssist.nextPlanned(plan, bundle, now: now), let start = next.startTime {
            let formatter = DateFormatter()
            formatter.locale = locale
            formatter.timeZone = bundle.event.timeZone
            let calendar = PlanCalendar.calendar(bundle.event.timeZone)
            formatter.dateFormat = PlanDate(start, in: calendar) == PlanDate(now, in: calendar) ? "h:mm a" : "EEE h:mm a"
            return "Next: \(next.name) · \(formatter.string(from: start))\(place(next))"
        }
        return "Your plan is done · " + Planner.summary(plan, timeZone: bundle.event.timeZone, locale: locale)
    }

    // MARK: - Helpers

    /// Items at `locationId` that haven't started, in time order.
    static func upcoming(at locationId: Int, _ ctx: RouterContext) -> [ScheduleItem] {
        ctx.bundle.schedule
            .filter { $0.locationId == locationId && ($0.startTime.map { $0 > ctx.now } ?? false) }
            .sorted(by: Planner.itemOrder)
    }

    private static func planner(_ ctx: RouterContext, _ preferences: PlanPreferences,
                                constraints: PlanConstraints = .none, extraLocation: Int? = nil) -> Planner {
        var locations = ctx.likes.locations
        if let extraLocation { locations.insert(extraLocation) }
        return Planner(bundle: ctx.bundle, preferences: preferences, heartedItems: ctx.likes.scheduleItems,
                       heartedLocations: locations, constraints: constraints)
    }

    private static func createdAt(_ now: Date) -> Date {
        Date(timeIntervalSince1970: now.timeIntervalSince1970.rounded(.down))
    }

    private static func newPlan(_ plan: Plan, text: String, _ ctx: RouterContext) -> PlanProposal {
        let before = PlanProposals.emptyPlan(eventId: ctx.bundle.event.id, createdAt: plan.createdAt)
        let edit = PlanEdit(before: before, after: plan, diff: PlanDiff.between(before, plan, ctx.bundle), notes: [])
        return PlanProposal(kind: .change, text: text, options: [ProposalOption(label: "Use This Plan", apply: .newPlan(plan), edit: edit)])
    }

    private static func replacedId(_ action: AssistantAction, _ ctx: RouterContext) -> Int? {
        guard let ops = action.ops(ctx.bundle, now: ctx.now), ops.count == 1, case .replace(let item, _, _, _) = ops[0] else { return nil }
        return item
    }
}
