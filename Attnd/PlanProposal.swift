// PlanProposal.swift
// Attnd (app + App Clip; pure, unit tested in PlanProposalTests — same
// rules and cases as Android's `domain/PlanProposal.kt`)
//
// The plan page edits the plan in place (plan tab spec, Nov 15, 2026; on iOS the plan page of the
// "My plan" button): a turn that would change the plan is not applied at once but shown as a **proposal** in the timeline:
//   - `PlanProposals.from(routed:)` / `from(actions:)` / `from(chip:)` / `shared` / `swap`
//     turn the router's or the model's plan edits, a chip (like clash: "Add to plan instead of
//     X?") or a shared plan link into a `PlanProposal` (≤ 4 options, each previewed with
//     `PlanEditor.preview`). Kinds: add (one `add` op), replace (one `replace` op), change
//     (anything else: remove, move, constraints, versions, shared plans).
//   - `PlanPreview.of` is what the timeline draws: marks on current rows (removed / moved; for a
//     replace the replaced row), suggested rows (item, option, the planned item they follow —
//     nil = first of the day) and the diff pill ("−2 items, +1 lunch break").
//   - `ProposalReply.parse` reads what is typed while a proposal is shown: "yes" / "do it" /
//     "apply" → option 1, "the second one" / "option 3" / "#2" / "last" → that option, "no" /
//     "cancel" / "never mind" → cancel; anything else is a new turn (and clears the proposal).

import Foundation

/// How one option is applied.
enum ProposalApply: Hashable, Sendable {
    /// `plan_edit` / `plan_version`, dispatched as the person's own choice (with Undo).
    case action(AssistantAction)
    /// A whole plan (shared plan links: "Use this plan", "Merge with mine").
    case plan(Plan)
    /// A new plan made for an inline action without a plan ("Plan around this", PlanDock.swift).
    case newPlan(Plan)
}

struct ProposalOption: Hashable, Sendable {
    var label: String
    var apply: ProposalApply
    /// The previewed result.
    var edit: PlanEdit
}

enum ProposalKind: String, Hashable, Sendable {
    case add, replace, change
}

struct PlanProposal: Hashable, Sendable {
    static let maxOptions = 4

    var kind: ProposalKind
    /// The sentence for VoiceOver and the pill's title ("Removed Velvet Mesquite.").
    var text: String
    var options: [ProposalOption]
    /// The crossed-out row of a replace.
    var replaced: Int? = nil

    /// Option rows are tapped one by one (add / replace); a change is applied from the pill.
    var hasOptionRows: Bool { kind != .change }
}

/// One dashed "suggested" row.
struct ProposalSuggestion: Hashable, Sendable {
    var itemId: Int
    /// Index into `PlanProposal.options`.
    var option: Int
    /// The current plan's item of that day it follows (nil: before the day's first item).
    var after: Int?
    var start: Date
}

enum PreviewMark: String, Hashable, Sendable {
    /// Crossed out (removed, or the replaced row).
    case removed
    /// Another showing takes its place ("Moved" badge).
    case moved
}

/// What the timeline shows for a proposal.
struct PlanPreview: Hashable, Sendable {
    var marks: [Int: PreviewMark] = [:]
    var mealMarks: [MealSlot: PreviewMark] = [:]
    /// Per day, in timeline order (after-position, start, option).
    var suggestions: [PlanDate: [ProposalSuggestion]] = [:]
    var pill: String = ""

    /// Rules:
    /// - Marks: items every option removes → removed (a replace's `replaced` always); items every
    ///   option moves → moved. Meals: every option's removed meals → removed, moved meals → moved.
    /// - Suggestions: add / replace → each option's added (and moved-to) items; change → option 1's
    ///   only (all of them). Day = the item's start day in the event's zone. `after` = for a replace on the
    ///   replaced item's day, the replaced item; otherwise the last current-plan item of that day
    ///   starting at or before the suggestion (nil when none). At most 4 option rows.
    /// - Pill: one option → `diffText` of it; more → "Pick one of N".
    static func of(_ proposal: PlanProposal, plan: Plan?, _ bundle: EventBundle) -> PlanPreview {
        var preview = PlanPreview()
        let diffs = proposal.options.map(\.edit.diff)
        guard let first = diffs.first else { return preview }
        let calendar = PlanCalendar.calendar(bundle.event.timeZone)

        var removedEverywhere = Set(first.removed)
        var movedEverywhere = Set(first.moved.map(\.from))
        var mealsRemoved = Set(first.mealsRemoved)
        var mealsMoved = Set(first.mealsMoved)
        for diff in diffs.dropFirst() {
            removedEverywhere.formIntersection(diff.removed)
            movedEverywhere.formIntersection(diff.moved.map(\.from))
            mealsRemoved.formIntersection(diff.mealsRemoved)
            mealsMoved.formIntersection(diff.mealsMoved)
        }
        for id in removedEverywhere { preview.marks[id] = .removed }
        for id in movedEverywhere { preview.marks[id] = .moved }
        if let replaced = proposal.replaced { preview.marks[replaced] = .removed }
        for slot in mealsRemoved { preview.mealMarks[slot] = .removed }
        for slot in mealsMoved { preview.mealMarks[slot] = .moved }

        let current = plan?.days ?? []
        let replacedDay = proposal.replaced.flatMap { id in current.first { $0.items.contains { $0.itemId == id } }?.date }
        var rows: [ProposalSuggestion] = []
        var seen = Set<Int>()
        let options = proposal.hasOptionRows ? Array(proposal.options.enumerated()) : Array(proposal.options.enumerated().prefix(1))
        for (index, option) in options {
            let ids = option.edit.diff.added + option.edit.diff.moved.map(\.to)
            for id in ids where (!proposal.hasOptionRows || rows.count < PlanProposal.maxOptions) && seen.insert(id).inserted {
                guard let start = option.edit.after.items.first(where: { $0.itemId == id })?.start ?? bundle.scheduleItem(id)?.startTime else { continue }
                let date = PlanDate(start, in: calendar)
                let after: Int?
                if let replaced = proposal.replaced, replacedDay == date {
                    after = replaced
                } else {
                    after = current.first { $0.date == date }?.items.last { $0.start <= start }?.itemId
                }
                rows.append(ProposalSuggestion(itemId: id, option: index, after: after, start: start))
            }
        }
        for row in rows {
            preview.suggestions[PlanDate(row.start, in: calendar), default: []].append(row)
        }
        for (date, list) in preview.suggestions {
            let order = current.first { $0.date == date }?.items.map(\.itemId) ?? []
            func position(_ s: ProposalSuggestion) -> Int { s.after.flatMap { order.firstIndex(of: $0) } ?? -1 }
            preview.suggestions[date] = list.sorted {
                (position($0), $0.start, $0.option) < (position($1), $1.start, $1.option)
            }
        }
        preview.pill = proposal.options.count == 1 ? diffText(first) : "Pick one of \(proposal.options.count)"
        return preview
    }

    /// "−2 items, +1 lunch break": removed items, added items, moved items ("1 moved"), then per
    /// meal kind removed ("−1 lunch break"), added ("+1 dinner break"), moved ("lunch break
    /// moved"); "No change" when empty. U+2212 minus.
    static func diffText(_ diff: PlanDiff) -> String {
        func items(_ n: Int) -> String { n == 1 ? "1 item" : "\(n) items" }
        func meals(_ slots: [MealSlot], _ sign: String) -> [String] {
            MealKind.allCases.compactMap { kind in
                let n = slots.filter { $0.kind == kind }.count
                guard n > 0 else { return nil }
                let name = kind.label.lowercased()
                return "\(sign)\(n) \(n == 1 ? name : name + "s")"
            }
        }
        var parts: [String] = []
        if !diff.removed.isEmpty { parts.append("\u{2212}" + items(diff.removed.count)) }
        if !diff.added.isEmpty { parts.append("+" + items(diff.added.count)) }
        if !diff.moved.isEmpty { parts.append("\(diff.moved.count) moved") }
        parts += meals(diff.mealsRemoved, "\u{2212}")
        parts += meals(diff.mealsAdded, "+")
        parts += MealKind.allCases.filter { kind in diff.mealsMoved.contains { $0.kind == kind } }.map { "\($0.label.lowercased()) moved" }
        return parts.isEmpty ? "No change" : parts.joined(separator: ", ")
    }
}

/// What is typed while a proposal is shown.
enum ProposalReply: Hashable, Sendable {
    case apply(Int)
    case cancel
    /// Not an answer: a new turn (which clears the proposal).
    case none

    private static let yes: Set<String> = [
        "yes", "y", "yep", "yeah", "yup", "sure", "ok", "okay", "do it", "do that", "apply", "apply it", "go ahead",
        "sounds good", "please", "yes please", "that one", "let s do it", "lets do it", "perfect", "great", "confirm",
    ]
    private static let no: Set<String> = [
        "no", "n", "nope", "nah", "cancel", "never mind", "nevermind", "stop", "forget it", "not now", "don t", "no thanks", "keep it",
    ]
    private static let ordinals: [String: Int] = [
        "1": 1, "one": 1, "first": 1, "1st": 1,
        "2": 2, "two": 2, "second": 2, "2nd": 2,
        "3": 3, "three": 3, "third": 3, "3rd": 3,
        "4": 4, "four": 4, "fourth": 4, "4th": 4,
    ]

    /// `options`: how many the proposal has. An option number out of range → none.
    static func parse(_ input: String, options: Int) -> ProposalReply {
        let cmd = AssistantRouter.command(input.replacingOccurrences(of: "#", with: " "))
        if cmd.isEmpty || options <= 0 { return .none }
        if yes.contains(cmd) { return .apply(0) }
        if no.contains(cmd) { return .cancel }
        // "the second one", "option 3", "number 2", "#2", "2", "the last one", "go with the first".
        guard let m = Rx.find(#"^(?:(?:let s |lets )?(?:go with|take|pick|choose|use|apply|add|do)\s+)?(?:the\s+)?(?:option|number|no|choice)?\s*(\w+)(?:\s+(?:one|option))?(?:\s+please)?$"#, cmd) else {
            return .none
        }
        let word = m[1]
        let index: Int
        if word == "last" {
            index = options
        } else if let n = ordinals[word] {
            index = n
        } else {
            return .none
        }
        return index >= 1 && index <= options ? .apply(index - 1) : .none
    }
}

/// A swap command's result.
enum SwapCommand: Hashable, Sendable {
    case proposal(PlanProposal)
    case message(String)
}

/// Turns edits into proposals (see the file comment).
enum PlanProposals {

    static func isPlanWrite(_ action: AssistantAction) -> Bool {
        action.name == .planEdit || action.name == .planVersion
    }

    static func kind(_ ops: [PlanOp]) -> ProposalKind {
        guard ops.count == 1, let op = ops.first else { return .change }
        switch op {
        case .add: return .add
        case .replace: return .replace
        default: return .change
        }
    }

    private static func replacedItem(_ ops: [PlanOp]) -> Int? {
        if ops.count == 1, case .replace(let item, _, _, _)? = ops.first { return item }
        return nil
    }

    /// One option for a `plan_edit` / `plan_version` action (nil: no plan, unreadable ops).
    static func option(_ action: AssistantAction, label: String, _ ctx: RouterContext) -> ProposalOption? {
        guard let plan = ctx.plan else { return nil }
        switch action.name {
        case .planEdit:
            guard let ops = action.ops(ctx.bundle, now: ctx.now) else { return nil }
            return ProposalOption(label: label, apply: .action(action), edit: PlanEditor.preview(plan, ops, ctx.bundle, ctx.likes, now: ctx.now))
        case .planVersion:
            guard let kind = PlanVersionKind.of(action.string("kind")) else { return nil }
            return ProposalOption(label: label, apply: .action(action), edit: PlanVersions.make(kind, plan, ctx.bundle, ctx.likes, now: ctx.now))
        default:
            return nil
        }
    }

    /// The proposal for one action (the router's or the model's edit, a chip).
    static func from(action: AssistantAction, label: String? = nil, _ ctx: RouterContext) -> PlanProposal? {
        let ops = action.name == .planEdit ? action.ops(ctx.bundle, now: ctx.now) ?? [] : []
        let name = label ?? defaultLabel(action, ops, ctx)
        guard let option = option(action, label: name, ctx) else { return nil }
        return PlanProposal(
            kind: action.name == .planEdit ? kind(ops) : .change,
            text: label ?? AssistantRouter.describe(option.edit, ctx.bundle),
            options: [option],
            replaced: replacedItem(ops)
        )
    }

    /// The router's turn: its edit (`RoutedTurn.edit` + a plan write) or a "Which one do you
    /// mean?" pick whose chips are all plan edits (≤ 4 options). nil: not an edit.
    static func from(routed: RoutedTurn, _ ctx: RouterContext) -> PlanProposal? {
        if routed.edit != nil, let action = routed.actions.first(where: isPlanWrite) {
            return from(action: action, ctx)
        }
        guard routed.intent == .pick else { return nil }
        let chips = routed.blocks.flatMap { block -> [AssistantChip] in
            if case .chips(let chips) = block { return chips }
            return []
        }
        guard !chips.isEmpty, chips.allSatisfy({ isPlanWrite($0.action) }) else { return nil }
        return from(chips: chips, text: "Which one?", ctx)
    }

    /// The model's turn: its first plan write (nil when it has none).
    static func from(actions: [AssistantAction], _ ctx: RouterContext) -> PlanProposal? {
        actions.first(where: isPlanWrite).flatMap { from(action: $0, ctx) }
    }

    /// Plan-edit chips as options (≤ 4). The kind is the first chip's; a replace keeps its item
    /// only when every chip replaces the same one.
    static func from(chips: [AssistantChip], text: String, _ ctx: RouterContext) -> PlanProposal? {
        let options = chips.filter { isPlanWrite($0.action) }.prefix(PlanProposal.maxOptions).compactMap { option($0.action, label: $0.label, ctx) }
        guard !options.isEmpty else { return nil }
        let opsList = chips.prefix(options.count).map { $0.action.ops(ctx.bundle, now: ctx.now) ?? [] }
        let kinds = Set(opsList.map(kind))
        let replaced = Set(opsList.map(replacedItem))
        return PlanProposal(
            kind: kinds.count == 1 ? kinds.first! : .change,
            text: text,
            options: options,
            replaced: replaced.count == 1 ? replaced.first! : nil
        )
    }

    /// A shared plan link (API-015): "Use this plan" and, when `merged` exists, "Merge with mine".
    static func shared(use: Plan, merged: Plan?, current: Plan?, eventId: Int, _ bundle: EventBundle) -> PlanProposal {
        let before = current ?? emptyPlan(eventId: eventId, createdAt: use.createdAt)
        func edit(_ after: Plan) -> PlanEdit { PlanEdit(before: before, after: after, diff: PlanDiff.between(before, after, bundle), notes: []) }
        var options = [ProposalOption(label: "Use This Plan", apply: .plan(use), edit: edit(use))]
        if let merged { options.append(ProposalOption(label: "Merge with Mine", apply: .plan(merged), edit: edit(merged))) }
        return PlanProposal(kind: .change, text: "Someone shared a plan with \(use.itemIds.count) items.", options: options)
    }

    static func emptyPlan(eventId: Int, createdAt: Date) -> Plan {
        Plan(eventId: eventId, createdAt: createdAt, request: "", preferences: PlanPreferences(), days: [], fingerprints: [:])
    }

    /// "swap the next thing" / "swap my next one" / "replace Velvet Mesquite" (no "with" / "for"):
    /// up to 4 of the planned item's alternatives (the planner's swap list) that haven't started
    /// and aren't planned, each a replace. nil: not a swap command (the router takes it).
    static func swap(_ input: String, _ ctx: RouterContext) -> SwapCommand? {
        let cmd = AssistantRouter.command(input)
        guard let m = Rx.find(#"^(?:swap|replace|change)\s+(?:out\s+)?(.+)$"#, cmd),
              !Rx.contains(#"\s(?:with|for)\s"#, " " + m[1] + " ") else { return nil }
        guard let plan = ctx.plan else { return .message(AssistantRouter.noPlanText) }
        let phrase = m[1]
        let target: ScheduleItem
        if Rx.matches(#"(?:the |my )?next(?: thing| one| item| act| show)?"#, phrase) {
            guard let next = LiveAssist.nextPlanned(plan, ctx.bundle, now: ctx.now) else { return .message("Nothing else is in your plan.") }
            target = next
        } else {
            guard case .found(let ref) = AssistantRouter.resolve(phrase, [.schedule], ctx, preferPlanned: true),
                  let item = ctx.bundle.scheduleItem(ref.id) else { return nil }
            target = item
        }
        guard let planned = plan.items.first(where: { $0.itemId == target.id }) else {
            return .message("\(target.name) isn't in your plan.")
        }
        let planIds = Set(plan.itemIds)
        let alternatives = planned.alternatives.compactMap { ctx.bundle.scheduleItem($0) }
            .filter { !planIds.contains($0.id) && ($0.startTime ?? .distantPast) > ctx.now }
            .prefix(PlanProposal.maxOptions)
        guard !alternatives.isEmpty else { return .message("There's nothing to swap \(target.name) for.") }
        let chips = alternatives.map { AssistantChip(label: $0.name, action: .planEdit([.replace(item: target.id, with: $0.id)], ctx.bundle)) }
        guard let proposal = from(chips: chips, text: "Swap \(target.name) for:", ctx) else { return nil }
        return .proposal(proposal)
    }

    private static func defaultLabel(_ action: AssistantAction, _ ops: [PlanOp], _ ctx: RouterContext) -> String {
        if action.name == .planVersion { return PlanVersionKind.of(action.string("kind"))?.label ?? "Apply" }
        if ops.count == 1 {
            switch ops[0] {
            case .add(let id): return ctx.bundle.scheduleItem(id)?.name ?? "Add"
            case .replace(_, let with?, _, _): return ctx.bundle.scheduleItem(with)?.name ?? "Replace"
            default: break
            }
        }
        return "Apply"
    }
}

// MARK: - Sequences ("let's do music, food, then more music")

/// A plan-like sequence of kinds ("music, food, then more music", "tacos then a band", "morning
/// music, lunch, …") becomes one proposal (owner, Nov 21, 2026): each step filled from the
/// schedule in order — music = a live-music item in progress or next (later steps: starting after
/// the previous step), food / drinks = the place nearest the previous step at the next quarter
/// hour after it (+ 5 min walk), 45 min (lunch before 4 PM, dinner after) — previewed as the plan
/// with those entries added. Apply adds them (My schedule follows the plan), with Undo. nil: not a
/// sequence, or a step can't be filled (the router / model answer instead).
enum SequenceKind: String, Hashable, Sendable {
    case music, food, drinks
}

extension PlanProposals {
    /// The steps of a sequence, or nil (fewer than two, a step that isn't a kind, no "then" / comma).
    static func sequenceSteps(_ input: String) -> [SequenceKind]? {
        let lower = " " + input.lowercased() + " "
        guard lower.contains(" then ") || lower.contains(",") || lower.contains("→") || lower.contains("->") else { return nil }
        // Normalised text has no punctuation: split on the original's commas and on "then".
        let raw = input.lowercased()
            .replacingOccurrences(of: "→", with: ",")
            .replacingOccurrences(of: "->", with: ",")
            .replacingOccurrences(of: " and then ", with: ",")
            .replacingOccurrences(of: " after that ", with: ",")
            .replacingOccurrences(of: " then ", with: ",")
            .split(separator: ",")
            .map { PlanText.normalize(String($0)) }
            .filter { !$0.isEmpty }
        guard raw.count >= 2, raw.count <= 6 else { return nil }
        var steps: [SequenceKind] = []
        for part in raw {
            let words = Set(part.split(separator: " ").map(String.init))
            let fillers: Set<String> = ["lets", "let", "s", "do", "some", "more", "a", "an", "the", "and", "then", "first", "go", "get",
                                        "grab", "see", "catch", "bit", "of", "to", "for", "with", "i", "we", "want", "like", "maybe",
                                        "after", "that", "later", "another", "one", "morning", "afternoon", "evening", "night", "finally",
                                        "end", "start", "live", "good", "great", "something", "quick", "have"]
            let music: Set<String> = ["music", "band", "bands", "show", "shows", "concert", "concerts", "set", "sets", "gig", "act", "acts", "stage"]
            let food: Set<String> = ["food", "lunch", "dinner", "tacos", "taco", "bbq", "snack", "snacks", "bite", "meal", "eat", "brunch"]
            let drinks: Set<String> = ["drinks", "drink", "beer", "beers", "cocktail", "cocktails"]
            let kind: SequenceKind?
            if !words.isDisjoint(with: music) { kind = .music }
            else if !words.isDisjoint(with: food) { kind = .food }
            else if !words.isDisjoint(with: drinks) { kind = .drinks }
            else { kind = nil }
            // Every word must be a kind word or a filler (so "music by Juniper Lane" isn't read as a kind).
            let known = fillers.union(music).union(food).union(drinks)
            guard let kind, words.isSubset(of: known) else { return nil }
            steps.append(kind)
        }
        return steps
    }

    /// The proposal for a sequence typed in the chat (nil: not one, or a step can't be filled).
    static func sequence(_ input: String, _ ctx: RouterContext) -> PlanProposal? {
        guard let steps = sequenceSteps(input) else { return nil }
        let bundle = ctx.bundle
        let calendar = PlanCalendar.calendar(bundle.event.timeZone)
        var cursor = ctx.now
        var lastPlace: Coordinate? = ctx.user
        var used = Set<Int>()
        var usedPlaces = Set<Int>()
        var picked: [PlanEntry] = []
        var parts: [String] = []

        func isMusic(_ item: ScheduleItem) -> Bool {
            item.tags.contains { PlanText.normalize($0).contains("music") }
                || (bundle.location(item.locationId)?.category).map { PlanText.normalize($0) == "stage" } ?? false
        }
        func kindMatches(_ location: Location, _ kind: SequenceKind) -> Bool {
            let texts = ([location.category ?? ""] + location.tags).map(PlanText.normalize)
            switch kind {
            case .food: return texts.contains { $0.contains("food") }
            case .drinks: return texts.contains { $0.contains("drink") || $0.contains("beer") }
            case .music: return false
            }
        }
        func clock(_ date: Date) -> String { AssistantText.format(date, "h:mm a", bundle.event.timeZone, ctx.locale) }

        for (index, step) in steps.enumerated() {
            switch step {
            case .music:
                let candidates = bundle.schedule.filter { item in
                    guard let start = item.startTime, !used.contains(item.id), isMusic(item),
                          let end = ScheduleTiming.effectiveEnd(of: item), end > cursor else { return false }
                    // The first step may be on already; later ones start after the previous step.
                    return index == 0 ? start >= cursor || ScheduleTiming.isHappening(item, at: cursor) : start >= cursor
                }
                guard let item = candidates.min(by: { ($0.startTime!, $0.id) < ($1.startTime!, $1.id) }),
                      let start = item.startTime, let end = ScheduleTiming.effectiveEnd(of: item) else { return nil }
                used.insert(item.id)
                picked.append(.item(PlannedItem(itemId: item.id, start: start, end: end, reason: "In your sequence",
                                                walkMinutes: nil, alternatives: [], orInstead: [])))
                parts.append("**\(item.name)** (\(clock(start)))")
                cursor = end
                if let c = bundle.location(item.locationId)?.coordinate { lastPlace = c }
            case .food, .drinks:
                let places = bundle.locations.filter { kindMatches($0, step) && !usedPlaces.contains($0.id) }
                guard !places.isEmpty else { return nil }
                let place = places.min { a, b in
                    let da = lastPlace.flatMap { p in a.coordinate.map { Planner.distance(p, $0) } } ?? .infinity
                    let db = lastPlace.flatMap { p in b.coordinate.map { Planner.distance(p, $0) } } ?? .infinity
                    return da != db ? da < db : (a.sortOrder, a.id) < (b.sortOrder, b.id)
                }!
                usedPlaces.insert(place.id)
                // The next quarter hour after the previous step and a short walk.
                let earliest = cursor.addingTimeInterval(5 * 60)
                let minute = calendar.component(.minute, from: earliest)
                let second = calendar.component(.second, from: earliest)
                let roundUp = (15 - minute % 15) % 15
                var start = earliest.addingTimeInterval(TimeInterval(roundUp * 60 - second))
                if start < earliest { start = start.addingTimeInterval(15 * 60) }
                let end = start.addingTimeInterval(TimeInterval(MySchedule.defaultMinutes * 60))
                let hour = calendar.component(.hour, from: start)
                picked.append(.meal(MealBreak(kind: hour < 16 ? .lunch : .dinner, start: start, end: end, locationId: place.id)))
                parts.append("**\(place.name)** at \(clock(start))")
                cursor = end
                if let c = place.coordinate { lastPlace = c }
            }
        }
        let before = ctx.plan ?? emptyPlan(eventId: bundle.event.id, createdAt: ctx.now)
        var after = before
        for entry in picked {
            let date = PlanDate(entry.start, in: calendar)
            if case .item(let planned) = entry, after.itemIds.contains(planned.itemId) { continue }
            if let i = after.days.firstIndex(where: { $0.date == date }) {
                after.days[i].entries.append(entry)
                after.days[i].entries.sort { ($0.start, $0.end) < ($1.start, $1.end) }
                after.days[i].windowStart = min(after.days[i].windowStart, entry.start)
                after.days[i].windowEnd = max(after.days[i].windowEnd, entry.end)
            } else {
                after.days.append(PlanDay(date: date, windowStart: entry.start, windowEnd: entry.end, entries: [entry]))
                after.days.sort { $0.date < $1.date }
            }
            if case .item(let planned) = entry, let item = bundle.scheduleItem(planned.itemId) {
                after.fingerprints[planned.itemId] = Planner.fingerprint(item)
            }
        }
        if after.request.isEmpty { after.request = input }
        let edit = PlanEdit(before: before, after: after, diff: PlanDiff.between(before, after, bundle), notes: [])
        let text = parts.count == 2
            ? "\(parts[0]), then \(parts[1])."
            : parts.dropLast().joined(separator: ", ") + ", then " + parts.last! + "."
        let option = ProposalOption(label: "Add to My Schedule", apply: .newPlan(after), edit: edit)
        return PlanProposal(kind: .add, text: text.prefix(1).uppercased() + text.dropFirst(), options: [option])
    }
}
