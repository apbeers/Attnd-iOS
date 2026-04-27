// LocationPermissionManager.swift
// Attnd
//
// Async/await wrapper around CLLocationManager for a one-shot location request.
// Handles the notDetermined → authorized → location flow transparently.

import CoreLocation

@MainActor
final class LocationPermissionManager: NSObject, ObservableObject, CLLocationManagerDelegate {

    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<CLLocationCoordinate2D?, Never>?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    /// Requests location permission if needed, then resolves with the current coordinate.
    /// Returns nil if the user denies access or an error occurs.
    func requestLocation() async -> CLLocationCoordinate2D? {
        await withCheckedContinuation { cont in
            continuation = cont
            let status = manager.authorizationStatus
            if status == .notDetermined {
                manager.requestWhenInUseAuthorization()
            } else if status == .authorizedWhenInUse || status == .authorizedAlways {
                manager.requestLocation()
            } else {
                cont.resume(returning: nil)
                continuation = nil
            }
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            if manager.authorizationStatus == .authorizedWhenInUse ||
               manager.authorizationStatus == .authorizedAlways {
                manager.requestLocation()
            } else if manager.authorizationStatus != .notDetermined {
                continuation?.resume(returning: nil)
                continuation = nil
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor in
            continuation?.resume(returning: locations.first?.coordinate)
            continuation = nil
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            continuation?.resume(returning: nil)
            continuation = nil
        }
    }
}
