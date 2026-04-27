// MapView.swift
// Attnd

import SwiftUI
import MapKit

struct MapView: View {
    let locations: [Location]
    let centerCoordinate: CLLocationCoordinate2D?
    let showUserLocation: Bool

    init(
        locations: [Location] = [],
        centerCoordinate: CLLocationCoordinate2D? = nil,
        showUserLocation: Bool = false
    ) {
        self.locations = locations
        self.centerCoordinate = centerCoordinate
        self.showUserLocation = showUserLocation
    }

    var body: some View {
        Map(initialPosition: initialPosition) {
            ForEach(locations) { location in
                Marker(
                    location.name,
                    coordinate: CLLocationCoordinate2D(
                        latitude: location.latitude,
                        longitude: location.longitude
                    )
                )
            }
            if showUserLocation {
                UserAnnotation()
            }
        }
        .mapStyle(.standard)
        .navigationTitle("Map")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var initialPosition: MapCameraPosition {
        if let center = centerCoordinate {
            return .region(MKCoordinateRegion(
                center: center,
                span: MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02)
            ))
        }
        if let first = locations.first {
            return .region(MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: first.latitude, longitude: first.longitude),
                span: MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02)
            ))
        }
        return .region(MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 32.754695, longitude: -97.331605),
            span: MKCoordinateSpan(latitudeDelta: 0.5, longitudeDelta: 0.5)
        ))
    }
}

#Preview {
    MapView()
}
