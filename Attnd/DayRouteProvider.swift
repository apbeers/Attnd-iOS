// DayRouteProvider.swift
// Attnd (app + App Clip)
//
// The plan's walking legs on real paths (assistant spec §5): `DayRoutes.of` gives the stops and
// the straight-line estimate at once; this provider asks MapKit for a walking route per leg
// (`MKDirections`, `.walking`, never navigation), one leg after another, and keeps the results
// for the day in memory (key: the day + its stops). `route(_:)` returns the day route with every
// plausible service leg (`DayRoutes.withServiceLegs`: ≤ 2.5 × the straight line); a leg that
// fails or is implausible keeps its estimate ("about 4 min walk"). Not in screenshot mode.

import CoreLocation
import MapKit
import Observation

@MainActor
@Observable
final class DayRouteProvider {
    private(set) var legs: [String: [LegRoute?]] = [:]
    @ObservationIgnored private var loading: Set<String> = []

    static func key(_ route: DayRoute) -> String {
        route.date.description + ":" + route.stops.map { String($0.locationId) }.joined(separator: ",")
    }

    /// `base` with the walking legs computed so far.
    func route(_ base: DayRoute) -> DayRoute {
        guard let service = legs[Self.key(base)] else { return base }
        return DayRoutes.withServiceLegs(base, service)
    }

    /// Computes the legs of `base` once (no-op while loading or when done).
    func load(_ base: DayRoute) async {
        let key = Self.key(base)
        guard !ScreenshotMode.isActive, legs[key] == nil, !loading.contains(key), !base.legs.isEmpty else { return }
        loading.insert(key)
        defer { loading.remove(key) }
        var results: [LegRoute?] = []
        for leg in base.legs {
            if Task.isCancelled { return }
            results.append(await Self.walk(from: leg.from.point, to: leg.to.point))
        }
        legs[key] = results
    }

    func clear() {
        legs = [:]
    }

    private struct Result: Sendable {
        var points: [Coordinate]
        var seconds: TimeInterval
        var meters: Double
    }

    private static func walk(from origin: Coordinate, to destination: Coordinate) async -> LegRoute? {
        let request = MKDirections.Request()
        request.source = MKMapItem(location: CLLocation(latitude: origin.latitude, longitude: origin.longitude), address: nil)
        request.destination = MKMapItem(location: CLLocation(latitude: destination.latitude, longitude: destination.longitude), address: nil)
        request.transportType = .walking
        request.requestsAlternateRoutes = false
        let directions = MKDirections(request: request)
        let result: Result? = await withCheckedContinuation { continuation in
            // The handler runs on the main thread; only plain values leave it.
            directions.calculate { response, _ in
                guard let route = response?.routes.first else {
                    continuation.resume(returning: nil)
                    return
                }
                let polyline = route.polyline
                let count = polyline.pointCount
                var coordinates = [CLLocationCoordinate2D](repeating: CLLocationCoordinate2D(), count: count)
                if count > 0 {
                    polyline.getCoordinates(&coordinates, range: NSRange(location: 0, length: count))
                }
                let points = coordinates.compactMap { Coordinate.valid(latitude: $0.latitude, longitude: $0.longitude) }
                continuation.resume(returning: Result(points: points, seconds: route.expectedTravelTime, meters: route.distance))
            }
        }
        guard let result, result.points.count >= 2 else { return nil }
        return LegRoute(distanceMeters: result.meters, durationSeconds: Int(result.seconds.rounded()), points: result.points, isEstimate: false)
    }
}
