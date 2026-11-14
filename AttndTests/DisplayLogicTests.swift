// DisplayLogicTests.swift
// AttndTests
//
// The pure logic behind the server-driven display config: schedule grouping
// (by day in the event's time zone, by location, now/next), location grouping,
// search, map clustering and framing, fold-avoiding overlay insets, and the
// offline media cache rules (API-007: file names, prefetch set, pruning, sniffing).

import XCTest
@testable import Attnd

final class DisplayLogicTests: XCTestCase {

    private func date(_ iso: String) -> Date {
        guard let d = ISODate.parse(iso) else { fatalError("bad fixture date \(iso)") }
        return d
    }

    private func item(_ id: Int, _ start: String?, end: String? = nil, location: Int? = nil,
                      locationName: String? = nil, tags: [String] = []) -> ScheduleItem {
        ScheduleItem(
            id: id, name: "Item \(id)",
            startTime: start.map(date), endTime: end.map(date),
            locationId: location, locationName: locationName, tags: tags
        )
    }

    private let chicago = TimeZone(identifier: "America/Chicago")!
    private let utc = TimeZone(identifier: "UTC")!

    // MARK: - By day

    func testByDay_GroupsInEventTimeZone() {
        // 23:30 Chicago on the 14th is the 15th in UTC.
        let items = [
            item(1, "2026-11-14T23:30:00-06:00"),
            item(2, "2026-11-15T01:00:00-06:00"),
            item(3, "2026-11-15T10:00:00-06:00"),
        ]
        let chicagoDays = ScheduleGrouping.byDay(items, timeZone: chicago)
        XCTAssertEqual(chicagoDays.map { $0.items.map(\.id) }, [[1], [2, 3]])

        // In UTC all three are on the 15th (05:30Z, 07:00Z, 16:00Z).
        let utcDays = ScheduleGrouping.byDay(items, timeZone: utc)
        XCTAssertEqual(utcDays.map { $0.items.map(\.id) }, [[1, 2, 3]])
    }

    func testByDay_SortsDaysAndPutsUndatedLast() {
        let items = [
            item(1, "2026-11-15T10:00:00-06:00"),
            item(2, nil),
            item(3, "2026-11-14T10:00:00-06:00"),
        ]
        let sections = ScheduleGrouping.byDay(items, timeZone: chicago)
        XCTAssertEqual(sections.map { $0.items.map(\.id) }, [[3], [1], [2]])
        XCTAssertEqual(sections.last?.id, "day-tba")
        XCTAssertEqual(Set(sections.map(\.id)).count, sections.count, "section ids are unique")
    }

    // MARK: - Timeline

    func testTimeline_SingleSectionInServerOrder() {
        let items = [item(2, "2026-11-14T10:00:00Z"), item(1, "2026-11-14T11:00:00Z")]
        let sections = ScheduleGrouping.timeline(items)
        XCTAssertEqual(sections.count, 1)
        XCTAssertEqual(sections[0].items.map(\.id), [2, 1])
        XCTAssertTrue(ScheduleGrouping.timeline([]).isEmpty)
    }

    // MARK: - By location

    func testByLocation_OrganizerOrder_UnknownThenGeneral() {
        let locations = [Location(id: 20, name: "Stage B"), Location(id: 10, name: "Stage A")]
        let items = [
            item(1, "2026-11-14T10:00:00Z", location: 10),
            item(2, "2026-11-14T11:00:00Z"),
            item(3, "2026-11-14T12:00:00Z", location: 20),
            item(4, "2026-11-14T13:00:00Z", location: 99, locationName: "Hidden tent"),
            item(5, "2026-11-14T14:00:00Z", location: 10),
        ]
        let sections = ScheduleGrouping.byLocation(items, locations: locations)
        XCTAssertEqual(sections.map(\.title), ["Stage B", "Stage A", "Hidden tent", "General"])
        XCTAssertEqual(sections[1].items.map(\.id), [1, 5])
        XCTAssertEqual(sections[3].items.map(\.id), [2])
    }

    // MARK: - Now / next

    func testNowNext_Buckets() {
        let now = date("2026-11-14T12:00:00Z")
        let items = [
            item(1, "2026-11-14T10:00:00Z", end: "2026-11-14T11:00:00Z"), // ended
            item(2, "2026-11-14T11:30:00Z", end: "2026-11-14T13:00:00Z"), // happening
            item(3, "2026-11-14T11:30:00Z"),                              // happening (default 1h)
            item(4, "2026-11-14T13:30:00Z"),                              // up next (< 2h)
            item(5, "2026-11-14T14:00:00Z"),                              // up next (exactly 2h)
            item(6, "2026-11-14T15:00:00Z"),                              // later
            item(7, nil),                                                 // later (TBA)
            item(8, "2026-11-14T10:30:00Z"),                              // ended (default 1h)
        ]
        let sections = ScheduleGrouping.nowNext(items, now: now)
        XCTAssertEqual(sections.map(\.id), ["now", "next", "later"])
        XCTAssertEqual(sections[0].items.map(\.id), [2, 3])
        XCTAssertEqual(sections[1].items.map(\.id), [4, 5])
        XCTAssertEqual(sections[2].items.map(\.id), [6, 7])
    }

    func testNowNext_OmitsEmptySections() {
        let now = date("2026-11-14T12:00:00Z")
        let sections = ScheduleGrouping.nowNext([item(1, "2026-11-14T20:00:00Z")], now: now)
        XCTAssertEqual(sections.map(\.id), ["later"])
        XCTAssertTrue(ScheduleGrouping.nowNext([], now: now).isEmpty)
    }

    func testSections_DispatchesOnStyle() {
        let items = [item(1, "2026-11-14T10:00:00Z", location: 1)]
        let locs = [Location(id: 1, name: "A")]
        let now = date("2026-11-14T09:00:00Z")
        XCTAssertEqual(ScheduleGrouping.sections(for: items, style: .timeline, now: now, timeZone: utc, locations: locs).first?.id, "timeline")
        XCTAssertEqual(ScheduleGrouping.sections(for: items, style: .byLocation, now: now, timeZone: utc, locations: locs).first?.id, "loc-1")
        XCTAssertEqual(ScheduleGrouping.sections(for: items, style: .nowNext, now: now, timeZone: utc, locations: locs).first?.id, "next")
    }

    // MARK: - Timing

    func testHasEnded_UsesEndTimeOrDefaultDuration() {
        let now = date("2026-11-14T12:00:00Z")
        XCTAssertTrue(ScheduleTiming.hasEnded(item(1, "2026-11-14T10:00:00Z"), at: now))
        XCTAssertFalse(ScheduleTiming.hasEnded(item(2, "2026-11-14T10:00:00Z", end: "2026-11-14T13:00:00Z"), at: now))
        XCTAssertFalse(ScheduleTiming.hasEnded(item(3, nil), at: now))
    }

    // MARK: - Locations

    func testLocationsByCategory() {
        let locations = [
            Location(id: 1, name: "Grill", category: "Food"),
            Location(id: 2, name: "Info"),
            Location(id: 3, name: "Main", category: "Stage"),
            Location(id: 4, name: "Tacos", category: "Food"),
            Location(id: 5, name: "Shop", category: "Merch"),
        ]
        let sections = LocationGrouping.byCategory(locations, categoryOrder: ["Stage", "Food"])
        XCTAssertEqual(sections.map(\.title), ["Stage", "Food", "Merch", "Other"])
        XCTAssertEqual(sections[1].locations.map(\.id), [1, 4])
        XCTAssertEqual(sections[3].locations.map(\.id), [2])
    }

    func testCategoriesAndFilter() {
        let locations = [Location(id: 1, name: "A", category: "Food"), Location(id: 2, name: "B", category: "Stage"),
                         Location(id: 3, name: "C", category: "Food")]
        XCTAssertEqual(LocationGrouping.categories([], locations: locations), ["Food", "Stage"])
        XCTAssertEqual(LocationGrouping.categories(["Stage"], locations: locations), ["Stage"])
        XCTAssertEqual(LocationGrouping.filter(locations, category: "Food").map(\.id), [1, 3])
        XCTAssertEqual(LocationGrouping.filter(locations, category: nil).count, 3)
    }

    // MARK: - Search

    func testSearch() {
        let loc = Location(id: 1, name: "Café Olé", snippet: "Coffee", category: "Food")
        XCTAssertTrue(SearchMatching.matches(loc, query: "cafe"))
        XCTAssertTrue(SearchMatching.matches(loc, query: "food"))
        XCTAssertTrue(SearchMatching.matches(loc, query: "  "))
        XCTAssertFalse(SearchMatching.matches(loc, query: "stage"))

        let it = item(1, nil, locationName: "Main Stage", tags: ["Music"])
        XCTAssertTrue(SearchMatching.matches(it, query: "music"))
        XCTAssertTrue(SearchMatching.matches(it, query: "main"))
        XCTAssertFalse(SearchMatching.matches(it, query: "food"))
    }

    // MARK: - Map

    func testClustering_GroupsNearbyAndSplitsWhenZoomedIn() {
        let locations = [
            Location(id: 1, name: "A", latitude: 32.7500, longitude: -97.3300),
            Location(id: 2, name: "B", latitude: 32.7501, longitude: -97.3301),
            Location(id: 3, name: "C", latitude: 32.9000, longitude: -97.1000),
            Location(id: 4, name: "No coords"),
            Location(id: 5, name: "Zero", latitude: 0, longitude: 0),
        ]
        let zoomedOut = MapClustering.clusters(for: locations, latitudeDelta: 1, longitudeDelta: 1)
        XCTAssertEqual(zoomedOut.reduce(0) { $0 + $1.locations.count }, 3, "no pin without a real coordinate")
        XCTAssertTrue(zoomedOut.contains { Set($0.locations.map(\.id)) == [1, 2] })

        let zoomedIn = MapClustering.clusters(for: locations, latitudeDelta: 0.0001, longitudeDelta: 0.0001)
        XCTAssertEqual(zoomedIn.count, 3)
        XCTAssertTrue(zoomedIn.allSatisfy(\.isSingle))
        XCTAssertEqual(Set(zoomedIn.map(\.id)).count, zoomedIn.count)

        XCTAssertEqual(MapClustering.unclustered(locations).map(\.id), ["loc-1", "loc-2", "loc-3"])
    }

    func testRegionFitting() throws {
        let coords = [Coordinate(latitude: 10, longitude: 20), Coordinate(latitude: 12, longitude: 24)]
        let region = try XCTUnwrap(MapRegionMath.fitting(coords))
        XCTAssertEqual(region.center, Coordinate(latitude: 11, longitude: 22))
        XCTAssertGreaterThanOrEqual(region.latitudeDelta, 2)
        XCTAssertGreaterThanOrEqual(region.longitudeDelta, 4)
        XCTAssertNil(MapRegionMath.fitting([]))

        let single = try XCTUnwrap(MapRegionMath.fitting([Coordinate(latitude: 1, longitude: 1)]))
        XCTAssertEqual(single.latitudeDelta, MapRegionMath.minimumDelta)
    }

    func testInitialRegion_FitAllVersusStreetLevel() throws {
        let event = Coordinate(latitude: 32.75, longitude: -97.33)
        let pins = [Coordinate(latitude: 32.70, longitude: -97.40), Coordinate(latitude: 32.80, longitude: -97.20)]
        let fit = try XCTUnwrap(MapRegionMath.initialRegion(fitAll: true, event: event, locations: pins))
        XCTAssertGreaterThan(fit.latitudeDelta, 0.1)
        let street = try XCTUnwrap(MapRegionMath.initialRegion(fitAll: false, event: event, locations: pins))
        XCTAssertEqual(street.center, event)
        XCTAssertEqual(street.latitudeDelta, MapRegionMath.streetLevelDelta)
        // Each falls back to the other.
        XCTAssertEqual(MapRegionMath.initialRegion(fitAll: false, event: nil, locations: pins)?.center, fit.center)
        XCTAssertEqual(MapRegionMath.initialRegion(fitAll: true, event: event, locations: [])?.center, event)
        XCTAssertNil(MapRegionMath.initialRegion(fitAll: true, event: nil, locations: []))
    }

    // MARK: - Reserved regions

    func testInsets_NoReservedRegions() {
        let insets = ReservedRegionLayout.insets(container: CGSize(width: 800, height: 600), avoiding: [])
        XCTAssertEqual(insets, .init())
    }

    func testInsets_VerticalFold_UsesTrailingSide() {
        // Open wide: a 20pt hinge down the middle.
        let insets = ReservedRegionLayout.insets(
            container: CGSize(width: 800, height: 600),
            avoiding: [CGRect(x: 390, y: 0, width: 20, height: 600)]
        )
        XCTAssertEqual(insets.leading, 410)
        XCTAssertEqual(insets.trailing, 0)
        XCTAssertEqual(insets.top, 0)
    }

    func testInsets_VerticalStripNearTrailingEdge_UsesLeadingSide() {
        let insets = ReservedRegionLayout.insets(
            container: CGSize(width: 800, height: 400),
            avoiding: [CGRect(x: 760, y: 100, width: 40, height: 200)]
        )
        XCTAssertEqual(insets.leading, 0)
        XCTAssertEqual(insets.trailing, 40)
    }

    func testInsets_TopCameraHousing_PushesBelow() {
        let insets = ReservedRegionLayout.insets(
            container: CGSize(width: 400, height: 800),
            avoiding: [CGRect(x: 150, y: 0, width: 100, height: 30)]
        )
        XCTAssertEqual(insets.top, 30)
        XCTAssertEqual(insets.bottom, 0)
    }

    func testInsets_HorizontalFoldAcrossMiddle_IsIgnored() {
        // Open tall: overlays are anchored to the top and bottom edges and never cross it.
        let insets = ReservedRegionLayout.insets(
            container: CGSize(width: 400, height: 800),
            avoiding: [CGRect(x: 0, y: 390, width: 400, height: 20)]
        )
        XCTAssertEqual(insets, .init())
    }

    func testInsets_RegionOutsideContainer_IsIgnored() {
        let insets = ReservedRegionLayout.insets(
            container: CGSize(width: 400, height: 800),
            avoiding: [CGRect(x: 500, y: 0, width: 20, height: 800)]
        )
        XCTAssertEqual(insets, .init())
    }


    // MARK: - Offline media cache (API-007)

    func testMediaFileName_StablePerURLWithSaneExtension() throws {
        let a = try XCTUnwrap(URL(string: "https://res.cloudinary.com/x/image/upload/v1/stage.JPG"))
        let name = MediaCache.fileName(for: a)
        XCTAssertEqual(name, MediaCache.fileName(for: a), "stable")
        XCTAssertTrue(name.hasSuffix(".jpg"))
        XCTAssertEqual(name.count, 64 + 4, "sha256 hex + extension")
        let b = try XCTUnwrap(URL(string: "https://example.com/image?id=5"))
        XCTAssertTrue(MediaCache.fileName(for: b).hasSuffix(".bin"))
        XCTAssertNotEqual(MediaCache.fileName(for: b), MediaCache.fileName(for: URL(string: "https://example.com/image?id=6")!))
        let weird = try XCTUnwrap(URL(string: "https://example.com/file.reallylongext"))
        XCTAssertTrue(MediaCache.fileName(for: weird).hasSuffix(".bin"))
    }

    func testMediaReferencedURLs_LogosImagesThenFlyer_Deduplicated() throws {
        let logo = URL(string: "https://attnd.app/media/logo.png")!
        let img = URL(string: "https://attnd.app/media/a.jpg")!
        let flyer = URL(string: "https://attnd.app/media/flyer.pdf")!
        var event = Event(id: 1, name: "E", eventCode: "E")
        event.logoUrl = logo
        event.flyerUrl = flyer
        var display = DisplayConfig.default
        display.logoUrl = logo
        let locations = [
            Location(id: 1, name: "A", imageUrl: img),
            Location(id: 2, name: "B"),
            Location(id: 3, name: "C", imageUrl: img),
            Location(id: 4, name: "D", imageUrl: URL(string: "file:///etc/passwd")),
        ]
        let bundle = EventBundle(event: event, display: display, locations: locations)
        XCTAssertEqual(MediaCache.referencedURLs(for: bundle), [logo, img, flyer])
        XCTAssertEqual(MediaCache.referencedURLs(event: nil, display: .default, locations: []), [])
    }

    func testMediaNeedsDownload_MissingOrStale() {
        let now = date("2026-11-14T12:00:00Z")
        XCTAssertTrue(MediaCache.needsDownload(existing: nil, now: now))
        let fresh = MediaCache.CachedFile(name: "a", bytes: 1, modified: now.addingTimeInterval(-3600))
        XCTAssertFalse(MediaCache.needsDownload(existing: fresh, now: now))
        let stale = MediaCache.CachedFile(name: "a", bytes: 1, modified: now.addingTimeInterval(-2 * 86_400))
        XCTAssertTrue(MediaCache.needsDownload(existing: stale, now: now))
    }

    func testMediaPrune_UnreferencedFirstThenLargestOverBudget() {
        let t = date("2026-11-14T12:00:00Z")
        let files = [
            MediaCache.CachedFile(name: "old", bytes: 10, modified: t),
            MediaCache.CachedFile(name: "big", bytes: 60, modified: t),
            MediaCache.CachedFile(name: "mid", bytes: 30, modified: t),
            MediaCache.CachedFile(name: "small", bytes: 5, modified: t),
        ]
        let referenced: Set<String> = ["big", "mid", "small"]
        XCTAssertEqual(MediaCache.filesToDelete(files, referenced: referenced, maxTotalBytes: 1000), ["old"])
        XCTAssertEqual(MediaCache.filesToDelete(files, referenced: referenced, maxTotalBytes: 40), ["old", "big"])
        XCTAssertEqual(MediaCache.filesToDelete(files, referenced: referenced, maxTotalBytes: 4), ["old", "big", "mid", "small"])
        XCTAssertEqual(MediaCache.filesToDelete([], referenced: referenced), [])
    }

    func testMediaSniffMIMEType() {
        XCTAssertEqual(MediaCache.sniffMIMEType(Data("%PDF-1.7".utf8)), "application/pdf")
        XCTAssertEqual(MediaCache.sniffMIMEType(Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A])), "image/png")
        XCTAssertEqual(MediaCache.sniffMIMEType(Data([0xFF, 0xD8, 0xFF, 0xE0])), "image/jpeg")
        XCTAssertEqual(MediaCache.sniffMIMEType(Data("GIF89a".utf8)), "image/gif")
        XCTAssertEqual(MediaCache.sniffMIMEType(Data("RIFF\u{0}\u{0}\u{0}\u{0}WEBPVP8 ".utf8)), "image/webp")
        XCTAssertEqual(MediaCache.sniffMIMEType(Data([0, 0, 0, 0x18] + Array("ftypheic".utf8))), "image/heic")
        XCTAssertNil(MediaCache.sniffMIMEType(Data("<html>".utf8)))
        XCTAssertNil(MediaCache.sniffMIMEType(Data()))
    }
}
