// EventIntents.swift
// Attnd (app target only — not in the App Clip)
//
// Siri, Shortcuts and Spotlight actions for the joined event, answered from the app's local
// data (no server calls, no API change):
//   - Open intents (OpenIntent) for schedule items, locations, updates and the event; Spotlight
//     uses them for the indexed entities. They navigate with AppState.navigate(to:), which
//     also works when the item's tab is hidden.
//   - Answers without opening the app (dialog + snippet): what's happening now / next, when is
//     <item>, where is <location>, latest updates, and "ask about the event" (the on-device
//     model when available, else local search results).
//   - Search in the app, and App Shortcuts with natural phrases (AttndShortcuts).

import AppIntents
import SwiftUI

// MARK: - Open intents

struct OpenScheduleItemIntent: OpenIntent {
    static let title: LocalizedStringResource = "Open Schedule Item"
    static let supportedModes: IntentModes = .foreground

    @Parameter(title: "Schedule Item")
    var target: ScheduleItemEntity

    @MainActor
    func perform() async throws -> some IntentResult {
        await IntentBridge.navigate(to: .scheduleItem(target.id))
        return .result()
    }
}

struct OpenLocationIntent: OpenIntent {
    static let title: LocalizedStringResource = "Open Location"
    static let supportedModes: IntentModes = .foreground

    @Parameter(title: "Location")
    var target: LocationEntity

    @MainActor
    func perform() async throws -> some IntentResult {
        await IntentBridge.navigate(to: .location(target.id))
        return .result()
    }
}

struct OpenNotificationIntent: OpenIntent {
    static let title: LocalizedStringResource = "Open Event Update"
    static let supportedModes: IntentModes = .foreground

    @Parameter(title: "Update")
    var target: NotificationEntity

    @MainActor
    func perform() async throws -> some IntentResult {
        await IntentBridge.navigate(to: .notification(target.id))
        return .result()
    }
}

struct OpenEventIntent: OpenIntent {
    static let title: LocalizedStringResource = "Open Event"
    static let supportedModes: IntentModes = .foreground

    @Parameter(title: "Event")
    var target: EventEntity

    @MainActor
    func perform() async throws -> some IntentResult {
        await IntentBridge.navigate(to: .event(target.id))
        return .result()
    }
}

/// "Search Attnd for tacos": opens the search tab with the query.
struct SearchEventIntent: AppIntent {
    static let title: LocalizedStringResource = "Search Event"
    static let supportedModes: IntentModes = .foreground

    @Parameter(title: "Search For", requestValueDialog: "What are you looking for?")
    var query: String

    @MainActor
    func perform() async throws -> some IntentResult {
        await IntentBridge.showSearch(query)
        return .result()
    }
}

// MARK: - Answers (no need to open the app)

struct WhatsOnNowIntent: AppIntent {
    static let title: LocalizedStringResource = "What's Happening Now"
    static let supportedModes: IntentModes = .background

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ShowsSnippetView {
        guard let bundle = await IntentBridge.bundle() else {
            return .result(dialog: IntentAnswers.noEvent, view: EmptyView())
        }
        let now = Date.now
        let index = EventSearchIndex(bundle)
        let happening = index.search("now", now: now)
        let upcoming = index.search("next", now: now)
        var sentences: [String] = []
        if happening.isEmpty {
            sentences.append("Nothing is happening right now.")
        } else {
            sentences.append("Happening now: " + IntentAnswers.list(happening.prefix(3).map { IntentAnswers.nowPhrase($0, bundle: bundle) }) + ".")
        }
        if !upcoming.isEmpty {
            sentences.append("Up next: " + IntentAnswers.list(upcoming.prefix(2).map { IntentAnswers.nextPhrase($0, bundle: bundle) }) + ".")
        } else if happening.isEmpty {
            sentences.append("Nothing starts in the next two hours.")
        }
        let rows = Array((happening.prefix(4) + upcoming.prefix(4)))
        return .result(
            dialog: "\(sentences.joined(separator: " "))",
            view: EventResultsSnippet(title: bundle.event.name, results: rows)
        )
    }
}

struct WhenIsIntent: AppIntent {
    static let title: LocalizedStringResource = "When Is"
    static let supportedModes: IntentModes = .background

    @Parameter(title: "Schedule Item", requestValueDialog: "Which part of the schedule?")
    var item: ScheduleItemEntity

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ShowsSnippetView {
        guard let bundle = await IntentBridge.bundle(),
              let scheduleItem = bundle.schedule.first(where: { $0.id == item.id }) else {
            return .result(dialog: IntentAnswers.noEvent, view: EmptyView())
        }
        let now = Date.now
        let entity = ScheduleItemEntity(scheduleItem, bundle: bundle)
        var text = "\(entity.name) is \(entity.timeText) at \(entity.locationName)."
        switch EventSearch.timeLabel(scheduleItem, now: now) {
        case .now?:   text += " It's on now."
        case .ended?: text += " It has ended."
        case .next?, nil:
            if let countdown = scheduleItem.startsInText(relativeTo: now) { text += " \(countdown)." }
        }
        let row = EventSearchIndex(bundle).result(for: .scheduleItem(scheduleItem.id), now: now)
        return .result(
            dialog: "\(text)",
            view: EventResultsSnippet(title: bundle.event.name, results: row.map { [$0] } ?? [])
        )
    }
}

struct WhereIsIntent: AppIntent {
    static let title: LocalizedStringResource = "Where Is"
    static let supportedModes: IntentModes = .background

    @Parameter(title: "Location", requestValueDialog: "Which place?")
    var location: LocationEntity

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ShowsSnippetView {
        guard let bundle = await IntentBridge.bundle(),
              let place = bundle.locations.first(where: { $0.id == location.id }) else {
            return .result(dialog: IntentAnswers.noEvent, view: EmptyView())
        }
        let now = Date.now
        var text: String
        if !place.address.isEmpty {
            text = "\(place.name) is at \(place.address)."
        } else if !place.snippet.isEmpty {
            text = "\(place.name): \(place.snippet)."
        } else {
            text = "\(place.name) is one of the event's locations."
        }
        let index = EventSearchIndex(bundle)
        let onNow = bundle.schedule.filter { $0.locationId == place.id && ScheduleTiming.isHappening($0, at: now) }
        if let first = onNow.first {
            text += " On now: \(first.name)."
        }
        let targets: [SearchTarget] = [.location(place.id)] + onNow.prefix(2).map { SearchTarget.scheduleItem($0.id) }
        return .result(
            dialog: "\(text)",
            view: EventResultsSnippet(title: bundle.event.name, results: targets.compactMap { index.result(for: $0, now: now) })
        )
    }
}

struct LatestUpdatesIntent: AppIntent {
    static let title: LocalizedStringResource = "Latest Event Updates"
    static let supportedModes: IntentModes = .background

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ShowsSnippetView {
        guard let bundle = await IntentBridge.bundle() else {
            return .result(dialog: IntentAnswers.noEvent, view: EmptyView())
        }
        guard let latest = bundle.notifications.first else {
            return .result(dialog: "The organizer hasn't posted any updates yet.", view: EmptyView())
        }
        let now = Date.now
        let index = EventSearchIndex(bundle)
        var text = "The latest update: \(latest.title)."
        if !latest.body.isEmpty { text += " \(EventSearch.excerpt(latest.body, limit: 160))" }
        let rows = bundle.notifications.prefix(3).compactMap { index.result(for: .notification($0.id), now: now) }
        return .result(dialog: "\(text)", view: EventResultsSnippet(title: bundle.event.name, results: rows))
    }
}

/// "Ask Attnd about my event": the on-device model with tool calling when it is available,
/// otherwise the local search results for the question's keywords. Always shows the items used.
struct AskEventIntent: AppIntent {
    static let title: LocalizedStringResource = "Ask About the Event"
    static let supportedModes: IntentModes = .background

    @Parameter(title: "Question", requestValueDialog: "What would you like to know about the event?")
    var question: String

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ShowsSnippetView {
        guard let bundle = await IntentBridge.bundle() else {
            return .result(dialog: IntentAnswers.noEvent, view: EmptyView())
        }
        let now = Date.now
        let index = EventSearchIndex(bundle)
        if EventAssistant.isAvailable,
           let answer = try? await EventAssistant.answer(question, bundle: bundle, now: now) {
            let rows = answer.sources.compactMap { index.result(for: $0, now: now) }
            return .result(dialog: "\(answer.text)", view: EventResultsSnippet(title: bundle.event.name, results: rows))
        }
        let targets = EntityLookup.targets(question, bundle: bundle, now: now)
        let rows = targets.prefix(4).compactMap { index.result(for: $0, now: now) }
        guard let first = rows.first else {
            return .result(dialog: "I couldn't find that in \(bundle.event.name).", view: EmptyView())
        }
        let dialog = "Here's what I found: \(first.title)" + (first.subtitle.isEmpty ? "." : ", \(first.subtitle).")
        return .result(dialog: "\(dialog)", view: EventResultsSnippet(title: bundle.event.name, results: rows))
    }
}

// MARK: - Answer wording

enum IntentAnswers {
    static var noEvent: IntentDialog { "Join an event in Attnd first." }

    /// "A, B and C".
    static func list(_ parts: [String]) -> String {
        switch parts.count {
        case 0: return ""
        case 1: return parts[0]
        default: return parts.dropLast().joined(separator: ", ") + " and " + (parts.last ?? "")
        }
    }

    /// "Roaming Mariachi at the Plaza until 3:00 PM".
    static func nowPhrase(_ result: EventSearchResult, bundle: EventBundle) -> String {
        guard case .scheduleItem(let id) = result.target, let item = bundle.schedule.first(where: { $0.id == id }) else {
            return result.title
        }
        var phrase = item.name
        if let place = item.locationName { phrase += " at \(place)" }
        if let end = ScheduleTiming.effectiveEnd(of: item) {
            phrase += " until \(EventTimeFormat.time(end, in: bundle.event.timeZone))"
        }
        return phrase
    }

    /// "Taco Tasting at 3:00 PM at the Food Court".
    static func nextPhrase(_ result: EventSearchResult, bundle: EventBundle) -> String {
        guard case .scheduleItem(let id) = result.target, let item = bundle.schedule.first(where: { $0.id == id }) else {
            return result.title
        }
        var phrase = item.name
        if let start = item.startTime { phrase += " at \(EventTimeFormat.time(start, in: bundle.event.timeZone))" }
        if let place = item.locationName { phrase += ", \(place)" }
        return phrase
    }
}

// MARK: - Snippet

/// The items behind a Siri answer: the same rows as the search tab.
struct EventResultsSnippet: View {
    let title: String
    let results: [EventSearchResult]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(results) { result in
                SearchResultRow(result: result)
            }
        }
        .padding()
        .tint(Color("AccentColor"))
    }
}

// MARK: - App Shortcuts

struct AttndShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: WhatsOnNowIntent(),
            phrases: [
                "What's happening now in \(.applicationName)",
                "What's on now in \(.applicationName)",
                "What's next in \(.applicationName)",
            ],
            shortTitle: "Happening Now",
            systemImageName: "dot.radiowaves.left.and.right"
        )
        AppShortcut(
            intent: WhenIsIntent(),
            phrases: [
                "When is \(\.$item) in \(.applicationName)",
                "When does \(\.$item) start in \(.applicationName)",
                "Look up a time in \(.applicationName)",
            ],
            shortTitle: "When Is…",
            systemImageName: "clock"
        )
        AppShortcut(
            intent: WhereIsIntent(),
            phrases: [
                "Where is \(\.$location) in \(.applicationName)",
                "Find \(\.$location) in \(.applicationName)",
                "Find a place in \(.applicationName)",
            ],
            shortTitle: "Where Is…",
            systemImageName: "mappin.and.ellipse"
        )
        AppShortcut(
            intent: LatestUpdatesIntent(),
            phrases: [
                "Latest updates in \(.applicationName)",
                "What's new at my event in \(.applicationName)",
            ],
            shortTitle: "Latest Updates",
            systemImageName: "bell"
        )
        AppShortcut(
            intent: AskEventIntent(),
            phrases: [
                "Ask \(.applicationName) about my event",
                "Ask \(.applicationName) a question",
            ],
            shortTitle: "Ask About the Event",
            systemImageName: "sparkles"
        )
        AppShortcut(
            intent: SearchEventIntent(),
            phrases: [
                "Search \(.applicationName)",
                "Search my event in \(.applicationName)",
            ],
            shortTitle: "Search Event",
            systemImageName: "magnifyingglass"
        )
    }
}
