// MapView.swift
// Attnd

import SwiftUI
import MapKit
import UIKit

struct MapView: View {
    let locations: [Location]
    let centerCoordinate: CLLocationCoordinate2D?

    @Environment(AppState.self) private var appState
    @State private var cameraPosition: MapCameraPosition
    @StateObject private var locationManager = LocationPermissionManager()
    @State private var showLocationDeniedAlert = false

    // Pin selection
    @State private var selectedLocationId: Int? = nil
    @State private var navigateToLocation: Location? = nil

    private var selectedLocation: Location? {
        guard let id = selectedLocationId else { return nil }
        return locations.first { $0.id == id }
    }

    init(
        locations: [Location] = [],
        centerCoordinate: CLLocationCoordinate2D? = nil
    ) {
        self.locations = locations
        self.centerCoordinate = centerCoordinate

        let pos: MapCameraPosition
        if let center = centerCoordinate {
            pos = .region(MKCoordinateRegion(
                center: center,
                span: MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02)
            ))
        } else if let first = locations.first {
            pos = .region(MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: first.latitude, longitude: first.longitude),
                span: MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02)
            ))
        } else {
            pos = .region(MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: 32.754695, longitude: -97.331605),
                span: MKCoordinateSpan(latitudeDelta: 0.5, longitudeDelta: 0.5)
            ))
        }
        _cameraPosition = State(initialValue: pos)
    }

    var body: some View {
        Map(position: $cameraPosition, selection: $selectedLocationId) {
            ForEach(locations) { location in
                Marker(
                    location.name,
                    coordinate: CLLocationCoordinate2D(
                        latitude: location.latitude,
                        longitude: location.longitude
                    )
                )
                .tag(location.id)
            }
            if appState.showUserLocation {
                UserAnnotation()
            }
        }
        .mapStyle(.standard)
        .navigationTitle("Map")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $navigateToLocation) { location in
            LocationDetailView(location: location)
        }
        .onChange(of: appState.mapCenterToken) {
            centerOnEvent()
        }
        // Single bottom overlay: FABs on trailing, info card below when a pin is selected
        .overlay(alignment: .bottom) {
            VStack(spacing: 0) {
                HStack(alignment: .bottom) {
                    Spacer()
                    MapFABStack(
                        onCenter: { centerOnEvent() },
                        onLocation: { Task { await zoomToUserLocation() } }
                    )
                    .padding()
                }

                if let loc = selectedLocation {
                    LocationInfoCard(location: loc) {
                        navigateToLocation = loc
                    }
                    .padding(.horizontal)
                    .padding(.bottom, 8)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.spring(duration: 0.3), value: selectedLocationId)
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

    private func centerOnEvent() {
        let target: CLLocationCoordinate2D
        if let center = centerCoordinate {
            target = center
        } else if let first = locations.first {
            target = CLLocationCoordinate2D(latitude: first.latitude, longitude: first.longitude)
        } else {
            return
        }
        withAnimation {
            cameraPosition = .region(MKCoordinateRegion(
                center: target,
                span: MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02)
            ))
        }
    }

    private func zoomToUserLocation() async {
        let coord = await locationManager.requestLocation()
        if let coord {
            appState.showUserLocation = true
            withAnimation {
                cameraPosition = .region(MKCoordinateRegion(
                    center: coord,
                    span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
                ))
            }
        } else {
            showLocationDeniedAlert = true
        }
    }
}

// MARK: - Map FAB Stack

/// Two floating action buttons — scope (re-center) and location.
/// On iOS 26+ they use native Liquid Glass; older OS falls back to .regularMaterial.
private struct MapFABStack: View {
    let onCenter: () -> Void
    let onLocation: () -> Void

    var body: some View {
        if #available(iOS 26, *) {
            GlassEffectContainer {
                VStack(spacing: 8) {
                    Button(action: onCenter) {
                        Image(systemName: "scope")
                            .frame(width: 44, height: 44)
                            .contentShape(Circle())
                    }
                    .glassEffect(in: Circle())

                    Button(action: onLocation) {
                        Image(systemName: "location.fill")
                            .frame(width: 44, height: 44)
                            .contentShape(Circle())
                    }
                    .glassEffect(in: Circle())
                }
            }
        } else {
            VStack(spacing: 12) {
                Button(action: onCenter) {
                    Image(systemName: "scope")
                        .padding(12)
                        .background(.regularMaterial, in: Circle())
                }
                Button(action: onLocation) {
                    Image(systemName: "location.fill")
                        .padding(12)
                        .background(.regularMaterial, in: Circle())
                }
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
                    Text(location.snippet)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding()
            .background {
                if #available(iOS 26, *) {
                    RoundedRectangle(cornerRadius: 14).glassEffect()
                } else {
                    RoundedRectangle(cornerRadius: 14).fill(.regularMaterial)
                }
            }
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    MapView()
        .environment(AppState())
}
