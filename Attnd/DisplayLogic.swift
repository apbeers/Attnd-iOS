// DisplayLogic.swift
// Attnd
//
// Pure functions behind the server-driven display config: schedule grouping
// (timeline / by day / by location / now-next), location grouping, search,
// map clustering and region fitting, and fold-aware overlay insets.
//
// Nothing in here touches SwiftUI, MapKit or app state, so it is all unit-tested.

import CoreGraphics
import Foundation

// MARK: - Sections

struct ScheduleSection: Identifiable, Hashable, Sendable {
    var id: String
    var title: String
    var items: [ScheduleItem]
}

struct LocationSection: Identifiable, Hashable, Sendable {
    var id: String
    var title: String
    var locations: [Location]
}

// MARK: - Schedule timing

enum ScheduleTiming {
    /// Assumed duration when an item has no end time.
    static let defaultDuration: TimeInterval = 60 * 60
    /// "Up next" covers this window after now.
    static let upNextWindow: TimeInterval = 2 * 60 * 60

    static func effectiveEnd(of item: ScheduleItem) -> Date? {
        guard let start = item.startTime else { return nil }
        if let end = item.endTime, end > start { return end }
        return start.addingTimeInterval(defaultDuration)
    }

    static func isHappening(_ item: ScheduleItem, at now: Date) -> Bool {
        guard let start = item.startTime, let end = effectiveEnd(of: item) else { return false }
        return start <= now && now < end
    }

    static func hasEnded(_ item: ScheduleItem, at now: Date) -> Bool {
        guard let end = effectiveEnd(of: item) else { return false }
        return end <= now
    }
}

// MARK: - Schedule grouping

enum ScheduleGrouping {

    static let generalTitle = "General"

    static func sections(
        for items: [ScheduleItem],
        style: ScheduleStyle,
        now: Date,
        timeZone: TimeZone,
        locations: [Location]
    ) -> [ScheduleSection] {
        switch style {
        case .timeline:   return timeline(items)
        case .byDay:      return byDay(items, timeZone: timeZone)
        case .byLocation: return byLocation(items, locations: locations)
        case .nowNext:    return nowNext(items, now: now)
        }
    }

    /// One chronological list (the server already sorts by start time).
    static func timeline(_ items: [ScheduleItem]) -> [ScheduleSection] {
        items.isEmpty ? [] : [ScheduleSection(id: "timeline", title: "", items: items)]
    }

    /// One section per calendar day in the event's time zone, in date order.
    /// Items without a start time go last under "Time TBA".
    static func byDay(_ items: [ScheduleItem], timeZone: TimeZone) -> [ScheduleSection] {
        let cal = EventTimeFormat.calendar(in: timeZone)
        var days: [Date: [ScheduleItem]] = [:]
        var undated: [ScheduleItem] = []
        for item in items {
            if let start = item.startTime {
                days[cal.startOfDay(for: start), default: []].append(item)
            } else {
                undated.append(item)
            }
        }
        var sections = days.keys.sorted().map { day in
            ScheduleSection(
                id: "day-\(Int(day.timeIntervalSince1970))",
                title: EventTimeFormat.dayTitle(day, in: timeZone),
                items: days[day] ?? []
            )
        }
        if !undated.isEmpty {
            sections.append(ScheduleSection(id: "day-tba", title: "Time TBA", items: undated))
        }
        return sections
    }

    /// One section per location, in the organizer's location order. Locations the
    /// bundle doesn't list come next (alphabetically); items with no location go
    /// last under "General".
    static func byLocation(_ items: [ScheduleItem], locations: [Location]) -> [ScheduleSection] {
        var byId: [Int: [ScheduleItem]] = [:]
        var general: [ScheduleItem] = []
        for item in items {
            if let id = item.locationId {
                byId[id, default: []].append(item)
            } else {
                general.append(item)
            }
        }
        var sections: [ScheduleSection] = []
        var used = Set<Int>()
        for location in locations {
            guard let group = byId[location.id], used.insert(location.id).inserted else { continue }
            sections.append(ScheduleSection(id: "loc-\(location.id)", title: location.name, items: group))
        }
        let unknown = byId.keys.filter { !used.contains($0) }.map { id -> ScheduleSection in
            let group = byId[id] ?? []
            let title = group.first?.locationName ?? "Location \(id)"
            return ScheduleSection(id: "loc-\(id)", title: title, items: group)
        }
        sections += unknown.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        if !general.isEmpty {
            sections.append(ScheduleSection(id: "loc-general", title: generalTitle, items: general))
        }
        return sections
    }

    /// "Happening now", then "Up next" (starting within 2 hours), then "Later".
    /// Ended items are left out; empty sections are omitted.
    static func nowNext(_ items: [ScheduleItem], now: Date) -> [ScheduleSection] {
        var happening: [ScheduleItem] = []
        var upNext: [ScheduleItem] = []
        var later: [ScheduleItem] = []
        let horizon = now.addingTimeInterval(ScheduleTiming.upNextWindow)
        for item in items {
            if ScheduleTiming.isHappening(item, at: now) {
                happening.append(item)
            } else if ScheduleTiming.hasEnded(item, at: now) {
                continue
            } else if let start = item.startTime, start <= horizon {
                upNext.append(item)
            } else {
                later.append(item)
            }
        }
        return [
            ScheduleSection(id: "now", title: "Happening now", items: happening),
            ScheduleSection(id: "next", title: "Up next", items: upNext),
            ScheduleSection(id: "later", title: "Later", items: later),
        ].filter { !$0.items.isEmpty }
    }
}

// MARK: - Location grouping & filtering

enum LocationGrouping {

    static let uncategorizedTitle = "Other"

    /// Sections per category, ordered like `categoryOrder` (the bundle's `categories`),
    /// then any other categories alphabetically, then uncategorized locations as "Other".
    /// Locations keep the organizer's order within each section.
    static func byCategory(_ locations: [Location], categoryOrder: [String]) -> [LocationSection] {
        var groups: [String: [Location]] = [:]
        var uncategorized: [Location] = []
        for location in locations {
            if let category = location.category {
                groups[category, default: []].append(location)
            } else {
                uncategorized.append(location)
            }
        }
        var order = categoryOrder.filter { groups[$0] != nil }
        let extra = groups.keys.filter { !order.contains($0) }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        order += extra
        var sections = order.map { LocationSection(id: "cat-\($0)", title: $0, locations: groups[$0] ?? []) }
        if !uncategorized.isEmpty {
            sections.append(LocationSection(id: "cat-none", title: uncategorizedTitle, locations: uncategorized))
        }
        return sections
    }

    /// Categories for the filter chips: the bundle's list, or (if empty) derived from locations.
    static func categories(_ bundleCategories: [String], locations: [Location]) -> [String] {
        if !bundleCategories.isEmpty { return bundleCategories }
        var seen = Set<String>()
        return locations.compactMap(\.category).filter { seen.insert($0).inserted }
    }

    static func filter(_ locations: [Location], category: String?) -> [Location] {
        guard let category else { return locations }
        return locations.filter { $0.category == category }
    }
}

// MARK: - A place's events (Places list disclosure)

/// What a place row's disclosure lists: the place's schedule items that haven't ended (in
/// progress first by start, then upcoming; no start time last), or — when nothing is ahead —
/// its ended items, shown greyed as "Ended". nil when the place has no items (no disclosure).
struct PlaceEvents: Hashable, Sendable {
    var items: [ScheduleItem]
    /// Every item has ended (they are listed greyed).
    var allEnded: Bool

    static func make(locationId: Int, schedule: [ScheduleItem], now: Date) -> PlaceEvents? {
        let here = schedule.filter { $0.locationId == locationId }
        guard !here.isEmpty else { return nil }
        let ahead = here.filter { !ScheduleTiming.hasEnded($0, at: now) }
        let listed = ahead.isEmpty ? here : ahead
        let sorted = listed.sorted { a, b in
            switch (a.startTime, b.startTime) {
            case let (x?, y?) where x != y: return x < y
            case (nil, _?): return false
            case (_?, nil): return true
            default: return a.id < b.id
            }
        }
        return PlaceEvents(items: sorted, allEnded: ahead.isEmpty)
    }

    /// The disclosure's label: "1 event", "3 events", "2 ended".
    var toggleTitle: String {
        let count = items.count
        if allEnded { return "\(count) ended" }
        return count == 1 ? "1 event" : "\(count) events"
    }
}

// MARK: - Search

enum SearchMatching {
    static func matches(_ location: Location, query: String) -> Bool {
        let q = normalised(query)
        guard !q.isEmpty else { return true }
        return [location.name, location.snippet, location.description, location.address, location.category ?? ""]
            .contains { $0.localizedStandardContains(q) }
    }

    static func matches(_ item: ScheduleItem, query: String) -> Bool {
        let q = normalised(query)
        guard !q.isEmpty else { return true }
        return ([item.name, item.description, item.locationName ?? ""] + item.tags)
            .contains { $0.localizedStandardContains(q) }
    }

    private static func normalised(_ query: String) -> String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Map clustering

struct MapCluster: Identifiable, Hashable, Sendable {
    var id: String
    var coordinate: Coordinate
    var locations: [Location]

    var isSingle: Bool { locations.count == 1 }
}

enum MapClustering {

    /// Groups locations that fall into the same cell of a grid laid over the
    /// visible span. Zooming in shrinks the cells, so clusters split apart.
    /// Locations without a valid coordinate are never placed on the map.
    static func clusters(
        for locations: [Location],
        latitudeDelta: Double,
        longitudeDelta: Double,
        gridDivisions: Double = 6
    ) -> [MapCluster] {
        let placed = locations.compactMap { loc in loc.coordinate.map { (loc, $0) } }
        let cellLat = max(latitudeDelta, 0.000_1) / gridDivisions
        let cellLng = max(longitudeDelta, 0.000_1) / gridDivisions

        struct Cell: Hashable { var row: Int; var col: Int }
        var order: [Cell] = []
        var members: [Cell: [(Location, Coordinate)]] = [:]
        for entry in placed {
            let cell = Cell(
                row: Int((entry.1.latitude / cellLat).rounded(.down)),
                col: Int((entry.1.longitude / cellLng).rounded(.down))
            )
            if members[cell] == nil { order.append(cell) }
            members[cell, default: []].append(entry)
        }
        return order.compactMap { cell in
            guard let group = members[cell], !group.isEmpty else { return nil }
            let lat = group.map { $0.1.latitude }.reduce(0, +) / Double(group.count)
            let lng = group.map { $0.1.longitude }.reduce(0, +) / Double(group.count)
            let ids = group.map { $0.0.id }
            let id = ids.count == 1 ? "loc-\(ids[0])" : "cluster-" + ids.sorted().map(String.init).joined(separator: "-")
            return MapCluster(id: id, coordinate: Coordinate(latitude: lat, longitude: lng), locations: group.map { $0.0 })
        }
    }

    /// Every valid location as its own (single) cluster — used when clustering is off.
    static func unclustered(_ locations: [Location]) -> [MapCluster] {
        locations.compactMap { loc in
            loc.coordinate.map { MapCluster(id: "loc-\(loc.id)", coordinate: $0, locations: [loc]) }
        }
    }
}

// MARK: - Map regions

struct MapRegionSpec: Hashable, Sendable {
    var center: Coordinate
    var latitudeDelta: Double
    var longitudeDelta: Double
}

enum MapRegionMath {
    static let streetLevelDelta = 0.01
    static let minimumDelta = 0.004

    /// The smallest region showing every coordinate, with some padding. nil if empty.
    static func fitting(_ coordinates: [Coordinate], padding: Double = 1.4) -> MapRegionSpec? {
        guard let first = coordinates.first else { return nil }
        var minLat = first.latitude, maxLat = first.latitude
        var minLng = first.longitude, maxLng = first.longitude
        for c in coordinates.dropFirst() {
            minLat = min(minLat, c.latitude); maxLat = max(maxLat, c.latitude)
            minLng = min(minLng, c.longitude); maxLng = max(maxLng, c.longitude)
        }
        return MapRegionSpec(
            center: Coordinate(latitude: (minLat + maxLat) / 2, longitude: (minLng + maxLng) / 2),
            latitudeDelta: min(max((maxLat - minLat) * padding, minimumDelta), 180),
            longitudeDelta: min(max((maxLng - minLng) * padding, minimumDelta), 360)
        )
    }

    /// Street-level region centred on a coordinate.
    static func streetLevel(_ center: Coordinate) -> MapRegionSpec {
        MapRegionSpec(center: center, latitudeDelta: streetLevelDelta, longitudeDelta: streetLevelDelta)
    }

    /// The initial region: fit all pins when `fitAll`, else the event at street level.
    /// Each falls back to the other when it has nothing to show.
    static func initialRegion(fitAll: Bool, event: Coordinate?, locations: [Coordinate]) -> MapRegionSpec? {
        let fitted = fitting(locations)
        let street = event.map(streetLevel)
        return fitAll ? (fitted ?? street) : (street ?? fitted)
    }

    /// A tighter region around a cluster, for "tap to zoom in".
    static func zoomIn(on cluster: MapCluster, currentLatitudeDelta: Double, currentLongitudeDelta: Double) -> MapRegionSpec {
        let fitted = fitting(cluster.locations.compactMap(\.coordinate))
        let lat = min(fitted?.latitudeDelta ?? .infinity, currentLatitudeDelta / 3)
        let lng = min(fitted?.longitudeDelta ?? .infinity, currentLongitudeDelta / 3)
        return MapRegionSpec(
            center: fitted?.center ?? cluster.coordinate,
            latitudeDelta: max(lat, minimumDelta / 4),
            longitudeDelta: max(lng, minimumDelta / 4)
        )
    }
}

// MARK: - Walking map (place detail)

/// The small walking map on a place's detail (instead of the big "Get Walking Directions"
/// button): only with a position (permission), the user more than "here" and within walking range
/// (8 km), never in screenshot mode. It frames the user, the place and the route's line.
enum PlaceWalkMap {
    static func shows(distanceMeters: Double?, screenshotMode: Bool) -> Bool {
        guard !screenshotMode, let meters = distanceMeters else { return false }
        return meters >= DistanceText.hereMeters && WalkTime.isWithinWalkingRange(meters)
    }

    /// The region showing the user, the place and the drawn line (route or straight line).
    static func region(user: Coordinate, destination: Coordinate, line: [Coordinate]) -> MapRegionSpec? {
        MapRegionMath.fitting([user, destination] + line, padding: 1.6)
    }
}

// MARK: - Fold / camera avoidance

/// Insets that keep floating overlays clear of reserved hardware regions
/// (the hinge of a foldable, camera housings).
enum ReservedRegionLayout {

    struct Insets: Hashable, Sendable {
        var top: CGFloat = 0
        var leading: CGFloat = 0
        var bottom: CGFloat = 0
        var trailing: CGFloat = 0
    }

    /// - Parameters:
    ///   - size: the overlay container's size.
    ///   - reserved: reserved rects in the container's coordinate space (leading = minX).
    ///   - minimumWidth: if the trailing side of a vertical fold is narrower than this,
    ///     the wider side is used instead.
    /// Vertical strips (a fold seen in a wide posture, a camera housing in landscape)
    /// confine overlays to one side. Horizontal strips hugging the top or bottom edge
    /// (a camera housing) push overlays below / above them. A horizontal strip across
    /// the middle (a fold in a tall posture) is left alone: edge-anchored overlays
    /// already stay on their own half.
    static func insets(container size: CGSize, avoiding reserved: [CGRect], minimumWidth: CGFloat = 280) -> Insets {
        var band = CGRect(origin: .zero, size: size)
        for raw in reserved {
            let rect = raw.intersection(CGRect(origin: .zero, size: size))
            guard !rect.isNull, !rect.isEmpty, rect.intersects(band) else { continue }
            if rect.height > rect.width {
                // Vertical strip: keep the side we can fit in, preferring trailing.
                let leadingWidth = rect.minX - band.minX
                let trailingWidth = band.maxX - rect.maxX
                if trailingWidth >= minimumWidth || trailingWidth >= leadingWidth {
                    band = CGRect(x: rect.maxX, y: band.minY, width: max(trailingWidth, 0), height: band.height)
                } else {
                    band = CGRect(x: band.minX, y: band.minY, width: max(leadingWidth, 0), height: band.height)
                }
            } else if rect.midY < size.height * 0.25 {
                // Horizontal strip along the top edge: start below it.
                let newMinY = max(band.minY, rect.maxY)
                band = CGRect(x: band.minX, y: newMinY, width: band.width, height: max(band.maxY - newMinY, 0))
            } else if rect.midY > size.height * 0.75 {
                // Horizontal strip along the bottom edge: end above it.
                let newMaxY = min(band.maxY, rect.minY)
                band = CGRect(x: band.minX, y: band.minY, width: band.width, height: max(newMaxY - band.minY, 0))
            }
        }
        return Insets(
            top: band.minY,
            leading: band.minX,
            bottom: size.height - band.maxY,
            trailing: size.width - band.maxX
        )
    }
}
