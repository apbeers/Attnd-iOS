// EventAssistant.swift
// Attnd (app + App Clip)
//
// "Ask about this event": Apple's on-device foundation model (Foundation Models framework)
// answers a question with tool calling over the joined event's local bundle. Nothing leaves
// the device. The tools are the app's own local search (EventSearch), now / next, location
// details and the organizer's latest updates; every item a tool returns carries an id like
// [s12], the model lists the ids it used, and the answer shows those items so the attendee
// can jump to them (falling back to the items the tools returned).
//
// It also reads plan requests into the planner's preferences (`planPreferences`, spec §6).
//
// Used by the search sheet (EventSearchView) and the plan page (AssistantController). When the
// model is unavailable (device not eligible, Apple Intelligence off, model not downloaded)
// `isAvailable` is false and callers show plain search results instead.
//
// iOS 27: `GenerationOptions.toolCallingMode` = `.required` makes the model look things up
// before it answers (iOS 26 has no such option and relies on the instructions).

import Foundation
import FoundationModels

enum EventAssistant {

    /// Whether the on-device model can answer right now.
    static var isAvailable: Bool {
        SystemLanguageModel.default.isAvailable
    }

    /// Answers `question` from the event's own content. Throws when the model fails or refuses.
    static func answer(_ question: String, bundle: EventBundle, now: Date) async throws -> EventAssistantAnswer {
        let index = EventSearchIndex(bundle)
        let recorder = SourceRecorder()
        let context = AssistantContext(index: index, bundle: bundle, now: now, recorder: recorder)
        let event = bundle.event
        let today = EventSearch.dayTimeRange(start: now, end: nil, timeZone: event.timeZone)
        let session = LanguageModelSession(
            tools: [
                SearchEventTool(context: context),
                WhatsOnTool(context: context),
                LocationDetailsTool(context: context),
                LatestUpdatesTool(context: context),
                EventInfoTool(bundle: bundle),
            ]
        ) {
            """
            You help an attendee of the event "\(event.name)" using the Attnd app. Answer questions \
            about this event only, using only facts returned by the tools; look things up before \
            answering. It is now \(today) in the event's time zone, and all times are in that zone.
            Every item a tool returns starts with an id in square brackets, such as [s12] or [l3]. \
            Put the ids of the items your answer relies on in `sources`.
            If the tools find nothing that answers the question, say that you couldn't find it in \
            the event's information. Answer in one to three short, friendly sentences.
            """
        }
        var options = GenerationOptions()
        options.temperature = 0.3
        #if IOS27_SDK
        if #available(iOS 27.0, *) {
            options.toolCallingMode = .required
        }
        #endif
        let started = ContinuousClock.now
        let response: LanguageModelSession.Response<AssistantReply>
        do {
            response = try await session.respond(generating: AssistantReply.self, options: options) {
                question
            }
        } catch {
            let ms = (ContinuousClock.now - started).wholeMilliseconds
            let ns = error as NSError
            AppLog.warning(.assistant, "assistant.error", "Ask failed after \(ms) ms", [
                "kind": "ask", "error": .string(String(describing: type(of: error))), "domain": .string(ns.domain), "code": .int(ns.code),
            ])
            AppLog.info(.assistant, "assistant.request", "Ask failed after \(ms) ms",
                        LogRedaction.textFields(question).merging(["kind": "ask", "name": "ask", "ms": .int(ms), "ok": false]) { _, new in new })
            throw error
        }
        let reply = response.content
        let looked = await recorder.targets
        var sources: [SearchTarget] = []
        for target in reply.sources.compactMap(SearchTarget.init(reference:))
        where index.result(for: target, now: now) != nil && !sources.contains(target) {
            sources.append(target)
        }
        if sources.isEmpty {
            // The model named nothing (or ids that don't exist): show what it looked at.
            sources = Array(looked.prefix(3))
        }
        let ms = (ContinuousClock.now - started).wholeMilliseconds
        AppLog.debug(.assistant, "assistant.answer", "Answered in \(ms) ms", [
            "ms": .int(ms), "citations": .int(reply.sources.count), "tool_calls": .int(looked.count),
            "fallback": .bool(sources.isEmpty || reply.sources.isEmpty),
        ])
        AppLog.info(.assistant, "assistant.request", "Ask answered in \(ms) ms", LogRedaction.textFields(question).merging([
            "kind": "ask", "name": "ask", "ms": .int(ms), "ok": true, "results": .int(sources.count),
        ]) { _, new in new })
        return EventAssistantAnswer(text: reply.text, sources: Array(sources.prefix(6)))
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

// MARK: - Structured reply

@Generable(description: "An answer about the event and the items it is based on.")
struct AssistantReply {
    @Guide(description: "The answer: one to three short sentences, using only facts the tools returned.")
    var text: String

    @Guide(description: "Ids from the tool results that the answer uses, such as s12, l3 or n5.")
    var sources: [String]
}

// MARK: - Tools

/// What the tools share: the bundle, its search index, the moment of the question, and a
/// record of every item they returned.
struct AssistantContext: Sendable {
    let index: EventSearchIndex
    let bundle: EventBundle
    let now: Date
    let recorder: SourceRecorder

    /// One line per item for the model: "[s12] Schedule item: Taco Tasting · Sat 3:00 – 4:00 PM · Food Court (Next) — …".
    func describe(_ target: SearchTarget) -> String? {
        guard let result = index.result(for: target, now: now) else { return nil }
        var line = "[\(target.reference)] \(result.kind.title): \(result.title)"
        if !result.subtitle.isEmpty { line += " · \(result.subtitle)" }
        if let label = result.timeLabel { line += " (\(label.rawValue))" }
        let details: String
        switch target {
        case .scheduleItem(let id):
            let item = bundle.schedule.first { $0.id == id }
            details = ([item?.description ?? ""] + EventAssistant.contextFacts(item?.context)).filter { !$0.isEmpty }.joined(separator: ". ")
        case .location(let id):
            let location = bundle.locations.first { $0.id == id }
            details = ([location?.address ?? "", location?.description ?? ""] + EventAssistant.contextFacts(location?.context))
                .filter { !$0.isEmpty }.joined(separator: ". ")
        case .notification(let id):
            details = bundle.notifications.first { $0.id == id }?.body ?? ""
        case .event:
            details = [bundle.event.address, bundle.event.description].filter { !$0.isEmpty }.joined(separator: ". ")
        }
        if !details.isEmpty { line += " — \(EventSearch.excerpt(details, limit: 360))" }
        return line
    }

    /// Describes `targets` (recording them as looked at), or says nothing matched.
    func report(_ targets: [SearchTarget], empty: String) async -> String {
        let lines = targets.compactMap(describe)
        guard !lines.isEmpty else { return empty }
        await recorder.add(targets)
        return lines.joined(separator: "\n")
    }
}

/// The items the tools returned, in order (for citations).
actor SourceRecorder {
    private(set) var targets: [SearchTarget] = []

    func add(_ new: [SearchTarget]) {
        for target in new where !targets.contains(target) {
            targets.append(target)
        }
    }
}

struct SearchEventTool: Tool {
    let name = "searchEvent"
    let description = """
        Searches the event's schedule, locations, organizer updates and event details by keywords. \
        Time words filter the schedule: now, next, today, tonight, tomorrow, a weekday, or a time like 7pm.
        """

    @Generable
    struct Arguments {
        @Guide(description: "A few keywords, for example \"tacos\", \"main stage\" or \"music tonight\".")
        var query: String
    }

    let context: AssistantContext

    func call(arguments: Arguments) async throws -> String {
        let index = context.index
        var results = index.search(arguments.query, now: context.now)
        if results.isEmpty {
            results = index.search(EventSearch.keywords(fromQuestion: arguments.query), now: context.now)
        }
        return await context.report(results.prefix(8).map(\.target), empty: "Nothing in the event matches \"\(arguments.query)\".")
    }
}

struct WhatsOnTool: Tool {
    let name = "whatsOn"
    let description = "Lists schedule items happening now and those starting within the next two hours."

    @Generable
    struct Arguments {
        @Guide(description: "\"now\" for items in progress, \"next\" for items starting soon, or \"both\".")
        var which: String
    }

    let context: AssistantContext

    func call(arguments: Arguments) async throws -> String {
        let which = EventSearch.fold(arguments.which)
        var targets: [SearchTarget] = []
        if which != "next" {
            targets += context.index.search("now", now: context.now).prefix(8).map(\.target)
        }
        if which != "now" {
            targets += context.index.search("next", now: context.now).prefix(8).map(\.target)
        }
        return await context.report(targets, empty: "Nothing is happening now or starting in the next two hours.")
    }
}

struct LocationDetailsTool: Tool {
    let name = "locationDetails"
    let description = "Finds a location of the event by name and returns its address, description, hours, menu, accessibility, age limit and what is scheduled there."

    @Generable
    struct Arguments {
        @Guide(description: "The location's name or part of it, for example \"main stage\" or \"restrooms\".")
        var name: String
    }

    let context: AssistantContext

    func call(arguments: Arguments) async throws -> String {
        let locations = context.index.search(arguments.name, now: context.now)
            .filter { $0.kind == .location }
            .prefix(3)
            .map(\.target)
        var targets: [SearchTarget] = []
        for target in locations {
            targets.append(target)
            guard case .location(let id) = target else { continue }
            let items = context.bundle.schedule
                .filter { $0.locationId == id && !ScheduleTiming.hasEnded($0, at: context.now) }
                .prefix(4)
                .map { SearchTarget.scheduleItem($0.id) }
            targets += items
        }
        return await context.report(targets, empty: "No location called \"\(arguments.name)\".")
    }
}

struct LatestUpdatesTool: Tool {
    let name = "latestUpdates"
    let description = "Returns the organizer's most recent announcements for the event, newest first."

    @Generable
    struct Arguments {
        @Guide(description: "How many updates to return, from 1 to 5.")
        var count: Int
    }

    let context: AssistantContext

    func call(arguments: Arguments) async throws -> String {
        let count = min(max(arguments.count, 1), 5)
        let targets = context.bundle.notifications.prefix(count).map { SearchTarget.notification($0.id) }
        return await context.report(targets, empty: "The organizer hasn't posted any updates.")
    }
}

// MARK: - Rich context (API-018)

extension EventAssistant {
    /// A schedule item's context as short facts: about, performers with genres and bios, price,
    /// age limit, accessibility.
    static func contextFacts(_ context: ScheduleItemContext?) -> [String] {
        guard let context else { return [] }
        var facts: [String] = []
        if !context.about.isEmpty { facts.append(context.about) }
        for performer in context.performers.prefix(3) {
            var fact = "Performer: \(performer.name)"
            if !performer.genres.isEmpty { fact += " (\(performer.genres.prefix(3).joined(separator: ", ")))" }
            if !performer.bio.isEmpty { fact += " — " + String(performer.bio.prefix(120)) }
            facts.append(fact)
        }
        if !context.price.isEmpty { facts.append("Price: \(context.price)") }
        if !context.ageLimit.isEmpty { facts.append("Age: \(context.ageLimit)") }
        if !context.accessibility.isEmpty { facts.append("Accessibility: \(context.accessibility)") }
        return facts
    }

    /// A location's context as short facts: about, hours, menu (≤ 6 lines), accessibility, age.
    static func contextFacts(_ context: LocationContext?) -> [String] {
        guard let context else { return [] }
        var facts: [String] = []
        if !context.about.isEmpty { facts.append(context.about) }
        if !context.hours.isEmpty { facts.append("Hours: \(context.hours)") }
        if !context.menu.isEmpty {
            facts.append("Menu: " + context.menu.prefix(6).map { entry in
                [entry.name, entry.price, entry.note].filter { !$0.isEmpty }.joined(separator: " ")
            }.joined(separator: "; "))
        }
        if !context.accessibility.isEmpty { facts.append("Accessibility: \(context.accessibility)") }
        if !context.ageLimit.isEmpty { facts.append("Age: \(context.ageLimit)") }
        return facts
    }

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
