// AssistantRouter.swift
// Attnd (app target only — not in the App Clip for now; unit tested in AssistantRouterTests)
//
// The rule-based assistant (assistant spec §3; every phone, pure), a port of Android's
// `domain/AssistantRouter.kt` grammar rules 1–29 with the same fixtures and exact block JSON.
// `route` reads the input (folded: lower case, accents dropped, everything but letters, digits
// and ':' as spaces) as a small command grammar, first match wins:
//  1. empty → EMPTY (suggestion chips).  2. "undo" → `plan_undo`.
//  3. "add <x | my plan> to (my) calendar" → `calendar`.
//  4. "replace | swap <a> with | for <b>" (b = "something like <item>", "something <tag>", a tag,
//     else an item; a prefers planned items) → `plan_edit replace`.
//  5. "remove | drop | skip | cancel <a>" → remove.  6. "add <a> (to my plan)" → add.
//  7. "move <a> later | earlier".  8. "keep" / "unkeep | unpin".
//  9. "already ate" … → `no_food_until` = now (minute) + 3 h.  10. "tired" … → pace relaxed.
// 11. "done | home | … by | at | before H(:MM)( am | pm)" → `done_by`; 12. "start at …" → `start_at`
//     (a bare 1–11 is the morning time when still ahead, else the evening; 12 is noon).
// 13. "short walks" … → `max_walk_min` 10; "walks under N min" → N.  14. "i m at <place>" → origin.
// 15. "more | less <tag>" → more / less tag.  16. chill / everything versions, "compare versions".
// 17. "unlike <x>" / "like | heart | love | save <x>".  18. toggles → a `confirm` block.
// 19. "share (my) plan" / "share <item>".  20. "why isn't <item> (in my plan)" → `why_not`.
// 21. "what s next" / "next … plan" → the next planned item.  22. "my plan", walking, recap.
// 23. the liked list.  24. "show | open … map | flyer | …" → `open`.  25. "near me" … → places.
// 26. a plan request → `plan_make`.  27. only time words → `timeline`.
// 28. a question → results for its keywords + a note.  29. otherwise a search; nothing → NO_MATCH.
// Plan commands without a plan → NO_PLAN. Every turn's blocks go through `BlockValidator`.

import Foundation

/// Everything the router (and the model prompt) may use. All local. (Not `AssistantContext`,
/// which is EventAssistant.swift's tool context.)
struct RouterContext: Sendable {
    var bundle: EventBundle
    var likes: LikeSet
    var plan: Plan?
    var now: Date
    /// The user's position, only when location is permitted and known.
    var user: Coordinate? = nil
    /// The planner may make plans (model available, not the App Clip).
    var canPlan = true
    /// Ask (the on-device model) is available; the router is then only the fallback.
    var modelAvailable = false
    var history = PlanHistory()
    var units: DistanceUnits = .imperial
    var locale = Locale(identifier: "en_US")
    /// The cached forecast for the event's days (`PlanWeather.promptLines`; empty without one).
    var weather: [String] = []

    var blockContext: BlockContext { BlockContext(bundle: bundle, plan: plan, now: now) }
}

enum AssistantIntent: Hashable, Sendable {
    case empty, search, question, noMatch, pick, whatsOn, nearMe, like, unlike, liked
    case planEdit, planUndo, planVersion, planCompare, planMake, planShow, planNext, walking, recap, noPlan
    case whyNot, toggle, open, share, calendar
}

/// A routed turn: what the router understood, the turn (validated blocks + actions) and any plan preview.
struct RoutedTurn: Hashable, Sendable {
    var intent: AssistantIntent
    var turn: AssistantTurn
    var edit: PlanEdit? = nil

    var blocks: [AssistantBlock] { turn.blocks }
    var actions: [AssistantAction] { turn.actions }
}

/// An entity name in a command, resolved through the search.
enum Resolution: Hashable, Sendable {
    case found(EntityRef)
    case ambiguous([EntityRef])
    case notFound
}

enum AssistantRouter {

    static let askUnavailable = "Ask needs on-device AI, which isn't available on this phone. Here's what matches."
    static let noMatchText = "Nothing matches that. Try one of these:"
    static let noPlanText = "You don't have a plan yet."
    private static let filler: Set<String> = ["the", "a", "an", "thing", "one", "that", "this"]
    private static let minBasePerToken = 3.0
    private static let questionWords: Set<String> = ["what", "when", "where", "who", "which", "how", "is", "are", "does", "do", "can", "will", "whats"]

    private static func done(_ intent: AssistantIntent, _ blocks: [AssistantBlock], _ ctx: RouterContext,
                             actions: [AssistantAction] = [], edit: PlanEdit? = nil) -> RoutedTurn {
        RoutedTurn(intent: intent, turn: AssistantTurn(blocks: BlockValidator.validate(blocks, ctx.blockContext), actions: actions), edit: edit)
    }

    static func route(_ input: String, _ ctx: RouterContext) -> RoutedTurn {
        let cmd = command(input)
        let plan = ctx.plan

        if cmd.isEmpty { return done(.empty, [.chips(suggestionChips(ctx))], ctx) }

        if cmd == "undo" || cmd == "undo that" {
            guard plan != nil else { return noPlan(ctx) }
            return ctx.history.canUndo
                ? done(.planUndo, [.text("Undid your last plan change.")], ctx, actions: [AssistantAction(name: .planUndo)])
                : done(.planUndo, [.text("There's nothing to undo.")], ctx)
        }

        if let m = Rx.find(#"^(?:add|put|save)\s+(.+?)\s+(?:to|in|on)\s+(?:my\s+)?calendar$"#, cmd) {
            let what = m[1]
            if what == "plan" || what == "my plan" {
                guard plan != nil else { return noPlan(ctx) }
                return done(.calendar, [.calendar(plan: true)], ctx)
            }
            return withEntity(what, [.schedule], ctx, .calendar, chip: { AssistantChip(label: name($0, ctx), action: calendarAction($0)) }) { ref in
                done(.calendar, [.calendar(ids: [ref.id])], ctx)
            }
        }

        if let turn = planCommand(cmd, ctx) { return turn }

        if let m = Rx.find(#"^(?:unlike|unheart|un like)\s+(.+)$"#, cmd) { return like(m[1], liked: false, ctx) }
        if let m = Rx.find(#"^(?:like|heart|love|save|i like|i love)\s+(.+)$"#, cmd) { return like(m[1], liked: true, ctx) }

        if let action = toggle(cmd) {
            return done(.toggle, [.confirm(action: action, prompt: ActionRegistry.confirmPrompt(action))], ctx)
        }

        if Rx.matches(#"share\s+(?:my\s+)?plan"#, cmd) {
            guard plan != nil else { return noPlan(ctx) }
            return done(.share, [.share("plan"), chips([AssistantChip(label: "Add my plan to calendar", action: .calendarPlan())])], ctx)
        }
        if let m = Rx.find(#"^share\s+(.+)$"#, cmd) {
            return withEntity(m[1], [.schedule], ctx, .share, chip: { ref in
                AssistantChip(label: name(ref, ctx), action: AssistantAction(name: .shareItem, params: ["id": .string(ref.code)]))
            }) { ref in done(.share, [.share("item:\(ref.code)")], ctx) }
        }

        if let m = Rx.find(#"^why\s+(?:isn t|isnt|is not|wasn t|not|no)\s+(.+?)(?:\s+in\s+(?:my\s+)?plan)?$"#, cmd) {
            return withEntity(m[1], [.schedule], ctx, .whyNot, chip: { ref in
                AssistantChip(label: name(ref, ctx), action: AssistantAction(name: .whyNot, params: ["item": .string(ref.code)]))
            }) { ref in done(.whyNot, whyNotBlocks(ref.id, ctx), ctx) }
        }

        if Rx.contains(#"\bwhat s next\b|\bnext\b.*\bplan\b"#, cmd) && (plan != nil || cmd.contains("plan")) {
            guard let plan else { return noPlan(ctx) }
            guard let next = LiveAssist.nextPlanned(plan, ctx.bundle, now: ctx.now), let start = next.startTime else {
                return done(.planNext, [.text("Nothing else is in your plan.")], ctx)
            }
            let relative = AssistantText.relativeStart(start, end: ScheduleTiming.effectiveEnd(of: next), now: ctx.now,
                                                       zone: ctx.bundle.event.timeZone, locale: ctx.locale)
            return done(.planNext, [
                .text("Next in your plan: **\(next.name)**, \(relative)."), .itemCard(id: next.id), .countdown(id: next.id),
                chips(entityChips(EntityRef(kind: .schedule, id: next.id), ctx)),
            ], ctx)
        }

        if Rx.matches(#"(?:(?:show|open|see)\s+)?(?:me\s+)?(?:my\s+)?plan"#, cmd) || cmd == "my plan" {
            guard plan != nil else { return noPlan(ctx) }
            return done(.planShow, planBlocks(ctx), ctx)
        }
        if Rx.contains(#"\b(how far|how much walking|walking)\b"#, cmd) && !cmd.contains("short") {
            guard let plan else { return noPlan(ctx) }
            return done(.walking, walkingBlocks(plan, ctx), ctx)
        }
        if Rx.contains(#"\b(recap|how did i do|my day so far)\b"#, cmd) {
            guard let plan else { return noPlan(ctx) }
            let today = PlanDate(ctx.now, in: PlanCalendar.calendar(ctx.bundle.event.timeZone))
            let date = plan.days.last { $0.date <= today }?.date ?? plan.days.first?.date ?? today
            let recap = LiveAssist.recap(plan, ctx.bundle, ctx.likes, date: date, now: ctx.now, units: ctx.units, locale: ctx.locale)
            return done(.recap, [.text(recap.text), .summary("recap"), chips(recap.chips)], ctx)
        }

        if Rx.matches(#"liked|likes|my likes|what (?:have|did) i liked?|show (?:me )?(?:my )?likes|what i liked|things i liked"#, cmd) {
            return done(.liked, likedBlocks(ctx), ctx)
        }

        if let m = Rx.find(#"^(?:show|open|go to|take me to|see)\s+(?:me\s+)?(?:the\s+|my\s+)?(map|flyer|schedule|locations|updates|options|settings|tour)$"#, cmd) {
            let screen = m[1] == "settings" ? "options" : m[1]
            return done(.open, [.text("Opening \(screen == "options" ? "Options" : "the \(screen)").")], ctx, actions: [.open(screen)])
        }

        if Rx.contains(#"\b(near me|nearby|closest|around me|near here)\b"#, cmd) { return nearMe(cmd, ctx) }

        if ctx.canPlan && PlanRequest.looksLikePlan(input) {
            return done(.planMake, [.text("Making your plan.")], ctx, actions: [.planMake(input.trimmingCharacters(in: .whitespacesAndNewlines))])
        }

        let keywords = AssistantSearch.keywords(cmd)
        if AssistantSearch.parse(keywords).isTimeOnly { return whatsOn(keywords, input, ctx) }

        let firstWord = cmd.split(separator: " ").first.map(String.init) ?? cmd
        let question = input.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("?") || questionWords.contains(firstWord)
        let results = AssistantSearch.search(ctx.bundle, question ? keywords : cmd, now: ctx.now)
        if results.isEmpty { return done(.noMatch, [.text(noMatchText), .chips(suggestionChips(ctx))], ctx) }
        let blocks = searchBlocks(results, ctx)
        if question { return done(.question, [.text(ctx.modelAvailable ? "Here's what matches." : askUnavailable)] + blocks, ctx) }
        return done(.search, blocks, ctx)
    }

    /// Lower case, accents dropped, everything but letters, digits and ':' → spaces, collapsed.
    static func command(_ input: String) -> String {
        let spaced = Rx.replace(#"[^\p{L}\p{N}:]+"#, AssistantSearch.fold(input), with: " ")
        return Rx.replace(#"\s+"#, spaced.trimmingCharacters(in: .whitespacesAndNewlines), with: " ")
    }

    // MARK: Plan commands (4–16)

    private static func planCommand(_ cmd: String, _ ctx: RouterContext) -> RoutedTurn? {
        let bundle = ctx.bundle
        func op(_ ops: [PlanOp]) -> RoutedTurn { edit(ops, ctx) }
        func item(_ phrase: String, _ makeOps: @escaping (Int) -> [PlanOp]) -> RoutedTurn {
            guard ctx.plan != nil else { return noPlan(ctx) }
            return withEntity(phrase, [.schedule], ctx, .planEdit, chip: { ref in
                AssistantChip(label: name(ref, ctx), action: .planEdit(makeOps(ref.id), bundle))
            }, preferPlanned: true) { ref in op(makeOps(ref.id)) }
        }

        if let m = Rx.find(#"^(?:replace|swap)\s+(.+?)\s+(?:with|for)\s+(.+)$"#, cmd) {
            guard ctx.plan != nil else { return noPlan(ctx) }
            let target = m[2]
            let likeMatch = Rx.find(#"^(?:something|anything|one|some)\s+(?:like|similar to)\s+(.+)$"#, target)
            let tagPhrase = Rx.find(#"^(?:something|some|more)\s+(.+)$"#, target)?[1] ?? target
            let tag = tagOf(tagPhrase, bundle)
            let replacement: (Int) -> [PlanOp]
            if let likeMatch {
                let likeId: Int
                switch resolve(likeMatch[1], [.schedule], ctx) {
                case .found(let ref): likeId = ref.id
                case .ambiguous(let refs) where !refs.isEmpty: likeId = refs[0].id
                default: return notFound(likeMatch[1], ctx)
                }
                replacement = { [.replace(item: $0, like: likeId)] }
            } else if let tag {
                replacement = { [.replace(item: $0, tag: tag)] }
            } else {
                switch resolve(target, [.schedule], ctx) {
                case .found(let ref):
                    let withId = ref.id
                    replacement = { [.replace(item: $0, with: withId)] }
                case .ambiguous(let refs):
                    return pick(refs, ctx, .planEdit) { ref in
                        var ops: [PlanOp] = [.add(item: ref.id)]
                        if case .found(let from) = resolve(m[1], [.schedule], ctx, preferPlanned: true) { ops = [.replace(item: from.id, with: ref.id)] }
                        return AssistantChip(label: name(ref, ctx), action: .planEdit(ops, bundle))
                    }
                case .notFound:
                    return notFound(target, ctx)
                }
            }
            return item(m[1], replacement)
        }
        if let m = Rx.find(#"^(?:remove|drop|skip|cancel)\s+(.+?)(?:\s+from\s+(?:my\s+)?plan)?$"#, cmd) {
            return item(m[1]) { [.remove(item: $0)] }
        }
        if let m = Rx.find(#"^add\s+(.+?)(?:\s+to\s+(?:my\s+)?plan)?$"#, cmd) {
            guard ctx.plan != nil else { return noPlan(ctx) }
            return withEntity(m[1], [.schedule], ctx, .planEdit, chip: { ref in
                AssistantChip(label: name(ref, ctx), action: .planEdit([.add(item: ref.id)], bundle))
            }) { ref in op([.add(item: ref.id)]) }
        }
        if let m = Rx.find(#"^move\s+(.+?)\s+(later|earlier)$"#, cmd) {
            let later = m[2] == "later"
            return item(m[1]) { [.move(item: $0, later: later)] }
        }
        if let m = Rx.find(#"^(?:unkeep|unpin|don t keep)\s+(.+)$"#, cmd) { return item(m[1]) { [.unkeep(item: $0)] } }
        if let m = Rx.find(#"^keep\s+(.+)$"#, cmd) { return item(m[1]) { [.keep(item: $0)] } }

        if Rx.contains(#"\b(already ate|just ate|i ate|had lunch|had dinner|had food|ate already)\b"#, cmd) {
            guard ctx.plan != nil else { return noPlan(ctx) }
            return op([.noFoodUntil(PlanCalendar.truncatedToMinute(ctx.now).addingTimeInterval(3 * 3600))])
        }
        if Rx.contains(#"\b(i m tired|im tired|i am tired|tired|exhausted|slow down|take it easy)\b"#, cmd) {
            guard ctx.plan != nil else { return noPlan(ctx) }
            return op([.pace(.relaxed)])
        }
        if let m = Rx.find(#"\b(?:done|finish|finished|home|back|out|leave|leaving)\s+(?:by|at|before)\s+(\d{1,2})(?::(\d{2}))?\s*(am|pm|a m|p m)?\b"#, cmd) {
            guard ctx.plan != nil else { return noPlan(ctx) }
            guard let time = clock(m, ctx) else { return nil }
            return op([.doneBy(time)])
        }
        if let m = Rx.find(#"\b(?:start|begin|starting)\s+(?:at|after|from|around)\s+(\d{1,2})(?::(\d{2}))?\s*(am|pm|a m|p m)?\b"#, cmd) {
            guard ctx.plan != nil else { return noPlan(ctx) }
            guard let time = clock(m, ctx) else { return nil }
            return op([.startAt(time)])
        }
        if let m = Rx.find(#"\bwalks? (?:under|less than|up to|of at most) (\d{1,2}) ?(?:min|mins|minutes)\b"#, cmd) {
            guard ctx.plan != nil else { return noPlan(ctx) }
            return op([.maxWalk(max(Int(m[1]) ?? 1, 1))])
        }
        if Rx.contains(#"\b(short walks?|less walking|walk less|shorter walks|no long walks|don t want to walk)\b"#, cmd) {
            guard ctx.plan != nil else { return noPlan(ctx) }
            return op([.maxWalk(PlanVersionKind.chillMaxWalk)])
        }
        if let m = Rx.find(#"^(?:i m|im|i am)\s+(?:at|by|near|in)\s+(.+)$"#, cmd) {
            guard ctx.plan != nil else { return noPlan(ctx) }
            return withEntity(m[1], [.location], ctx, .planEdit, chip: { ref in
                AssistantChip(label: name(ref, ctx), action: .planEdit([.fromLocation(ref.id)], bundle))
            }) { ref in op([.fromLocation(ref.id)]) }
        }
        if let m = Rx.find(#"^(?:more|extra|lots of)\s+(.+)$"#, cmd), let tag = tagOf(m[1], bundle) {
            return ctx.plan == nil ? noPlan(ctx) : op([.moreTag(tag)])
        }
        if let m = Rx.find(#"^(?:less|fewer|no more|not so much)\s+(.+)$"#, cmd), let tag = tagOf(m[1], bundle) {
            return ctx.plan == nil ? noPlan(ctx) : op([.lessTag(tag)])
        }
        var version: PlanVersionKind?
        if Rx.contains(#"\b(chill|relaxed|easy) (version|plan|day)\b"#, cmd) { version = .chill }
        else if Rx.contains(#"\b(see everything|see it all|packed version|packed plan|everything version)\b"#, cmd) { version = .everything }
        if let version {
            guard let plan = ctx.plan else { return noPlan(ctx) }
            let preview = PlanVersions.make(version, plan, bundle, ctx.likes, now: ctx.now)
            return done(.planVersion, [.text("\(version.label): \(describe(preview, bundle))"), .planDiff(preview.diff), editChips()], ctx,
                        actions: [.planVersion(version)], edit: preview)
        }
        if Rx.contains(#"\bcompare\b.*\b(versions?|plans?)\b"#, cmd) {
            guard ctx.plan != nil else { return noPlan(ctx) }
            return done(.planCompare, [.compare(a: "plan:chill", b: "plan:everything")], ctx)
        }
        return nil
    }

    private static func edit(_ ops: [PlanOp], _ ctx: RouterContext) -> RoutedTurn {
        guard let plan = ctx.plan else { return noPlan(ctx) }
        let preview = PlanEditor.preview(plan, ops, ctx.bundle, ctx.likes, now: ctx.now)
        return done(.planEdit, [.text(describe(preview, ctx.bundle)), .planDiff(preview.diff), editChips()], ctx,
                    actions: [.planEdit(ops, ctx.bundle)], edit: preview)
    }

    private static func editChips() -> AssistantBlock {
        .chips([AssistantChip(label: "Undo", action: AssistantAction(name: .planUndo)), AssistantChip(label: "Show my plan", action: AssistantAction(name: .plan))])
    }

    /// The sentence above a `plan_diff`: "Moved X to 8:00 PM." "Removed A and B." "Added C." "No
    /// lunch break." "Added a dinner break." "Moved the lunch break." then each note + "."; "Your
    /// plan stays the same." when nothing changed and there are no notes.
    static func describe(_ edit: PlanEdit, _ bundle: EventBundle, locale: Locale = Locale(identifier: "en_US")) -> String {
        let diff = edit.diff
        func n(_ id: Int) -> String { bundle.scheduleItem(id)?.name ?? "an item" }
        let zone = bundle.event.timeZone
        var parts: [String] = []
        for move in diff.moved {
            let time = bundle.scheduleItem(move.to)?.startTime.map { AssistantText.format($0, "h:mm a", zone, locale) } ?? "another time"
            parts.append("Moved \(n(move.from)) to \(time).")
        }
        if !diff.removed.isEmpty { parts.append("Removed \(names(diff.removed.map(n))).") }
        if !diff.added.isEmpty { parts.append("Added \(names(diff.added.map(n))).") }
        for slot in diff.mealsRemoved { parts.append("No \(slot.kind.label.lowercased()).") }
        for slot in diff.mealsAdded { parts.append("Added a \(slot.kind.label.lowercased()).") }
        for slot in diff.mealsMoved { parts.append("Moved the \(slot.kind.label.lowercased()).") }
        for note in edit.notes { parts.append("\(note).") }
        return parts.isEmpty ? "Your plan stays the same." : parts.joined(separator: " ")
    }

    private static func names(_ list: [String]) -> String {
        switch list.count {
        case 0: return ""
        case 1: return list[0]
        default: return list.dropLast().joined(separator: ", ") + " and " + (list.last ?? "")
        }
    }

    private static func clock(_ m: [String], _ ctx: RouterContext) -> PlanClock? {
        guard let hour = Int(m[1]) else { return nil }
        let minute = Int(m[2]) ?? 0
        let suffix = m[3].replacingOccurrences(of: " ", with: "")
        if hour > 23 || minute > 59 { return nil }
        let h: Int
        if suffix == "pm" {
            if hour > 12 { return nil }
            h = hour % 12 + 12
        } else if suffix == "am" {
            if hour > 12 { return nil }
            h = hour % 12
        } else if hour == 0 || hour >= 12 {
            h = hour
        } else {
            let calendar = PlanCalendar.calendar(ctx.bundle.event.timeZone)
            let local = calendar.dateComponents([.hour, .minute, .second], from: ctx.now)
            let nowMinutes = Double((local.hour ?? 0) * 60 + (local.minute ?? 0)) + Double(local.second ?? 0) / 60
            h = Double(hour * 60 + minute) > nowMinutes ? hour : hour + 12
        }
        return PlanClock(hour: h, minute: minute)
    }

    /// An event tag equal to `phrase`, or to it without / with a final "s".
    static func tagOf(_ phrase: String, _ bundle: EventBundle) -> String? {
        let p = AssistantSearch.normalize(phrase).trimmingCharacters(in: .whitespaces)
        if p.isEmpty { return nil }
        let tags = PlanRequest.tagVocabulary(bundle)
        let singular = p.hasSuffix("s") ? String(p.dropLast()) : p
        return tags.first { AssistantSearch.normalize($0) == p }
            ?? tags.first { AssistantSearch.normalize($0) == singular }
            ?? tags.first { AssistantSearch.normalize($0) == p + "s" }
    }

    // MARK: Entities

    /// Resolves a name in a command: filler words dropped, the rest searched (all tokens) among
    /// `kinds`; with `preferPlanned` and a plan, planned items win when any match. Base score =
    /// score without the now / next / ended boosts. Found = the top result when its base ≥ 3 × the
    /// number of text tokens and no other result has the same base; Ambiguous = ≤ 5 results tied
    /// at the top; otherwise NotFound.
    static func resolve(_ phrase: String, _ kinds: Set<RefKind>, _ ctx: RouterContext, preferPlanned: Bool = false) -> Resolution {
        let words = command(phrase).split(separator: " ").map(String.init).filter { !$0.isEmpty && !filler.contains($0) }
        if words.isEmpty { return .notFound }
        let text = words.joined(separator: " ")
        let tokens = AssistantSearch.parse(text).tokens.count
        var results = AssistantSearch.search(ctx.bundle, text, now: ctx.now).filter { r in RefKind.of(r.kind).map { kinds.contains($0) } ?? false }
        if preferPlanned, let plan = ctx.plan {
            let planned = results.filter { $0.kind == .schedule && plan.itemIds.contains($0.id) }
            if !planned.isEmpty { results = planned }
        }
        if results.isEmpty { return .notFound }
        let scored = results.map { ($0, base($0)) }.stableSorted { a, b in
            if a.1 != b.1 { return a.1 > b.1 }
            return (a.0.timing != .ended) && (b.0.timing == .ended)
        }
        let top = scored[0].1
        if top < minBasePerToken * Double(tokens) { return .notFound }
        let refs = scored.filter { $0.1 == top }.compactMap { EntityRef.of($0.0) }
        return refs.count == 1 ? .found(refs[0]) : .ambiguous(Array(refs.prefix(5)))
    }

    private static func base(_ result: AssistantSearch.Result) -> Double {
        switch result.timing {
        case .now?: return result.score - AssistantSearch.boostNow
        case .next?: return result.score - AssistantSearch.boostNext
        case .ended?: return result.score - AssistantSearch.penaltyEnded
        case nil: return result.score
        }
    }

    private static func withEntity(
        _ phrase: String,
        _ kinds: Set<RefKind>,
        _ ctx: RouterContext,
        _ intent: AssistantIntent,
        chip: (EntityRef) -> AssistantChip,
        preferPlanned: Bool = false,
        found: (EntityRef) -> RoutedTurn
    ) -> RoutedTurn {
        switch resolve(phrase, kinds, ctx, preferPlanned: preferPlanned) {
        case .found(let ref): return found(ref)
        case .ambiguous(let refs): return pick(refs, ctx, intent, chip)
        case .notFound: return notFound(phrase, ctx)
        }
    }

    /// Ambiguity: "Which one do you mean?" + one chip per candidate.
    private static func pick(_ refs: [EntityRef], _ ctx: RouterContext, _ intent: AssistantIntent, _ chip: (EntityRef) -> AssistantChip) -> RoutedTurn {
        let chips = refs.prefix(BlockValidator.maxChips).map { ref -> AssistantChip in
            var c = chip(ref)
            let same = refs.filter { name($0, ctx) == name(ref, ctx) }.count > 1
            c.label = ChipText.fit("", same ? "\(c.label) · \(shortDetail(ref, ctx))" : c.label)
            return c
        }
        return RoutedTurn(intent: .pick, turn: AssistantTurn(blocks: BlockValidator.validate([.text("Which one do you mean?"), .chips(Array(chips))], ctx.blockContext)))
    }

    private static func notFound(_ phrase: String, _ ctx: RouterContext) -> RoutedTurn {
        RoutedTurn(intent: .noMatch, turn: AssistantTurn(blocks: BlockValidator.validate(
            [.text("I couldn't find “\(phrase.trimmingCharacters(in: .whitespacesAndNewlines))”."), .chips(suggestionChips(ctx))], ctx.blockContext)))
    }

    private static func noPlan(_ ctx: RouterContext) -> RoutedTurn {
        let chips = ctx.canPlan
            ? PlanRequest.examples(ctx.bundle, now: ctx.now).filter(\.isPlan).map { AssistantChip(label: ChipText.fit("", $0.text), action: .planMake($0.text)) }
            : suggestionChips(ctx)
        return RoutedTurn(intent: .noPlan, turn: AssistantTurn(blocks: BlockValidator.validate([.text(noPlanText), .chips(chips)], ctx.blockContext)))
    }

    private static func name(_ ref: EntityRef, _ ctx: RouterContext) -> String { ref.name(ctx.bundle) ?? ref.code }

    private static func shortDetail(_ ref: EntityRef, _ ctx: RouterContext) -> String {
        switch ref.kind {
        case .schedule:
            return ctx.bundle.scheduleItem(ref.id)?.startTime.map { AssistantText.format($0, "EEE h:mm a", ctx.bundle.event.timeZone, ctx.locale) } ?? ""
        case .location: return ctx.bundle.location(ref.id)?.category ?? ""
        case .update: return ""
        }
    }

    private static func calendarAction(_ ref: EntityRef) -> AssistantAction {
        AssistantAction(name: .addToCalendar, params: ["ids": .array([.string(ref.code)])])
    }

    // MARK: Likes

    private static func like(_ phrase: String, liked: Bool, _ ctx: RouterContext) -> RoutedTurn {
        let intent: AssistantIntent = liked ? .like : .unlike
        return withEntity(phrase, [.schedule, .location], ctx, intent, chip: { ref in
            AssistantChip(label: name(ref, ctx), action: .like(ref.kind.searchKind, ref.id, liked: liked))
        }) { ref in
            let kind = ref.kind.searchKind
            let already = ctx.likes.has(kind, ref.id) == liked
            var after = ctx
            after.likes = ctx.likes.with(kind, ref.id, liked: liked)
            let text: String
            if already && liked { text = "You already like \(name(ref, ctx))." }
            else if already { text = "You don't like \(name(ref, ctx)) yet." }
            else if liked { text = "Liked \(name(ref, ctx))." }
            else { text = "Unliked \(name(ref, ctx))." }
            let clash = liked && ref.kind == .schedule ? ctx.plan.flatMap { LiveAssist.likeClash(ref.id, $0, ctx.bundle) } : nil
            let blocks: [AssistantBlock] = [.text(text), BlockValidator.card(ref), chips((clash.map { [$0] } ?? []) + entityChips(ref, after))]
            return RoutedTurn(intent: intent, turn: AssistantTurn(
                blocks: BlockValidator.validate(blocks, ctx.blockContext),
                actions: already ? [] : [.like(kind, ref.id, liked: liked)]
            ))
        }
    }

    private static func likedBlocks(_ ctx: RouterContext) -> [AssistantBlock] {
        let refs = AssistantSearch.liked(ctx.bundle, ctx.likes, now: ctx.now).compactMap { EntityRef.of($0) }
        if refs.isEmpty { return [.text("You haven't liked anything yet."), .chips(suggestionChips(ctx))] }
        return [.list(ids: refs, title: AssistantSearch.likedTitle)]
    }

    // MARK: Layout (spec §2 rules)

    /// Search results as blocks, places first, then schedule items, then updates: one → its card,
    /// 2–8 → a carousel, more → a list (titles "Places", "Schedule", "Updates"); places add a map
    /// when 2+ have coordinates. An event-only match → a text with its dates and address. Then the
    /// lead entity's chips.
    static func searchBlocks(_ results: [AssistantSearch.Result], _ ctx: RouterContext) -> [AssistantBlock] {
        let refs = results.compactMap { EntityRef.of($0) }
        let places = refs.filter { $0.kind == .location }
        let items = refs.filter { $0.kind == .schedule }
        let updates = refs.filter { $0.kind == .update }
        guard let lead = places.first ?? items.first ?? updates.first else {
            if results.contains(where: { $0.kind == .event }) {
                return [.text("**\(ctx.bundle.event.name)** · \(AssistantSearch.eventDetail(ctx.bundle.event, locale: ctx.locale))"), .chips(suggestionChips(ctx))]
            }
            return []
        }
        var blocks: [AssistantBlock] = []
        if let block = group(places, "Places") { blocks.append(block) }
        let pins = places.map(\.id).filter { ctx.bundle.location($0)?.coordinate != nil }
        if pins.count >= 2 { blocks.append(.map(pins: Array(pins.prefix(BlockValidator.maxPins)))) }
        if let block = group(items, "Schedule") { blocks.append(block) }
        if let block = group(updates, "Updates") { blocks.append(block) }
        blocks.append(chips(entityChips(lead, ctx)))
        return blocks
    }

    private static func group(_ refs: [EntityRef], _ title: String) -> AssistantBlock? {
        if refs.isEmpty { return nil }
        if refs.count == 1 { return BlockValidator.card(refs[0]) }
        return refs.count <= BlockValidator.maxCarousel ? .carousel(ids: refs, title: title) : .list(ids: refs, title: title)
    }

    private static func chips(_ list: [AssistantChip]) -> AssistantBlock { .chips(Array(list.prefix(BlockValidator.maxChips))) }

    /// Follow-ups for one entity. Item: Like/Unlike; "Add to my plan" (a plan, not in it, not
    /// started); "Show on map" (location with coordinates). Place: Like/Unlike; "Show on map" and
    /// "Directions" (with coordinates). Update: "All updates".
    static func entityChips(_ ref: EntityRef, _ ctx: RouterContext) -> [AssistantChip] {
        let bundle = ctx.bundle
        switch ref.kind {
        case .schedule:
            guard let item = bundle.scheduleItem(ref.id) else { return [] }
            var result = [likeChip(ref, ctx)]
            if let plan = ctx.plan, !plan.itemIds.contains(item.id), let start = item.startTime, start > ctx.now {
                result.append(AssistantChip(label: "Add to my plan", action: .planEdit([.add(item: item.id)], bundle)))
            }
            if let location = bundle.location(item.locationId), location.coordinate != nil {
                result.append(AssistantChip(label: "Show on map", action: .open("map", EntityRef(kind: .location, id: location.id))))
            }
            return result
        case .location:
            guard let location = bundle.location(ref.id) else { return [] }
            var result = [likeChip(ref, ctx)]
            if location.coordinate != nil {
                result.append(AssistantChip(label: "Show on map", action: .open("map", ref)))
                result.append(AssistantChip(label: "Directions", action: .directions(location.id)))
            }
            return result
        case .update:
            return [AssistantChip(label: "All updates", action: .open("updates"))]
        }
    }

    private static func likeChip(_ ref: EntityRef, _ ctx: RouterContext) -> AssistantChip {
        let liked = ctx.likes.has(ref.kind.searchKind, ref.id)
        return AssistantChip(label: liked ? "Unlike" : "Like", action: .like(ref.kind.searchKind, ref.id, liked: !liked))
    }

    /// The empty-state chips, ≤ 5: "Happening now", "Up next" (when something is), "Liked" (when
    /// anything is liked), then the categories (each a search).
    static func suggestionChips(_ ctx: RouterContext) -> [AssistantChip] {
        let suggestions = AssistantSearch.suggestions(ctx.bundle, now: ctx.now)
        let timed = suggestions.filter { $0.query == "now" || $0.query == "next" }
        var result = timed.map { AssistantChip(label: $0.label, action: .search($0.query)) }
        if !ctx.likes.isEmpty { result.append(AssistantChip(label: AssistantSearch.likedTitle, action: AssistantAction(name: .liked))) }
        result += suggestions.filter { $0.query != "now" && $0.query != "next" }.map { AssistantChip(label: $0.label, action: .search($0.query)) }
        return Array(result.prefix(BlockValidator.maxChips))
    }

    // MARK: Time and place

    /// "What's on tonight": schedule items matching the time words, not ended, as a timeline
    /// titled "Happening now" / "Up next" / the words capitalised; chips "Make a plan for this"
    /// (plans can be made, no plan yet) and "Show the map".
    private static func whatsOn(_ keywords: String, _ input: String, _ ctx: RouterContext) -> RoutedTurn {
        let items = AssistantSearch.search(ctx.bundle, keywords, now: ctx.now).filter { $0.kind == .schedule && $0.timing != .ended }.map(\.id)
        let trimmed = keywords.trimmingCharacters(in: .whitespaces)
        let title: String
        switch trimmed {
        case "now", "happening now": title = AssistantSearch.nowTitle
        case "next", "up next", "soon": title = AssistantSearch.nextTitle
        default: title = trimmed.prefix(1).uppercased() + trimmed.dropFirst()
        }
        let blocks: [AssistantBlock]
        if items.isEmpty {
            blocks = [.text("Nothing's on then."), .chips(suggestionChips(ctx))]
        } else {
            var list: [AssistantChip] = []
            if ctx.canPlan && ctx.plan == nil {
                list.append(AssistantChip(label: "Make a plan for this", action: .planMake(input.trimmingCharacters(in: .whitespacesAndNewlines))))
            }
            list.append(AssistantChip(label: "Show the map", action: .open("map")))
            blocks = [.timeline(ids: items, title: title), chips(list)]
        }
        return done(.whatsOn, blocks, ctx)
    }

    private static func nearMe(_ cmd: String, _ ctx: RouterContext) -> RoutedTurn {
        let stripped = Rx.replace(#"\b(near me|nearby|closest|around me|near here|what s|whats|the|is|are|places?)\b"#, cmd, with: " ")
        let rest = Rx.replace(#"\s+"#, stripped.trimmingCharacters(in: .whitespaces), with: " ")
        let keywords = AssistantSearch.keywords(rest)
        let query = (keywords == rest && AssistantSearch.words(keywords).allSatisfy { AssistantSearch.stopWords.contains($0) } ? "" : keywords)
            .trimmingCharacters(in: .whitespaces)
        let bundle = ctx.bundle
        let places: [Int]
        if query.isEmpty {
            places = bundle.locations.filter { $0.coordinate != nil }
                .stableSorted { $0.sortOrder != $1.sortOrder ? $0.sortOrder < $1.sortOrder : $0.id < $1.id }.map(\.id)
        } else {
            places = AssistantSearch.search(bundle, query, now: ctx.now).filter { $0.kind == .location }.map(\.id)
        }
        if places.isEmpty { return done(.noMatch, [.text(noMatchText), .chips(suggestionChips(ctx))], ctx) }
        var blocks: [AssistantBlock] = []
        let ordered: [Int]
        if let user = ctx.user {
            let withPoint = places.filter { bundle.location($0)?.coordinate != nil }
            let without = places.filter { bundle.location($0)?.coordinate == nil }
            let measured: [(id: Int, meters: Double)] = withPoint.compactMap { id in
                bundle.location(id)?.coordinate.map { (id: id, meters: Planner.distance(user, $0)) }
            }
            let near: [Int] = measured.stableSorted { a, b in a.meters != b.meters ? a.meters < b.meters : a.id < b.id }.map(\.id)
            ordered = near + without
            let pins = Array(ordered.filter { bundle.location($0)?.coordinate != nil }.prefix(BlockValidator.maxPins))
            if !pins.isEmpty { blocks.append(.map(pins: pins)) }
        } else {
            blocks.append(.text("Turn on location to see what's closest."))
            ordered = places
        }
        let refs = ordered.map { EntityRef(kind: .location, id: $0) }
        let title = ctx.user != nil ? "Near you" : "Places"
        if refs.count == 1 { blocks.append(BlockValidator.card(refs[0])) }
        else if refs.count <= BlockValidator.maxCarousel { blocks.append(.carousel(ids: refs, title: title)) }
        else { blocks.append(.list(ids: refs, title: title)) }
        blocks.append(chips(entityChips(refs[0], ctx)))
        return done(.nearMe, blocks, ctx)
    }

    // MARK: Plan views

    private static func planBlocks(_ ctx: RouterContext) -> [AssistantBlock] {
        guard let plan = ctx.plan else { return [] }
        var list = [
            AssistantChip(label: "Share my plan", action: AssistantAction(name: .sharePlan)),
            AssistantChip(label: "Add my plan to calendar", action: .calendarPlan()),
            AssistantChip(label: PlanVersionKind.chill.label + " version", action: .planVersion(.chill)),
        ]
        if ctx.history.canUndo { list.append(AssistantChip(label: "Undo", action: AssistantAction(name: .planUndo))) }
        return [.text(Planner.summary(plan, timeZone: ctx.bundle.event.timeZone, locale: ctx.locale)), .plan(day: nil), chips(list)]
    }

    private static func walkingBlocks(_ plan: Plan, _ ctx: RouterContext) -> [AssistantBlock] {
        let today = PlanDate(ctx.now, in: PlanCalendar.calendar(ctx.bundle.event.timeZone))
        let date = plan.days.first { $0.date == today && !$0.items.isEmpty }?.date
        guard let route = DayRoutes.of(plan, ctx.bundle, date: date) else { return [.text("Your plan has no walking yet.")] }
        let stops = route.stops.map(\.locationId)
        var blocks: [AssistantBlock] = [.text(DayRoutes.totalText(route, today: today, ctx.units, locale: ctx.locale)), .summary("walking")]
        if !stops.isEmpty {
            var seen = Set<Int>()
            blocks.append(.map(pins: stops.filter { seen.insert($0).inserted }, route: stops))
        }
        return blocks
    }

    /// `why_not`: the explanation, the item's card and "Swap it in".
    static func whyNotBlocks(_ itemId: Int, _ ctx: RouterContext) -> [AssistantBlock] {
        guard let answer = WhyNot.explain(itemId, ctx.plan, ctx.bundle, ctx.likes, now: ctx.now, locale: ctx.locale) else { return [] }
        var blocks: [AssistantBlock] = [.text(answer.text), .itemCard(id: itemId)]
        if let chip = WhyNot.chip(answer, ctx.bundle) { blocks.append(chips([chip])) }
        return blocks
    }

    // MARK: Toggles

    private static func toggle(_ cmd: String) -> AssistantAction? {
        let name: ActionName
        if Rx.contains(#"\b(remind|reminders?)\b"#, cmd) { name = .reminders }
        else if Rx.contains(#"\b(lock screen|live update|live updates|follow)\b"#, cmd) { name = .followLockScreen }
        else if Rx.contains(#"\b(notifications?|notify)\b"#, cmd) { name = .notifications }
        else { return nil }
        let off = Rx.contains(#"\b(off|stop|disable|don t)\b|\bno\s"#, cmd + " ")
        return .toggle(name, on: !off)
    }

    // MARK: Read actions (model tool calls, chips)

    /// Renders a read action's result with the same layout rules (validated; writes → empty).
    static func renderRead(_ action: AssistantAction, _ ctx: RouterContext) -> [AssistantBlock] {
        let bundle = ctx.bundle
        var blocks: [AssistantBlock] = []
        switch action.name {
        case .search:
            blocks = searchBlocks(AssistantSearch.search(bundle, action.string("query") ?? "", now: ctx.now), ctx)
        case .getItem:
            if let id = action.id("id", prefix: "s") { blocks = [.itemCard(id: id), chips(entityChips(EntityRef(kind: .schedule, id: id), ctx))] }
        case .getLocation:
            if let id = action.id("id", prefix: "l") { blocks = [.placeCard(id: id), chips(entityChips(EntityRef(kind: .location, id: id), ctx))] }
        case .getUpdate:
            if let id = action.id("id", prefix: "u") { blocks = [.updateCard(id: id)] }
        case .eventInfo:
            blocks = [.text("**\(bundle.event.name)** · \(AssistantSearch.eventDetail(bundle.event, locale: ctx.locale))")]
        case .nowNext:
            blocks = [.nowNext(location: action.id("location", prefix: "l"))]
        case .whatsOn:
            blocks = [.timeline(source: "whats_on")]
        case .liked:
            blocks = likedBlocks(ctx)
        case .plan:
            blocks = ctx.plan != nil ? planBlocks(ctx) : [.text(noPlanText)]
        case .nearMe:
            blocks = nearMe("near me " + (action.string("kind") ?? ""), ctx).blocks
        case .whyNot:
            if let id = action.id("item", prefix: "s") { blocks = whyNotBlocks(id, ctx) }
        case .route:
            if let to = action.id("to_location", prefix: "l") {
                let from = action.id("from", prefix: "l")
                let stops = [from, to].compactMap { $0 }
                var seen = Set<Int>()
                blocks = [.map(pins: stops.filter { seen.insert($0).inserted }, route: stops)]
            }
        case .dayRoute:
            blocks = ctx.plan.map { walkingBlocks($0, ctx) } ?? [.text(noPlanText)]
        default:
            blocks = []
        }
        return BlockValidator.validate(blocks, ctx.blockContext)
    }
}
