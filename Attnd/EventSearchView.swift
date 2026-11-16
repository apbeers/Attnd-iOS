// EventSearchView.swift
// Attnd
//
// The search sheet of the App Clip and of screenshot mode (the full app searches from My plan's
// input bar, AssistantView.swift, which reuses this file's result rows and destinations; there
// this sheet only shows items of hidden tabs pushed by `navigate(to:)`): one
// local search across the joined event — schedule, locations, organizer updates and the
// event itself (EventSearch). Works offline; the query never leaves the device (only the
// fact of a search is counted, API-005).
//
// The sheet has its own navigation stack (`AppState.searchPath`): tapping a result pushes
// its detail, so Back returns to the results and items in tabs the organizer hid
// (`display.tabs`) open too. Siri, Spotlight and other jumps use `AppState.navigate(to:)`,
// which prefers the item's own tab and otherwise opens this sheet with the item pushed.
//
// The search field is focused (keyboard up) when the sheet opens: the field sits in the
// navigation bar drawer, where activating it with `searchable(isPresented:)` reliably
// brings up the keyboard on iOS 26 (programmatic focus of the bottom-bar search field
// doesn't), and `searchFocused` asks for focus as well.
//
// In the full app, a question typed here offers "Ask" when the on-device model is available
// (Apple Intelligence, EventAssistant.swift): the answer cites the items it used. A request
// that looks like a plan ("Plan my Saturday around live music") makes one instead (the
// planner, spec §6) and offers "Open My plan". Without
// the model (or in the App Clip) the plain results are shown, searching the question's
// keywords when the question as typed finds nothing.

import SwiftUI
#if !APP_CLIP
// For `appEntityIdentifier` (SwiftUI + App Intents); the App Clip has no App Intents.
import AppIntents
#endif

// MARK: - Sheet

struct EventSearchSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    /// Focus the field once the results screen first appears. False when Siri / Spotlight
    /// opened the sheet on an item (Back from it then shows the results without the keyboard).
    @State private var pendingFocus: Bool

    init(focusesSearchField: Bool) {
        _pendingFocus = State(initialValue: focusesSearchField)
    }

    var body: some View {
        @Bindable var state = appState
        NavigationStack(path: $state.searchPath) {
            EventSearchView(pendingFocus: $pendingFocus)
                .navigationDestination(for: SearchTarget.self) { target in
                    SearchDestinationView(target: target)
                }
                // Schedule item details link to their location.
                .navigationDestination(for: Location.self) { location in
                    LocationDetailView(location: location)
                }
                // The "Liked" suggestion.
                .navigationDestination(for: HeartedListRoute.self) { _ in
                    HeartedListView()
                }
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close", systemImage: "xmark", role: .close) {
                            dismiss()
                        }
                    }
                }
        }
        .presentationDetents([.large])
    }
}

// MARK: - Search screen

struct EventSearchView: View {
    /// Set by the sheet: activate and focus the search field when this screen appears.
    @Binding var pendingFocus: Bool

    @Environment(AppState.self) private var appState

    /// The assistant's answer for `answeredQuery`, or its progress.
    @State private var assistant: AssistantPhase = .idle
    /// Whether the search field is active (`searchable(isPresented:)`).
    @State private var isSearchPresented = false
    @FocusState private var isSearchFocused: Bool

    private enum AssistantPhase: Equatable {
        case idle
        case thinking(query: String)
        case answered(query: String, answer: EventAssistantAnswer)
        case failed(query: String)
        /// A plan request (spec §6, full app): planning, the plan made, or why nothing fits.
        case planning(query: String)
        case planned(query: String, summary: String, itemIds: [Int])
        case planFailed(query: String, message: String)
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
        .navigationBarTitleDisplayMode(.inline)
        // Always shown in the navigation bar drawer: there, activating it (isPresented) brings
        // up the keyboard reliably, also inside a sheet that is still animating in.
        .searchable(
            text: $state.searchText,
            isPresented: $isSearchPresented,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: Text("Schedule, places, updates")
        )
        .searchFocused($isSearchFocused)
        .modifier(SearchUsageCounting(text: appState.searchText, source: "sheet"))
        // Distances to places in the results.
        .usesUserLocation(heading: true)
        .onChange(of: appState.searchText) {
            if case .idle = assistant { return }
            assistant = .idle
        }
        // Onboarding's "Plan your day" examples ask straight away.
        .task(id: appState.autoAskQuery) {
            guard let question = appState.autoAskQuery else { return }
            appState.autoAskQuery = nil
            guard question == query else { return }
            await ask(question)
        }
        .task {
            guard pendingFocus else { return }
            pendingFocus = false
            isSearchPresented = true
            isSearchFocused = true
            // The sheet may still be animating in; ask again once it has settled.
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled, !isSearchFocused else { return }
            isSearchPresented = true
            isSearchFocused = true
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
                HeartableResultRow(result: result)
            }
            .onScreenEntity(result.target)
        }
    }

    // MARK: Suggestions

    @ViewBuilder
    private var suggestions: some View {
        let items = appState.currentBundle.map(EventSearch.suggestions) ?? []
        if !items.isEmpty || appState.hasHearts {
            Section {
                if appState.hasHearts {
                    NavigationLink(value: HeartedListRoute()) {
                        Label("Liked", systemImage: "heart.fill")
                    }
                }
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
        // A question already put to the model (e.g. onboarding's "What's on near me right now?").
        switch assistant {
        case .thinking(let asked), .answered(let asked, _), .failed(let asked),
             .planning(let asked), .planned(let asked, _, _), .planFailed(let asked, _):
            if asked == query { return true }
        case .idle:
            break
        }
        // Plan requests ("Kid-friendly afternoon") make a plan (spec §6).
        if AppState.plannerAvailable, PlanRequest.looksLikePlan(query) { return true }
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
            case .planning(let asked) where asked == query:
                HStack(spacing: 12) {
                    ProgressView()
                    Text("Planning on your iPhone…")
                        .foregroundStyle(.secondary)
                }
            case .planned(let asked, let summary, let itemIds) where asked == query:
                Text("Here's your plan: \(summary). It's in My plan.")
                    .textSelection(.enabled)
                if AppState.hasPlanPanel {
                    Button("Open My Plan", systemImage: "list.bullet.clipboard") {
                        openMyPlan()
                    }
                }
                ForEach(itemIds.compactMap { index.result(for: .scheduleItem($0), now: now) }) { result in
                    NavigationLink(value: result.target) {
                        SearchResultRow(result: result)
                    }
                }
            case .planFailed(let asked, let message) where asked == query:
                Label(message, systemImage: "calendar.badge.exclamationmark")
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
            } else if case .planned(let asked, _, _) = assistant, asked == query {
                Text("Planned on this device from the schedule, your likes and walking times.")
            }
        }
    }

    private func openMyPlan() {
        #if !APP_CLIP
        appState.showMyPlan()
        #endif
    }

    private func ask(_ question: String) async {
        #if !APP_CLIP
        guard let bundle = appState.currentBundle else { return }
        if AppState.plannerAvailable, PlanRequest.looksLikePlan(question) {
            await plan(question)
            return
        }
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

    #if !APP_CLIP
    /// A plan request: the planner makes and stores the plan (the plan panel); the answer
    /// is its summary and items, with "Open My plan".
    private func plan(_ request: String) async {
        assistant = .planning(query: request)
        let plan = await appState.makePlan(request)
        guard query == request else { return }
        if let plan, !plan.isEmpty {
            assistant = .planned(
                query: request,
                summary: Planner.summary(plan, timeZone: appState.timeZone),
                itemIds: plan.itemIds
            )
        } else {
            assistant = .planFailed(query: request, message: appState.planner.error ?? AppState.nothingFitsMessage)
        }
    }
    #endif
}

// MARK: - Result row

/// A search result with a heart (schedule items and places) and, for places, the distance.
/// The plain `SearchResultRow` is also used by Siri snippets, which have no app state.
struct HeartableResultRow: View {
    let result: EventSearchResult

    @Environment(AppState.self) private var appState

    var body: some View {
        switch result.target {
        case .location(let id):
            HStack(spacing: 8) {
                SearchResultRow(result: result)
                DistanceBadge(target: appState.location(id: id)?.coordinate)
                HeartButton(target: result.target, font: .subheadline)
            }
        case .scheduleItem:
            HStack(spacing: 8) {
                SearchResultRow(result: result)
                HeartButton(target: result.target, font: .subheadline)
            }
        case .notification, .event:
            SearchResultRow(result: result)
        }
    }
}

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

/// The detail for a result, pushed on the search sheet's stack.
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
/// pushed). Options shows the same header.
struct EventInfoView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        List {
            if let event = appState.currentEvent {
                Section {
                    EventHeader(event: event, logoUrl: appState.logoUrl)
                    if let website = event.websiteUrl {
                        EventWebsiteLink(url: website)
                    }
                    GetTicketsRow(action: appState.ticketAction)
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
    func onScreenEntities<Item: Hashable & SendableMetatype>(
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
