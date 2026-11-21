// EventSearchView.swift
// Attnd
//
// The search sheet without the on-device model and in screenshot mode (with the model, the app
// and the App Clip search from the plan page's text box, AssistantView.swift, which reuses this
// file's result rows and destinations; there this sheet only shows items of hidden tabs pushed
// by `navigate(to:)`): one local search across the joined event — schedule, locations,
// organizer updates and the event itself (EventSearch). Works offline; the query never leaves
// the device (only the fact of a search is counted, API-005).
//
// The sheet has its own navigation stack (`AppState.searchPath`): tapping a result pushes
// its detail, so Back returns to the results and items in tabs the organizer hid
// (`display.tabs`) open too. Links, notifications and other jumps use `AppState.navigate(to:)`,
// which prefers the item's own tab and otherwise opens this sheet with the item pushed.
//
// The search field is focused (keyboard up) when the sheet opens: the field sits in the
// navigation bar drawer, where activating it with `searchable(isPresented:)` reliably
// brings up the keyboard on iOS 26 (programmatic focus of the bottom-bar search field
// doesn't), and `searchFocused` asks for focus as well.
//
// There is no AI here: the sheet exists where the on-device model doesn't (or in screenshot
// mode). A question that matches nothing as typed shows the results for its keywords.

import SwiftUI

// MARK: - Sheet

struct EventSearchSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    /// Focus the field once the results screen first appears. False when a link or notification
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

    /// Whether the search field is active (`searchable(isPresented:)`).
    @State private var isSearchPresented = false
    @FocusState private var isSearchFocused: Bool

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
                if !query.isEmpty, results.isEmpty {
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
                        Label(MyScheduleText.title, systemImage: "calendar")
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

}

// MARK: - Result row

/// A search result with a heart (schedule items and places) and, for places, the distance.
/// The plain `SearchResultRow` needs no app state.
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

/// The event's own details (a search result for the event, or a link to the event when
/// pushed). Options shows the same header. API-024: the sections of the event's `event_info`
/// layout (or the built-in default, today's screen), each only when the event has its data.
struct EventInfoView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        List {
            if let event = appState.currentEvent {
                let sections = appState.screenSections(.eventInfo, now: .now) { bundle, state in
                    ScreenFacts.event(bundle, state)
                }
                ForEach(sections, id: \.type) { section in
                    EventInfoSection(section: section, event: event)
                }
            }
        }
        .navigationTitle(appState.currentEvent?.name ?? "Event")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// One section of the event's info (List sections).
private struct EventInfoSection: View {
    let section: LayoutSection
    let event: Event

    @Environment(AppState.self) private var appState

    var body: some View {
        let context = event.context ?? EventContext()
        switch section.type {
        case "header":
            Section {
                EventHeader(event: event, logoUrl: appState.logoUrl)
                if section.shows("website"), let website = event.websiteUrl {
                    EventWebsiteLink(url: website)
                }
            }
        case "about":
            ContextTextSection(title: section.title ?? "About", text: event.description)
            // API-018: the organizer's notes for the assistant.
            ContextTextSection(title: section.title ?? "Details", text: context.about)
        case "faq": EventFAQSection(faq: context.faq, title: section.title, limit: section.limit)
        case "amenities": EventAmenitiesSection(amenities: context.amenities, title: section.title)
        case "getting_there": ContextTextSection(title: section.title ?? "Getting There", text: context.gettingThere)
        case "accessibility": ContextTextSection(title: section.title ?? "Accessibility", text: context.accessibility)
        case "policies": ContextTextSection(title: section.title ?? "Policies", text: context.policies)
        case "weather_plan": ContextTextSection(title: section.title ?? "Weather Plan", text: context.weatherPlan)
        case "links": ContextLinksSection(links: context.links, title: section.title)
        default: EmptyView()
        }
    }
}
