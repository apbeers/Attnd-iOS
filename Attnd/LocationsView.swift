// LocationsView.swift
// Attnd
//
// Locations tab. A NavigationSplitView: list → detail side by side on regular
// width (unfolded iPhone Duo, landscape Pro Max), collapsing to a push stack on compact width.
//
// Display config: `locations_style` (cards / list / grouped by category),
// `show_location_images`, `enable_search` and `group_by_category` (filter chips).
// Each place with schedule items gets a disclosure ("3 events") that lists its upcoming items
// inline (`PlaceEvents`); tapping one pushes its detail over the place's detail. A place's
// detail shows a small walking map (route, user dot, pin) within walking range, else the
// "Get Walking Directions" button.

import ImageIO
import SwiftUI
import UIKit
import MapKit

// MARK: - Tab

struct LocationsTab: View {
    @Environment(AppState.self) private var appState
    @State private var selection: Location?
    /// Pushed over the selected place's detail: a schedule item opened from the list's disclosure
    /// (and the places it links to).
    @State private var detailPath = NavigationPath()
    /// Set while opening an item from the disclosure, so the selection change keeps the path.
    @State private var keepsDetailPath = false

    var body: some View {
        NavigationSplitView {
            LocationsView(selection: $selection, openItem: open)
                .eventStatusBanners()
                // The large title on the bar's own row: no empty band above it.
                .toolbarTitleDisplayMode(.inlineLarge)
                .optionsToolbarItem(for: .locations)
        } detail: {
            NavigationStack(path: $detailPath) {
                Group {
                    if let selection, let location = appState.location(id: selection.id) {
                        LocationDetailView(location: location)
                    } else {
                        ContentUnavailableView("Select a Location", systemImage: "list.bullet")
                    }
                }
                .navigationDestination(for: ScheduleItem.self) { item in
                    ScheduleItemDetailView(item: appState.schedule.first { $0.id == item.id } ?? item)
                }
                .navigationDestination(for: Location.self) { location in
                    LocationDetailView(location: location)
                }
            }
        }
        // Another place selected: its detail starts fresh.
        .onChange(of: selection?.id) {
            if keepsDetailPath {
                keepsDetailPath = false
            } else {
                detailPath = NavigationPath()
            }
        }
        .onChange(of: appState.locations) {
            // Drop a selection the organizer removed.
            if let id = selection?.id, appState.location(id: id) == nil { selection = nil }
            selectScreenshotLocationIfNeeded()
        }
        .onAppear(perform: selectScreenshotLocationIfNeeded)
        // A jump from search, a link or a notification (AppState.navigate).
        .onChange(of: appState.focusRequest, initial: true) {
            guard case .location(let id)? = appState.focusRequest, let location = appState.location(id: id) else { return }
            appState.focusRequest = nil
            selection = location
        }
    }

    /// An item from a place's disclosure: the place selected, the item pushed over its detail
    /// (Back returns to the place, then the list).
    private func open(_ item: ScheduleItem, at location: Location) {
        keepsDetailPath = selection?.id != location.id
        selection = location
        detailPath = NavigationPath([item])
    }

    /// The `location` App Store screenshot opens one location's detail (ScreenshotMode).
    private func selectScreenshotLocationIfNeeded() {
        guard selection == nil, let screenshot = ScreenshotMode.current, screenshot.screen == .location else { return }
        selection = screenshot.screenshotLocation(in: appState.locations)
    }
}

// MARK: - List

struct LocationsView: View {
    @Binding var selection: Location?
    /// A schedule item tapped in a place's disclosure.
    var openItem: (ScheduleItem, Location) -> Void = { _, _ in }

    @Environment(AppState.self) private var appState
    @State private var searchText = ""
    @State private var selectedCategory: String?
    /// The "Liked" chip: only liked (hearted) locations.
    @State private var heartedOnly = false
    /// Places whose upcoming events are expanded inline.
    @State private var expanded: Set<Int> = []

    private var display: DisplayConfig { appState.display }
    /// The tab's own layout (API-027 `places_tab`) picks the list; else `display.locations_style`.
    private var style: LocationsStyle {
        appState.placesTabLayout?.style.flatMap(LocationsStyle.init(rawValue:)) ?? display.locationsStyle
    }

    private var filtered: [Location] {
        LocationGrouping.filter(appState.locations, category: selectedCategory)
            // My schedule's places, including the places of its items.
            .filter { !heartedOnly || appState.myScheduleLocationIds.contains($0.id) }
            .filter { SearchMatching.matches($0, query: searchText) }
    }

    var body: some View {
        let locations = filtered
        // Re-evaluated every minute for the "Now: … · Next …" lines.
        TimelineView(.periodic(from: .now, by: 60)) { context in
            list(locations, now: context.date)
        }
        .navigationTitle(appState.title(of: .locations))
        .modifier(SearchableIf(enabled: display.enableSearch, text: $searchText, prompt: "Search \(appState.title(of: .locations).lowercased())"))
        .refreshable { await appState.pullToRefresh() }
        .usesUserLocation(heading: true)
    }

    private func list(_ locations: [Location], now: Date) -> some View {
        List(selection: $selection) {
            // The Liked chip is always there (an empty state explains it before anything is liked).
            CategoryChips(
                categories: appState.filterCategories,
                selection: $selectedCategory,
                heartedOnly: $heartedOnly
            )
            .listRowInsets(EdgeInsets())
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            // API-027: the organizer's featured places first.
            let featured = (appState.placesTabLayout?.featured ?? []).compactMap { id in locations.first { $0.id == id } }
            if !featured.isEmpty, searchText.isEmpty {
                Section(appState.placesTabLayout?.featuredTitle ?? "Featured") {
                    rows(featured, now: now)
                }
            }
            switch style {
            case .grouped:
                ForEach(LocationGrouping.byCategory(locations, categoryOrder: appState.categories)) { section in
                    Section(section.title) {
                        rows(section.locations, now: now)
                    }
                }
            case .list, .cards:
                rows(locations, now: now)
            }
        }
        .modifier(LocationsListStyle(isCards: style == .cards))
        .overlay {
            if locations.isEmpty {
                if !searchText.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                } else if heartedOnly {
                    NothingLikedView(hasLikes: !appState.myScheduleLocationIds.isEmpty)
                } else if appState.isLoading {
                    ProgressView()
                } else {
                    ContentUnavailableView(
                        "No Locations",
                        systemImage: "mappin.slash",
                        description: Text("Locations will appear here once they're published.")
                    )
                }
            }
        }
    }

    @ViewBuilder
    private func rows(_ locations: [Location], now: Date) -> some View {
        let isCards = style == .cards
        ForEach(locations) { location in
            let events = PlaceEvents.make(locationId: location.id, schedule: appState.schedule, now: now)
            let isExpanded = events != nil && expanded.contains(location.id)
            NavigationLink(value: location) {
                VStack(alignment: .leading, spacing: 6) {
                    if isCards {
                        LocationCard(location: location, showImage: display.showLocationImages, now: now)
                    } else {
                        LocationRow(location: location, showImage: display.showLocationImages, now: now)
                    }
                    if let events {
                        PlaceEventsToggle(title: events.toggleTitle, isExpanded: isExpanded) {
                            withAnimation(.snappy) {
                                if isExpanded { expanded.remove(location.id) } else { expanded.insert(location.id) }
                            }
                        }
                        // Under the row's text (past the thumbnail in the list style).
                        .padding(.leading, !isCards && display.showLocationImages ? 76 : 0)
                    }
                }
            }
            .listRowSeparator(isCards || isExpanded ? .hidden : .automatic)
            .locationPeek(location, now: now) { selection = location }
            if isExpanded, let events {
                ForEach(events.items) { item in
                    PlaceEventRow(item: item, ended: events.allEnded, now: now, timeZone: appState.timeZone) {
                        openItem(item, location)
                    }
                    .listRowSeparator(isCards || item.id != events.items.last?.id ? .hidden : .automatic)
                }
            }
        }
    }
}

// MARK: - A place's events (disclosure)

/// "3 events ⌄" under a place row: shows or hides its upcoming items inline. Borderless, so it
/// works inside the row's link without opening the place.
private struct PlaceEventsToggle: View {
    let title: String
    let isExpanded: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: "calendar")
                Text(title)
                Image(systemName: "chevron.down")
                    .rotationEffect(.degrees(isExpanded ? 180 : 0))
            }
            .font(.caption.weight(.semibold))
            .lineLimit(1)
            .fixedSize()
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(title)
        .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
        .accessibilityHint(isExpanded ? "Hides this place's events." : "Shows this place's events.")
    }
}

/// One item in a place's disclosure: time (event's zone), name, Now / in 12 min (or "Ended",
/// greyed), a heart. Tapping it opens the item's detail.
private struct PlaceEventRow: View {
    let item: ScheduleItem
    let ended: Bool
    let now: Date
    let timeZone: TimeZone
    let open: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Button(action: open) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(EventTimeFormat.range(start: item.startTime, end: item.endTime, in: timeZone, now: now))
                        .font(.caption.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 72, alignment: .leading)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.name)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(ended ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                            .lineLimit(2)
                        if let relative = RelativeTimeText.item(item, now: now, timeZone: timeZone) {
                            Text(relative)
                                .font(.caption.weight(.bold))
                                .foregroundStyle(ended ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
                        }
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.primary)
            HeartButton(target: .scheduleItem(item.id), font: .subheadline)
        }
        .padding(.leading, 12)
        .opacity(ended ? 0.7 : 1)
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Peek

extension View {
    /// Long press: a preview card with the key info, and Heart / Show on Map / Open.
    func locationPeek(_ location: Location, now: Date, open: @escaping () -> Void) -> some View {
        modifier(LocationPeekModifier(location: location, now: now, open: open))
    }
}

private struct LocationPeekModifier: ViewModifier {
    let location: Location
    let now: Date
    let open: () -> Void

    @Environment(AppState.self) private var appState

    func body(content: Content) -> some View {
        let target = SearchTarget.location(location.id)
        let hearted = appState.isHearted(target)
        content.contextMenu {
            Button {
                appState.toggleHeart(target)
            } label: {
                Label(hearted ? MyScheduleText.remove : "Add to My Schedule", systemImage: hearted ? "heart.slash" : "heart")
            }
            if location.coordinate != nil, appState.shows(.map) {
                Button {
                    appState.showOnMap(locationId: location.id)
                } label: {
                    Label("Show on Map", systemImage: "map")
                }
            }
            Button(action: open) {
                Label("Open", systemImage: "arrow.up.forward.app")
            }
        } preview: {
            LocationPeek(
                location: location,
                glanceLine: LocationGlance.make(locationId: location.id, schedule: appState.schedule, now: now)
                    .rowLine(now: now, timeZone: appState.timeZone),
                distance: appState.userLocation.direction(to: location.coordinate)?
                    .text(imperial: DistanceText.usesImperial()),
                hearted: hearted
            )
            .environment(appState)
        }
    }
}

/// Plain list for cards, inset grouped otherwise (listStyle needs one concrete type).
private struct LocationsListStyle: ViewModifier {
    let isCards: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if isCards {
            content.listStyle(.plain)
        } else {
            content.listStyle(.insetGrouped)
        }
    }
}

// MARK: - Search

/// `.searchable` only when the display config enables search (this tab's own list filter;
/// the floating search button searches the whole event); searches are counted by
/// `SearchUsageCounting`.
struct SearchableIf: ViewModifier {
    let enabled: Bool
    @Binding var text: String
    let prompt: String

    @ViewBuilder
    func body(content: Content) -> some View {
        if enabled {
            content
                // Under the navigation bar, never in the bottom toolbar: the bottom-trailing
                // corner belongs to the floating search button (ContentView).
                .searchable(text: $text, placement: .navigationBarDrawer, prompt: Text(prompt))
                .modifier(SearchUsageCounting(text: text, source: "tab"))
        } else {
            content
        }
    }
}

/// Counts a `search` (API-005, no detail) when a search is submitted or once a non-empty
/// query has settled for 1.5 s. Shared by the per-tab search fields and the search sheet.
/// Only the fact of a search is counted, never the text.
struct SearchUsageCounting: ViewModifier {
    let text: String
    /// `search.query` source: "sheet" or "tab".
    var source = "sheet"

    @Environment(AppState.self) private var appState
    /// The query last counted (kept on device only), so a submit and the settle timer count it once.
    @State private var countedQuery = ""

    private static let settleDelay: Duration = .milliseconds(1500)

    func body(content: Content) -> some View {
        content
            .onSubmit(of: .search) { countSearch() }
            .task(id: text) {
                guard !normalizedQuery.isEmpty else {
                    countedQuery = ""
                    return
                }
                try? await Task.sleep(for: Self.settleDelay)
                guard !Task.isCancelled else { return }
                countSearch()
            }
    }

    private var normalizedQuery: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func countSearch() {
        let query = normalizedQuery
        guard !query.isEmpty, query != countedQuery else { return }
        countedQuery = query
        // The text only in Debug/Dev builds; production logs its length.
        if AppLog.isEnabled(.debug), let index = appState.searchIndex {
            let started = ContinuousClock.now
            let results = index.search(query, now: .now).count
            let ms = (ContinuousClock.now - started).wholeMilliseconds
            AppLog.debug(.search, "search.query", "Search: \(results) results in \(ms) ms", LogRedaction.textFields(query).merging([
                "results": .int(results), "ms": .int(ms), "source": .string(source),
                "time_words": .bool(!EventSearch.parse(query).timeFilters.isEmpty),
            ]) { _, new in new })
        }
        appState.track(.search)
    }
}

// MARK: - Category chips

/// Category filter chips. Floating over the map they are Liquid Glass buttons (the
/// selected one tinted, `.glassProminent`); inside a list (content layer) they are
/// ordinary bordered capsules, since glass belongs to the controls layer.
struct CategoryChips: View {
    let categories: [String]
    @Binding var selection: String?
    /// True over the map; false inside the Locations list.
    var floating = false
    /// The "My Schedule" toggle chip (places in My schedule), first in the row (nil: not shown).
    /// Places and the Map always show it (their empty state explains it).
    var heartedOnly: Binding<Bool>? = nil

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            chipRow
                .padding(.horizontal)
                .padding(.vertical, 6)
        }
        .scrollClipDisabled()
        .accessibilityLabel("Filters")
    }

    @ViewBuilder
    private var chipRow: some View {
        if floating {
            GlassEffectContainer(spacing: 8) {
                chips
            }
        } else {
            chips
        }
    }

    private var chips: some View {
        HStack(spacing: 8) {
            if let heartedOnly {
                let isOn = heartedOnly.wrappedValue
                chip(MyScheduleText.title, systemImage: isOn ? "heart.fill" : "heart", isSelected: isOn) {
                    heartedOnly.wrappedValue.toggle()
                }
            }
            if !categories.isEmpty {
                chip("All", isSelected: selection == nil) { selection = nil }
                ForEach(categories, id: \.self) { category in
                    chip(category, isSelected: selection == category) {
                        selection = selection == category ? nil : category
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func chip(_ title: String, systemImage: String? = nil, isSelected: Bool, action: @escaping () -> Void) -> some View {
        let button = Button(action: action) {
            // Icon + full title, never truncated ("♥ Liked").
            HStack(spacing: 5) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .accessibilityHidden(true)
                }
                Text(title)
            }
            .font(.subheadline.weight(isSelected ? .semibold : .regular))
            .lineLimit(1)
            .fixedSize()
            // Over the map: primary text on the glass and white on the tinted selected chip,
            // so they read in light and dark mode (the tint on translucent glass didn't).
            .foregroundStyle(chipForeground(isSelected: isSelected))
        }
        .accessibilityLabel(title)
        .buttonBorderShape(.capsule)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        switch (floating, isSelected) {
        case (true, true):   button.buttonStyle(.glassProminent)
        case (true, false):  button.buttonStyle(.glass)
        case (false, true):  button.buttonStyle(.borderedProminent)
        case (false, false): button.buttonStyle(.bordered)
        }
    }

    private func chipForeground(isSelected: Bool) -> AnyShapeStyle {
        switch (floating, isSelected) {
        case (true, true):  return AnyShapeStyle(Color.white)
        case (true, false): return AnyShapeStyle(Color.primary)
        // In the list the system styles apply (tint text on bordered, white on prominent).
        case (false, true): return AnyShapeStyle(Color.white)
        case (false, false): return AnyShapeStyle(.tint)
        }
    }
}

// MARK: - Rows

/// Compact row with an optional thumbnail, what's on now / next there, the distance from the
/// user (with location permission) and a heart.
struct LocationRow: View {
    let location: Location
    let showImage: Bool
    var now: Date = .now

    var body: some View {
        HStack(spacing: 12) {
            if showImage {
                LocationImage(url: location.imageUrl)
                    .frame(width: 64, height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(location.name)
                    .font(.headline)
                if !location.snippet.isEmpty {
                    Text(location.snippet)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                LocationGlanceLine(location: location, now: now)
                DistanceBadge(target: location.coordinate)
            }
            Spacer(minLength: 0)
            HeartButton(target: .location(location.id))
        }
        .padding(.vertical, 4)
    }
}

/// Large card with a wide image.
struct LocationCard: View {
    let location: Location
    let showImage: Bool
    var now: Date = .now

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if showImage {
                LocationImage(url: location.imageUrl)
                    .frame(maxWidth: .infinity)
                    .frame(height: 180)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            }
            HStack(alignment: .firstTextBaseline) {
                Text(location.name)
                    .font(.title3.bold())
                Spacer(minLength: 0)
                HeartButton(target: .location(location.id))
            }
            if !location.snippet.isEmpty {
                Text(location.snippet)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
            LocationGlanceLine(location: location, now: now)
            HStack {
                if let category = location.category {
                    Text(category)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.tint)
                }
                Spacer(minLength: 0)
                DistanceBadge(target: location.coordinate)
            }
        }
        .padding(.vertical, 8)
    }
}

/// "Now: Prairie Lights · Next 8:30 Midnight Choir" for a location with schedule items.
struct LocationGlanceLine: View {
    let location: Location
    let now: Date

    @Environment(AppState.self) private var appState

    var body: some View {
        let glance = LocationGlance.make(locationId: location.id, schedule: appState.schedule, now: now)
        if let line = glance.rowLine(now: now, timeZone: appState.timeZone) {
            HStack(spacing: 6) {
                if glance.isLive {
                    Circle().fill(.red).frame(width: 7, height: 7).accessibilityHidden(true)
                }
                Text(line)
                    .lineLimit(1)
            }
            .font(.caption)
            .foregroundStyle(.tint)
        }
    }
}

/// Remote image with placeholder and failure states, from the offline cache when it has it.
struct LocationImage: View {
    let url: URL?

    var body: some View {
        if let url {
            CachedImage(url: url) { image in
                image.resizable().scaledToFill()
            } placeholder: { failed in
                if failed {
                    placeholder(systemImage: "photo")
                } else {
                    Color(.systemGray5).overlay(ProgressView())
                }
            }
        } else {
            placeholder(systemImage: "mappin")
        }
    }

    private func placeholder(systemImage: String) -> some View {
        Color(.systemGray5)
            .overlay(Image(systemName: systemImage).foregroundStyle(.secondary))
    }
}

// MARK: - Cached image

/// AsyncImage replacement backed by the offline cache (API-007): memory, then disk
/// (`ImageStore`, prefetched after every bundle), then the network (kept for next time).
/// Decoding and downsampling run off the main actor.
struct CachedImage<Content: View, Placeholder: View>: View {
    let url: URL
    private let content: (Image) -> Content
    private let placeholder: (_ failed: Bool) -> Placeholder

    @State private var loaded: LoadedImage?
    @State private var failedURL: URL?

    init(
        url: URL,
        @ViewBuilder content: @escaping (Image) -> Content,
        @ViewBuilder placeholder: @escaping (_ failed: Bool) -> Placeholder
    ) {
        self.url = url
        self.content = content
        self.placeholder = placeholder
    }

    var body: some View {
        // The memory cache answers synchronously, so scrolling back never flashes a placeholder.
        let image = loaded.flatMap { $0.url == url ? $0.image : nil } ?? ImageMemoryCache.shared.image(for: url)
        ZStack {
            if let image {
                content(Image(uiImage: image))
            } else {
                placeholder(failedURL == url)
            }
        }
        .task(id: url) { await load() }
    }

    private func load() async {
        let url = self.url
        if let hit = ImageMemoryCache.shared.image(for: url) {
            loaded = LoadedImage(url: url, image: hit)
            return
        }
        guard let data = await ImageStore.shared.data(for: url),
              let image = await ImageDecoding.decode(data) else {
            if !Task.isCancelled { failedURL = url }
            return
        }
        ImageMemoryCache.shared.insert(image, for: url)
        guard !Task.isCancelled else { return }
        loaded = LoadedImage(url: url, image: image)
        failedURL = nil
    }
}

private struct LoadedImage {
    let url: URL
    let image: UIImage
}

enum ImageDecoding {
    /// Large enough for a full-width hero on the widest iPhone display; smaller originals stay as they are.
    static let maxPixelSize = 2400

    /// Decodes and downsamples (ImageIO) off the main actor. nil for data that isn't an image.
    static func decode(_ data: Data) async -> UIImage? {
        let maxPixelSize = ImageDecoding.maxPixelSize
        return await Task.detached(priority: .userInitiated) { () -> UIImage? in
            let sourceOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]
            guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions as CFDictionary) else { return nil }
            let thumbnailOptions: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            ]
            guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) else { return nil }
            // Decoded here too, not at first draw on the main thread (perf, batch 7).
            let image = UIImage(cgImage: cgImage)
            return image.preparingForDisplay() ?? image
        }.value
    }
}

// MARK: - Location Detail

struct LocationDetailView: View {
    let location: Location

    @Environment(AppState.self) private var appState
    /// The container's width: two columns from `DetailColumns.minWidth`.
    @State private var width: CGFloat = 0

    var body: some View {
        // TimelineView drives live countdown labels every 30 s across the whole page.
        TimelineView(.periodic(from: .now, by: 30)) { context in
            detailContent(now: context.date)
        }
        .navigationTitle(location.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // The header card shows the name (batch 7): the title stays for Back and VoiceOver.
            ToolbarItem(placement: .principal) { Color.clear.frame(width: 1, height: 1).accessibilityHidden(true) }
            HeartToolbarItem(target: .location(location.id), appState: appState)
            if location.coordinate != nil, appState.shows(.map) {
                ToolbarSpacer(.fixed, placement: .topBarTrailing)
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        // Also closes the search sheet when the detail was opened from search.
                        appState.showOnMap(locationId: location.id)
                    } label: {
                        // Icon and title: bars show the icon, vertical bars and accessibility use the title.
                        Label("Show on Map", systemImage: "map")
                    }
                }
            }
        }
        // Counted for every route here: the list, a map pin, a schedule item (API-005).
        .task(id: location.id) { appState.track(.locationView, id: location.id) }
        .usesUserLocation(heading: true)
    }

    /// API-024: the sections the event's `place_detail` layout lists (or the built-in default,
    /// today's screen), in order; each draws only when the place has its data. The header's image
    /// always sits at the top, full width.
    private func detailContent(now: Date) -> some View {
        let within = location.coordinate.flatMap { appState.userLocation.direction(to: $0)?.meters }.map { $0 <= 8_000 } ?? false
        let sections = appState.screenSections(.placeDetail, now: now, subject: ScreenFacts.subject(location)) { bundle, state in
            var walking = state
            walking.withinWalk = within
            return ScreenFacts.place(location, bundle, walking)
        }
        let header = sections.first { $0.type == "header" }
        let columns = DetailColumns.split(sections, screen: .placeDetail, width: Double(width))
        return ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if let header, header.shows("image"), let url = location.imageUrl {
                    LocationImage(url: url)
                        .frame(maxWidth: .infinity)
                        .frame(height: 240)
                        .clipped()
                        // Mirrors and blurs the image into the area under the bars
                        // and beside it in wide layouts, instead of a hard edge.
                        .backgroundExtensionEffect()
                        .overlay(alignment: .bottomTrailing) {
                            PhotoCreditLine(credit: location.imageCredit, attributionURL: location.imageAttributionUrl)
                        }
                }

                if let columns {
                    // Wide (iPhone Duo unfolded): header and walk map leading, details trailing.
                    // Equal margins from the edges and the fold, both columns from the same top (batch 7).
                    HStack(alignment: .top, spacing: 48) {
                        sectionColumn(columns.leading, now: now)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                        sectionColumn(columns.trailing, now: now)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 16)
                    .padding(.bottom, 24)
                } else {
                    // Little content on a wide window: one readable column, centred (batch 7).
                    sectionColumn(sections, now: now)
                        .padding(.horizontal)
                        .padding(.vertical, 16)
                        .padding(.bottom, 24)
                        .frame(maxWidth: width >= 700 ? 680 : .infinity)
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }

    private func sectionColumn(_ sections: [LayoutSection], now: Date) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(sections.enumerated()), id: \.element.type) { index, section in
                if Self.dividerBefore(section, previous: index > 0 ? sections[index - 1] : nil) {
                    Divider()
                }
                self.section(section, now: now)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    /// The place's context parts (hours, good to know, menu, links) are one group: a divider
    /// before the group, before About and before the schedule, as on the fixed screen.
    private static let contextGroup: Set<String> = ["hours", "good_to_know", "menu", "links"]

    private static func dividerBefore(_ section: LayoutSection, previous: LayoutSection?) -> Bool {
        guard let previous else { return false }
        switch section.type {
        case "about", "at_this_location", "now_next": return true
        default:
            return contextGroup.contains(section.type) && !contextGroup.contains(previous.type) && previous.type != "about"
        }
    }

    @ViewBuilder
    private func section(_ section: LayoutSection, now: Date) -> some View {
        switch section.type {
        case "header": header(section, now: now)
        case "walk_map": walkMap
        case "directions":
            if location.coordinate != nil { directionsButton }
        // "ask_about": removed Nov 21, 2026 (no Ask About This); older layouts draw nothing.
        case "about":
            if let title = section.title {
                Text(title).font(.title3.bold())
            }
            // The description and API-018's about, once (`AboutText`).
            let about = AboutText.merged(description: location.description, about: location.context?.about)
            if !about.isEmpty {
                Text(about).font(.body)
            }
        case "hours":
            if let hours = location.context?.hours, !hours.isEmpty { PlaceHoursLine(hours: hours) }
        case "good_to_know":
            if let context = location.context { PlaceFactsLines(context: context) }
        case "menu":
            if let menu = location.context?.menu, !menu.isEmpty { MenuList(menu: menu, title: section.title) }
        case "links":
            PlaceLinks(links: location.context?.links ?? [], website: location.website)
        case "now_next":
            NowNextStrip(locationId: location.id)
        case "at_this_location": atThisLocation(section, now: now)
        default:
            EmptyView()
        }
    }

    private func header(_ section: LayoutSection, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(location.name).font(.title2.bold())

            if section.shows("category"), let category = location.category {
                Text(category)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.tint)
            }

            if section.shows("tags"), !location.tags.isEmpty {
                // Lower case from the server (API-010), capitalised for display.
                Text(TagText.line(location.tags))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            if section.shows("address"), !location.address.isEmpty {
                Text(location.address)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            if section.shows("distance") {
                DistanceBadge(target: location.coordinate, font: .subheadline)
            }

            if section.shows("now_next") {
                LocationGlanceLine(location: location, now: now)
            }
        }
    }

    /// Within walking range: a small map with the walk (route or dashed estimate), the user and
    /// the pin, plus Directions. Farther away, without a position or in screenshot mode: the big
    /// button.
    @ViewBuilder
    private var walkMap: some View {
        if let destination = location.coordinate {
            if let user = appState.userLocation.location,
               PlaceWalkMap.shows(
                   distanceMeters: appState.userLocation.direction(to: destination)?.meters,
                   screenshotMode: ScreenshotMode.isActive
               ) {
                PlaceWalkMapCard(location: location, user: user, destination: destination)
            } else {
                directionsButton
            }
        }
    }

    private var directionsButton: some View {
        Button {
            WalkingDirections.open(to: location)
        } label: {
            Label("Get Walking Directions", systemImage: "figure.walk")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.glassProminent)
        .controlSize(.large)
    }

    @ViewBuilder
    private func atThisLocation(_ section: LayoutSection, now: Date) -> some View {
        let items = appState.scheduleItems(at: location.id)
        if !items.isEmpty {
            Text(section.title ?? "At This Location")
                .font(.title3.bold())
                .padding(.top, 4)

            ForEach(items) { item in
                LocationScheduleRow(item: item, now: now, timeZone: appState.timeZone)
                if item.id != items.last?.id {
                    Divider().padding(.vertical, 2)
                }
            }
        }
    }
}

// MARK: - Walking map inside Location Detail

/// The walk to a place, inline in its detail: the route (`WalkingRouteProvider`, cached until
/// the user moves > 50 m) or a dashed straight line, the user's dot and the place's pin, framed
/// to fit; "12 min walk · 0.6 mi" / "about 8 min walk" and a Directions button (Apple Maps,
/// walking). Not interactive inside the scroll view: a tap opens the Map tab on the place (when
/// the event shows it). The detail's `usesUserLocation` keeps the position fresh only while it
/// is on screen.
private struct PlaceWalkMapCard: View {
    let location: Location
    let user: Coordinate
    let destination: Coordinate

    @Environment(AppState.self) private var appState
    @State private var position: MapCameraPosition = .automatic

    private struct WalkRequest: Equatable {
        var locationId: Int
        var user: Coordinate
        var destination: Coordinate
    }

    var body: some View {
        let loaded = appState.walkingRoutes.route(for: location.id, from: user)
        // Until the route arrives (or fails) the text is the straight-line estimate.
        let walk = loaded ?? WalkRoute.make(
            locationId: location.id, origin: user, destination: destination,
            routePoints: nil, routeSeconds: nil, routeMeters: nil
        )
        let line = loaded?.linePoints ?? []
        let region = PlaceWalkMap.region(user: user, destination: destination, line: line)
        VStack(alignment: .leading, spacing: 10) {
            Map(position: $position, interactionModes: []) {
                if let loaded {
                    if loaded.isEstimate {
                        MapPolyline(coordinates: line.map(\.clCoordinate))
                            .stroke(.tint, style: StrokeStyle(lineWidth: 4, lineCap: .round, dash: [2, 8]))
                    } else {
                        MapPolyline(coordinates: line.map(\.clCoordinate))
                            .stroke(.tint, lineWidth: 5)
                    }
                }
                Marker(location.name, coordinate: destination.clCoordinate)
                UserAnnotation { user in HeadingUserDot(heading: user.heading) }
            }
            .mapStyle(.standard(pointsOfInterest: .excludingAll))
            // No system map controls on small maps (their Liquid Glass compass / scale could
            // float as an empty glass circle over the card).
            .mapControls { }
            .frame(height: 190)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .contentShape(RoundedRectangle(cornerRadius: 16))
            .onTapGesture {
                if appState.shows(.map) { appState.showOnMap(locationId: location.id) }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Map of the walk to \(location.name)")
            .accessibilityHint(appState.shows(.map) ? "Opens the Map tab on this place." : "")
            .accessibilityAddTraits(appState.shows(.map) ? .isButton : [])

            HStack(spacing: 12) {
                Label(walk.text(imperial: DistanceText.usesImperial()), systemImage: "figure.walk")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Button {
                    WalkingDirections.open(to: location)
                } label: {
                    Label("Directions", systemImage: "arrow.triangle.turn.up.right.diamond.fill")
                }
                .buttonStyle(.glassProminent)
                .controlSize(.small)
                .accessibilityHint("Opens walking directions in Maps.")
            }
        }
        .onAppear { if let region { position = .region(region.mkRegion) } }
        .onChange(of: region) { _, new in
            guard let new else { return }
            withAnimation { position = .region(new.mkRegion) }
        }
        // The walking route (MKDirections), reused while the user stays within 50 m.
        .task(id: WalkRequest(locationId: location.id, user: user, destination: destination)) {
            await appState.walkingRoutes.load(locationId: location.id, from: user, to: destination)
        }
    }
}

// MARK: - Schedule row inside Location Detail

private struct LocationScheduleRow: View {
    let item: ScheduleItem
    let now: Date
    let timeZone: TimeZone

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(EventTimeFormat.range(start: item.startTime, end: item.endTime, in: timeZone, now: now))
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Spacer()
                if let relative = RelativeTimeText.item(item, now: now, timeZone: timeZone) {
                    Text(relative)
                        .font(.caption)
                        .fontWeight(.bold)
                        .foregroundStyle(ScheduleTiming.hasEnded(item, at: now) ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
                }
            }
            if let progress = ScheduleTiming.progress(item, at: now) {
                ItemProgressBar(progress: progress)
            }
            HStack(alignment: .firstTextBaseline) {
                Text(item.name).font(.headline)
                Spacer(minLength: 0)
                HeartButton(target: .scheduleItem(item.id), font: .subheadline)
            }
            if !item.description.isEmpty {
                Text(item.description)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 6)
    }
}

#Preview {
    LocationsTab()
        .environment(AppState())
}

// MARK: - Photo credit (API-022 / API-031)

/// The small credit on a large place photo: `image_credit`, or for a live Google photo the
/// authors' names fetched from `image_attribution_url` (linked to their profiles), shown over the
/// photo's bottom-trailing corner on a dark scrim so it stays readable. Nothing without a credit.
struct PhotoCreditLine: View {
    let credit: String?
    let attributionURL: URL?

    @State private var attribution: PhotoAttribution?

    var body: some View {
        if let line = attribution?.linkedCredit ?? credit.map({ AttributedString($0) }) {
            Text(line)
                .font(.caption2)
                .foregroundStyle(.white)
                .tint(.white)
                .lineLimit(2)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.black.opacity(0.55), in: .rect(cornerRadius: 8))
                .padding(8)
                .task(id: attributionURL) {
                    attribution = nil
                    guard let url = attributionURL, let data = await ImageStore.httpCached(url) else { return }
                    attribution = PhotoAttribution.decode(data)
                }
        }
    }
}
