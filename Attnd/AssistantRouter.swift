// AssistantRouter.swift
// Attnd (app + App Clip; unit tested in AssistantRouterTests)
//
// The rule-based assistant (assistant spec §3; every phone, pure), a port of Android's
// `domain/AssistantRouter.kt` grammar rules 1–29 with the same fixtures and exact block JSON.
// `route` reads the input (folded: lower case, accents dropped, everything but letters, digits
// and ':' as spaces) as a small command grammar, first match wins:
//  1. empty → EMPTY (suggestion chips).  2. "undo" → `plan_undo`.
//  3. "add <x | my plan> to (my) calendar" → `calendar`: on iOS a "not available" text (+ Share my
//     plan); no Add to Calendar here since Nov 19, 2026 (Android adds it).
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

/// Everything the router (and the model prompt) may use. All local.
struct RouterContext: Sendable {
    var bundle: EventBundle
    var likes: LikeSet
    var plan: Plan?
    var now: Date
    /// The user's position, only when location is permitted and known.
    var user: Coordinate? = nil
    /// The planner may make plans (model available).
    var canPlan = true
    /// Ask (the on-device model) is available; the router is then only the fallback.
    var modelAvailable = false
    var history = PlanHistory()
    var units: DistanceUnits = .imperial
    var locale = Locale(identifier: "en_US")
    /// My schedule (iOS): timed places, reminders, clashes. `likes` mirrors its membership.
    var schedule = MySchedule()
    /// What the conversation showed ("add it", "the second one").
    var memory = ConversationContext()

    var blockContext: BlockContext { BlockContext(bundle: bundle, plan: plan, now: now) }

    /// My schedule as the router sees it: the entries, plus likes and planned items it doesn't
    /// list yet (they are in My schedule in the app; tests may pass only likes and a plan).
    var mine: MySchedule {
        var merged = schedule
        for id in likes.scheduleItems.union(plan?.itemIds ?? []).sorted() where !merged.contains(.scheduleItem(id)) {
            merged.add(.scheduleItem(id))
        }
        for id in likes.locations.sorted() where !merged.contains(.location(id)) { merged.add(.location(id)) }
        return merged
    }
}

enum AssistantIntent: Hashable, Sendable {
    case empty, search, question, noMatch, pick, whatsOn, nearMe, like, unlike, liked
    case planEdit, planUndo, planVersion, planCompare, planMake, planShow, planNext, walking, recap, noPlan
    case whyNot, toggle, open, share, calendar
    /// My schedule commands (add / remove / move / remind / what's on my schedule / clashes).
    case schedule
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
    private static let filler: Set<String> = ["the", "a", "an", "thing", "one", "that", "this", "it", "please"]
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

        if Rx.matches(#"^(?:add|put|save)\s+(.+?)\s+(?:to|in|on)\s+(?:my\s+)?calendar$"#, cmd) {
            var blocks: [AssistantBlock] = [.text(calendarText)]
            if plan != nil { blocks.append(chips([AssistantChip(label: "Share my plan", action: AssistantAction(name: .sharePlan))])) }
            return done(.calendar, blocks, ctx)
        }

        if let turn = scheduleCommand(cmd, ctx) { return turn }

        if let turn = planCommand(cmd, ctx) { return turn }

        if let m = Rx.find(#"^(?:unlike|unheart|un like)\s+(.+)$"#, cmd) { return like(m[1], liked: false, ctx) }
        if let m = Rx.find(#"^(?:like|heart|love|i like|i love)\s+(.+)$"#, cmd) { return like(m[1], liked: true, ctx) }

        if let action = toggle(cmd) {
            return done(.toggle, [.confirm(action: action, prompt: ActionRegistry.confirmPrompt(action))], ctx)
        }

        if Rx.matches(#"share\s+(?:my\s+)?plan"#, cmd) {
            guard plan != nil else { return noPlan(ctx) }
            return done(.share, [.share("plan")], ctx)
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
            guard plan != nil else { return done(.schedule, myScheduleBlocks(nil, ctx), ctx) }
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

        if Rx.matches(#"liked|likes|my likes|what (?:have|did) i liked?|show (?:me )?(?:my )?likes|what i liked|things i liked|saved|saved places|my saved places"#, cmd) {
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

    // MARK: My schedule (iOS, Nov 21, 2026)

    /// "my schedule", "my plan", "my itinerary", "my agenda", "my day".
    private static let scheduleNoun = #"(?:my\s+)?(?:schedule|plan|itinerary|agenda|day)"#
    private static let clockPattern = #"(\d{1,2})(?::(\d{2}))?\s*(am|pm|a m|p m)?"#
    private static let mealWords: Set<String> = ["dinner", "lunch", "breakfast", "brunch", "food", "eat", "something to eat", "a bite", "snack", "snacks", "drinks"]

    /// The My schedule grammar (before the plan rules): add / put / save / book <x> (to my
    /// schedule) (at <time>); remove / drop / cancel / skip <x> (from my schedule); move <x> to
    /// <time>; remind me <n> min before <x> / remind me about <x> <n> min before / don't remind me
    /// about <x>; what's on my schedule (<day>); show <x> on the map; directions (to) <x>; find <x>.
    /// Names resolve through the conversation memory first ("it", "the second one").
    static func scheduleCommand(_ cmd: String, _ ctx: RouterContext) -> RoutedTurn? {
        let kinds: Set<RefKind> = [.schedule, .location]
        if let m = Rx.find(#"^(?:find|search for|look for|looking for|i want|i need|get me)\s+(.+)$"#, cmd) {
            let phrase = m[1].trimmingCharacters(in: .whitespaces)
            let query = mealWords.contains(Rx.replace(#"^(?:some|a|an|the)\s+"#, phrase, with: "")) ? "food" : AssistantSearch.keywords(phrase)
            let results = AssistantSearch.search(ctx.bundle, query, now: ctx.now)
            if results.isEmpty { return done(.noMatch, [.text(noMatchText), .chips(suggestionChips(ctx))], ctx) }
            return done(.search, searchBlocks(results, ctx), ctx)
        }
        if let m = Rx.find(#"^(?:add|put|save|book|schedule)\s+(.+?)(?:\s+(?:to|in|on|into)\s+"# + scheduleNoun + #")?(?:\s+(?:at|for)\s+"# + clockPattern + #")?$"#, cmd) {
            let time = m[2].isEmpty ? nil : clock([m[0], m[2], m[3], m[4]], ctx)
            if m[1].hasSuffix(" calendar") { return nil }
            return withScheduleEntity(m[1], kinds, ctx) { refs in
                refs.count == 1 ? add(refs[0], time: time, ctx) : addMany(refs, ctx)
            }
        }
        if let m = Rx.find(#"^(?:remove|drop|cancel|skip|delete|take off|take out)\s+(.+?)(?:\s+(?:from|off|out of)\s+"# + scheduleNoun + ")?$", cmd) {
            return withScheduleEntity(m[1], kinds, ctx, preferScheduled: true) { refs in remove(refs, ctx) }
        }
        if let m = Rx.find(#"^(?:move|change|reschedule|push|switch)\s+(.+?)\s+to\s+"# + clockPattern + "$", cmd) {
            guard let time = clock([m[0], m[2], m[3], m[4]], ctx) else { return nil }
            return withScheduleEntity(m[1], kinds, ctx, preferScheduled: true) { refs in move(refs[0], time, ctx) }
        }
        if let m = Rx.find(#"^remind me\s+(\d{1,3})\s*(min|mins|minutes|m|hour|hours|h)?\s+before\s+(.+)$"#, cmd) {
            let minutes = (Int(m[1]) ?? 15) * (m[2].hasPrefix("h") ? 60 : 1)
            return withScheduleEntity(m[3], kinds, ctx, preferScheduled: true) { refs in remind(refs[0], minutes, ctx) }
        }
        if let m = Rx.find(#"^remind me\s+(?:about|of|before)\s+(.+?)(?:\s+(\d{1,3})\s*(min|mins|minutes|m|hour|hours|h)?\s+before)?$"#, cmd) {
            let minutes = m[2].isEmpty ? MySchedule.defaultReminder : (Int(m[2]) ?? 15) * (m[3].hasPrefix("h") ? 60 : 1)
            return withScheduleEntity(m[1], kinds, ctx, preferScheduled: true) { refs in remind(refs[0], minutes, ctx) }
        }
        if let m = Rx.find(#"^(?:don t|do not|dont|stop|no)\s+remind(?:ing)?\s+me\s+(?:about|of)\s+(.+)$"#, cmd) {
            return withScheduleEntity(m[1], kinds, ctx, preferScheduled: true) { refs in remind(refs[0], 0, ctx) }
        }
        if let m = Rx.find(#"^(?:what s|whats|what is|what do i have|show|show me|see)?\s*(?:on|in)?\s*my\s+(?:schedule|itinerary|agenda)(?:\s+(?:for\s+|on\s+)?(today|tonight|tomorrow|monday|tuesday|wednesday|thursday|friday|saturday|sunday|mon|tue|wed|thu|fri|sat|sun))?$"#, cmd) {
            return done(.schedule, myScheduleBlocks(m[1].isEmpty ? nil : day(m[1], ctx), ctx), ctx)
        }
        if let m = Rx.find(#"^(?:show|see|put|find)\s+(.+?)\s+on\s+(?:the\s+)?map$"#, cmd) {
            return withScheduleEntity(m[1], kinds, ctx) { refs in
                guard let place = placeOf(refs[0], ctx) else {
                    return done(.open, [.text("\(name(refs[0], ctx)) has no place on the map.")], ctx)
                }
                return done(.open, [.text("Showing \(ctx.bundle.location(place)?.name ?? "it") on the map.")], ctx,
                            actions: [.open("map", EntityRef(kind: .location, id: place))])
            }
        }
        if let m = Rx.find(#"^(?:directions|get directions|walking directions|walk me|take me|how do i get)(?:\s+(?:to|there|here))?\s*(.*)$"#, cmd) {
            let phrase = m[1].isEmpty ? "there" : m[1]
            return withScheduleEntity(phrase, kinds, ctx) { refs in
                guard let place = placeOf(refs[0], ctx), ctx.bundle.location(place)?.coordinate != nil else {
                    return done(.open, [.text("There's no map point for \(name(refs[0], ctx)).")], ctx)
                }
                return done(.open, [.text("Directions to \(ctx.bundle.location(place)?.name ?? "it").")], ctx, actions: [.directions(place)])
            }
        }
        return nil
    }

    /// The place of an entity: a place itself, an item's location.
    private static func placeOf(_ ref: EntityRef, _ ctx: RouterContext) -> Int? {
        switch ref.kind {
        case .location: return ref.id
        case .schedule: return ctx.bundle.scheduleItem(ref.id)?.locationId.flatMap { ctx.bundle.location($0)?.id }
        case .update: return nil
        }
    }

    /// Resolves for My schedule: memory first; with `preferScheduled`, entries win when any match.
    private static func withScheduleEntity(_ phrase: String, _ kinds: Set<RefKind>, _ ctx: RouterContext, preferScheduled: Bool = false,
                                           found: ([EntityRef]) -> RoutedTurn) -> RoutedTurn {
        if let refs = ctx.memory.resolve(phrase, kinds: kinds, ctx.bundle), !refs.isEmpty {
            let text = command(phrase)
            if refs.count == 1 || ["them", "both", "both of them", "those", "these", "all of them", "all of those", "all three", "all"].contains(text) {
                return found(refs)
            }
            return pick(refs, ctx, .schedule) { ref in AssistantChip(label: name(ref, ctx), action: .scheduleAdd(ref)) }
        }
        switch resolve(phrase, kinds, ctx) {
        case .found(let ref): return found([ref])
        case .ambiguous(let refs):
            if preferScheduled {
                let scheduled = refs.filter { ctx.mine.contains(target($0)) }
                if scheduled.count == 1 { return found(scheduled) }
            }
            return pick(refs, ctx, .schedule) { ref in AssistantChip(label: name(ref, ctx), action: .scheduleAdd(ref)) }
        case .notFound:
            // Small typos ("prairie lihgts"): the search's best result when it is the only one on top.
            let words = command(phrase).split(separator: " ").map(String.init).filter { !filler.contains($0) }
            let results = AssistantSearch.search(ctx.bundle, words.joined(separator: " "), now: ctx.now)
                .filter { r in RefKind.of(r.kind).map { kinds.contains($0) } ?? false }
            if let first = results.first, let ref = EntityRef.of(first), !words.isEmpty,
               results.dropFirst().first.map({ base($0) < base(first) }) ?? true {
                return found([ref])
            }
            return notFound(phrase, ctx)
        }
    }

    static func target(_ ref: EntityRef) -> SearchTarget {
        switch ref.kind {
        case .schedule: return .scheduleItem(ref.id)
        case .location: return .location(ref.id)
        case .update: return .notification(ref.id)
        }
    }

    private static func clockOf(_ date: Date, _ ctx: RouterContext) -> PlanClock {
        let calendar = PlanCalendar.calendar(ctx.bundle.event.timeZone)
        return PlanClock(hour: calendar.component(.hour, from: date), minute: calendar.component(.minute, from: date))
    }

    private static func time(_ date: Date, _ ctx: RouterContext) -> String {
        AssistantText.format(date, "h:mm a", ctx.bundle.event.timeZone, ctx.locale)
    }

    /// "Added X" / the clash question; a place without a time is saved (with "Pick a time" chips).
    private static func add(_ ref: EntityRef, time clock: PlanClock?, _ ctx: RouterContext) -> RoutedTurn {
        let bundle = ctx.bundle
        let entry = ctx.mine.entry(for: target(ref))
        let card = BlockValidator.card(ref)
        switch ref.kind {
        case .schedule:
            if entry != nil {
                return done(.schedule, [.text("**\(name(ref, ctx))** is already in your schedule."), card, chips(entityChips(ref, ctx))], ctx)
            }
            if let span = ctx.mine.span(of: target(ref), bundle),
               let clash = ctx.mine.clashes(start: span.start, end: span.end, excluding: target(ref), bundle, now: ctx.now).first {
                return clashTurn(ref, clash, time: nil, ctx)
            }
            return done(.schedule, [.text("Added **\(name(ref, ctx))** to your schedule."), card, chips(addedChips(ref, ctx))], ctx,
                        actions: [.scheduleAdd(ref)])
        case .location:
            guard let clock else {
                if entry != nil {
                    let at = entry?.at.map { " at " + time($0, ctx) } ?? ""
                    return done(.schedule, [.text("**\(name(ref, ctx))** is already in your schedule\(at)."), card, chips(entityChips(ref, ctx))], ctx)
                }
                // Saved at once without a time (owner, Nov 21, 2026: no "When?"); the chips offer
                // a time for whoever wants one.
                let options = ctx.mine.suggestedTimes(for: ref.id, bundle, now: ctx.now, walkMinutes: walkMinutes(ref.id, ctx))
                var times = Array(options.times.prefix(2))
                if let suggested = options.suggested, !times.contains(suggested) { times.insert(suggested, at: 0) }
                var list = times.prefix(2).map { at in
                    AssistantChip(label: "Pick a time: " + time(at, ctx), action: .scheduleMove(ref, time: clockOf(at, ctx).description))
                }
                list.append(contentsOf: addedChips(ref, ctx).filter { $0.action.name != .scheduleReminder })
                return done(.schedule, [.text("Saved **\(name(ref, ctx))** to your schedule."), card, chips(list)], ctx,
                            actions: [.scheduleAdd(ref)])
            }
            let at = MySchedule.date(clock, near: nil, now: ctx.now, timeZone: bundle.event.timeZone)
            if let span = ctx.mine.span(of: target(ref), at: at, bundle),
               let clash = ctx.mine.clashes(start: span.start, end: span.end, excluding: target(ref), bundle, now: ctx.now).first {
                return clashTurn(ref, clash, time: clock, ctx)
            }
            let verb = entry == nil ? "Added" : "Moved"
            return done(.schedule, [.text("\(verb) **\(name(ref, ctx))** \(entry == nil ? "to your schedule at" : "to") \(time(at, ctx))."), card,
                                    chips(addedChips(ref, ctx))], ctx, actions: [.scheduleAdd(ref, time: clock.description)])
        case .update:
            return done(.schedule, [.text("Updates can't go in your schedule.")], ctx)
        }
    }

    /// "That overlaps X at 7:00 PM. Replace it or keep both?"
    private static func clashTurn(_ ref: EntityRef, _ clash: MyScheduleRow, time clock: PlanClock?, _ ctx: RouterContext) -> RoutedTurn {
        let other = EntityRef(kind: clash.entry.kind == .item ? .schedule : .location, id: clash.entry.id)
        let timeText = clock?.description
        return done(.schedule, [
            .text("That overlaps **\(clash.name)** at \(time(clash.start, ctx)). Replace it or keep both?"),
            BlockValidator.card(ref),
            chips([
                AssistantChip(label: ChipText.fit("Replace ", clash.name), action: .scheduleAdd(ref, time: timeText, replace: other)),
                AssistantChip(label: "Keep both", action: .scheduleAdd(ref, time: timeText)),
            ]),
        ], ctx)
    }

    private static func addMany(_ refs: [EntityRef], _ ctx: RouterContext) -> RoutedTurn {
        // Items, and places saved without a time.
        let new = refs.filter { $0.kind != .update && !ctx.mine.contains(target($0)) }
        guard !new.isEmpty else {
            return done(.schedule, [.text("They're already in your schedule.")], ctx)
        }
        return done(.schedule, [.text("Added \(names(new.map { "**\(name($0, ctx))**" })) to your schedule."), .list(ids: new, title: MyScheduleTitle.title)],
                    ctx, actions: new.map { .scheduleAdd($0) })
    }

    private static func remove(_ refs: [EntityRef], _ ctx: RouterContext) -> RoutedTurn {
        let inSchedule = refs.filter { ctx.mine.contains(target($0)) }
        guard !inSchedule.isEmpty else {
            return done(.schedule, [.text("**\(name(refs[0], ctx))** isn't in your schedule.")], ctx)
        }
        return done(.schedule, [.text("Removed \(names(inSchedule.map { "**\(name($0, ctx))**" })) from your schedule.")], ctx,
                    actions: inSchedule.map { .scheduleRemove($0) })
    }

    private static func move(_ ref: EntityRef, _ clock: PlanClock, _ ctx: RouterContext) -> RoutedTurn {
        let bundle = ctx.bundle
        switch ref.kind {
        case .location:
            let entry = ctx.mine.entry(for: target(ref))
            guard entry != nil else { return add(ref, time: clock, ctx) }
            let at = MySchedule.date(clock, near: entry?.at, now: ctx.now, timeZone: bundle.event.timeZone)
            return done(.schedule, [.text("Moved **\(name(ref, ctx))** to \(time(at, ctx))."), BlockValidator.card(ref)], ctx,
                        actions: [.scheduleMove(ref, time: clock.description)])
        case .schedule:
            let start = bundle.scheduleItem(ref.id)?.startTime.map { " (\(time($0, ctx)))" } ?? ""
            var list: [AssistantChip] = []
            if ctx.mine.contains(target(ref)) { list.append(AssistantChip(label: "Remove it", action: .scheduleRemove(ref))) }
            return done(.schedule, [.text("**\(name(ref, ctx))** is at a set time\(start); the organizer decides when it is."),
                                    BlockValidator.card(ref), chips(list)], ctx)
        case .update:
            return done(.schedule, [.text("Updates can't go in your schedule.")], ctx)
        }
    }

    private static func remind(_ ref: EntityRef, _ minutes: Int, _ ctx: RouterContext) -> RoutedTurn {
        let value = MySchedule.nearestReminder(minutes)
        let inSchedule = ctx.mine.contains(target(ref))
        let text = value == 0
            ? "No reminder for **\(name(ref, ctx))**."
            : "I'll remind you \(MyScheduleTitle.reminder(value)) **\(name(ref, ctx))**."
        if inSchedule {
            return done(.schedule, [.text(text)], ctx, actions: [.scheduleReminder(ref, minutes: value)])
        }
        guard ref.kind == .schedule else {
            return add(ref, time: nil, ctx)
        }
        return done(.schedule, [.text("Added **\(name(ref, ctx))** to your schedule. " + text), BlockValidator.card(ref)], ctx,
                    actions: [.scheduleAdd(ref), .scheduleReminder(ref, minutes: value)])
    }

    private static func addedChips(_ ref: EntityRef, _ ctx: RouterContext) -> [AssistantChip] {
        var list = [AssistantChip(label: "Remind me 30 min before", action: .scheduleReminder(ref, minutes: 30))]
        list.append(AssistantChip(label: "Show my schedule", action: AssistantAction(name: .mySchedule)))
        if let place = placeOf(ref, ctx), ctx.bundle.location(place)?.coordinate != nil {
            list.append(AssistantChip(label: "Show on map", action: .open("map", EntityRef(kind: .location, id: place))))
        }
        return list
    }

    private static func walkMinutes(_ locationId: Int, _ ctx: RouterContext) -> Int? {
        guard let user = ctx.user, let point = ctx.bundle.location(locationId)?.coordinate else { return nil }
        let meters = Planner.distance(user, point)
        return WalkTime.isWithinWalkingRange(meters) ? WalkTime.minutes(WalkTime.estimatedSeconds(straightMeters: meters)) : nil
    }

    /// today / tonight / tomorrow / a weekday → the event day (the next one on or after today).
    private static func day(_ word: String, _ ctx: RouterContext) -> PlanDate? {
        let calendar = PlanCalendar.calendar(ctx.bundle.event.timeZone)
        let today = PlanDate(ctx.now, in: calendar)
        switch word {
        case "today", "tonight": return today
        case "tomorrow": return today.adding(days: 1)
        default:
            let names = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"]
            guard let index = names.firstIndex(of: String(word.prefix(3))) else { return nil }
            return (0..<7).map { today.adding(days: $0) }.first { $0.weekday == index + 1 }
        }
    }

    /// "What's on my schedule (Saturday)": the timed entries (that day, else from now) and saved places.
    static func myScheduleBlocks(_ day: PlanDate?, _ ctx: RouterContext) -> [AssistantBlock] {
        let bundle = ctx.bundle
        let rows = day.map { ctx.mine.rows(on: $0, bundle, now: ctx.now) } ?? ctx.mine.rows(bundle, now: ctx.now).filter { !$0.ended }
        let refs = rows.map { EntityRef(kind: $0.entry.kind == .item ? .schedule : .location, id: $0.entry.id) }
        let saved = day == nil ? ctx.mine.savedPlaceIds.filter { bundle.location($0) != nil }.map { EntityRef(kind: .location, id: $0) } : []
        guard !refs.isEmpty || !saved.isEmpty else {
            var list: [AssistantChip] = []
            if ctx.canPlan { list.append(AssistantChip(label: "Plan my day", action: .planMake("Plan my day"))) }
            list += suggestionChips(ctx)
            return [.text(day == nil ? "Your schedule is empty. Add things with + or ask me." : "Nothing in your schedule that day."), chips(list)]
        }
        let when = day.map { " on \($0.weekdayName)" } ?? ""
        var blocks: [AssistantBlock] = [.text(refs.count == 1 ? "1 thing in your schedule\(when)." : "\(refs.count) things in your schedule\(when).")]
        if !refs.isEmpty { blocks.append(.list(ids: refs, title: MyScheduleTitle.title)) }
        if !saved.isEmpty { blocks.append(.list(ids: saved, title: "Saved Places")) }
        var list: [AssistantChip] = []
        if ctx.canPlan { list.append(AssistantChip(label: "Plan my day", action: .planMake("Plan my day"))) }
        return blocks + [chips(list)]
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
        // "remove X" / "add X" are My schedule commands (scheduleCommand), which the plan follows.
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
        // References to what the conversation showed come first ("it", "the second one").
        if let refs = ctx.memory.resolve(phrase, kinds: kinds, ctx.bundle) {
            return refs.count == 1 ? .found(refs[0]) : .ambiguous(Array(refs.prefix(5)))
        }
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

    static let calendarText = "Attnd doesn't add things to your calendar."

    // MARK: Likes

    /// "like X" / "unlike X" (older words): add to / remove from My schedule.
    private static func like(_ phrase: String, liked: Bool, _ ctx: RouterContext) -> RoutedTurn {
        withScheduleEntity(phrase, [.schedule, .location], ctx, preferScheduled: !liked) { refs in
            liked ? add(refs[0], time: nil, ctx) : remove(refs, ctx)
        }
    }

    private static func likedBlocks(_ ctx: RouterContext) -> [AssistantBlock] {
        let refs = AssistantSearch.liked(ctx.bundle, ctx.likes, now: ctx.now).compactMap { EntityRef.of($0) }
        if refs.isEmpty { return [.text("Your schedule is empty."), .chips(suggestionChips(ctx))] }
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

    /// "Add to my schedule" / "Remove from my schedule" (was Like / Unlike).
    private static func likeChip(_ ref: EntityRef, _ ctx: RouterContext) -> AssistantChip {
        let added = ctx.mine.contains(target(ref))
        return added
            ? AssistantChip(label: "Remove from my schedule", action: .scheduleRemove(ref))
            : AssistantChip(label: "Add to my schedule", action: .scheduleAdd(ref))
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
        case .mySchedule:
            blocks = myScheduleBlocks(action.string("day").flatMap(PlanDate.parse), ctx)
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
