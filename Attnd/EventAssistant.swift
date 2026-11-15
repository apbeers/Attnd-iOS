// EventAssistant.swift
// Attnd (app target only — not in the App Clip)
//
// "Ask about this event": Apple's on-device foundation model (Foundation Models framework)
// answers a question with tool calling over the joined event's local bundle. Nothing leaves
// the device. The tools are the app's own local search (EventSearch), now / next, location
// details and the organizer's latest updates; every item a tool returns carries an id like
// [s12], the model lists the ids it used, and the answer shows those items so the attendee
// can jump to them (falling back to the items the tools returned).
//
// Used by the search tab (EventSearchView) and Siri / Shortcuts (AskEventIntent). When the
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
        let response = try await session.respond(generating: AssistantReply.self, options: options) {
            question
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
        return EventAssistantAnswer(text: reply.text, sources: Array(sources.prefix(6)))
    }
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
            details = bundle.schedule.first { $0.id == id }?.description ?? ""
        case .location(let id):
            let location = bundle.locations.first { $0.id == id }
            details = [location?.address ?? "", location?.description ?? ""].filter { !$0.isEmpty }.joined(separator: ". ")
        case .notification(let id):
            details = bundle.notifications.first { $0.id == id }?.body ?? ""
        case .event:
            details = [bundle.event.address, bundle.event.description].filter { !$0.isEmpty }.joined(separator: ". ")
        }
        if !details.isEmpty { line += " — \(EventSearch.excerpt(details, limit: 240))" }
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
    let description = "Finds a location of the event by name and returns its address, description and what is scheduled there."

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
