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
        // A second request while one is pending would orphan the first continuation.
        finish(with: nil)
        return await withCheckedContinuation { cont in
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

    // Delegate callbacks are nonisolated. Only Sendable values (the status enum,
    // the coordinate) cross into the main actor; the manager itself is reached
    // through `self.manager` there instead of capturing the callback's parameter.

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            if status == .authorizedWhenInUse || status == .authorizedAlways {
                self.manager.requestLocation()
            } else if status != .notDetermined {
                self.finish(with: nil)
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let coordinate = locations.first?.coordinate
        Task { @MainActor in
            self.finish(with: coordinate)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            self.finish(with: nil)
        }
    }

    private func finish(with coordinate: CLLocationCoordinate2D?) {
        continuation?.resume(returning: coordinate)
        continuation = nil
    }
}
