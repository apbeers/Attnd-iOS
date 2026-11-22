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
    /// The selected pin and the chips, owned by MapTab (`MapUIState`) so they survive fold /
    /// unfold: the folded map and the unfolded split one are different views (batch 7 fix round).
    @Binding var ui: MapUIState
    /// The tab's floating button at the bottom of the map's trailing column (no side pane).
    var showsFloatingButton = false
    /// The time-travel scrubber (unfolded, regular width).
    var showsTimeTravel = false

    @Environment(AppState.self) private var appState
    @StateObject private var locationManager = LocationPermissionManager()
    @State private var showLocationDeniedAlert = false

    private var selectedLocationId: Int? {
        get { ui.selectedLocationId }
        nonmutating set { ui.selectedLocationId = newValue }
    }
    private var selectedCategory: String? {
        get { ui.selectedCategory }
        nonmutating set { ui.selectedCategory = newValue }
    }
    /// The "My Schedule" chip: only places in My schedule.
    private var heartedOnly: Bool {
        get { ui.heartedOnly }
        nonmutating set { ui.heartedOnly = newValue }
    }
    /// Refreshed every 30 s for the live dots, "Next 7:30" and the now-playing strip.
    @State private var now = Date.now
    /// Visible span, for clustering. Updated when the camera stops moving.
    @State private var visibleSpan = MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)
    /// The map's size in points, for "do these pins overlap" (clustering).
    @State private var mapSize = CGSize(width: 400, height: 700)
    /// The location button's mode, like Apple Maps: off → follow → follow with heading.
    @State private var tracking = MapTracking.off
    /// 0…1 along the walking line: the pulse flowing from the user to the place.
    @State private var pulse: Double = 0
    /// The camera's heading, for the user dot's cone (drawn in screen space).
    @State private var cameraHeading: Double = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private var visibleLocations: [Location] {
        LocationGrouping.filter(appState.locations, category: selectedCategory)
            // My schedule's places, including the places of its items.
            .filter { !heartedOnly || appState.myScheduleLocationIds.contains($0.id) }
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
            // Only pins that would overlap (< 24 pt apart) merge (batch 7).
            return MapClustering.overlapping(
                for: visibleLocations,
                latitudeDelta: visibleSpan.latitudeDelta,
                longitudeDelta: visibleSpan.longitudeDelta,
                mapWidth: mapSize.width,
                mapHeight: mapSize.height
            )
        }
        return MapClustering.unclustered(visibleLocations)
    }

    private var selectedLocation: Location? { appState.location(id: selectedLocationId) }

    var body: some View {
        let allClusters = self.clusters
        let walk = currentWalk
        let glances = showsGlance ? LocationGlance.all(schedule: appState.schedule, now: now) : [:]
        // Time travel: the pins of what's on at the scrubber's time light up, the others dim.
        let travelTime = showsTimeTravel ? ui.timeTravel : nil
        let lit = travelTime.map { TimeTravel.litLocationIds(at: $0, in: appState.schedule) }
        let badges = travelTime != nil ? [] : allClusters.filter(\.isSingle).compactMap { cluster -> PinBadge? in
            let location = cluster.locations[0]
            guard let glance = glances[location.id] else { return nil }
            let subtitle = glance.pinSubtitle(now: now, timeZone: appState.timeZone)
            guard glance.isLive || subtitle != nil else { return nil }
            return PinBadge(locationId: location.id, coordinate: cluster.coordinate, isLive: glance.isLive, subtitle: subtitle)
        }
        Map(position: $cameraPosition, selection: $ui.selectedLocationId) {
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
                if let lit {
                    Marker(cluster.locations[0].name, coordinate: cluster.coordinate.clCoordinate)
                        .tint(lit.contains(cluster.locations[0].id) ? Color.accentColor : Color.gray)
                        .tag(cluster.locations[0].id)
                } else {
                    Marker(cluster.locations[0].name, coordinate: cluster.coordinate.clCoordinate)
                        .tag(cluster.locations[0].id)
                }
            }
            // Live dot / "Next 7:30" floating just above the pin's balloon (not selectable).
            ForEach(badges) { badge in
                // "Happening now" sits under the pin's name; "Next 7:30" stays above the balloon.
                Annotation("", coordinate: badge.coordinate.clCoordinate, anchor: badge.isLive ? .top : .bottom) {
                    PinGlanceBadge(isLive: badge.isLive, subtitle: badge.subtitle)
                        .padding(badge.isLive ? .top : .bottom,
                                 badge.isLive ? 22 : (badge.locationId == selectedLocationId ? 66 : 42))
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
            // A pulse that flows along the walking line, user → place (~2 s; not with Reduce Motion).
            if let walk, !reduceMotion, let point = RoutePulse.point(along: walk.linePoints, fraction: pulse) {
                Annotation("", coordinate: point.clCoordinate) {
                    Circle()
                        .fill(.tint)
                        .frame(width: 12, height: 12)
                        .overlay(Circle().stroke(.white, lineWidth: 2))
                        .shadow(color: .accentColor.opacity(0.6), radius: 6)
                        .opacity(RoutePulse.opacity(pulse))
                        .allowsHitTesting(false)
                }
                .annotationTitles(.hidden)
            }
            if appState.showUserLocation {
                // The dot with a heading cone whenever the compass is available (batch 7).
                UserAnnotation { user in HeadingUserDot(heading: user.heading, mapHeading: cameraHeading) }
            }
        }
        .mapStyle(.standard)
        // Edge to edge (batch 7): up under the status bar / camera, and to the fold or the pane's
        // edge on an unfolded Duo; the overlays below keep to the safe area.
        .ignoresSafeArea(.container, edges: [.top, .horizontal])
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
            // A fold / unfold or rotation is a resize: keep the region the map shows (the
            // binding may hold a user-moved position Map can't restore by itself).
            let resized = abs(size.width - mapSize.width) > 1 || abs(size.height - mapSize.height) > 1
            mapSize = size
            if resized, hasPositioned, cameraPosition.region == nil, cameraPosition.camera == nil,
               !cameraPosition.followsUserLocation, let saved = appState.lastMapRegion {
                cameraPosition = .region(saved)
            }
        }
        .task(id: walk.map { "\($0.linePoints.count)-\($0.isEstimate)" } ?? "none") {
            guard walk != nil, !reduceMotion else { return }
            // Hitch audit (Nov 22, 2026): every pulse step re-evaluates the whole map (all pins,
            // badges, clusters), so it runs at ~15 fps and only for a few passes after the route
            // appears (it showed the direction; a pulse forever cost frames while panning).
            let start = Date.now
            while !Task.isCancelled {
                let elapsed = Date.now.timeIntervalSince(start)
                guard elapsed < RoutePulse.period * Double(RoutePulse.passes) else { break }
                pulse = RoutePulse.fraction(elapsed: elapsed)
                try? await Task.sleep(for: .milliseconds(66))
            }
            pulse = 0
        }
        .onMapCameraChange(frequency: .continuous) { context in
            let heading = context.camera.heading
            if abs(heading - cameraHeading) > 2 { cameraHeading = heading }
        }
        .onMapCameraChange(frequency: .onEnd) { context in
            visibleSpan = context.region.span
            appState.lastMapRegion = context.region
            // A pan or pinch ends following, like Apple Maps.
            if tracking != .off, !cameraPosition.followsUserLocation { tracking = .off }
            MapRenderTiming.cameraSettled(pins: allClusters.count, clustered: appState.display.mapClustering)
        }
        .navigationTitle(appState.currentEvent?.name ?? "Map")
        // Batch 7: no bar on the map; it runs edge to edge (the chips float in the safe area).
        .toolbar(.hidden, for: .navigationBar)
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
        // Linked panes: a pin tapped here scrolls the schedule pane to that place's next set (not
        // when the pane's own pick moved the selection).
        .onChange(of: ui.selectedLocationId) { _, id in
            if let picked = ui.paneItemId, appState.schedule.first(where: { $0.id == picked })?.locationId == id { return }
            ui.paneScrollLocationId = id
        }
        // Drag between panes: a set or place dropped on the map shows where it is.
        .payloadDrop { payload in
            switch payload {
            case .place(let id):
                guard appState.location(id: id)?.coordinate != nil else { return }
                focus(on: id)
            case .item(let id):
                guard let locationId = appState.schedule.first(where: { $0.id == id })?.locationId,
                      appState.location(id: locationId)?.coordinate != nil else { return }
                ui.paneItemId = id
                focus(on: locationId)
            }
        }
        .onChange(of: selectedCategory) { dropHiddenSelection(); refitForFilter() }
        .onChange(of: heartedOnly) { dropHiddenSelection(); refitForFilter() }
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
        // API-024: the event's `map_overlay` layout turns the Now playing strip and the selected
        // place's card on or off (their places in the column are fixed).
        let overlay = Set(appState.screenSections(.mapOverlay, now: now) { bundle, state in
            ScreenFacts.common(bundle, state).union(["now_playing"])
        }.map(\.type))
        let travelTime = showsTimeTravel ? ui.timeTravel : nil
        let nowPlaying = showsGlance && overlay.contains("now_playing")
            ? NowPlayingItem.items(schedule: appState.schedule, locations: visibleLocations, now: travelTime ?? now) : []
        let travelRange = showsTimeTravel && showsGlance ? TimeTravel.range(appState.schedule, now: now) : nil
        let selected = overlay.contains("selected_place") ? selectedLocation : nil
        // The Liked chip is always there, so the chip row always is.
        return VStack(spacing: 0) {
            CategoryChips(
                categories: appState.filterCategories,
                selection: $ui.selectedCategory,
                floating: true,
                heartedOnly: $ui.heartedOnly
            )
            if !nowPlaying.isEmpty {
                NowPlayingStrip(items: nowPlaying) { locationId in
                    focus(on: locationId)
                }
            }
            Spacer(minLength: 0)
            if heartedOnly, visibleLocations.isEmpty {
                // The Liked chip with nothing liked (or no liked place with a pin).
                NothingLikedView(hasLikes: !appState.myScheduleLocationIds.isEmpty)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 8)
                    .glassEffect(.regular, in: .rect(cornerRadius: 24))
                    .frame(maxWidth: 420)
                    .padding(.horizontal, 24)
                    .allowsHitTesting(false)
                Spacer(minLength: 0)
            }
            // Batch 7 (Duo folded: the trailing column crowded the vertical tab bar and the camera
            // island): one row in the bottom-leading corner, the map buttons then My plan / search.
            // Unfolded (regular width): a small vertical group at the map's trailing edge, next
            // to the tab rail; the selected place's card and the time-travel scrubber sit beside it,
            // docked at the map's bottom edge above Apple Maps' legal label (owner, after 181: the
            // scrubber floated in the middle of the map).
            if horizontalSizeClass == .regular {
                HStack(alignment: .bottom, spacing: 12) {
                    VStack(alignment: .leading, spacing: 8) {
                        if let location = selected {
                            LocationInfoCard(location: location, walkText: walkCardText) {
                                appState.mapNavigation.open(location.id)
                            }
                            .frame(maxWidth: 480)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                        }
                        if let travelRange {
                            TimeTravelDock(
                                range: travelRange,
                                points: TimeTravel.snapPoints(appState.schedule, in: travelRange),
                                now: now,
                                timeZone: appState.timeZone,
                                time: $ui.timeTravel,
                                startsCollapsed: selected != nil || mapSize.height < 520
                            )
                            .debugFloatingFrame("time_travel")
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .bottomLeading)
                    VStack(spacing: 10) {
                        MapButtonStack(
                            onCenter: recenter,
                            onLocation: { Task { await cycleTracking() } },
                            tracking: tracking,
                            vertical: true
                        )
                        if showsFloatingButton { FloatingTabButton() }
                    }
                }
                .padding(.leading, 16)
                .padding(.trailing, 16)
                // Clear of Apple Maps' legal / attribution label in the bottom-leading corner.
                .padding(.bottom, MapOverlayMetrics.legalClearance)
            } else {
                if let location = selected {
                    LocationInfoCard(location: location, walkText: walkCardText) {
                        appState.mapNavigation.open(location.id)
                    }
                    .frame(maxWidth: 480)
                    .padding(.horizontal)
                    .padding(.bottom, 8)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                HStack(spacing: 10) {
                    MapButtonStack(
                        onCenter: recenter,
                        onLocation: { Task { await cycleTracking() } },
                        tracking: tracking
                    )
                    if showsFloatingButton {
                        FloatingTabButton()
                    }
                    Spacer(minLength: 0)
                }
                .padding(.leading, 16)
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
        // Folding / unfolding swaps the full-screen map for the split one (a new Map): keep the
        // region the map last showed, never the world camera (batch 7).
        if hasPositioned, cameraPosition.region == nil, cameraPosition.camera == nil, !cameraPosition.followsUserLocation {
            if let saved = appState.lastMapRegion {
                cameraPosition = .region(saved)
            } else if let region = initialRegion {
                cameraPosition = .region(region.mkRegion)
            }
            return
        }
        guard !hasPositioned, let region = initialRegion else { return }
        cameraPosition = .region(region.mkRegion)
        hasPositioned = !appState.locations.isEmpty
    }

    /// A category or My Schedule chip changed: frame the pins that are left with some padding
    /// (one pin at street level), or every pin again when the filter is cleared (owner, after 181:
    /// "Family" left one pin with the camera far out over the city). Nothing to show: unchanged.
    private func refitForFilter() {
        let filtered = selectedCategory != nil || heartedOnly
        guard let region = filtered
            ? MapRegionMath.filterRegion(visibleLocations.compactMap(\.coordinate))
            : MapRegionMath.fitting(visibleLocations.compactMap(\.coordinate)) else { return }
        if tracking != .off { tracking = .off }
        withAnimation { cameraPosition = .region(region.mkRegion) }
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

    /// The location button: off → follow → follow with heading → off.
    private func cycleTracking() async {
        let next = tracking.next
        if next == .off {
            tracking = .off
            // Stay where the map is.
            if let region = cameraPosition.region { cameraPosition = .region(region) } else { cameraPosition = .automatic }
            return
        }
        if tracking == .off {
            guard await locationManager.requestLocation() != nil else {
                showLocationDeniedAlert = true
                return
            }
            appState.showUserLocation = true
        }
        tracking = next
        withAnimation {
            cameraPosition = .userLocation(followsHeading: next == .heading, fallback: .automatic)
        }
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

/// The location button's modes (Apple Maps): off, follow, follow with heading.
enum MapTracking: Equatable {
    case off, follow, heading

    var next: MapTracking {
        switch self {
        case .off: return .follow
        case .follow: return .heading
        case .heading: return .off
        }
    }

    var systemImage: String {
        switch self {
        case .off: return "location"
        case .follow: return "location.fill"
        case .heading: return "location.north.line.fill"
        }
    }

    var title: String {
        switch self {
        case .off: return "Follow my location"
        case .follow: return "Follow my location and heading"
        case .heading: return "Stop following"
        }
    }
}

/// Floating buttons: re-centre on the event and show my location. Interactive Liquid
/// Glass (it reacts to touch) in one container, so the two circles blend like the system's
/// map controls.
private struct MapButtonStack: View {
    let onCenter: () -> Void
    let onLocation: () -> Void
    var tracking: MapTracking = .off
    var vertical = false

    var body: some View {
        GlassEffectContainer(spacing: 8) {
            let layout = vertical ? AnyLayout(VStackLayout(spacing: 8)) : AnyLayout(HStackLayout(spacing: 8))
            layout {
                button("Show the whole event", systemImage: "scope", action: onCenter)
                button(tracking.title, systemImage: tracking.systemImage, action: onLocation)
                    .contentTransition(.symbolEffect(.replace))
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
        .debugFloatingFrame("map_\(systemImage)")
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
        MapView(cameraPosition: .constant(.automatic), hasPositioned: .constant(false), ui: .constant(MapUIState()), showsFloatingButton: true)
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
