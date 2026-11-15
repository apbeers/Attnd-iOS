// DayRoute.swift
// Attnd (app target only — not in the App Clip; unit tested in AssistantExtrasTests)
//
// The plan's walking legs (assistant spec §5), a port of Android's `domain/DayRoute.kt`:
// numbered stops (consecutive items at one location share a stop), legs between them as the
// straight-line estimate, upgraded per leg by a real route (iOS: MKDirections walking, one per
// leg) when it is plausible (≤ 2.5 × the straight line), and the day's totals.

import Foundation

/// A walk between two points: from a routing service (`isEstimate` false) or the straight-line
/// estimate (Android `WalkRoute`; not `WalkRoute` in Glance.swift, the map card's route).
struct LegRoute: Hashable, Sendable {
    var distanceMeters: Double
    var durationSeconds: Int
    var points: [Coordinate]
    var isEstimate: Bool

    /// Straight line × 1.2 at 1.3 m/s.
    static func estimate(_ origin: Coordinate, _ destination: Coordinate) -> LegRoute {
        let straight = Planner.distance(origin, destination)
        return LegRoute(distanceMeters: straight * WalkTime.detourFactor, durationSeconds: AssistantText.estimateSeconds(straight),
                        points: [origin, destination], isEstimate: true)
    }
}

/// A numbered stop of the day's walk: one location and the consecutive planned items there.
struct RouteStop: Hashable, Sendable {
    var number: Int
    var locationId: Int
    var point: Coordinate
    var itemIds: [Int]
}

/// The walk between two consecutive stops.
struct RouteLeg: Hashable, Sendable {
    var from: RouteStop
    var to: RouteStop
    /// The last item at `from` and the first at `to`.
    var fromItem: Int
    var toItem: Int
    var straightMeters: Double
    var route: LegRoute
}

struct DayRoute: Hashable, Sendable {
    var date: PlanDate
    var stops: [RouteStop]
    var legs: [RouteLeg]

    var totalMeters: Double { legs.reduce(0) { $0 + $1.route.distanceMeters } }
    var totalSeconds: Int { legs.reduce(0) { $0 + $1.route.durationSeconds } }
}

enum DayRoutes {
    static let maxStops = 25

    /// The route of `date` (default: the plan's first day with items), optionally only through
    /// `only` (the recap's checked-off items). nil when the day isn't planned.
    static func of(_ plan: Plan, _ bundle: EventBundle, date: PlanDate? = nil, only: Set<Int>? = nil) -> DayRoute? {
        let day = date.map { d in plan.days.first { $0.date == d } } ?? plan.days.first { !$0.items.isEmpty }
        guard let day else { return nil }
        var stops: [RouteStop] = []
        for entry in day.items {
            if let only, !only.contains(entry.itemId) { continue }
            guard let item = bundle.scheduleItem(entry.itemId), let location = bundle.location(item.locationId),
                  let point = location.coordinate else { continue }
            if let last = stops.last, last.locationId == location.id {
                stops[stops.count - 1].itemIds.append(item.id)
            } else {
                stops.append(RouteStop(number: stops.count + 1, locationId: location.id, point: point, itemIds: [item.id]))
            }
        }
        let legs = zip(stops, stops.dropFirst()).map { a, b in
            RouteLeg(from: a, to: b, fromItem: a.itemIds.last ?? 0, toItem: b.itemIds.first ?? 0,
                     straightMeters: Planner.distance(a.point, b.point), route: LegRoute.estimate(a.point, b.point))
        }
        return DayRoute(date: day.date, stops: stops, legs: legs)
    }

    /// The points for one multi-stop request, or nil with fewer than 2 or more than 25 stops.
    static func waypoints(_ route: DayRoute) -> [Coordinate]? {
        let points = route.stops.map(\.point)
        return (2...maxStops).contains(points.count) ? points : nil
    }

    /// `route` with service routes per leg (index = leg index; nil = keep the estimate).
    static func withServiceLegs(_ route: DayRoute, _ service: [LegRoute?]) -> DayRoute {
        var updated = route
        for (index, leg) in route.legs.enumerated() {
            guard index < service.count, let candidate = service[index], !candidate.isEstimate,
                  AssistantText.acceptsRoute(routeMeters: candidate.distanceMeters, straightMeters: leg.straightMeters) else { continue }
            updated.legs[index].route = candidate
        }
        return updated
    }

    /// A leg row: "6 min walk · 0.3 mi" (the estimate says "about 6 min walk · 0.3 mi").
    static func legText(_ leg: RouteLeg, _ units: DistanceUnits, locale: Locale) -> String {
        let text = "\(AssistantText.walk(leg.route.durationSeconds)) · \(AssistantText.distance(leg.route.distanceMeters, units, locale: locale))"
        return leg.route.isEstimate ? "about \(text)" : text
    }

    /// "2.8 mi walking today", "1.2 km walking on Sunday"; "No walking" without legs.
    static func totalText(_ route: DayRoute, today: PlanDate, _ units: DistanceUnits, locale: Locale) -> String {
        if route.legs.isEmpty { return "No walking" }
        let distance = AssistantText.distance(route.totalMeters, units, locale: locale)
        let day = route.date == today ? "today" : "on \(AssistantText.weekdayName(route.date, locale: locale))"
        return "\(distance) walking \(day)"
    }
}
