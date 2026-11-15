// EventSearchView.swift
// Attnd
//
// The search tab (`Tab(role: .search)` in ContentView): one local search across the joined
// event — schedule, locations, organizer updates and the event itself (EventSearch). Works
// offline; the query never leaves the device (only the fact of a search is counted, API-005).
//
// Tapping a result pushes its detail onto this tab's stack, so Back returns to the results
// and items in tabs the organizer hid (`display.tabs`) open too. Siri, Spotlight and other
// jumps use `AppState.navigate(to:)`, which prefers the item's own tab.
//
// In the full app, a question typed here offers "Ask" when the on-device model is available
// (Apple Intelligence, EventAssistant.swift): the answer cites the items it used. Without
// the model (or in the App Clip) the plain results are shown, searching the question's
// keywords when the question as typed finds nothing.

import SwiftUI
#if !APP_CLIP
// For `appEntityIdentifier` (SwiftUI + App Intents); the App Clip has no App Intents.
import AppIntents
#endif

// MARK: - Tab

struct EventSearchTab: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var state = appState
        NavigationStack(path: $state.searchPath) {
            EventSearchView()
                .navigationDestination(for: SearchTarget.self) { target in
                    SearchDestinationView(target: target)
                }
                // Schedule item details link to their location.
                .navigationDestination(for: Location.self) { location in
                    LocationDetailView(location: location)
                }
        }
    }
}

// MARK: - Search screen

struct EventSearchView: View {
    @Environment(AppState.self) private var appState

    /// The assistant's answer for `answeredQuery`, or its progress.
    @State private var assistant: AssistantPhase = .idle

    private enum AssistantPhase: Equatable {
        case idle
        case thinking(query: String)
        case answered(query: String, answer: EventAssistantAnswer)
        case failed(query: String)
    }

    private var query: String {
        appState.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        @Bindable var state = appState
        TimelineView(.periodic(from: .now, by: 60)) { context in
            content(now: context.date)
        }
        .navigationTitle("Search")
        .searchable(text: $state.searchText, prompt: Text("Schedule, places, updates"))
        .modifier(SearchUsageCounting(text: appState.searchText))
        .onChange(of: appState.searchText) {
            if case .idle = assistant { return }
            assistant = .idle
        }
    }

    @ViewBuilder
    private func content(now: Date) -> some View {
        if let index = appState.searchIndex {
            let typed = index.search(query, now: now)
            let fallback = typed.isEmpty ? keywordFallback(index: index, now: now) : nil
            let results = fallback?.results ?? typed
            List {
                if query.isEmpty {
                    suggestions
                } else {
                    if canAsk {
                        askSection(index: index, now: now)
                    }
                    if let fallback, !fallback.results.isEmpty {
                        Section {
                            resultRows(fallback.results)
                        } header: {
                            Text("Results for “\(fallback.keywords)”")
                        }
                    } else if !results.isEmpty {
                        Section {
                            resultRows(results)
                        }
                    }
                }
            }
            .overlay {
                if !query.isEmpty, results.isEmpty, !canAsk {
                    ContentUnavailableView.search(text: query)
                }
            }
        } else {
            ContentUnavailableView(
                "Nothing to Search Yet",
                systemImage: "magnifyingglass",
                description: Text("The event's schedule, places and updates appear here once they've loaded.")
            )
        }
    }

    /// A question as typed ("when is the mariachi?") rarely matches with every word; search its keywords.
    private func keywordFallback(index: EventSearchIndex, now: Date) -> (keywords: String, results: [EventSearchResult])? {
        let keywords = EventSearch.keywords(fromQuestion: query)
        guard !keywords.isEmpty, EventSearch.normalise(keywords) != EventSearch.normalise(query) else { return nil }
        return (keywords, index.search(keywords, now: now))
    }

    @ViewBuilder
    private func resultRows(_ results: [EventSearchResult]) -> some View {
        ForEach(results.prefix(100)) { result in
            NavigationLink(value: result.target) {
                SearchResultRow(result: result)
            }
            .onScreenEntity(result.target)
        }
    }

    // MARK: Suggestions

    @ViewBuilder
    private var suggestions: some View {
        let items = appState.currentBundle.map(EventSearch.suggestions) ?? []
        if !items.isEmpty {
            Section {
                ForEach(items) { suggestion in
                    Button {
                        appState.searchText = suggestion.query
                    } label: {
                        Label(suggestion.title, systemImage: suggestion.systemImage)
                    }
                }
            } header: {
                Text("Suggestions")
            } footer: {
                Text("Search the schedule, locations, updates and event info. Try “music tonight” or “food 6pm”.")
            }
        }
    }

    // MARK: Ask (on-device model)

    /// "Ask" is offered for questions while Apple Intelligence's on-device model is available.
    private var canAsk: Bool {
        #if APP_CLIP
        return false
        #else
        guard !query.isEmpty, !ScreenshotMode.isActive, EventAssistant.isAvailable else { return false }
        return EventSearch.looksLikeQuestion(query) || EventSearch.words(query).count >= 4
        #endif
    }

    @ViewBuilder
    private func askSection(index: EventSearchIndex, now: Date) -> some View {
        Section {
            switch assistant {
            case .answered(let asked, let answer) where asked == query:
                Text(answer.text)
                    .textSelection(.enabled)
                ForEach(answer.sources.compactMap { index.result(for: $0, now: now) }) { result in
                    NavigationLink(value: result.target) {
                        SearchResultRow(result: result)
                    }
                }
            case .thinking(let asked) where asked == query:
                HStack(spacing: 12) {
                    ProgressView()
                    Text("Looking through the event…")
                        .foregroundStyle(.secondary)
                }
            case .failed(let asked) where asked == query:
                Label("Couldn't answer that. Try the results below or rephrase.", systemImage: "exclamationmark.bubble")
                    .foregroundStyle(.secondary)
            default:
                Button {
                    Task { await ask(query) }
                } label: {
                    Label("Ask about this event", systemImage: "sparkles")
                }
            }
        } header: {
            Text("Ask")
        } footer: {
            if case .answered(let asked, _) = assistant, asked == query {
                Text("Answered on this device from the event's info. Tap an item to check the details.")
            }
        }
    }

    private func ask(_ question: String) async {
        #if !APP_CLIP
        guard let bundle = appState.currentBundle else { return }
        assistant = .thinking(query: question)
        do {
            let answer = try await EventAssistant.answer(question, bundle: bundle, now: .now)
            guard query == question else { return }
            assistant = .answered(query: question, answer: answer)
        } catch {
            guard query == question else { return }
            assistant = .failed(query: question)
        }
        #endif
    }
}

// MARK: - Result row

/// Kind icon, title with the matched part emphasised, one line of inline info and a Now /
/// Next / Ended label for schedule items.
struct SearchResultRow: View {
    let result: EventSearchResult

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: result.kind.systemImage)
                .foregroundStyle(.tint)
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(highlightedTitle)
                        .lineLimit(2)
                    Spacer(minLength: 0)
                    if let label = result.timeLabel {
                        Text(label.rawValue)
                            .font(.caption.bold())
                            .foregroundStyle(label == .ended ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
                    }
                }
                if !result.subtitle.isEmpty {
                    Text(result.subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityHint(result.kind.title)
    }

    /// The title with every matched range in bold.
    private var highlightedTitle: AttributedString {
        let characters = Array(result.title)
        var text = AttributedString()
        var cursor = 0
        for range in result.titleHighlights where range.lowerBound >= cursor && range.upperBound <= characters.count {
            text += AttributedString(String(characters[cursor..<range.lowerBound]))
            var match = AttributedString(String(characters[range]))
            match.inlinePresentationIntent = .stronglyEmphasized
            text += match
            cursor = range.upperBound
        }
        text += AttributedString(String(characters[cursor...]))
        return text
    }
}

// MARK: - Destinations

/// The detail for a result, pushed on the search tab's stack.
struct SearchDestinationView: View {
    let target: SearchTarget

    @Environment(AppState.self) private var appState

    var body: some View {
        switch target {
        case .location(let id):
            if let location = appState.location(id: id) {
                LocationDetailView(location: location)
            } else {
                gone
            }
        case .scheduleItem(let id):
            if let item = appState.schedule.first(where: { $0.id == id }) {
                ScheduleItemDetailView(item: item)
            } else {
                gone
            }
        case .notification(let id):
            NotificationsView(focusId: id)
        case .event:
            EventInfoView()
        }
    }

    private var gone: some View {
        ContentUnavailableView(
            "No Longer Listed",
            systemImage: "questionmark.circle",
            description: Text("The organizer removed this item.")
        )
    }
}

/// The event's own details (a search result for the event, or Siri's "open the event" when
/// pushed). The Options tab shows the same header.
struct EventInfoView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        List {
            if let event = appState.currentEvent {
                Section {
                    EventHeader(event: event, logoUrl: appState.logoUrl)
                }
                if !event.description.isEmpty {
                    Section("About") {
                        Text(event.description)
                    }
                }
            }
        }
        .navigationTitle(appState.currentEvent?.name ?? "Event")
        .navigationBarTitleDisplayMode(.inline)
        .onScreenEntity(.event(appState.currentEvent?.id ?? 0))
    }
}

// MARK: - Siri on-screen awareness

extension View {
    /// Tells Siri and Apple Intelligence which event item this view shows (App Intents
    /// entities, EventEntities.swift). No-op in the App Clip, which has no App Intents.
    @ViewBuilder
    func onScreenEntity(_ target: SearchTarget) -> some View {
        #if APP_CLIP
        self
        #else
        appEntityIdentifier(target.entityIdentifier)
        #endif
    }

    /// The same for a list whose selection type is `Item`: each row is an entity.
    @ViewBuilder
    func onScreenEntities<Item: Hashable>(
        forSelectionType type: Item.Type,
        _ target: @escaping @Sendable (Item) -> SearchTarget
    ) -> some View {
        #if APP_CLIP
        self
        #else
        appEntityIdentifier(forSelectionType: type) { item in
            target(item).entityIdentifier
        }
        #endif
    }
}
