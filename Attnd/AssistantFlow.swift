// AssistantFlow.swift
// Attnd (app + App Clip; unit tested in AssistantFlowTests)
//
// The plan page's pure assistant helpers (assistant spec §3, §6–8), a port of Android's
// `domain/AssistantFlow.kt` with the same tests (iOS has no stored transcript, so Android's
// `AssistantTranscript` isn't ported):
//   - AssistantFlow: which path a typed turn takes, forced search / plan turns, the text the
//     model's conversation keeps of an answer, "Ask about this".
//   - BlockData: what a block shows, resolved from the bundle (timeline sources, compare sides,
//     summaries).
//   - LiveHintRules: the pinned plan's live hints (running late, gaps, skipped, changes, recap).
//   - SharedPlans: "Use this plan" / "Merge with mine" for shared plan links (API-015).

import Foundation

/// Which path a typed turn takes.
enum TurnPath: String, CaseIterable, Hashable, Sendable {
    case search, ask, plan
}

/// How a turn runs (Android `AssistantFlow`, rule for rule):
/// - `path`: a forced path wins (ask only with the model). Otherwise plan intents → plan; with the
///   model, a question, no match or a search of 4+ words → ask (the model reads it, the router is
///   its fallback); everything else → search (the router: commands, likes, toggles, navigation,
///   short searches and time words answer instantly and deterministically).
/// - A forced search runs a plain `search` of the text; a forced plan without a plan intent makes a
///   plan (`plan_make`) when plans can be made.
enum AssistantFlow {

    static let planIntents: Set<AssistantIntent> = [
        .planEdit, .planUndo, .planVersion, .planCompare, .planMake, .planShow, .planNext, .walking, .recap, .noPlan, .whyNot,
    ]

    private static let asked: Set<AssistantIntent> = [.question, .noMatch]

    static func path(_ intent: AssistantIntent, _ input: String, modelAvailable: Bool, forced: TurnPath? = nil) -> TurnPath {
        if forced == .ask { return modelAvailable ? .ask : .search }
        if let forced { return forced }
        if planIntents.contains(intent) { return .plan }
        if modelAvailable && (asked.contains(intent) || (intent == .search && AssistantSearch.words(input).count >= 4)) { return .ask }
        return .search
    }

    /// A plain `search` turn for a forced search.
    static func searchTurn(_ input: String, _ ctx: RouterContext) -> AssistantTurn {
        let blocks = AssistantRouter.renderRead(.search(input.trimmingCharacters(in: .whitespacesAndNewlines)), ctx)
        if !blocks.isEmpty { return AssistantTurn(blocks: blocks) }
        return AssistantTurn(blocks: BlockValidator.validate(
            [.text(AssistantRouter.noMatchText), .chips(AssistantRouter.suggestionChips(ctx))], ctx.blockContext
        ))
    }

    /// A forced plan turn that isn't a plan command: make a plan from the text.
    static func planTurn(_ input: String, _ routed: RoutedTurn, _ ctx: RouterContext) -> AssistantTurn {
        if planIntents.contains(routed.intent) || !ctx.canPlan { return routed.turn }
        return AssistantTurn(blocks: [.text("Making your plan.")], actions: [.planMake(input.trimmingCharacters(in: .whitespacesAndNewlines))])
    }

    /// What the model's conversation remembers of an assistant turn: its text blocks (bold markers
    /// dropped), else "Showed <first names>", else the block types.
    static func replyText(_ turn: AssistantTurn, _ bundle: EventBundle) -> String {
        let texts = turn.blocks.compactMap { block -> String? in
            if case .text(let text) = block { return text.replacingOccurrences(of: "**", with: "") }
            return nil
        }.joined(separator: " ")
        if !texts.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return String(texts.prefix(200)) }
        var seen = Set<EntityRef>()
        let names = turn.blocks.flatMap(refs).filter { seen.insert($0).inserted }.compactMap { $0.name(bundle) }.prefix(3)
        if !names.isEmpty { return "Showed " + names.joined(separator: ", ") }
        let types = turn.blocks.map(\.type).joined(separator: ", ")
        return "Showed " + (types.isEmpty ? "nothing" : types)
    }

    /// The entities a block shows (logging counts, conversation text).
    static func refs(_ block: AssistantBlock) -> [EntityRef] {
        switch block {
        case .itemCard(let id, _), .countdown(let id): return [EntityRef(kind: .schedule, id: id)]
        case .placeCard(let id, _): return [EntityRef(kind: .location, id: id)]
        case .updateCard(let id): return [EntityRef(kind: .update, id: id)]
        case .list(let ids, _, _), .carousel(let ids, _): return ids
        case .timeline(let ids, _, _): return ids.map { EntityRef(kind: .schedule, id: $0) }
        case .map(let pins, _): return pins.map { EntityRef(kind: .location, id: $0) }
        case .gallery(let ids, _): return ids.map { EntityRef(kind: .location, id: $0) }
        case .planDiff(let diff): return (diff.removed + diff.added).map { EntityRef(kind: .schedule, id: $0) }
        default: return []
        }
    }

    /// "Ask about this" from a detail screen: the text the assistant runs for that entity.
    static func askAbout(_ ref: EntityRef, _ bundle: EventBundle) -> String? {
        ref.name(bundle).map { "Tell me about \($0)" }
    }

    /// The turn for "Ask about this" without the model: the entity's card and chips (like `get_item`).
    static func aboutTurn(_ ref: EntityRef, _ ctx: RouterContext) -> AssistantTurn {
        let name: ActionName
        switch ref.kind {
        case .schedule: name = .getItem
        case .location: name = .getLocation
        case .update: name = .getUpdate
        }
        return AssistantTurn(blocks: AssistantRouter.renderRead(AssistantAction(name: name, params: ["id": .string(ref.code)]), ctx))
    }
}

/// A plan version or a schedule item on one side of a `compare` block.
enum CompareSide: Hashable, Sendable {
    case item(ScheduleItem)
    case version(PlanVersionKind, PlanEdit)
}

/// The data a block shows, resolved from the bundle (blocks carry ids and options only):
/// - `timeline` ids as given; source `plan` = today's plan day (else the first day with entries) in
///   plan order; source `whats_on` = items not ended that start within the next 3 h, by (start,
///   end, id), at most 20.
/// - `compare` sides: "s12" → the item, "plan:chill" / "plan:everything" → that version's preview.
/// - `summary`: walking → `DayRoutes.totalText` of today's (else the first) plan day; recap →
///   `LiveAssist.recap` of today; liked_counts → "3 liked items and 2 liked places".
enum BlockData {
    static let whatsOnAhead: TimeInterval = 3 * 3600

    static func timeline(_ ids: [Int], source: String?, _ bundle: EventBundle, _ plan: Plan?, now: Date) -> [Int] {
        if !ids.isEmpty { return ids }
        switch source {
        case "plan"?:
            return planDay(plan, bundle, now: now)?.items.map(\.itemId) ?? []
        case "whats_on"?:
            let items = bundle.schedule.filter { item in
                guard let start = item.startTime, let end = ScheduleTiming.effectiveEnd(of: item) else { return false }
                return end > now && start < now.addingTimeInterval(whatsOnAhead)
            }
            return Array(items.stableSorted(by: Planner.itemOrder).map(\.id).prefix(BlockValidator.maxList))
        default:
            return []
        }
    }

    static func planDay(_ plan: Plan?, _ bundle: EventBundle, now: Date, day: PlanDate? = nil) -> PlanDay? {
        guard let plan else { return nil }
        if let day { return plan.days.first { $0.date == day } }
        let today = PlanDate(now, in: PlanCalendar.calendar(bundle.event.timeZone))
        return plan.days.first { $0.date == today && !$0.entries.isEmpty } ?? plan.days.first { !$0.entries.isEmpty }
    }

    static func compare(_ side: String, _ plan: Plan?, _ bundle: EventBundle, _ likes: LikeSet, now: Date) -> CompareSide? {
        let s = side.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if s.hasPrefix("plan:") {
            guard let kind = PlanVersionKind.of(String(s.dropFirst(5))), let plan else { return nil }
            return .version(kind, PlanVersions.make(kind, plan, bundle, likes, now: now))
        }
        guard let ref = EntityRef.parse(s), ref.kind == .schedule, let item = bundle.scheduleItem(ref.id) else { return nil }
        return .item(item)
    }

    static func summary(_ kind: String, _ plan: Plan?, _ bundle: EventBundle, _ likes: LikeSet, now: Date,
                        units: DistanceUnits, locale: Locale) -> String? {
        let today = PlanDate(now, in: PlanCalendar.calendar(bundle.event.timeZone))
        switch kind {
        case "walking":
            guard let plan, let day = planDay(plan, bundle, now: now), let route = DayRoutes.of(plan, bundle, date: day.date) else { return nil }
            return DayRoutes.totalText(route, today: today, units, locale: locale)
        case "recap":
            guard let plan else { return nil }
            let date = plan.days.last { $0.date <= today }?.date ?? plan.days.first?.date ?? today
            return LiveAssist.recap(plan, bundle, likes, date: date, now: now, units: units, locale: locale).text
        case "liked_counts":
            return likedCounts(likes)
        default:
            return nil
        }
    }

    static func likedCounts(_ likes: LikeSet) -> String {
        func n(_ count: Int, _ one: String) -> String { "\(count) liked \(count == 1 ? one : one + "s")" }
        return "\(n(likes.scheduleItems.count, "item")) and \(n(likes.locations.count, "place"))"
    }
}

/// What the pinned plan shows live (spec §6), from position samples taken while the app is visible.
struct LiveHints: Hashable, Sendable {
    var runningLate: RunningLate? = nil
    var gaps: [GapSuggestion] = []
    /// "You skipped X — fill the gap?" chips.
    var skipped: [AssistantChip] = []
    /// Planned items the organizer changed or removed.
    var changed: [Int] = []
    /// Today's planned items have all ended: show the day's recap.
    var recapReady = false

    var isEmpty: Bool { runningLate == nil && gaps.isEmpty && skipped.isEmpty && changed.isEmpty && !recapReady }
}

/// Combines the `LiveAssist` rules for the pinned plan: running late (position known), gap
/// fillers (today), skipped items (minus `dismissed`), organizer changes, and recap-ready
/// (today's plan day has items, every one has ended, and now is still that day).
enum LiveHintRules {
    static func of(_ plan: Plan?, _ bundle: EventBundle, _ likes: LikeSet, now: Date, user: Coordinate?,
                   samples: [LocationSample], dismissed: Set<Int> = []) -> LiveHints {
        guard let plan else { return LiveHints() }
        let today = PlanDate(now, in: PlanCalendar.calendar(bundle.event.timeZone))
        let day = plan.days.first { $0.date == today }
        let recap = day.map { !$0.items.isEmpty && $0.items.allSatisfy { $0.end <= now } } ?? false
        return LiveHints(
            runningLate: LiveAssist.runningLate(plan, bundle, now: now, user: user),
            gaps: LiveAssist.gaps(plan, bundle, likes, now: now),
            skipped: LiveAssist.skipped(plan, bundle, samples: samples, now: now).filter { !dismissed.contains($0) }
                .compactMap { LiveAssist.skippedChip($0, bundle) },
            changed: LiveAssist.changedItems(plan, bundle),
            recapReady: recap
        )
    }
}

/// Shared plan links (API-015) opened in the app (spec §7): "Use this plan" = exactly the shared
/// items still ahead, as a plan (every other item excluded while planning, so the planner adds
/// walks and order but nothing else; stored with the shared items pinned only, so later edits
/// re-solve normally); "Merge with mine" = `GroupPlan` over every shared plan received for the
/// event plus the attendee's likes, with the current plan's preferences (or meals on).
enum SharedPlans {
    static let useRequest = "Shared plan"
    static let mergeRequest = "Group plan"
    /// Shared plans remembered per event for "Merge with mine".
    static let maxShared = 10

    static func use(_ ids: [Int], day: PlanDate?, _ bundle: EventBundle, _ likes: LikeSet, now: Date) -> Plan? {
        var seen = Set<Int>()
        let known = ids.filter { bundle.scheduleItem($0) != nil && seen.insert($0).inserted }
        if known.isEmpty { return nil }
        let calendar = PlanCalendar.calendar(bundle.event.timeZone)
        let itemDays = known.compactMap { bundle.scheduleItem($0)?.startTime.map { PlanDate($0, in: calendar) } }
        let days = Array(Set((day.map { [$0] } ?? []) + itemDays)).sorted()
        let excluded = Set(bundle.schedule.map(\.id).filter { !known.contains($0) })
        var plan = Planner(
            bundle: bundle,
            preferences: PlanPreferences(days: days, pace: .packed),
            heartedItems: likes.scheduleItems,
            heartedLocations: likes.locations,
            constraints: PlanConstraints(pinned: Set(known), excluded: excluded)
        ).plan(from: now, request: useRequest)
        if plan.isEmpty { return nil }
        plan.constraints = PlanConstraints(pinned: Set(known))
        return plan
    }

    static func merge(_ shared: [[Int]], _ own: LikeSet, _ bundle: EventBundle, current: Plan?, now: Date) -> Plan? {
        if shared.isEmpty { return nil }
        let preferences = current?.preferences ?? PlanPreferences(includeMeals: true)
        let plan = GroupPlan.plan(shared, own, bundle, preferences, now: now, request: mergeRequest)
        return plan.isEmpty ? nil : plan
    }

    /// The stored shared plans (one line of comma-separated ids each) with `ids` added last.
    static func adding(_ ids: [Int], to stored: [[Int]]) -> [[Int]] {
        Array((stored.filter { $0 != ids } + [ids]).suffix(maxShared))
    }

    static func encode(_ plans: [[Int]]) -> String {
        plans.map { $0.map(String.init).joined(separator: ",") }.joined(separator: "\n")
    }

    static func decode(_ text: String?) -> [[Int]] {
        (text ?? "").split(separator: "\n").map { line in line.split(separator: ",").compactMap { Int($0) } }.filter { !$0.isEmpty }
    }
}
