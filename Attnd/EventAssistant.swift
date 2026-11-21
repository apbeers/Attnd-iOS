// EventAssistant.swift
// Attnd (app + App Clip)
//
// Apple's on-device foundation model (Foundation Models framework) for the plan page: the
// event assistant's turns (`assistantTurn`: streamed block JSON, with the `lookup` and
// `eventInfo` tools over the joined event's local bundle), the planner's preferences
// (`planPreferences`, spec §6). Nothing leaves the device.
//
// Used only where the model is available (`isAvailable`; AppState.modelReady): without it
// the app has no plan page and shows the plain search sheet.

import Foundation
import FoundationModels

enum EventAssistant {

    /// Whether the on-device model can answer right now.
    static var isAvailable: Bool {
        SystemLanguageModel.default.isAvailable
    }
}

// MARK: - Assistant turns (tool calling, iOS Nov 21, 2026)

/// What one model turn produced: the answer text, what `show` asked to display, the writes the
/// tools validated (run by the caller through the ActionDispatcher), and how it went.
struct ModelTurnOutput: Sendable {
    var text: String
    var shown: [AssistantBlock]
    var actions: [AssistantAction]
    var toolCalls: Int
    var trimmed: [String]
    var newSession: Bool
}

extension EventAssistant {
    /// One event-assistant turn on the conversation's session (kept across turns, rebuilt for
    /// another event, when the next prompt wouldn't fit the 4096-token window, or after the
    /// window overflowed once). The model writes the answer text and calls tools: reads (`find`,
    /// `event_info`, `my_schedule`, `now_next`), writes (`add_to_schedule`, `remove_from_schedule`,
    /// `move_entry`, `set_reminder`, `plan_day`; validated, run afterwards through the
    /// ActionDispatcher) and `show` (components to display). A bad tool call gets an error back
    /// and the model may retry; it never discards the answer. Throws when the model fails (the
    /// caller answers with the router and logs it).
    @MainActor
    static func assistantTurn(
        _ input: String,
        _ ctx: RouterContext,
        conversation: AssistantConversation,
        retrieved: [AssistantSearch.Result],
        onPartial: @escaping @MainActor @Sendable (String, [AssistantBlock], String?) -> Void
    ) async throws -> ModelTurnOutput {
        let store = AssistantSessionStore.shared
        let started = ContinuousClock.now
        var fresh = store.prepare(eventId: ctx.bundle.event.id)
        func prompt() -> BudgetedPrompt {
            let limit = fresh ? TokenBudget.freshPrompt : max(0, TokenBudget.window - TokenBudget.fixed - TokenBudget.reply - store.used)
            return AssistantModel.toolPrompt(input, ctx, conversation, retrieved, freshSession: fresh, limit: limit)
        }
        var budgeted = prompt()
        if !fresh && (!TokenBudget.fits(used: store.used, prompt: budgeted.tokens) || !budgeted.trimmed.isEmpty) {
            store.reset()
            fresh = true
            budgeted = prompt()
        }
        if !budgeted.trimmed.isEmpty {
            AppLog.debug(.assistant, "assistant.answer", "Prompt trimmed to fit", ["trimmed": .string(budgeted.trimmed.joined(separator: ",")), "tokens": .int(budgeted.tokens)])
        }
        await store.hub.begin(ctx)
        var text = ""
        do {
            text = try await stream(budgeted.text, store: store, onPartial: onPartial)
        } catch let error where String(describing: error).contains("exceededContextWindowSize") {
            // The window overflowed (the estimate was low): once more in a new session, cut harder.
            AppLog.notice(.assistant, "assistant.error", "Context window exceeded; new session", ["kind": "context_window"])
            store.reset()
            fresh = true
            budgeted = AssistantModel.toolPrompt(input, ctx, conversation, retrieved, freshSession: true, limit: TokenBudget.freshPrompt / 2)
            await store.hub.begin(ctx)
            do {
                text = try await stream(budgeted.text, store: store, onPartial: onPartial)
            } catch {
                store.reset()
                throw error
            }
        } catch {
            // A cancelled or failed turn may leave the session mid-response: the next turn starts a new one.
            store.reset()
            throw error
        }
        let result = await store.hub.finish()
        store.used += budgeted.tokens + TokenBudget.estimate(text) + result.toolTokens + 40
        AppLog.debug(.assistant, "assistant.answer", "Assistant turn written in \((ContinuousClock.now - started).wholeMilliseconds) ms", [
            "ms": .int((ContinuousClock.now - started).wholeMilliseconds), "citations": 0, "tool_calls": .int(result.calls), "fallback": false,
        ])
        return ModelTurnOutput(text: text, shown: result.shown, actions: result.actions, toolCalls: result.calls,
                               trimmed: budgeted.trimmed, newSession: fresh)
    }

    @MainActor
    private static func stream(_ prompt: String, store: AssistantSessionStore,
                               onPartial: @escaping @MainActor @Sendable (String, [AssistantBlock], String?) -> Void) async throws -> String {
        let session = store.session()
        var options = GenerationOptions()
        options.temperature = 0.2
        var raw = ""
        let stream = session.streamResponse(to: prompt, options: options)
        for try await snapshot in stream {
            try Task.checkCancellation()
            raw = snapshot.content
            let shown = await store.hub.shownSoFar()
            let stage = await store.hub.currentStage()
            onPartial(raw, shown, stage)
        }
        return raw
    }
}

/// The conversation's model session (one at a time; per event).
@MainActor
final class AssistantSessionStore {
    static let shared = AssistantSessionStore()

    let hub = AssistantToolHub()
    private var current: LanguageModelSession?
    private var eventId: Int?
    /// Estimated tokens the session's transcript already holds.
    var used = 0

    /// Keeps the session for the same event; true when the next turn starts a fresh one.
    func prepare(eventId: Int) -> Bool {
        if self.eventId != eventId { reset() }
        self.eventId = eventId
        return current == nil
    }

    func reset() {
        current = nil
        used = 0
    }

    func session() -> LanguageModelSession {
        if let current { return current }
        let hub = self.hub
        let session = LanguageModelSession(tools: [
            FindTool(hub: hub), EventInfoTool(hub: hub), MyScheduleTool(hub: hub), NowNextTool(hub: hub),
            AddToScheduleTool(hub: hub), RemoveFromScheduleTool(hub: hub), MoveEntryTool(hub: hub),
            SetReminderTool(hub: hub), ShowTool(hub: hub), PlanDayTool(hub: hub),
        ]) {
            """
            You are the on-device assistant of the Attnd event app. Answer in one or two short, \
            friendly sentences in the attendee's language. Use only facts from the prompt and the \
            tools; never invent places, times or ids. Ids look like s12 (schedule item), l3 (place), \
            u9 (update). "It", "that" and "the second one" mean the SHOWN entries. To change the \
            attendee's schedule call add_to_schedule, remove_from_schedule, move_entry or \
            set_reminder; plan_day makes a plan. Every answer that names a schedule item or a place \
            MUST call show with their ids (card for one, carousel for several, now_next for what's \
            on, timeline for a sequence of times). When you show something, write ONE short sentence \
            (at most 15 words) and never list in text what a component shows. Never write ids such \
            as s12 or l3 in the text, and no filler like "Anything else?". \
            "Music, food, then more music" or "X then Y" is a plan: call plan_day. \
            "My plan", "itinerary" and "agenda" mean My schedule. If a tool returns an error, fix \
            the call and try once more.
            """
        }
        current = session
        return session
    }
}

/// What the tools of one turn see and record (the bundle, My schedule, the memory; the writes,
/// the components shown, errors per tool).
actor AssistantToolHub {
    private var ctx: RouterContext?
    private var actions: [AssistantAction] = []
    private var shown: [AssistantBlock] = []
    private var errors: [String: Int] = [:]
    private var calls = 0
    private var toolTokens = 0
    private var stage: String?

    /// The working line's stage: what the last tool call is doing.
    func currentStage() -> String? { stage }

    func begin(_ ctx: RouterContext) {
        stage = nil
        self.ctx = ctx
        actions = []
        shown = []
        errors = [:]
        calls = 0
        toolTokens = 0
    }

    func finish() -> (actions: [AssistantAction], shown: [AssistantBlock], calls: Int, toolTokens: Int) {
        (actions, shown, calls, toolTokens)
    }

    func shownSoFar() -> [AssistantBlock] { shown }

    private func answer(_ text: String) -> String {
        toolTokens += TokenBudget.estimate(text)
        return text
    }

    /// Reads: lines in the prompt's ITEMS format.
    func read(_ tool: String, _ argument: String) -> String {
        calls += 1
        guard let ctx else { return answer("No event.") }
        let bundle = ctx.bundle
        switch tool {
        case "find": stage = "Searching…"
        case "event_info": stage = "Reading the event info…"
        case "my_schedule": stage = "Checking your schedule…"
        default: stage = "Checking what's on…"
        }
        switch tool {
        case "find":
            var results = AssistantSearch.search(bundle, argument, now: ctx.now, limit: 8)
            if results.isEmpty {
                results = AssistantSearch.search(bundle, AssistantSearch.keywords(argument), now: ctx.now, mode: .anyToken, limit: 8)
            }
            let lines = results.compactMap { result -> String? in
                guard let ref = EntityRef.of(result) else { return nil }
                let detail = AssistantSearch.detail(result, bundle, locale: ctx.locale)
                let extra = AssistantModel.contextLine(ref, bundle).map { " — \($0)" } ?? ""
                return "[\(ref.code)] \(result.title)" + (detail.isEmpty ? "" : " — \(detail)") + extra
            }
            return answer(lines.isEmpty ? "Nothing in the event matches \"\(argument)\"." : lines.joined(separator: "\n"))
        case "event_info":
            return answer(EventAssistant.eventFacts(bundle, topic: argument))
        case "my_schedule":
            let day = PlanDate.parse(argument.trimmingCharacters(in: .whitespaces))
            let rows = day.map { ctx.schedule.rows(on: $0, bundle, now: ctx.now) } ?? ctx.schedule.rows(bundle, now: ctx.now).filter { !$0.ended }
            let zone = bundle.event.timeZone
            let lines = rows.map { row in
                "[\(row.entry.kind == .item ? "s" : "l")\(row.entry.id)] \(row.name) — \(AssistantText.format(row.start, "EEE h:mm a", zone, ctx.locale))"
                    + (row.entry.reminderMinutes == 0 ? " — no reminder" : " — reminder \(row.entry.reminderMinutes) min before")
            }
            return answer(lines.isEmpty ? "My schedule is empty." : lines.joined(separator: "\n"))
        case "now_next":
            let place = EntityRef.parse(argument).flatMap { $0.kind == .location ? $0.id : nil }
            let items = bundle.schedule.filter { place == nil || $0.locationId == place }
                .filter { !ScheduleTiming.hasEnded($0, at: ctx.now) && $0.startTime != nil }
                .stableSorted(by: Planner.itemOrder).prefix(6)
            let zone = bundle.event.timeZone
            let lines = items.map { item in
                let state = ScheduleTiming.isHappening(item, at: ctx.now) ? "now" : AssistantText.format(item.startTime ?? ctx.now, "h:mm a", zone, ctx.locale)
                return "[s\(item.id)] \(item.name) — \(state)" + (bundle.location(item.locationId).map { " — [l\($0.id)] \($0.name)" } ?? "")
            }
            return answer(lines.isEmpty ? "Nothing is on now or next." : lines.joined(separator: "\n"))
        default:
            return answer("Unknown tool.")
        }
    }

    /// Writes: validated now (an error goes back to the model), run after the turn.
    func write(_ name: ActionName, _ params: JSONObject) -> String {
        calls += 1
        guard let ctx else { return answer("No event.") }
        if errors[name.key, default: 0] >= 2 { return answer("Error: stop calling \(name.key) for this request; answer in words.") }
        switch AssistantModel.toolAction(name, params, ctx) {
        case .success(let action):
            actions.append(action)
            let target = action.scheduleTarget().flatMap { $0.name(ctx.bundle) } ?? "it"
            switch name {
            case .scheduleAdd: stage = "Adding \(target)…"
            case .scheduleRemove: stage = "Removing \(target)…"
            case .scheduleMove: stage = "Moving \(target)…"
            default: stage = "Setting a reminder for \(target)…"
            }
            return answer("Done: \(name.key) \(target). The app shows the result with Undo.")
        case .failure(let error):
            errors[name.key, default: 0] += 1
            return answer(error.message)
        }
    }

    func show(_ type: String, _ ids: [String], _ title: String) -> String {
        calls += 1
        guard let ctx else { return answer("No event.") }
        guard let block = AssistantModel.showBlock(type, ids: ids, title: title, ctx) else {
            errors["show", default: 0] += 1
            return answer("Error: can't show \(type) with those ids. Components: \(AssistantModel.showTypes).")
        }
        if shown.count < BlockValidator.maxBlocks - 1 { shown.append(block) }
        stage = "Showing \(ComponentCatalogue.canonical(type).replacingOccurrences(of: "_", with: " "))…"
        return answer("Shown.")
    }

    func plan(_ request: String) -> String {
        calls += 1
        let trimmed = request.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return answer("Error: say what the plan is about.") }
        actions.append(.planMake(trimmed))
        stage = "Planning your day…"
        return answer("Planning now; the plan appears as a preview in the app.")
    }
}

// MARK: Tools

struct FindTool: Tool {
    let name = "find"
    let description = "Searches the event's schedule, places (menus, performers, amenities, tags) and updates. Time words filter the schedule: now, next, tonight, tomorrow, a weekday, 7pm."
    @Generable struct Arguments {
        @Guide(description: "A few keywords, e.g. \"tacos\", \"main stage\", \"music tonight\".")
        var query: String
    }
    let hub: AssistantToolHub
    func call(arguments: Arguments) async throws -> String { await hub.read("find", arguments.query) }
}

struct EventInfoTool: Tool {
    let name = "event_info"
    let description = "The event's own information: about, FAQ, amenities (restrooms, water, ATMs, first aid, charging, with their place), accessibility, policies, getting there, the weather plan."
    @Generable struct Arguments {
        @Guide(description: "\"faq\", \"amenities\", \"restrooms\", \"accessibility\", \"policies\", \"getting there\", \"weather\" or \"all\".")
        var topic: String
    }
    let hub: AssistantToolHub
    func call(arguments: Arguments) async throws -> String { await hub.read("event_info", arguments.topic) }
}

struct MyScheduleTool: Tool {
    let name = "my_schedule"
    let description = "What is in the attendee's schedule (items and places with times and reminders)."
    @Generable struct Arguments {
        @Guide(description: "A day as YYYY-MM-DD, or an empty string for everything still ahead.")
        var day: String
    }
    let hub: AssistantToolHub
    func call(arguments: Arguments) async throws -> String { await hub.read("my_schedule", arguments.day) }
}

struct NowNextTool: Tool {
    let name = "now_next"
    let description = "What is on now and next, at one place or everywhere."
    @Generable struct Arguments {
        @Guide(description: "A place id like \"l3\", or an empty string for everywhere.")
        var place: String
    }
    let hub: AssistantToolHub
    func call(arguments: Arguments) async throws -> String { await hub.read("now_next", arguments.place) }
}

struct AddToScheduleTool: Tool {
    let name = "add_to_schedule"
    let description = "Adds a schedule item (s12) or a place (l3) to the attendee's schedule. Places take a time; without one they are saved."
    @Generable struct Arguments {
        @Guide(description: "The id, e.g. \"s12\" or \"l3\".")
        var target: String
        @Guide(description: "For places: the time as HH:MM (24-hour), or an empty string.")
        var time: String
    }
    let hub: AssistantToolHub
    func call(arguments: Arguments) async throws -> String {
        var params: JSONObject = ["target": .string(arguments.target)]
        if !arguments.time.trimmingCharacters(in: .whitespaces).isEmpty { params["time"] = .string(arguments.time) }
        return await hub.write(.scheduleAdd, params)
    }
}

struct RemoveFromScheduleTool: Tool {
    let name = "remove_from_schedule"
    let description = "Removes an item or place from the attendee's schedule."
    @Generable struct Arguments {
        @Guide(description: "The id, e.g. \"s12\" or \"l3\".")
        var target: String
    }
    let hub: AssistantToolHub
    func call(arguments: Arguments) async throws -> String { await hub.write(.scheduleRemove, ["target": .string(arguments.target)]) }
}

struct MoveEntryTool: Tool {
    let name = "move_entry"
    let description = "Moves a place in the attendee's schedule to another time (schedule items have the organizer's time)."
    @Generable struct Arguments {
        @Guide(description: "The place id, e.g. \"l3\".")
        var target: String
        @Guide(description: "The new time as HH:MM (24-hour).")
        var time: String
    }
    let hub: AssistantToolHub
    func call(arguments: Arguments) async throws -> String {
        await hub.write(.scheduleMove, ["target": .string(arguments.target), "time": .string(arguments.time)])
    }
}

struct SetReminderTool: Tool {
    let name = "set_reminder"
    let description = "Sets how long before an entry of the attendee's schedule the reminder comes: 5, 10, 15, 30 or 60 minutes, or 0 for none."
    @Generable struct Arguments {
        @Guide(description: "The id, e.g. \"s12\" or \"l3\".")
        var target: String
        @Guide(description: "Minutes before: 5, 10, 15, 30, 60, or 0 for no reminder.")
        var minutes: Int
    }
    let hub: AssistantToolHub
    func call(arguments: Arguments) async throws -> String {
        await hub.write(.scheduleReminder, ["target": .string(arguments.target), "minutes": .int(arguments.minutes)])
    }
}

struct ShowTool: Tool {
    let name = "show"
    let description = "Shows a component under the answer: card, carousel, list, map, timeline, now_next, countdown, gallery, or a screen part such as menu (a place), performers (an item), hours, faq, amenities, getting_there, accessibility, policies, weather_plan, my_schedule, whats_on, places, updates, urgent, website, flyer."
    @Generable struct Arguments {
        @Guide(description: "The component type, e.g. \"carousel\", \"menu\" or \"faq\".")
        var component: String
        @Guide(description: "Ids it shows, e.g. [\"l3\"]; empty for event-wide parts like faq.")
        var ids: [String]
        @Guide(description: "A short title, or an empty string.")
        var title: String
    }
    let hub: AssistantToolHub
    func call(arguments: Arguments) async throws -> String { await hub.show(arguments.component, arguments.ids, arguments.title) }
}

struct PlanDayTool: Tool {
    let name = "plan_day"
    let description = "Plans the attendee's day (or a part of it) into their schedule from a request like \"Saturday around country music\"."
    @Generable struct Arguments {
        @Guide(description: "The request in a few words.")
        var request: String
    }
    let hub: AssistantToolHub
    func call(arguments: Arguments) async throws -> String { await hub.plan(arguments.request) }
}

// MARK: - Planner preferences (spec §6)

extension EventAssistant {
    /// The planner's preferences for `request`, read by the on-device model as structured output
    /// (`PlanPreferencesReply`) and validated against the bundle (`PlanRequest.validate`: unknown
    /// tags, categories, ids and days dropped). The scheduling itself is plain code (Planner).
    /// Throws when the model is unavailable or fails; callers then use `PlanRequest.heuristic`.
    static func planPreferences(
        _ request: String,
        bundle: EventBundle,
        heartedItems: Set<Int>,
        now: Date
    ) async throws -> PlanPreferences {
        let session = LanguageModelSession {
            """
            You read an attendee's request for a plan of the event "\(bundle.event.name)" and fill in \
            their preferences. Use only tags from TAGS, categories from CATEGORIES, item numbers from \
            ITEMS and dates from DAYS. Leave a field empty when the request doesn't say.
            """
        }
        var options = GenerationOptions()
        options.temperature = 0
        let prompt = PlanRequest.prompt(bundle, request: request, heartedItems: heartedItems, now: now)
        let response = try await session.respond(generating: PlanPreferencesReply.self, options: options) {
            prompt
        }
        let reply = response.content
        var raw = PlanModelReply()
        raw.likedTags = reply.likedTags
        raw.dislikedTags = reply.dislikedTags
        raw.likedCategories = reply.likedCategories
        raw.dislikedCategories = reply.dislikedCategories
        raw.similarTo = reply.similarTo.map(String.init)
        raw.days = reply.days
        raw.earliest = reply.earliest
        raw.latest = reply.latest
        raw.hours = reply.hours
        raw.pace = reply.pace
        raw.includeMeals = reply.includeMeals
        raw.kidFriendly = reply.kidFriendly
        return PlanRequest.validate(raw, bundle: bundle, now: now)
    }
}

/// What the attendee wants from a plan, as the model reads the request (the fields of the
/// prompt's JSON form). Empty strings / 0 mean "not said".
@Generable(description: "An attendee's preferences for a plan of the event.")
struct PlanPreferencesReply {
    @Guide(description: "liked_tags: tags from TAGS the request asks for, lower case.")
    var likedTags: [String]

    @Guide(description: "disliked_tags: tags from TAGS the request wants to avoid, lower case.")
    var dislikedTags: [String]

    @Guide(description: "liked_categories: categories from CATEGORIES the request asks for.")
    var likedCategories: [String]

    @Guide(description: "disliked_categories: categories from CATEGORIES the request wants to avoid.")
    var dislikedCategories: [String]

    @Guide(description: "similar_to: the numbers of ITEMS the request names or wants more of.")
    var similarTo: [Int]

    @Guide(description: "days: dates from DAYS the request asks for, as YYYY-MM-DD; empty when it names none.")
    var days: [String]

    @Guide(description: "earliest: the earliest time as HH:MM (24-hour), or an empty string.")
    var earliest: String

    @Guide(description: "latest: the latest time as HH:MM (24-hour), or an empty string.")
    var latest: String

    @Guide(description: "hours: how many hours the attendee has, or 0 when the request doesn't say.")
    var hours: Double

    @Guide(description: "pace: relaxed, balanced or packed.")
    var pace: String

    @Guide(description: "include_meals: true when the request mentions lunch, dinner or food breaks.")
    var includeMeals: Bool

    @Guide(description: "kid_friendly: true for kids or family.")
    var kidFriendly: Bool
}

// MARK: - Event facts (API-018)

extension EventAssistant {
    /// The event's own facts for the `eventInfo` tool, ≤ ~1,600 characters: about, FAQ,
    /// amenities (with the location id they are at), accessibility, policies, getting there and the
    /// weather plan.
    static func eventFacts(_ bundle: EventBundle, topic: String) -> String {
        let context = bundle.event.context
        let want = EventSearch.fold(topic).trimmingCharacters(in: .whitespacesAndNewlines)
        func wanted(_ words: [String]) -> Bool { want.isEmpty || want == "all" || words.contains { want.contains($0) } }
        var lines: [String] = []
        if let about = context?.about, !about.isEmpty, wanted(["about", "event", "what"]) { lines.append("About: " + String(about.prefix(300))) }
        if let context {
            if !context.faq.isEmpty, wanted(["faq", "question", "bag", "pet", "entry", "rule", "ticket", "polic"]) {
                lines += context.faq.prefix(8).map { "Q: \($0.question) A: \(String($0.answer.prefix(200)))" }
            }
            if !context.amenities.isEmpty, wanted(["amenit", "restroom", "toilet", "water", "atm", "first aid", "charg", "locker", "parking", "shuttle", "food", "merch", "info", "access"]) {
                lines += context.amenities.prefix(12).map { amenity in
                    var line = "Amenity: \(amenity.kind.label) — \(amenity.name)"
                    if let location = bundle.location(amenity.locationId) { line += " at [l\(location.id)] \(location.name)" }
                    if !amenity.note.isEmpty { line += " (\(amenity.note))" }
                    return line
                }
            }
            if !context.accessibility.isEmpty, wanted(["access", "wheelchair", "step", "sensory"]) { lines.append("Accessibility: " + String(context.accessibility.prefix(300))) }
            if !context.policies.isEmpty, wanted(["polic", "rule", "bag", "allowed", "bring"]) { lines.append("Policies: " + String(context.policies.prefix(300))) }
            if !context.gettingThere.isEmpty, wanted(["getting", "there", "parking", "bus", "train", "shuttle", "drive", "transit"]) {
                lines.append("Getting there: " + String(context.gettingThere.prefix(300)))
            }
            if !context.weatherPlan.isEmpty, wanted(["weather", "rain", "storm", "heat"]) { lines.append("Weather plan: " + String(context.weatherPlan.prefix(200))) }
        }
        if lines.isEmpty {
            return want == "all" || context == nil
                ? "The organizer hasn't added venue information for this event."
                : eventFacts(bundle, topic: "all")
        }
        var text = ""
        for line in lines where text.count + line.count < 1_600 { text += (text.isEmpty ? "" : "\n") + line }
        return text
    }
}
