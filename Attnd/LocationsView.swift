// LocationsView.swift
// Attnd
//
// Locations tab. A NavigationSplitView: list → detail side by side on regular
// width (unfolded iPhone Duo, iPad), collapsing to a push stack on compact width.
//
// Display config: `locations_style` (cards / list / grouped by category),
// `show_location_images`, `enable_search` and `group_by_category` (filter chips).

import SwiftUI
import MapKit

// MARK: - Tab

struct LocationsTab: View {
    @Environment(AppState.self) private var appState
    @State private var selection: Location?

    var body: some View {
        NavigationSplitView {
            LocationsView(selection: $selection)
                .eventStatusBanners()
        } detail: {
            NavigationStack {
                if let selection, let location = appState.location(id: selection.id) {
                    LocationDetailView(location: location)
                } else {
                    ContentUnavailableView("Select a Location", systemImage: "mappin.and.ellipse")
                }
            }
        }
        .onChange(of: appState.locations) {
            // Drop a selection the organizer removed.
            if let id = selection?.id, appState.location(id: id) == nil { selection = nil }
        }
    }
}

// MARK: - List

struct LocationsView: View {
    @Binding var selection: Location?

    @Environment(AppState.self) private var appState
    @State private var searchText = ""
    @State private var selectedCategory: String?

    private var display: DisplayConfig { appState.display }

    private var filtered: [Location] {
        LocationGrouping.filter(appState.locations, category: selectedCategory)
            .filter { SearchMatching.matches($0, query: searchText) }
    }

    var body: some View {
        let locations = filtered
        List(selection: $selection) {
            if !appState.filterCategories.isEmpty {
                CategoryChips(categories: appState.filterCategories, selection: $selectedCategory)
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            }
            switch display.locationsStyle {
            case .grouped:
                ForEach(LocationGrouping.byCategory(locations, categoryOrder: appState.categories)) { section in
                    Section(section.title) {
                        rows(section.locations)
                    }
                }
            case .list, .cards:
                rows(locations)
            }
        }
        .modifier(LocationsListStyle(isCards: display.locationsStyle == .cards))
        .navigationTitle("Locations")
        .modifier(SearchableIf(enabled: display.enableSearch, text: $searchText, prompt: "Search locations"))
        .refreshable { await appState.refreshBundle() }
        .overlay {
            if locations.isEmpty {
                if !searchText.isEmpty {
                    ContentUnavailableView.search(text: searchText)
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
    private func rows(_ locations: [Location]) -> some View {
        ForEach(locations) { location in
            NavigationLink(value: location) {
                if display.locationsStyle == .cards {
                    LocationCard(location: location, showImage: display.showLocationImages)
                } else {
                    LocationRow(location: location, showImage: display.showLocationImages)
                }
            }
            .listRowSeparator(display.locationsStyle == .cards ? .hidden : .automatic)
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

/// `.searchable` only when the display config enables search.
struct SearchableIf: ViewModifier {
    let enabled: Bool
    @Binding var text: String
    let prompt: String

    @ViewBuilder
    func body(content: Content) -> some View {
        if enabled {
            content.searchable(text: $text, prompt: Text(prompt))
        } else {
            content
        }
    }
}

// MARK: - Category chips

struct CategoryChips: View {
    let categories: [String]
    @Binding var selection: String?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip("All", isSelected: selection == nil) { selection = nil }
                ForEach(categories, id: \.self) { category in
                    chip(category, isSelected: selection == category) {
                        selection = selection == category ? nil : category
                    }
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 6)
        }
        .accessibilityLabel("Filter by category")
    }

    private func chip(_ title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(isSelected ? .semibold : .regular))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
        .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
        .background {
            Capsule().fill(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.regularMaterial))
        }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - Rows

/// Compact row with an optional thumbnail.
struct LocationRow: View {
    let location: Location
    let showImage: Bool

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
            }
        }
        .padding(.vertical, 4)
    }
}

/// Large card with a wide image.
struct LocationCard: View {
    let location: Location
    let showImage: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if showImage {
                LocationImage(url: location.imageUrl)
                    .frame(maxWidth: .infinity)
                    .frame(height: 180)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            }
            Text(location.name)
                .font(.title3.bold())
            if !location.snippet.isEmpty {
                Text(location.snippet)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
            if let category = location.category {
                Text(category)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.tint)
            }
        }
        .padding(.vertical, 8)
    }
}

/// Remote image with placeholder and failure states.
struct LocationImage: View {
    let url: URL?

    var body: some View {
        if let url {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFill()
                case .failure:
                    placeholder(systemImage: "photo")
                default:
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

                    if !location.address.isEmpty {
                        Text(location.address)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    if let coordinate = location.coordinate {
                        Button {
                            openWalkingDirections(to: coordinate)
                        } label: {
                            Label("Get Walking Directions", systemImage: "figure.walk")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
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
                if ScheduleTiming.isHappening(item, at: now) {
                    Text("Now")
                        .font(.caption.bold())
                        .foregroundStyle(.tint)
                } else if let countdown = item.startsInText(relativeTo: now) {
                    Text(countdown)
                        .font(.caption)
                        .fontWeight(.bold)
                        .foregroundStyle(.tint)
                }
            }
            Text(item.name).font(.headline)
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
