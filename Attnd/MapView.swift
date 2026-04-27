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
        Map(position: $cameraPosition) {
            ForEach(locations) { location in
                Marker(
                    location.name,
                    coordinate: CLLocationCoordinate2D(
                        latitude: location.latitude,
                        longitude: location.longitude
                    )
                )
            }
            if appState.showUserLocation {
                UserAnnotation()
            }
        }
        .mapStyle(.standard)
        .navigationTitle("Map")
        .navigationBarTitleDisplayMode(.inline)
        .overlay(alignment: .bottomTrailing) {
            Button {
                Task { await zoomToUserLocation() }
            } label: {
                Image(systemName: "location.fill")
                    .padding(12)
                    .background(.regularMaterial, in: Circle())
            }
            .padding()
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

#Preview {
    MapView()
        .environment(AppState())
}
