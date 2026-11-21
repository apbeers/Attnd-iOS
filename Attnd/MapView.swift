// MapView.swift
// Attnd
//
// The event map. Honours the display config: `map_fit_all` (initial framing),
// `map_clustering` (grid clustering by zoom level, see MapClustering) and
// `group_by_category` (category chips). Locations without coordinates get no pin.
//
// Floating overlays (category chips, map buttons, the selected-location card) are
// laid out with ReservedRegionAvoiding so they stay clear of the fold and camera
// housings on foldables. The tab's floating button (My plan / search, `FloatingTabButton`) is the
// last element of the same overlay column (`showsFloatingButton`, phones): the map buttons, then
// the selected-location card, then the floating button, so they never overlap. (The generic
// `floatingActionButton()` modifier relies on extra bottom safe area, which the map's overlay
// doesn't receive.) With the side pane (wide layouts) the button sits over the whole arrangement.
//
// Glance (Glance.swift): a live dot / "Next 7:30" over pins with something on now or soon, a
// "now playing" strip under the chips, a Liked chip (always shown; with nothing liked it shows
// an empty state over the map), and for the selected pin the distance,
// a heart and — within walking range — a walking route ("12 min walk · 0.6 mi"; a dashed
// straight line + "about 8 min walk" when there is no believable route). Location and compass
// run only while a pin is selected. Navigation is never started (Directions stays in the detail).

import SwiftUI
import MapKit
import UIKit

struct MapView: View {
    @Binding var cameraPosition: MapCameraPosition
    /// Whether the initial framing has been applied (owned by MapTab so it survives layout changes).
    @Binding var hasPositioned: Bool
    /// The tab's floating button at the bottom of the map's trailing column (no side pane).
    var showsFloatingButton = false

    @Environment(AppState.self) private var appState
    @StateObject private var locationManager = LocationPermissionManager()
    @State private var showLocationDeniedAlert = false

    @State private var selectedLocationId: Int?
    @State private var selectedCategory: String?
    /// The "Liked" chip: only liked (hearted) pins.
    @State private var heartedOnly = false
    /// Refreshed every 30 s for the live dots, "Next 7:30" and the now-playing strip.
    @State private var now = Date.now
    /// Visible span, for clustering. Updated when the camera stops moving.
    @State private var visibleSpan = MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)

    private var visibleLocations: [Location] {
        LocationGrouping.filter(appState.locations, category: selectedCategory)
            .filter { !heartedOnly || appState.isHearted(.location($0.id)) }
    }

    /// Screenshot mode keeps the App Store map clean.
    private var showsGlance: Bool { !ScreenshotMode.isActive }

    /// The walk to the selected pin: needs location permission and the user within ~8 km.
    private var walkRequest: WalkRequest? {
        guard let location = selectedLocation, let destination = location.coordinate,
              let direction = appState.userLocation.direction(to: destination),
              let user = appState.userLocation.location,
              !direction.isHere, WalkTime.isWithinWalkingRange(direction.meters) else { return nil }
        return WalkRequest(locationId: location.id, user: user, destination: destination)
    }

    private struct WalkRequest: Equatable {
        var locationId: Int
        var user: Coordinate
        var destination: Coordinate
    }

    private var currentWalk: WalkRoute? {
        guard let request = walkRequest else { return nil }
        return appState.walkingRoutes.route(for: request.locationId, from: request.user)
    }

    private var clusters: [MapCluster] {
        if appState.display.mapClustering {
            return MapClustering.clusters(
                for: visibleLocations,
                latitudeDelta: visibleSpan.latitudeDelta,
                longitudeDelta: visibleSpan.longitudeDelta
            )
        }
        return MapClustering.unclustered(visibleLocations)
    }

    private var selectedLocation: Location? { appState.location(id: selectedLocationId) }

    var body: some View {
        let allClusters = self.clusters
        let walk = currentWalk
        let glances = showsGlance ? LocationGlance.all(schedule: appState.schedule, now: now) : [:]
        let badges = allClusters.filter(\.isSingle).compactMap { cluster -> PinBadge? in
            let location = cluster.locations[0]
            guard let glance = glances[location.id] else { return nil }
            let subtitle = glance.pinSubtitle(now: now, timeZone: appState.timeZone)
            guard glance.isLive || subtitle != nil else { return nil }
            return PinBadge(locationId: location.id, coordinate: cluster.coordinate, isLive: glance.isLive, subtitle: subtitle)
        }
        Map(position: $cameraPosition, selection: $selectedLocationId) {
            if let walk {
                if walk.isEstimate {
                    MapPolyline(coordinates: walk.linePoints.map(\.clCoordinate))
                        .stroke(.tint, style: StrokeStyle(lineWidth: 4, lineCap: .round, dash: [2, 8]))
                } else {
                    MapPolyline(coordinates: walk.linePoints.map(\.clCoordinate))
                        .stroke(.tint, lineWidth: 5)
                }
            }
            ForEach(allClusters.filter(\.isSingle)) { cluster in
                Marker(cluster.locations[0].name, coordinate: cluster.coordinate.clCoordinate)
                    .tag(cluster.locations[0].id)
            }
            // Live dot / "Next 7:30" floating just above the pin's balloon (not selectable).
            ForEach(badges) { badge in
                Annotation("", coordinate: badge.coordinate.clCoordinate, anchor: .bottom) {
                    PinGlanceBadge(isLive: badge.isLive, subtitle: badge.subtitle)
                        .padding(.bottom, badge.locationId == selectedLocationId ? 66 : 42)
                }
                .annotationTitles(.hidden)
            }
            ForEach(allClusters.filter { !$0.isSingle }) { cluster in
                Annotation("\(cluster.locations.count) places", coordinate: cluster.coordinate.clCoordinate) {
                    ClusterBadge(count: cluster.locations.count) {
                        zoom(into: cluster)
                    }
                }
            }
            if appState.showUserLocation {
                UserAnnotation()
            }
        }
        .mapStyle(.standard)
        .onMapCameraChange(frequency: .onEnd) { context in
            visibleSpan = context.region.span
            MapRenderTiming.cameraSettled(pins: allClusters.count, clustered: appState.display.mapClustering)
        }
        .navigationTitle(appState.currentEvent?.name ?? "Map")
        .navigationBarTitleDisplayMode(.inline)
        // Place details pushed over the map (`AppState.mapNavigation.path`, location ids).
        .navigationDestination(for: Int.self) { locationId in
            if let location = appState.location(id: locationId) {
                LocationDetailView(location: location)
            } else {
                ContentUnavailableView("Place Not Found", systemImage: "mappin.slash")
            }
        }
        .onAppear {
            MapRenderTiming.appeared()
            positionInitiallyIfNeeded()
        }
        .onChange(of: appState.locations) { positionInitiallyIfNeeded() }
        .onChange(of: appState.mapCenterToken) { recenter() }
        // initial: a "Show on Map" from another tab may arrive before this view exists.
        // "Show on Map" from a detail pushed over this map pops it first (MapNavigation).
        .onChange(of: appState.mapFocusLocationId, initial: true) { _, requested in
            guard requested != nil, let id = appState.mapNavigation.takeFocus() else { return }
            focus(on: id)
        }
        .onChange(of: selectedCategory) { dropHiddenSelection() }
        .onChange(of: heartedOnly) { dropHiddenSelection() }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled else { break }
                now = .now
            }
        }
        // The walking route for the selected pin (cached until the user moves > 50 m).
        .task(id: walkRequest) {
            guard let request = walkRequest else { return }
            await appState.walkingRoutes.load(locationId: request.locationId, from: request.user, to: request.destination)
        }
        // Position + compass only while the selected-location card shows distance and route.
        .usesUserLocation(heading: true, active: selectedLocationId != nil)
        .overlay {
            ReservedRegionAvoiding {
                overlayContent
            }
        }
        .alert("Location Access Denied", isPresented: $showLocationDeniedAlert) {
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Enable location access in Settings to show your position on the map.")
        }
    }

    // MARK: - Overlays

    private var overlayContent: some View {
        let nowPlaying = showsGlance ? NowPlayingItem.items(schedule: appState.schedule, locations: visibleLocations, now: now) : []
        // The Liked chip is always there, so the chip row always is.
        return VStack(spacing: 0) {
            CategoryChips(
                categories: appState.filterCategories,
                selection: $selectedCategory,
                floating: true,
                heartedOnly: $heartedOnly
            )
            if !nowPlaying.isEmpty {
                NowPlayingStrip(items: nowPlaying) { locationId in
                    focus(on: locationId)
                }
            }
            Spacer(minLength: 0)
            if heartedOnly, visibleLocations.isEmpty {
                // The Liked chip with nothing liked (or no liked place with a pin).
                NothingLikedView(hasLikes: appState.locations.contains { appState.isHearted(.location($0.id)) })
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 8)
                    .glassEffect(.regular, in: .rect(cornerRadius: 24))
                    .frame(maxWidth: 420)
                    .padding(.horizontal, 24)
                    .allowsHitTesting(false)
                Spacer(minLength: 0)
            }
            HStack {
                Spacer()
                MapButtonStack(
                    onCenter: recenter,
                    onLocation: { Task { await zoomToUserLocation() } }
                )
                .padding(.horizontal)
                .padding(.vertical, showsFloatingButton ? 8 : 16)
            }
            if let location = selectedLocation {
                LocationInfoCard(location: location, walkText: walkCardText) {
                    appState.mapNavigation.open(location.id)
                }
                .frame(maxWidth: 480)
                .padding(.horizontal)
                .padding(.bottom, 8)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if showsFloatingButton {
                // One trailing column: map buttons, (card), then My plan / search, centred
                // under the 44 pt map buttons.
                HStack(spacing: 0) {
                    Spacer(minLength: 0)
                    FloatingTabButton()
                        .padding(.trailing, FloatingSearchButtonMetrics.trailingPadding)
                }
                .padding(.bottom, FloatingSearchButtonMetrics.bottomPadding)
            }
        }
        // Clear the floating demo / ended / offline badges (eventStatusBanners(reservesSpace: false)).
        .padding(.top, 8 + EventStatusBadgeKind.reservedTopHeight(appState))
        .animation(.spring(duration: 0.3), value: selectedLocationId)
        .animation(.easeInOut, value: nowPlaying.map(\.id))
    }

    /// "12 min walk · 0.6 mi", or "about 8 min walk" without a believable route.
    private var walkCardText: String? {
        currentWalk?.text(imperial: DistanceText.usesImperial())
    }

    private func dropHiddenSelection() {
        if let id = selectedLocationId, !visibleLocations.contains(where: { $0.id == id }) {
            selectedLocationId = nil
        }
    }

    // MARK: - Camera

    private var initialRegion: MapRegionSpec? {
        MapRegionMath.initialRegion(
            fitAll: appState.display.mapFitAll,
            event: appState.currentEvent?.coordinate,
            locations: visibleLocations.compactMap(\.coordinate)
        )
    }

    /// Frames the map once; re-frames when the pins first arrive with the bundle.
    private func positionInitiallyIfNeeded() {
        guard !hasPositioned, let region = initialRegion else { return }
        cameraPosition = .region(region.mkRegion)
        hasPositioned = !appState.locations.isEmpty
    }

    private func recenter() {
        guard let region = initialRegion else { return }
        withAnimation { cameraPosition = .region(region.mkRegion) }
    }

    private func focus(on locationId: Int) {
        guard let location = appState.location(id: locationId), let coordinate = location.coordinate else { return }
        if selectedCategory != nil, location.category != selectedCategory {
            selectedCategory = nil
        }
        if heartedOnly, !appState.isHearted(.location(locationId)) {
            heartedOnly = false
        }
        selectedLocationId = locationId
        // A focus that arrives as the map appears wins over the initial framing.
        hasPositioned = true
        withAnimation { cameraPosition = .region(MapRegionMath.streetLevel(coordinate).mkRegion) }
    }

    private func zoom(into cluster: MapCluster) {
        let region = MapRegionMath.zoomIn(
            on: cluster,
            currentLatitudeDelta: visibleSpan.latitudeDelta,
            currentLongitudeDelta: visibleSpan.longitudeDelta
        )
        withAnimation { cameraPosition = .region(region.mkRegion) }
    }

    private func zoomToUserLocation() async {
        guard let coordinate = await locationManager.requestLocation() else {
            showLocationDeniedAlert = true
            return
        }
        appState.showUserLocation = true
        withAnimation {
            cameraPosition = .region(MKCoordinateRegion(
                center: coordinate,
                span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
            ))
        }
    }
}

// MARK: - MapKit bridging

extension Coordinate {
    var clCoordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

extension MapRegionSpec {
    var mkRegion: MKCoordinateRegion {
        MKCoordinateRegion(
            center: center.clCoordinate,
            span: MKCoordinateSpan(latitudeDelta: latitudeDelta, longitudeDelta: longitudeDelta)
        )
    }
}

// MARK: - Cluster badge

private struct ClusterBadge: View {
    let count: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text("\(count)")
                .font(.subheadline.bold())
                .monospacedDigit()
                .foregroundStyle(.white)
                .frame(minWidth: 36, minHeight: 36)
                .padding(.horizontal, 4)
                .background(Circle().fill(.tint))
                .overlay(Circle().stroke(.white, lineWidth: 2))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(count) places. Zoom in")
    }
}

// MARK: - Map buttons

/// Floating buttons: re-centre on the event and show my location. Interactive Liquid
/// Glass (it reacts to touch) in one container, so the two circles blend like the system's
/// map controls.
private struct MapButtonStack: View {
    let onCenter: () -> Void
    let onLocation: () -> Void

    var body: some View {
        GlassEffectContainer(spacing: 8) {
            VStack(spacing: 8) {
                button("Show the whole event", systemImage: "scope", action: onCenter)
                button("Show my location", systemImage: "location.fill", action: onLocation)
            }
        }
    }

    private func button(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .labelStyle(.iconOnly)
                .font(.body.weight(.medium))
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.tint)
        .glassEffect(.regular.interactive(), in: .circle)
    }
}

// MARK: - Pin glance

/// A String id on purpose: Map content in a ForEach is tagged with its id when the id has the
/// selection's type (Int), and these badges must never be selectable.
private struct PinBadge: Identifiable {
    var locationId: Int
    var coordinate: Coordinate
    var isLive: Bool
    var subtitle: String?

    var id: String { "badge-\(locationId)" }
}

// MARK: - Location Info Card

/// The selected pin: name, snippet, what's on, distance + arrow, the walk, a heart. Tapping the
/// text opens the detail; the heart is its own button.
private struct LocationInfoCard: View {
    let location: Location
    let walkText: String?
    let onTap: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onTap) {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(location.name)
                            .font(.headline)
                            .foregroundStyle(.primary)
                        if !location.snippet.isEmpty {
                            Text(location.snippet)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        LocationGlanceLine(location: location, now: .now)
                        HStack(spacing: 8) {
                            DistanceBadge(target: location.coordinate, font: .subheadline)
                            if let walkText {
                                Label(walkText, systemImage: "figure.walk")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .contentShape(.rect(cornerRadius: 22))
            }
            .buttonStyle(.plain)
            HeartButton(target: .location(location.id), font: .title3)
        }
        .padding()
        // Interactive Liquid Glass card (was a glass capsule drawn behind a rounded rectangle).
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 22))
    }
}

#Preview {
    NavigationStack {
        MapView(cameraPosition: .constant(.automatic), hasPositioned: .constant(false), showsFloatingButton: true)
    }
    .environment(AppState())
}

// MARK: - First render timing (API-014 `perf_map_first_render`)

/// The Map tab's first appearance → its first settled camera (SwiftUI's Map has no "rendered"
/// callback; the first `onMapCameraChange(.onEnd)` comes once the initial region is drawn).
/// Once per launch; signpost "map first render".
@MainActor
enum MapRenderTiming {
    private static var interval: AppSignpost.Interval?
    private static var done = false

    static func appeared() {
        guard !done, interval == nil else { return }
        interval = AppSignpost.begin(.mapFirstRender)
    }

    static func cameraSettled(pins: Int, clustered: Bool) {
        guard !done, let interval else { return }
        done = true
        self.interval = nil
        let ms = AppSignpost.end(interval, ["pins": .int(pins)])
        AppLog.info(.map, "map.first_render", "Map ready in \(ms) ms", ["ms": .int(ms), "pins": .int(pins), "clustered": .bool(clustered)])
        PerfMetrics.shared.record(.perfMapFirstRender, detail: PerfBucket.mapFirstRender(ms: ms))
    }
}
