// LocationPermissionManager.swift
// Attnd
//
// Async/await wrapper around CLLocationManager for a one-shot location request.
// Handles the notDetermined → authorized → location flow transparently.

import CoreLocation

extension CLAuthorizationStatus {
    /// `location.permission` status (LOG_EVENTS.md): granted, denied, not_determined, restricted.
    var logName: String {
        switch self {
        case .notDetermined:                         return "not_determined"
        case .restricted:                            return "restricted"
        case .denied:                                return "denied"
        case .authorizedAlways, .authorizedWhenInUse: return "granted"
        @unknown default:                            return "denied"
        }
    }
}

/// `location.permission` fields.
func locationPermissionFields(_ status: CLAuthorizationStatus, precise: Bool, asked: Bool) -> LogFields {
    [
        "status": .string(status.logName), "precision": .string(precise ? "precise" : "approximate"),
        "background": .bool(status == .authorizedAlways), "asked": .bool(asked),
    ]
}

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
                AppLog.notice(.location, "location.permission", "Asking for location",
                              locationPermissionFields(status, precise: manager.accuracyAuthorization == .fullAccuracy, asked: true))
            }
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
        AppLog.notice(.location, "location.permission", "Location permission: \(status.logName)",
                      locationPermissionFields(status, precise: manager.accuracyAuthorization == .fullAccuracy, asked: false))
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
        let ns = error as NSError
        AppLog.warning(.location, "location.error", "One-shot location failed", [
            "error": .string(ns.localizedDescription), "domain": .string(ns.domain), "code": .int(ns.code),
        ])
        Task { @MainActor in
            self.finish(with: nil)
        }
    }

    private func finish(with coordinate: CLLocationCoordinate2D?) {
        continuation?.resume(returning: coordinate)
        continuation = nil
    }
}
