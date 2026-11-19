// EventAssistant.swift
// Attnd (app + App Clip)
//
// Apple's on-device foundation model (Foundation Models framework) for the plan page: the
// event assistant's turns (`assistantTurn`: streamed block JSON, with the `lookup` and
// `eventInfo` tools over the joined event's local bundle), the planner's preferences
// (`planPreferences`, spec §6) and the day summaries (`daySummary`). Nothing leaves the device.
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

// MARK: - Assistant turns (assistant spec §3)

extension EventAssistant {
    /// One event-assistant turn: the model reads `prompt` (`AssistantModel.prompt`: event facts,
    /// plan, likes, conversation, ≤ 12 retrieved items) and writes the block JSON
    /// (`{"blocks":[…],"actions":[…]}`), which `AssistantModel.parse` validates. It may look up
    /// more items with the `lookup` tool (lines in the prompt's ITEMS format). `onPartial` gets
    /// the text so far while it streams (the screen renders the blocks that are complete).
    /// Throws when the model is unavailable or fails; the caller then answers with the router.
    static func assistantTurn(
        _ prompt: String,
        bundle: EventBundle,
        now: Date,
        onPartial: @escaping @MainActor @Sendable (String) -> Void
    ) async throws -> (raw: String, toolCalls: Int) {
        let counter = ToolCallCounter()
        let session = LanguageModelSession(tools: [
            AssistantLookupTool(bundle: bundle, now: now, counter: counter),
            EventInfoTool(bundle: bundle, counter: counter),
        ]) {
            """
            You are the on-device assistant of the Attnd event app. You only choose how to answer: \
            reply with exactly one JSON object in the format the prompt describes, no other text. \
            Use only ids from ITEMS or from the lookup tool, never invent ids, times or facts; ask the \
            eventInfo tool about the venue, FAQ, amenities, policies, getting there or the weather plan. \
            Keep text short and friendly.
            """
        }
        var options = GenerationOptions()
        options.temperature = 0.2
        let started = ContinuousClock.now
        var raw = ""
        let stream = session.streamResponse(to: prompt, options: options)
        for try await snapshot in stream {
            try Task.checkCancellation()
            raw = snapshot.content
            await onPartial(raw)
        }
        let calls = await counter.count
        AppLog.debug(.assistant, "assistant.answer", "Assistant turn written in \((ContinuousClock.now - started).wholeMilliseconds) ms", [
            "ms": .int((ContinuousClock.now - started).wholeMilliseconds), "citations": 0, "tool_calls": .int(calls), "fallback": false,
        ])
        return (raw, calls)
    }
}

/// Counts the assistant's tool calls (`assistant.turn` `tool_calls`).
actor ToolCallCounter {
    private(set) var count = 0
    func add() { count += 1 }
}

/// The assistant's one tool: searches the event and returns lines like the prompt's ITEMS
/// ("[s12] Name — Sat 7:00–8:30 PM · Main Stage"), ids the block JSON may use.
struct AssistantLookupTool: Tool {
    let name = "lookup"
    let description = """
        Searches the event's schedule items, places and organizer updates by keywords. Time words \
        filter the schedule: now, next, tonight, tomorrow, a weekday or a time like 7pm.
        """

    @Generable
    struct Arguments {
        @Guide(description: "A few keywords, for example \"tacos\", \"main stage\" or \"music tonight\".")
        var query: String
    }

    let bundle: EventBundle
    let now: Date
    let counter: ToolCallCounter

    func call(arguments: Arguments) async throws -> String {
        await counter.add()
        var results = AssistantSearch.search(bundle, arguments.query, now: now, limit: 8)
        if results.isEmpty {
            results = AssistantSearch.search(bundle, AssistantSearch.keywords(arguments.query), now: now, mode: .anyToken, limit: 8)
        }
        let lines = results.compactMap { result -> String? in
            guard let ref = EntityRef.of(result) else { return nil }
            let detail = AssistantSearch.detail(result, bundle, locale: .current)
            let extra = AssistantModel.contextLine(ref, bundle).map { " — \($0)" } ?? ""
            return "[\(ref.code)] \(result.title)" + (detail.isEmpty ? "" : " — \(detail)") + extra
        }
        return lines.isEmpty ? "Nothing in the event matches \"\(arguments.query)\"." : lines.joined(separator: "\n")
    }
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

/// The event's own information: about, FAQ, amenities, accessibility, policies, getting there,
/// the weather plan (API-018).
struct EventInfoTool: Tool {
    let name = "eventInfo"
    let description = """
        Returns the event's own information: about, FAQ, amenities such as restrooms, water, ATMs, \
        first aid and charging (with the place they are at), accessibility, policies, getting there \
        and the weather plan (what happens in bad weather).
        """

    @Generable
    struct Arguments {
        @Guide(description: "What to look up: \"faq\", \"amenities\", \"restrooms\", \"accessibility\", \"policies\", \"getting there\", \"weather\" or \"all\".")
        var topic: String
    }

    let bundle: EventBundle
    var counter: ToolCallCounter? = nil

    func call(arguments: Arguments) async throws -> String {
        await counter?.add()
        return EventAssistant.eventFacts(bundle, topic: arguments.topic)
    }
}

// MARK: - Plan page day summary

/// The plan page's summary of one day: one line and a few sentences for "Read more".
@Generable(description: "A short summary of an attendee's planned day at an event.")
struct PlanDaySummaryReply {
    @Guide(description: "One friendly line of at most 90 characters, for example \"Country and blues all afternoon, then the headliners at 7\".")
    var line: String

    @Guide(description: "Two to four sentences about the day: highlights, walking, breaks and the weather plan if given. Use only facts from the prompt.")
    var more: String
}

extension EventAssistant {
    /// The day's summary from `PlanPage.summaryPrompt` (throws when the model fails).
    static func daySummary(_ prompt: String) async throws -> (line: String, more: String) {
        let session = LanguageModelSession {
            """
            You summarise an attendee's plan for one day of an event in the Attnd app. Use only the \
            facts in the prompt; never invent acts, times or places.
            """
        }
        var options = GenerationOptions()
        options.temperature = 0.3
        let response = try await session.respond(generating: PlanDaySummaryReply.self, options: options) {
            prompt
        }
        let line = response.content.line.trimmingCharacters(in: .whitespacesAndNewlines)
        let more = response.content.more.trimmingCharacters(in: .whitespacesAndNewlines)
        return (String(line.prefix(120)), String(more.prefix(600)))
    }
}
