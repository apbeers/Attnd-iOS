// MapView.swift
// Attnd
//
// The event map. Honours the display config: `map_fit_all` (initial framing),
// `map_clustering` (grid clustering by zoom level, see MapClustering) and
// `group_by_category` (category chips). Locations without coordinates get no pin.
//
// Floating overlays (category chips, map buttons, the selected-location card) are
// laid out with ReservedRegionAvoiding so they stay clear of the fold and camera
// housings on foldables.

import SwiftUI
import MapKit
import UIKit

struct MapView: View {
    @Binding var cameraPosition: MapCameraPosition
    /// Whether the initial framing has been applied (owned by MapTab so it survives layout changes).
    @Binding var hasPositioned: Bool

    @Environment(AppState.self) private var appState
    @StateObject private var locationManager = LocationPermissionManager()
    @State private var showLocationDeniedAlert = false

    @State private var selectedLocationId: Int?
    @State private var navigateToLocation: Location?
    @State private var selectedCategory: String?
    /// Visible span, for clustering. Updated when the camera stops moving.
    @State private var visibleSpan = MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)

    private var visibleLocations: [Location] {
        LocationGrouping.filter(appState.locations, category: selectedCategory)
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
        Map(position: $cameraPosition, selection: $selectedLocationId) {
            ForEach(allClusters.filter(\.isSingle)) { cluster in
                Marker(cluster.locations[0].name, coordinate: cluster.coordinate.clCoordinate)
                    .tag(cluster.locations[0].id)
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
        }
        .navigationTitle(appState.currentEvent?.name ?? "Map")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $navigateToLocation) { location in
            LocationDetailView(location: location)
        }
        .onAppear(perform: positionInitiallyIfNeeded)
        .onChange(of: appState.locations) { positionInitiallyIfNeeded() }
        .onChange(of: appState.mapCenterToken) { recenter() }
        .onChange(of: appState.mapFocusLocationId) { _, id in
            guard let id else { return }
            focus(on: id)
            appState.mapFocusLocationId = nil
        }
        .onChange(of: selectedCategory) {
            if let id = selectedLocationId, !visibleLocations.contains(where: { $0.id == id }) {
                selectedLocationId = nil
            }
        }
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
        VStack(spacing: 0) {
            if !appState.filterCategories.isEmpty {
                CategoryChips(categories: appState.filterCategories, selection: $selectedCategory)
                    .padding(.top, 8)
            }
            Spacer(minLength: 0)
            HStack {
                Spacer()
                MapButtonStack(
                    onCenter: recenter,
                    onLocation: { Task { await zoomToUserLocation() } }
                )
                .padding()
            }
            if let location = selectedLocation {
                LocationInfoCard(location: location) {
                    navigateToLocation = location
                }
                .frame(maxWidth: 480)
                .padding(.horizontal)
                .padding(.bottom, 8)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.3), value: selectedLocationId)
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
        selectedLocationId = locationId
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

/// Floating buttons: re-centre on the event and show my location.
private struct MapButtonStack: View {
    let onCenter: () -> Void
    let onLocation: () -> Void

    var body: some View {
        GlassEffectContainer {
            VStack(spacing: 8) {
                Button(action: onCenter) {
                    Image(systemName: "scope")
                        .frame(width: 44, height: 44)
                        .contentShape(Circle())
                }
                .glassEffect(in: Circle())
                .accessibilityLabel("Show the whole event")

                Button(action: onLocation) {
                    Image(systemName: "location.fill")
                        .frame(width: 44, height: 44)
                        .contentShape(Circle())
                }
                .glassEffect(in: Circle())
                .accessibilityLabel("Show my location")
            }
        }
    }
}

// MARK: - Location Info Card

private struct LocationInfoCard: View {
    let location: Location
    let onTap: () -> Void

    var body: some View {
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
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding()
            .background {
                RoundedRectangle(cornerRadius: 14).glassEffect()
            }
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    NavigationStack {
        MapView(cameraPosition: .constant(.automatic), hasPositioned: .constant(false))
    }
    .environment(AppState())
}
