// LocationsView.swift
// Attnd
//
// Locations tab. A NavigationSplitView: list → detail side by side on regular
// width (unfolded iPhone Duo, landscape Pro Max), collapsing to a push stack on compact width.
//
// Display config: `locations_style` (cards / list / grouped by category),
// `show_location_images`, `enable_search` and `group_by_category` (filter chips).

import ImageIO
import SwiftUI
import UIKit
import MapKit

// MARK: - Tab

struct LocationsTab: View {
    @Environment(AppState.self) private var appState
    @State private var selection: Location?

    var body: some View {
        NavigationSplitView {
            LocationsView(selection: $selection)
                .eventStatusBanners()
                .optionsToolbarItem()
        } detail: {
            NavigationStack {
                if let selection, let location = appState.location(id: selection.id) {
                    LocationDetailView(location: location)
                } else {
                    ContentUnavailableView("Select a Location", systemImage: "list.bullet")
                }
            }
        }
        .onChange(of: appState.locations) {
            // Drop a selection the organizer removed.
            if let id = selection?.id, appState.location(id: id) == nil { selection = nil }
            selectScreenshotLocationIfNeeded()
        }
        .onAppear(perform: selectScreenshotLocationIfNeeded)
        // A jump from search, Siri or Spotlight (AppState.navigate).
        .onChange(of: appState.focusRequest, initial: true) {
            guard case .location(let id)? = appState.focusRequest, let location = appState.location(id: id) else { return }
            appState.focusRequest = nil
            selection = location
        }
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

    @Environment(AppState.self) private var appState
    @State private var searchText = ""
    @State private var selectedCategory: String?
    /// The "Hearted" chip: only hearted locations.
    @State private var heartedOnly = false

    private var display: DisplayConfig { appState.display }

    private var filtered: [Location] {
        LocationGrouping.filter(appState.locations, category: selectedCategory)
            .filter { !heartedOnly || appState.isHearted(.location($0.id)) }
            .filter { SearchMatching.matches($0, query: searchText) }
    }

    /// The Hearted chip appears once something is hearted (or while it is on).
    private var showsHeartedChip: Bool { appState.hasHearts || heartedOnly }

    var body: some View {
        let locations = filtered
        // Re-evaluated every minute for the "Now: … · Next …" lines.
        TimelineView(.periodic(from: .now, by: 60)) { context in
            list(locations, now: context.date)
        }
        .navigationTitle("Locations")
        .modifier(SearchableIf(enabled: display.enableSearch, text: $searchText, prompt: "Search locations"))
        .refreshable { await appState.pullToRefresh() }
        .usesUserLocation(heading: true)
    }

    private func list(_ locations: [Location], now: Date) -> some View {
        List(selection: $selection) {
            if !appState.filterCategories.isEmpty || showsHeartedChip {
                CategoryChips(
                    categories: appState.filterCategories,
                    selection: $selectedCategory,
                    heartedOnly: showsHeartedChip ? $heartedOnly : nil
                )
                .listRowInsets(EdgeInsets())
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            }
            switch display.locationsStyle {
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
        .modifier(LocationsListStyle(isCards: display.locationsStyle == .cards))
        // Siri on-screen awareness: the rows are LocationEntity values.
        .onScreenEntities(forSelectionType: Location.self) { .location($0.id) }
        .overlay {
            if locations.isEmpty {
                if !searchText.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                } else if heartedOnly {
                    ContentUnavailableView(
                        "No Hearted Places",
                        systemImage: "heart",
                        description: Text("Tap the heart on a place to keep it here.")
                    )
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
        ForEach(locations) { location in
            NavigationLink(value: location) {
                if display.locationsStyle == .cards {
                    LocationCard(location: location, showImage: display.showLocationImages, now: now)
                } else {
                    LocationRow(location: location, showImage: display.showLocationImages, now: now)
                }
            }
            .listRowSeparator(display.locationsStyle == .cards ? .hidden : .automatic)
            .locationPeek(location, now: now) { selection = location }
        }
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
                Label(hearted ? "Remove Heart" : "Heart", systemImage: hearted ? "heart.slash" : "heart")
            }
            if location.coordinate != nil, appState.tabs.contains(.map) {
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
    /// The "Hearted" toggle chip, first in the row (nil: not shown).
    var heartedOnly: Binding<Bool>? = nil
    /// The Schedule tab's "My plan" toggle chip (spec §6), before Hearted (nil: not shown).
    var myPlan: Binding<Bool>? = nil

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
            if let myPlan {
                let isOn = myPlan.wrappedValue
                chip("My plan", systemImage: "list.bullet.clipboard", isSelected: isOn) {
                    myPlan.wrappedValue.toggle()
                }
            }
            if let heartedOnly {
                let isOn = heartedOnly.wrappedValue
                chip("Hearted", systemImage: isOn ? "heart.fill" : "heart", isSelected: isOn) {
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
            Group {
                if let systemImage {
                    Label(title, systemImage: systemImage)
                } else {
                    Text(title)
                }
            }
            .font(.subheadline.weight(isSelected ? .semibold : .regular))
        }
        .buttonBorderShape(.capsule)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        switch (floating, isSelected) {
        case (true, true):   button.buttonStyle(.glassProminent)
        case (true, false):  button.buttonStyle(.glass)
        case (false, true):  button.buttonStyle(.borderedProminent)
        case (false, false): button.buttonStyle(.bordered)
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
            return UIImage(cgImage: cgImage)
        }.value
    }
}

// MARK: - Location Detail

struct LocationDetailView: View {
    let location: Location

    @Environment(AppState.self) private var appState

    var body: some View {
        // TimelineView drives live countdown labels every 30 s across the whole page.
        TimelineView(.periodic(from: .now, by: 30)) { context in
            detailContent(now: context.date)
        }
        .navigationTitle(location.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            HeartToolbarItem(target: .location(location.id), appState: appState)
            if location.coordinate != nil, appState.tabs.contains(.map) {
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
        // Siri on-screen awareness ("when does this open?", "share this").
        .onScreenEntity(.location(location.id))
        // Counted for every route here: the list, a map pin, a schedule item (API-005).
        .task(id: location.id) { appState.track(.locationView, id: location.id) }
        .usesUserLocation(heading: true)
    }

    @ViewBuilder
    private func detailContent(now: Date) -> some View {
        let items = appState.scheduleItems(at: location.id)
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if let url = location.imageUrl {
                    LocationImage(url: url)
                        .frame(maxWidth: .infinity)
                        .frame(height: 240)
                        .clipped()
                        // Mirrors and blurs the image into the area under the bars
                        // and beside it in wide layouts, instead of a hard edge.
                        .backgroundExtensionEffect()
                }

                VStack(alignment: .leading, spacing: 12) {
                    Text(location.name).font(.title2.bold())

                    if let category = location.category {
                        Text(category)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.tint)
                    }

                    if !location.tags.isEmpty {
                        // Lower case from the server (API-010), capitalised for display.
                        Text(TagText.line(location.tags))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    if !location.address.isEmpty {
                        Text(location.address)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    DistanceBadge(target: location.coordinate, font: .subheadline)

                    LocationGlanceLine(location: location, now: now)

                    if let coordinate = location.coordinate {
                        Button {
                            openWalkingDirections(to: coordinate)
                        } label: {
                            Label("Get Walking Directions", systemImage: "figure.walk")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.glassProminent)
                        .controlSize(.large)
                    }

                    if !location.description.isEmpty {
                        Divider()
                        Text(location.description).font(.body)
                    }

                    if let website = location.website {
                        Link("Visit Website", destination: website)
                            .font(.subheadline)
                    }

                    if !items.isEmpty {
                        Divider()
                        Text("At This Location")
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
                .padding(.horizontal)
                .padding(.vertical, 16)
                .padding(.bottom, 24)
            }
        }
    }

    private func openWalkingDirections(to coordinate: Coordinate) {
        let mapItem = MKMapItem(
            location: CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude),
            address: nil
        )
        mapItem.name = location.name
        mapItem.openInMaps(launchOptions: [
            MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeWalking
        ])
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
