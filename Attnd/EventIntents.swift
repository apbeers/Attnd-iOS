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
//   - Likes (hearts): like / unlike a schedule item or place, and "what have I liked" (stored on
//     the device per event, counted as API-009 usage like a heart in the app).
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
        let started = ContinuousClock.now
        defer { IntentLog.finished("OpenScheduleItemIntent", started: started) }
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
        let started = ContinuousClock.now
        defer { IntentLog.finished("OpenLocationIntent", started: started) }
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
        let started = ContinuousClock.now
        defer { IntentLog.finished("OpenNotificationIntent", started: started) }
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
        let started = ContinuousClock.now
        defer { IntentLog.finished("OpenEventIntent", started: started) }
        await IntentBridge.navigate(to: .event(target.id))
        return .result()
    }
}

/// "Search Attnd for tacos": opens the search sheet with the query.
struct SearchEventIntent: AppIntent {
    static let title: LocalizedStringResource = "Search Event"
    static let supportedModes: IntentModes = .foreground

    @Parameter(title: "Search For", requestValueDialog: "What are you looking for?")
    var query: String

    @MainActor
    func perform() async throws -> some IntentResult {
        let started = ContinuousClock.now
        defer { IntentLog.finished("SearchEventIntent", started: started) }
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
        let started = ContinuousClock.now
        defer { IntentLog.finished("WhatsOnNowIntent", started: started) }
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
        let started = ContinuousClock.now
        defer { IntentLog.finished("WhenIsIntent", started: started) }
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
            // "It starts in 12 min." / "It starts tomorrow 7:30 PM." (RelativeTimeText, never "in 50 h").
            if let start = scheduleItem.startTime, start > now {
                let relative = RelativeTimeText.start(start, end: scheduleItem.endTime, now: now, timeZone: bundle.event.timeZone)
                text += relative == "Starting now" ? " It's starting now." : " It starts \(relative)."
            }
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
        let started = ContinuousClock.now
        defer { IntentLog.finished("WhereIsIntent", started: started) }
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
        let started = ContinuousClock.now
        defer { IntentLog.finished("LatestUpdatesIntent", started: started) }
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
        let started = ContinuousClock.now
        defer { IntentLog.finished("AskEventIntent", started: started) }
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

// MARK: - Hearts

struct HeartScheduleItemIntent: AppIntent {
    static let title: LocalizedStringResource = "Like Schedule Item"
    static let supportedModes: IntentModes = .background

    @Parameter(title: "Schedule Item", requestValueDialog: "Which part of the schedule?")
    var item: ScheduleItemEntity

    @Parameter(title: "Like", default: true)
    var heart: Bool

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let started = ContinuousClock.now
        defer { IntentLog.finished("HeartScheduleItemIntent", started: started) }
        guard await IntentBridge.setHeart(heart, for: .scheduleItem(item.id)) else {
            return .result(dialog: IntentAnswers.noEvent)
        }
        let text = heart ? "Liked \(item.name)." : "Removed \(item.name) from your likes."
        return .result(dialog: "\(text)")
    }
}

struct HeartLocationIntent: AppIntent {
    static let title: LocalizedStringResource = "Like Location"
    static let supportedModes: IntentModes = .background

    @Parameter(title: "Location", requestValueDialog: "Which place?")
    var location: LocationEntity

    @Parameter(title: "Like", default: true)
    var heart: Bool

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let started = ContinuousClock.now
        defer { IntentLog.finished("HeartLocationIntent", started: started) }
        guard await IntentBridge.setHeart(heart, for: .location(location.id)) else {
            return .result(dialog: IntentAnswers.noEvent)
        }
        let text = heart ? "Liked \(location.name)." : "Removed \(location.name) from your likes."
        return .result(dialog: "\(text)")
    }
}

/// "What have I liked in Attnd": liked (hearted) schedule items (by time), then places.
struct HeartedItemsIntent: AppIntent {
    static let title: LocalizedStringResource = "What Have I Liked"
    static let supportedModes: IntentModes = .background

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ShowsSnippetView {
        let started = ContinuousClock.now
        defer { IntentLog.finished("HeartedItemsIntent", started: started) }
        guard let hearted = await IntentBridge.hearted() else {
            return .result(dialog: IntentAnswers.noEvent, view: EmptyView())
        }
        let bundle = hearted.bundle
        let targets = hearted.targets
        let now = Date.now
        let index = EventSearchIndex(bundle)
        let rows = targets.compactMap { index.result(for: $0, now: now) }
        guard !rows.isEmpty else {
            return .result(dialog: "You haven't liked anything in \(bundle.event.name) yet.", view: EmptyView())
        }
        let names = IntentAnswers.list(rows.prefix(3).map(\.title))
        let more = rows.count > 3 ? " and \(rows.count - 3) more" : ""
        return .result(
            dialog: "You've liked \(names)\(more).",
            view: EventResultsSnippet(title: bundle.event.name, results: Array(rows.prefix(8)))
        )
    }
}

// MARK: - My plan (assistant spec §6)

/// "What's next on my plan in Attnd": the next planned item, its time and the walk there.
struct PlanNextIntent: AppIntent {
    static let title: LocalizedStringResource = "What's Next on My Plan"
    static let supportedModes: IntentModes = .background

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ShowsSnippetView {
        let started = ContinuousClock.now
        defer { IntentLog.finished("PlanNextIntent", started: started) }
        guard let bundle = await IntentBridge.bundle(), let appState = IntentBridge.appState else {
            return .result(dialog: IntentAnswers.noEvent, view: EmptyView())
        }
        guard appState.planner.hasPlan else {
            return .result(dialog: "You don't have a plan for \(bundle.event.name) yet.", view: EmptyView())
        }
        let now = Date.now
        guard let next = appState.assistant.nextPlanned(now: now), let start = next.startTime else {
            return .result(dialog: "Nothing else is in your plan.", view: EmptyView())
        }
        let when = AssistantText.relativeStart(start, end: ScheduleTiming.effectiveEnd(of: next), now: now,
                                               zone: bundle.event.timeZone, locale: .current)
        let place = bundle.location(next.locationId)?.name
        let rows = EventSearchIndex(bundle).result(for: .scheduleItem(next.id), now: now).map { [$0] } ?? []
        let text = "Next in your plan: \(next.name)" + (place.map { " at \($0)" } ?? "") + ", \(when)."
        return .result(
            dialog: "\(text)",
            view: EventResultsSnippet(title: bundle.event.name, results: rows)
        )
    }
}

/// "Swap my next thing in Attnd": the next planned item for its best alternative (Undo in the app).
struct SwapNextPlanItemIntent: AppIntent {
    static let title: LocalizedStringResource = "Swap My Next Thing"
    static let supportedModes: IntentModes = .background

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let started = ContinuousClock.now
        defer { IntentLog.finished("SwapNextPlanItemIntent", started: started) }
        guard await IntentBridge.bundle() != nil, let appState = IntentBridge.appState else {
            return .result(dialog: IntentAnswers.noEvent)
        }
        return .result(dialog: "\(appState.assistant.swapNext())")
    }
}

/// "I already ate in Attnd": no food stops for 3 hours, the next meal break dropped.
struct AlreadyAteIntent: AppIntent {
    static let title: LocalizedStringResource = "I Already Ate"
    static let supportedModes: IntentModes = .background

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let started = ContinuousClock.now
        defer { IntentLog.finished("AlreadyAteIntent", started: started) }
        guard await IntentBridge.bundle() != nil, let appState = IntentBridge.appState else {
            return .result(dialog: IntentAnswers.noEvent)
        }
        return .result(dialog: "\(appState.assistant.alreadyAte())")
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

/// The items behind a Siri answer: the same rows as the search sheet.
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
            intent: HeartScheduleItemIntent(),
            phrases: [
                "Like \(\.$item) in \(.applicationName)",
                "Save \(\.$item) in \(.applicationName)",
            ],
            shortTitle: "Like",
            systemImageName: "heart"
        )
        AppShortcut(
            intent: HeartedItemsIntent(),
            phrases: [
                "What have I liked in \(.applicationName)",
                "Show my likes in \(.applicationName)",
            ],
            shortTitle: "Liked",
            systemImageName: "heart.fill"
        )
        AppShortcut(
            intent: PlanNextIntent(),
            phrases: [
                "What's next on my plan in \(.applicationName)",
                "What's my next thing in \(.applicationName)",
            ],
            shortTitle: "Next in My Plan",
            systemImageName: "list.bullet.clipboard"
        )
        AppShortcut(
            intent: AlreadyAteIntent(),
            phrases: [
                "I already ate in \(.applicationName)",
                "Tell \(.applicationName) I already ate",
            ],
            shortTitle: "I Already Ate",
            systemImageName: "fork.knife"
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


/// `assistant.request` (kind "intent") when a Siri / Shortcuts / Spotlight intent finishes.
enum IntentLog {
    static func finished(_ name: String, started: ContinuousClock.Instant) {
        let ms = (ContinuousClock.now - started).wholeMilliseconds
        AppLog.info(.assistant, "assistant.request", "\(name) in \(ms) ms", [
            "kind": "intent", "name": .string(name), "ms": .int(ms), "ok": true,
        ])
    }
}
