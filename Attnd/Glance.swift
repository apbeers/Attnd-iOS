// Glance.swift
// Attnd
//
// Pure, unit-tested rules behind the "glance" features (shared with the Android app; same
// rules and test cases, GlanceTests):
//   - RelativeTimeText: "in 12 min", "today 7:30 PM", "in 3 days" (never "in 2,000 h")
//   - DistanceText: "0.6 mi" / "500 ft" / "350 m" / "1.2 km" in the phone's region units
//   - Compass: distance, bearing, compass points, arrow rotation ("Northeast, 0.6 miles")
//   - WalkTime + RouteCache: walking estimates, route-vs-straight-line fallback, re-routing
//   - LocationGlance / NowPlaying: what's on now and next at each location
//   - UpdatesInbox: unread updates and the "newest update" banner
//   - EventPersonalState: hearts and the Updates "seen" mark, stored per event on the device
//
// No SwiftUI, MapKit or CoreLocation here.

import Foundation

// MARK: - Relative start time

enum RelativeTimeText {

    /// "Ended", "Started 20 min ago", "Now" (" · ends 8:30 PM" with `includeEnd`), "Starting now",
    /// "in 12 min", "in 3 h 20 min", "today 7:30 PM", "tomorrow 7:30 PM", "in 3 days",
    /// "in 2 weeks", "in 4 months", "in 1 year". Days, weeks, months and years are counted in
    /// calendar days of the EVENT's time zone. A missing (or not later) end means start + 1 h.
    static func start(
        _ start: Date,
        end: Date?,
        now: Date,
        timeZone: TimeZone,
        includeEnd: Bool = false,
        locale: Locale = .current
    ) -> String {
        let effectiveEnd = end.flatMap { $0 > start ? $0 : nil } ?? start.addingTimeInterval(ScheduleTiming.defaultDuration)
        if effectiveEnd <= now { return "Ended" }

        if start <= now {
            let elapsed = now.timeIntervalSince(start)
            var text: String
            if elapsed < 3600 {
                let minutes = Int(elapsed / 60)
                text = minutes < 1 ? "Started just now" : "Started \(minutes) min ago"
            } else {
                text = "Now"
            }
            if includeEnd {
                text += " · ends " + EventTimeFormat.shortDayTime(effectiveEnd, in: timeZone, now: now, locale: locale)
            }
            return text
        }

        let seconds = start.timeIntervalSince(now)
        if seconds < 60 { return "Starting now" }
        let totalMinutes = Int(seconds / 60)
        if totalMinutes < 60 { return "in \(totalMinutes) min" }
        if seconds < 6 * 3600 {
            let hours = totalMinutes / 60
            let minutes = totalMinutes % 60
            return minutes == 0 ? "in \(hours) h" : "in \(hours) h \(minutes) min"
        }

        let calendar = EventTimeFormat.calendar(in: timeZone)
        let today = calendar.startOfDay(for: now)
        let startDay = calendar.startOfDay(for: start)
        let days = calendar.dateComponents([.day], from: today, to: startDay).day ?? 0
        let time = EventTimeFormat.time(start, in: timeZone, locale: locale)
        if days <= 0 { return "today \(time)" }
        if days == 1 { return "tomorrow \(time)" }
        if days < 7 { return "in \(days) days" }
        if days < 35 {
            let weeks = days / 7
            return weeks == 1 ? "in 1 week" : "in \(weeks) weeks"
        }
        let months = max(calendar.dateComponents([.month], from: today, to: startDay).month ?? 1, 1)
        if months < 12 { return months == 1 ? "in 1 month" : "in \(months) months" }
        let years = max(calendar.dateComponents([.year], from: today, to: startDay).year ?? 1, 1)
        return years == 1 ? "in 1 year" : "in \(years) years"
    }

    /// A schedule item's text; nil without a start time.
    static func item(_ item: ScheduleItem, now: Date, timeZone: TimeZone, includeEnd: Bool = false, locale: Locale = .current) -> String? {
        guard let start = item.startTime else { return nil }
        return Self.start(start, end: item.endTime, now: now, timeZone: timeZone, includeEnd: includeEnd, locale: locale)
    }

    /// A nearby event's text: its start time, or `starts_in_hours` turned into a date (never
    /// printed as hours). Without an end the event lasts until the end of its first day.
    static func event(_ event: Event, startsInHours: Double?, now: Date, locale: Locale = .current) -> String? {
        let timeZone = event.timeZone
        let start = event.startTime ?? startsInHours.flatMap { hours in
            hours.isFinite ? now.addingTimeInterval(hours * 3600) : nil
        }
        guard let start else { return nil }
        let calendar = EventTimeFormat.calendar(in: timeZone)
        let end = event.endTime ?? calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: start))
        return Self.start(start, end: end, now: now, timeZone: timeZone, locale: locale)
    }
}

// MARK: - Distance

enum DistanceText {
    /// Regions that use miles and feet on road signs.
    static let imperialRegions: Set<String> = ["US", "GB", "LR", "MM"]
    /// Closer than this is "Here" (no arrow).
    static let hereMeters = 20.0

    static let metersPerMile = 1609.344
    static let feetPerMeter = 3.280_84

    static func usesImperial(_ locale: Locale = .current) -> Bool {
        imperialRegions.contains(locale.region?.identifier.uppercased() ?? "")
    }

    /// "500 ft" (under 0.1 mi, nearest 10 ft), "0.6 mi" (under 10), "12 mi"; or "350 m"
    /// (nearest 10 m), "1.2 km" (under 10), "12 km".
    static func text(meters: Double, imperial: Bool, locale: Locale = .current) -> String {
        let parts = components(meters: meters, imperial: imperial, locale: locale)
        return "\(parts.number) \(parts.short)"
    }

    /// For VoiceOver: "500 feet", "0.6 miles", "350 meters", "1.2 kilometers".
    static func spoken(meters: Double, imperial: Bool, locale: Locale = .current) -> String {
        let parts = components(meters: meters, imperial: imperial, locale: locale)
        let unit = parts.number == "1" ? String(parts.long.dropLast()) : parts.long
        return "\(parts.number) \(unit)"
    }

    private static func components(meters: Double, imperial: Bool, locale: Locale) -> (number: String, short: String, long: String) {
        let meters = max(meters, 0)
        if imperial {
            let miles = meters / metersPerMile
            if miles < 0.1 {
                let feet = max(Int((meters * feetPerMeter / 10).rounded()) * 10, 10)
                return (whole(feet, locale), "ft", "feet")
            }
            let tenths = (miles * 10).rounded() / 10
            if tenths < 10 { return (oneDecimal(tenths, locale), "mi", "miles") }
            return (whole(Int(miles.rounded()), locale), "mi", "miles")
        }
        let rounded = Int((meters / 10).rounded()) * 10
        if rounded < 1000 { return (whole(max(rounded, 10), locale), "m", "meters") }
        let km = meters / 1000
        let tenths = (km * 10).rounded() / 10
        if tenths < 10 { return (oneDecimal(tenths, locale), "km", "kilometers") }
        return (whole(Int(km.rounded()), locale), "km", "kilometers")
    }

    private static func oneDecimal(_ value: Double, _ locale: Locale) -> String {
        value.formatted(.number.precision(.fractionLength(1)).locale(locale))
    }

    private static func whole(_ value: Int, _ locale: Locale) -> String {
        value.formatted(.number.locale(locale))
    }
}

// MARK: - Compass

enum CompassPoint: Int, CaseIterable, Sendable {
    case north, northeast, east, southeast, south, southwest, west, northwest

    var name: String {
        switch self {
        case .north:     return "North"
        case .northeast: return "Northeast"
        case .east:      return "East"
        case .southeast: return "Southeast"
        case .south:     return "South"
        case .southwest: return "Southwest"
        case .west:      return "West"
        case .northwest: return "Northwest"
        }
    }
}

enum Compass {
    /// Mean Earth radius (haversine).
    static let earthRadius = 6_371_000.0

    /// Great-circle distance in metres (haversine).
    static func distance(_ a: Coordinate, _ b: Coordinate) -> Double {
        let lat1 = a.latitude * .pi / 180, lat2 = b.latitude * .pi / 180
        let dLat = lat2 - lat1
        let dLng = (b.longitude - a.longitude) * .pi / 180
        let h = sin(dLat / 2) * sin(dLat / 2) + cos(lat1) * cos(lat2) * sin(dLng / 2) * sin(dLng / 2)
        return 2 * earthRadius * asin(min(1, sqrt(h)))
    }

    /// Initial bearing from `a` to `b`, degrees clockwise from true north, 0 ..< 360.
    static func bearing(from a: Coordinate, to b: Coordinate) -> Double {
        let lat1 = a.latitude * .pi / 180, lat2 = b.latitude * .pi / 180
        let dLng = (b.longitude - a.longitude) * .pi / 180
        let y = sin(dLng) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLng)
        return normalized(atan2(y, x) * 180 / .pi)
    }

    static func normalized(_ degrees: Double) -> Double {
        guard degrees.isFinite else { return 0 }
        let r = degrees.truncatingRemainder(dividingBy: 360)
        let value = r < 0 ? r + 360 : r
        return value >= 360 ? 0 : value
    }

    /// The arrow's rotation on screen: bearing − heading (both from true north), 0 ..< 360.
    static func arrowRotation(bearing: Double, heading: Double) -> Double {
        normalized(bearing - heading)
    }

    /// The nearest of the eight compass points (each covers 45°, north = 337.5 ..< 22.5).
    static func point(_ bearing: Double) -> CompassPoint {
        let index = Int((normalized(bearing) + 22.5) / 45) % 8
        return CompassPoint(rawValue: index) ?? .north
    }

    /// Heading of the top of the UI from the device's heading (top of the device in portrait)
    /// and how far the interface is rotated clockwise from portrait (90 = landscape with the
    /// device's right edge up, 180 = upside down, 270 = left edge up).
    static func interfaceHeading(deviceHeading: Double, interfaceRotation: Double) -> Double {
        normalized(deviceHeading + interfaceRotation)
    }
}

/// Where a target is from the user: distance, bearing and the texts shown for it.
struct TargetDirection: Hashable, Sendable {
    var meters: Double
    var bearing: Double

    init(from user: Coordinate, to target: Coordinate) {
        meters = Compass.distance(user, target)
        bearing = Compass.bearing(from: user, to: target)
    }

    /// Within ~20 m: "Here", no arrow.
    var isHere: Bool { meters < DistanceText.hereMeters }

    var point: CompassPoint { Compass.point(bearing) }

    /// "0.6 mi" or "Here".
    func text(imperial: Bool, locale: Locale = .current) -> String {
        isHere ? "Here" : DistanceText.text(meters: meters, imperial: imperial, locale: locale)
    }

    /// "Northeast, 0.6 miles" or "Here".
    func accessibilityText(imperial: Bool, locale: Locale = .current) -> String {
        isHere ? "Here" : "\(point.name), \(DistanceText.spoken(meters: meters, imperial: imperial, locale: locale))"
    }

    /// The arrow's rotation, nil when no arrow is shown (here, or no heading).
    func arrowRotation(heading: Double?) -> Double? {
        guard !isHere, let heading else { return nil }
        return Compass.arrowRotation(bearing: bearing, heading: heading)
    }
}

// MARK: - Walking

enum WalkTime {
    /// Walking speed for estimates (m/s).
    static let speed = 1.3
    /// Paths are longer than the straight line.
    static let detourFactor = 1.2
    /// Walk times, routes and walk legs only when the user is this close (~5 mi / 8 km).
    static let maxDistance = 8_000.0
    /// A route longer than this × the straight line is ignored (festival grounds the map
    /// doesn't know): the dashed straight line and the estimate are shown instead.
    static let maxRouteDetour = 2.5
    /// A cached route is reused while the user stays within this distance of where it started.
    static let rerouteDistance = 50.0

    static func isWithinWalkingRange(_ meters: Double) -> Bool {
        meters.isFinite && meters <= maxDistance
    }

    /// Estimated seconds for a straight-line distance: × 1.2 at 1.3 m/s.
    static func estimatedSeconds(straightMeters: Double) -> TimeInterval {
        max(straightMeters, 0) * detourFactor / speed
    }

    /// Whole minutes, rounded up, at least 1.
    static func minutes(_ seconds: TimeInterval) -> Int {
        max(1, Int((seconds / 60).rounded(.up)))
    }

    /// "8 min", "1 h", "1 h 5 min".
    static func durationText(_ seconds: TimeInterval) -> String {
        let total = minutes(seconds)
        if total < 60 { return "\(total) min" }
        let hours = total / 60, rest = total % 60
        return rest == 0 ? "\(hours) h" : "\(hours) h \(rest) min"
    }

    /// Whether a computed route is believable compared with the straight line.
    static func acceptsRoute(routeMeters: Double, straightMeters: Double) -> Bool {
        routeMeters.isFinite && routeMeters > 0 && routeMeters <= maxRouteDetour * max(straightMeters, 1)
    }

    /// Schedule rows: "8 min walk" (estimate).
    static func rowText(straightMeters: Double) -> String {
        "\(durationText(estimatedSeconds(straightMeters: straightMeters))) walk"
    }
}

/// A walk to a location from `origin`: a real route, or the straight-line estimate.
struct WalkRoute: Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        /// A walking route (MKDirections): its path, time and length.
        case route(points: [Coordinate], seconds: TimeInterval, meters: Double)
        /// No usable route: a dashed straight line and an estimate.
        case estimate
    }

    var locationId: Int
    var origin: Coordinate
    var destination: Coordinate
    var kind: Kind

    var straightMeters: Double { Compass.distance(origin, destination) }

    /// A route result, or the estimate when it is missing or far longer than the straight line.
    static func make(
        locationId: Int,
        origin: Coordinate,
        destination: Coordinate,
        routePoints: [Coordinate]?,
        routeSeconds: TimeInterval?,
        routeMeters: Double?
    ) -> WalkRoute {
        let straight = Compass.distance(origin, destination)
        if let points = routePoints, points.count >= 2, let seconds = routeSeconds, let meters = routeMeters,
           seconds.isFinite, seconds > 0, WalkTime.acceptsRoute(routeMeters: meters, straightMeters: straight) {
            return WalkRoute(locationId: locationId, origin: origin, destination: destination,
                             kind: .route(points: points, seconds: seconds, meters: meters))
        }
        return WalkRoute(locationId: locationId, origin: origin, destination: destination, kind: .estimate)
    }

    var isEstimate: Bool { kind == .estimate }

    /// "12 min walk · 0.6 mi" for a route, "about 8 min walk" for an estimate.
    func text(imperial: Bool, locale: Locale = .current) -> String {
        switch kind {
        case .route(_, let seconds, let meters):
            return "\(WalkTime.durationText(seconds)) walk · \(DistanceText.text(meters: meters, imperial: imperial, locale: locale))"
        case .estimate:
            return "about \(WalkTime.durationText(WalkTime.estimatedSeconds(straightMeters: straightMeters))) walk"
        }
    }

    /// The line drawn on the map: the route's path, or origin → destination.
    var linePoints: [Coordinate] {
        switch kind {
        case .route(let points, _, _): return points
        case .estimate:                return [origin, destination]
        }
    }
}

/// The latest walk per location, reused while the user stays within 50 m of its origin.
struct RouteCache: Sendable {
    private(set) var routes: [Int: WalkRoute] = [:]

    func route(for locationId: Int, from user: Coordinate) -> WalkRoute? {
        guard let route = routes[locationId], Compass.distance(route.origin, user) <= WalkTime.rerouteDistance else { return nil }
        return route
    }

    func needsRoute(for locationId: Int, from user: Coordinate) -> Bool {
        route(for: locationId, from: user) == nil
    }

    mutating func store(_ route: WalkRoute) {
        routes[route.locationId] = route
    }

    mutating func removeAll() {
        routes = [:]
    }
}

// MARK: - Now / next per location

struct LocationGlance: Hashable, Sendable {
    /// In progress at the location (the earliest-starting one when several are).
    var current: ScheduleItem?
    /// The next item to start there (not yet started).
    var next: ScheduleItem?

    /// Pins: "Next 7:30" when the next item starts within this window.
    static let pinNextWindow: TimeInterval = 3 * 3600

    static func make(locationId: Int, schedule: [ScheduleItem], now: Date) -> LocationGlance {
        all(schedule: schedule, now: now)[locationId] ?? LocationGlance()
    }

    /// Glances for every location with schedule items (keyed by location id).
    static func all(schedule: [ScheduleItem], now: Date) -> [Int: LocationGlance] {
        var result: [Int: LocationGlance] = [:]
        for item in schedule {
            guard let locationId = item.locationId, let start = item.startTime else { continue }
            var glance = result[locationId] ?? LocationGlance()
            if ScheduleTiming.isHappening(item, at: now) {
                if glance.current.map({ earlier(item, than: $0) }) ?? true { glance.current = item }
            } else if start > now {
                if glance.next.map({ earlier(item, than: $0) }) ?? true { glance.next = item }
            }
            result[locationId] = glance
        }
        return result
    }

    private static func earlier(_ a: ScheduleItem, than b: ScheduleItem) -> Bool {
        let sa = a.startTime ?? .distantFuture, sb = b.startTime ?? .distantFuture
        return sa != sb ? sa < sb : a.id < b.id
    }

    var isLive: Bool { current != nil }

    /// "Next 7:30" when the next item starts within 3 h, else nil.
    func pinSubtitle(now: Date, timeZone: TimeZone, locale: Locale = .current) -> String? {
        guard let start = next?.startTime, start.timeIntervalSince(now) <= Self.pinNextWindow else { return nil }
        return "Next " + EventTimeFormat.clock(start, in: timeZone, locale: locale)
    }

    /// Location rows: "Now: Prairie Lights · Next 8:30 Midnight Choir" ("Next Sun 10:00 …" on
    /// another day); nil when nothing is on or coming.
    func rowLine(now: Date, timeZone: TimeZone, locale: Locale = .current) -> String? {
        var parts: [String] = []
        if let current { parts.append("Now: \(current.name)") }
        if let next, let start = next.startTime {
            let sameDay = EventTimeFormat.calendar(in: timeZone).isDate(start, inSameDayAs: now)
            let time = sameDay
                ? EventTimeFormat.clock(start, in: timeZone, locale: locale)
                : EventTimeFormat.weekdayClock(start, in: timeZone, locale: locale)
            parts.append("Next \(time) \(next.name)")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// A chip in the map's "now playing" strip.
struct NowPlayingItem: Identifiable, Hashable, Sendable {
    var itemId: Int
    var locationId: Int
    /// "Main Stage · Prairie Lights".
    var title: String
    var id: Int { itemId }

    /// Items in progress at a location that has a pin, by start time, then location order.
    static func items(schedule: [ScheduleItem], locations: [Location], now: Date) -> [NowPlayingItem] {
        let order = Dictionary(locations.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
        let byId = Dictionary(locations.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return schedule
            .filter { ScheduleTiming.isHappening($0, at: now) }
            .compactMap { item -> (ScheduleItem, Location)? in
                guard let id = item.locationId, let location = byId[id], location.coordinate != nil else { return nil }
                return (item, location)
            }
            .sorted { a, b in
                let sa = a.0.startTime ?? .distantPast, sb = b.0.startTime ?? .distantPast
                if sa != sb { return sa < sb }
                let oa = order[a.1.id] ?? 0, ob = order[b.1.id] ?? 0
                if oa != ob { return oa < ob }
                return a.0.id < b.0.id
            }
            .map { NowPlayingItem(itemId: $0.0.id, locationId: $0.1.id, title: "\($0.1.name) · \($0.0.name)") }
    }
}

extension ScheduleTiming {
    /// How far through an item in progress is (0…1); nil when it isn't in progress.
    static func progress(_ item: ScheduleItem, at now: Date) -> Double? {
        guard isHappening(item, at: now), let start = item.startTime, let end = effectiveEnd(of: item) else { return nil }
        let total = end.timeIntervalSince(start)
        guard total > 0 else { return nil }
        return min(max(now.timeIntervalSince(start) / total, 0), 1)
    }
}

// MARK: - Tags (API-010)

/// Tags arrive lower case ("live music"); filter and search on them as sent, capitalise only to show them.
enum TagText {
    /// "live music" → "Live music", "kid-friendly" → "Kid-friendly", "21+" → "21+".
    static func display(_ tag: String) -> String {
        guard let first = tag.first else { return tag }
        return first.uppercased() + tag.dropFirst()
    }

    /// "Live music · Free".
    static func line(_ tags: [String]) -> String {
        tags.map(display).joined(separator: " · ")
    }
}

// MARK: - Unread updates

enum UpdatesInbox {
    /// The banner shows an unread update for this long after it was sent.
    static let bannerWindow: TimeInterval = 24 * 3600

    /// Updates sent after `seenAt` (all of them when the tab was never seen). Updates without
    /// a send time never count.
    static func unread(_ notifications: [AppNotification], seenAt: Date?) -> [AppNotification] {
        notifications.filter { notification in
            guard let sent = notification.sendTime else { return false }
            return seenAt.map { sent > $0 } ?? true
        }
    }

    static func unreadCount(_ notifications: [AppNotification], seenAt: Date?) -> Int {
        unread(notifications, seenAt: seenAt).count
    }

    /// The newest unread update sent within the last 24 h, unless its banner was dismissed.
    static func banner(_ notifications: [AppNotification], seenAt: Date?, dismissedId: Int?, now: Date) -> AppNotification? {
        let newest = unread(notifications, seenAt: seenAt).max { a, b in
            let sa = a.sendTime ?? .distantPast, sb = b.sendTime ?? .distantPast
            return sa != sb ? sa < sb : a.id < b.id
        }
        guard let newest, let sent = newest.sendTime, newest.id != dismissedId,
              now.timeIntervalSince(sent) < bannerWindow else { return nil }
        return newest
    }

    /// Urgent announcements (API-011) stay front and centre this long after they were sent.
    static let urgentWindow: TimeInterval = 12 * 3600

    /// The newest urgent announcement sent within the last 12 h that wasn't dismissed (seen or
    /// not): the prominent red banner above the tabs and the Live Activity's urgent block. A
    /// send time slightly in the future (clock skew) still counts.
    static func urgent(_ notifications: [AppNotification], dismissed: Set<Int>, now: Date) -> AppNotification? {
        notifications
            .filter { notification in
                guard notification.isUrgent, !dismissed.contains(notification.id),
                      let sent = notification.sendTime else { return false }
                let age = now.timeIntervalSince(sent)
                return age < urgentWindow && age > -5 * 60
            }
            .max { a, b in
                let sa = a.sendTime ?? .distantPast, sb = b.sendTime ?? .distantPast
                return sa != sb ? sa < sb : a.id < b.id
            }
    }

    /// What to store as "seen" when the Updates tab is shown: now, or the newest send time if
    /// the server's clock is ahead of the device's.
    static func seenMark(_ notifications: [AppNotification], now: Date) -> Date {
        let newest = notifications.compactMap(\.sendTime).max() ?? now
        return max(now, newest)
    }
}

// MARK: - Per-event personal state (hearts, Updates seen)

/// What the attendee did in one event, kept on the device only (UserDefaults, so it is in the
/// device backup): hearted locations and schedule items, when the Updates tab was last seen and
/// the update whose banner was dismissed. Decoding is lenient so a newer build's file still loads.
struct EventPersonalState: Codable, Hashable, Sendable {
    var heartedLocations: Set<Int> = []
    var heartedScheduleItems: Set<Int> = []
    var updatesSeenAt: Date? = nil
    var dismissedUpdateBannerId: Int? = nil
    /// Urgent announcements (API-011) the user dismissed (banner or Live Activity).
    var dismissedUrgentIds: Set<Int> = []
    /// "Follow on Lock Screen" (Live Activity): nil = the default (on once something is hearted).
    var followOnLockScreen: Bool? = nil
    /// Schedule items skipped in the Live Activity ("Skip").
    var skippedItems: Set<Int> = []
    /// My schedule (iOS, Nov 21, 2026): nil until the event's likes and plan were migrated
    /// (`AppState.loadPersonalState`). The hearted sets above mirror its entries.
    var mySchedule: MySchedule? = nil

    init() {}

    private enum CodingKeys: String, CodingKey {
        case heartedLocations, heartedScheduleItems, updatesSeenAt, dismissedUpdateBannerId
        case dismissedUrgentIds, followOnLockScreen, skippedItems, mySchedule
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        heartedLocations = c.lenient(Set<Int>.self, .heartedLocations) ?? []
        heartedScheduleItems = c.lenient(Set<Int>.self, .heartedScheduleItems) ?? []
        updatesSeenAt = c.lenient(Date.self, .updatesSeenAt)
        dismissedUpdateBannerId = c.lenient(Int.self, .dismissedUpdateBannerId)
        dismissedUrgentIds = c.lenient(Set<Int>.self, .dismissedUrgentIds) ?? []
        followOnLockScreen = c.lenient(Bool.self, .followOnLockScreen)
        skippedItems = c.lenient(Set<Int>.self, .skippedItems) ?? []
        mySchedule = c.lenient(MySchedule.self, .mySchedule)
    }

    /// My schedule (empty before the migration).
    var schedule: MySchedule { mySchedule ?? MySchedule() }

    /// Runs `change` on My schedule and mirrors its entries into the hearted sets.
    mutating func updateSchedule<T>(_ change: (inout MySchedule) -> T) -> T {
        var schedule = self.schedule
        let result = change(&schedule)
        mySchedule = schedule
        heartedScheduleItems = schedule.itemIds
        heartedLocations = schedule.placeIds
        return result
    }

    /// Migrates the likes (and the plan of an older build) once; true when it ran.
    mutating func migrateSchedule(plan: Plan?) -> Bool {
        guard mySchedule == nil else { return false }
        let migrated = MySchedule.migrate(heartedItems: heartedScheduleItems, heartedLocations: heartedLocations, plan: plan)
        updateSchedule { $0 = migrated }
        return true
    }

    /// Whether the Live Activity follows this event: the user's choice, else on (batch 7: it
    /// starts on join).
    var followsOnLockScreen: Bool { followOnLockScreen ?? true }

    var hasHearts: Bool { !heartedLocations.isEmpty || !heartedScheduleItems.isEmpty }

    func isHearted(_ target: SearchTarget) -> Bool {
        switch target {
        case .location(let id):     return heartedLocations.contains(id)
        case .scheduleItem(let id): return heartedScheduleItems.contains(id)
        case .notification, .event: return false
        }
    }

    /// Adds a location or schedule item to My schedule (a place saved without a time) or removes
    /// it. Returns the usage metric to count (API-009), nil when nothing changed or the target
    /// can't be in My schedule.
    @discardableResult
    mutating func setHeart(_ hearted: Bool, for target: SearchTarget) -> UsageMetric? {
        updateSchedule { schedule in
            (hearted ? schedule.add(target) : schedule.remove(target))?.metric
        }
    }

    /// Hearted items that are still in the bundle: schedule items (by start), then locations
    /// (organizer order).
    func heartedTargets(in bundle: EventBundle) -> [SearchTarget] {
        let items = bundle.schedule
            .filter { heartedScheduleItems.contains($0.id) }
            .sorted { ($0.startTime ?? .distantFuture, $0.id) < ($1.startTime ?? .distantFuture, $1.id) }
            .map { SearchTarget.scheduleItem($0.id) }
        let places = bundle.locations.filter { heartedLocations.contains($0.id) }.map { SearchTarget.location($0.id) }
        return items + places
    }
}
