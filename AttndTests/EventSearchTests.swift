// EventSearchTests.swift
// AttndTests
//
// Local event search (EventSearch): the cases shared with the Android app. A fixed `now`
// (Saturday Nov 14, 2026, 2:00 PM in America/Chicago) and an event in America/Chicago.

import XCTest
@testable import Attnd

private func date(_ iso: String) -> Date {
    guard let d = ISODate.parse(iso) else { fatalError("bad fixture date \(iso)") }
    return d
}

final class EventSearchTests: XCTestCase {

    /// Saturday, Nov 14, 2026, 2:00 PM CST.
    private let now = date("2026-11-14T14:00:00-06:00")

    private let bundle: EventBundle = {
        let event = Event(
            id: 7, name: "Fall Fest", eventCode: "FALL26",
            description: "Music, food and fun by the river.",
            address: "100 Main St, Chicago",
            startTime: date("2026-11-14T08:00:00-06:00"),
            endTime: date("2026-11-15T18:00:00-06:00"),
            timeZoneIdentifier: "America/Chicago"
        )
        let locations = [
            Location(id: 1, name: "Main Stage", snippet: "Live music all day", category: "Stages",
                     latitude: 41.88, longitude: -87.63),
            Location(id: 2, name: "Food Court", snippet: "Tacos & more", category: "Food",
                     latitude: 41.881, longitude: -87.631),
            // No coordinates: never on the map, still searchable.
            Location(id: 3, name: "Café Lumière", snippet: "Coffee and pastries", category: "Food"),
            Location(id: 4, name: "Plaza", latitude: 41.882, longitude: -87.632),
        ]
        let schedule = [
            // Happening now (1:30–3:00 PM).
            ScheduleItem(id: 1, name: "Roaming Mariachi", description: "Strolling band",
                         startTime: date("2026-11-14T13:30:00-06:00"), endTime: date("2026-11-14T15:00:00-06:00"),
                         locationId: 4, locationName: "Plaza", tags: ["music"]),
            // Next (3:00–4:00 PM).
            ScheduleItem(id: 2, name: "Taco Tasting",
                         startTime: date("2026-11-14T15:00:00-06:00"), endTime: date("2026-11-14T16:00:00-06:00"),
                         locationId: 2, locationName: "Food Court"),
            // Tonight, later (7:00–9:00 PM).
            ScheduleItem(id: 3, name: "Evening Concert",
                         startTime: date("2026-11-14T19:00:00-06:00"), endTime: date("2026-11-14T21:00:00-06:00"),
                         locationId: 1, locationName: "Main Stage", tags: ["music"]),
            // Ended this morning.
            ScheduleItem(id: 4, name: "Morning Yoga",
                         startTime: date("2026-11-14T08:00:00-06:00"), endTime: date("2026-11-14T09:00:00-06:00"),
                         locationId: 4, locationName: "Plaza"),
            // Tomorrow, no location ("General").
            ScheduleItem(id: 5, name: "Sunday Brunch",
                         startTime: date("2026-11-15T10:00:00-06:00"), endTime: date("2026-11-15T11:30:00-06:00")),
            // Tonight, no end time (assumed 1 h).
            ScheduleItem(id: 6, name: "Late Show", startTime: date("2026-11-14T20:30:00-06:00"),
                         locationId: 1, locationName: "Main Stage"),
        ]
        let notifications = [
            AppNotification(id: 1, title: "Gates open", body: "The north entrance is open now.",
                            sendTime: date("2026-11-14T08:00:00-06:00")),
            AppNotification(id: 2, title: "Rain plan", body: "The concert moves to the big tent.",
                            sendTime: date("2026-11-14T12:00:00-06:00")),
        ]
        return EventBundle(event: event, categories: ["Stages", "Food"], locations: locations,
                           schedule: schedule, notifications: notifications)
    }()

    private func search(_ query: String) -> [EventSearchResult] {
        EventSearch.search(bundle, query: query, now: now)
    }

    private func targets(_ query: String) -> [SearchTarget] {
        search(query).map(\.target)
    }

    // MARK: - Rich context (API-018)

    func testPerformerNamesAndGenresAreSearched() {
        var withContext = bundle
        withContext.schedule[2].context = ScheduleItemContext(
            about: "An evening of bluegrass.",
            performers: [Performer(name: "Hazel Creek", bio: "A fiddle band from Austin.", genres: ["bluegrass", "Americana"])]
        )
        let find: (String) -> [SearchTarget] = { EventSearch.search(withContext, query: $0, now: self.now).map(\.target) }
        XCTAssertEqual(find("hazel creek").first, .scheduleItem(3), "performer name")
        XCTAssertEqual(find("americana").first, .scheduleItem(3), "genre")
        XCTAssertEqual(find("fiddle").first, .scheduleItem(3), "bio")
        XCTAssertFalse(targets("hazel").contains(.scheduleItem(3)), "nothing without context")
    }

    // MARK: - Text matching

    func testAccentFolding_CafeFindsCafe() {
        XCTAssertEqual(targets("cafe").first, .location(3))
        XCTAssertEqual(targets("CAFÉ LUMIERE").first, .location(3))
    }

    func testPrefix_MariFindsRoamingMariachi() {
        let results = search("mari")
        XCTAssertEqual(results.first?.target, .scheduleItem(1))
        // "Mari" of "Roaming Mariachi" is emphasised.
        XCTAssertEqual(results.first?.titleHighlights, [8..<12])
    }

    func testAndAcrossFields_TacoFood() {
        let found = targets("taco food")
        XCTAssertTrue(found.contains(.scheduleItem(2)), "name + location name")
        XCTAssertTrue(found.contains(.location(2)), "name + snippet")
        XCTAssertFalse(found.contains(.location(3)), "Food category but no taco")
        XCTAssertFalse(found.contains(.scheduleItem(1)))
    }

    func testTypo_Mariachy() {
        XCTAssertEqual(targets("mariachy"), [.scheduleItem(1)])
        // Short tokens never match by typo.
        XCTAssertTrue(targets("tacx").isEmpty)
    }

    func testPunctuationAndAmpersandAreSpaces() {
        XCTAssertTrue(targets("tacos&more").contains(.location(2)))
        XCTAssertTrue(targets("food-court").contains(.location(2)))
    }

    // MARK: - Time words (America/Chicago)

    func testNow_OnlyItemsInProgress() {
        XCTAssertEqual(targets("now"), [.scheduleItem(1)])
        XCTAssertEqual(targets("happening now"), [.scheduleItem(1)])
    }

    func testNext_StartingWithinTwoHours() {
        XCTAssertEqual(targets("next"), [.scheduleItem(2)])
        XCTAssertEqual(targets("up next"), [.scheduleItem(2)])
        XCTAssertEqual(targets("soon"), [.scheduleItem(2)])
    }

    func testTonight() {
        XCTAssertEqual(Set(targets("tonight")), [.scheduleItem(3), .scheduleItem(6)])
    }

    func testTodayAndTomorrow() {
        XCTAssertEqual(Set(targets("today")), [.scheduleItem(1), .scheduleItem(2), .scheduleItem(3), .scheduleItem(4), .scheduleItem(6)])
        XCTAssertEqual(targets("tomorrow"), [.scheduleItem(5)])
    }

    func testClockTimes() {
        XCTAssertEqual(targets("7pm"), [.scheduleItem(3)])
        XCTAssertEqual(targets("7 pm"), [.scheduleItem(3)])
        XCTAssertEqual(targets("19:00"), [.scheduleItem(3)])
        // In progress at 3:30 PM (and nothing around 3:30 AM).
        XCTAssertEqual(targets("3:30"), [.scheduleItem(2)])
        // Starting within 30 minutes after it.
        XCTAssertEqual(Set(targets("8:15pm")), [.scheduleItem(3), .scheduleItem(6)])
        XCTAssertEqual(targets("noon"), [])
        XCTAssertEqual(targets("10am"), [.scheduleItem(5)])
    }

    func testWeekdays() {
        let saturday: Set<SearchTarget> = [.scheduleItem(1), .scheduleItem(2), .scheduleItem(3), .scheduleItem(4), .scheduleItem(6)]
        XCTAssertEqual(Set(targets("saturday")), saturday)
        XCTAssertEqual(Set(targets("sat")), saturday)
        XCTAssertEqual(targets("sunday"), [.scheduleItem(5)])
    }

    func testTimeWordsOnly_ExcludeOtherKinds() {
        // "now" is also in a notification's body, but a time-only query lists schedule items only.
        XCTAssertFalse(targets("now").contains(.notification(1)))
    }

    func testMixed_MusicTonight() {
        // Time words filter schedule items; other kinds still match the words.
        let musicTonight = targets("music tonight")
        XCTAssertEqual(musicTonight.first, .scheduleItem(3))
        XCTAssertEqual(musicTonight.filter { $0.kind == .scheduleItem }, [.scheduleItem(3)])
        XCTAssertEqual(targets("food 3pm"), [.scheduleItem(2), .location(2), .location(3), .event(7)])
    }

    // MARK: - Ranking

    func testRanking_NowNextLaterEnded() {
        var shuffled = bundle
        shuffled.schedule = [
            ScheduleItem(id: 13, name: "Drum Show", startTime: date("2026-11-14T09:00:00-06:00"), endTime: date("2026-11-14T10:00:00-06:00")),
            ScheduleItem(id: 12, name: "Drum Show", startTime: date("2026-11-14T19:00:00-06:00"), endTime: date("2026-11-14T20:00:00-06:00")),
            ScheduleItem(id: 11, name: "Drum Show", startTime: date("2026-11-14T15:00:00-06:00"), endTime: date("2026-11-14T16:00:00-06:00")),
            ScheduleItem(id: 10, name: "Drum Show", startTime: date("2026-11-14T13:00:00-06:00"), endTime: date("2026-11-14T15:00:00-06:00")),
        ]
        let results = EventSearch.search(shuffled, query: "drum", now: now)
        XCTAssertEqual(results.map(\.target), [.scheduleItem(10), .scheduleItem(11), .scheduleItem(12), .scheduleItem(13)])
        XCTAssertEqual(results.map(\.timeLabel), [.now, .next, nil, .ended])
    }

    func testRanking_ExactNameBeforeDescriptionMatch() {
        // The location named "Main Stage" before the items held there.
        let found = targets("main stage")
        XCTAssertEqual(found.first, .location(1))
        XCTAssertTrue(found.contains(.scheduleItem(3)))
    }

    func testTieBreak_KindOrderThenTitle() {
        // "music": two schedule items (tag) and Main Stage (snippet); schedule items come first.
        let found = targets("music")
        XCTAssertEqual(Array(found.prefix(2)).map(\.kind), [.scheduleItem, .scheduleItem])
        XCTAssertTrue(found.contains(.location(1)))
    }

    // MARK: - Edge cases

    func testEmptyQuery_NoResults() {
        XCTAssertTrue(search("").isEmpty)
        XCTAssertTrue(search("   ").isEmpty)
        XCTAssertTrue(search("&-!").isEmpty)
    }

    func testItemWithoutLocation_General() {
        let result = search("brunch").first
        XCTAssertEqual(result?.target, .scheduleItem(5))
        XCTAssertTrue(result?.subtitle.hasSuffix("· General") ?? false, result?.subtitle ?? "")
    }

    func testLocationWithoutCoordinates_IsFound() {
        XCTAssertEqual(targets("lumiere"), [.location(3)])
    }

    func testNotificationBodyMatch() {
        XCTAssertEqual(targets("entrance"), [.notification(1)])
        XCTAssertEqual(targets("rain").first, .notification(2))
    }

    func testEventByCode() {
        XCTAssertEqual(targets("fall26"), [.event(7)])
    }

    func testSubtitles() {
        XCTAssertEqual(search("taco tasting").first?.subtitle.hasSuffix("· Food Court"), true)
        XCTAssertEqual(search("food court").first?.subtitle, "Food · Tacos & more")
        XCTAssertTrue(search("gates").first?.subtitle.contains("The north entrance") ?? false)
    }

    // MARK: - Parsing helpers

    func testClockMinutes() {
        XCTAssertEqual(EventSearch.clockMinutes("3pm", suffix: nil), [15 * 60])
        XCTAssertEqual(EventSearch.clockMinutes("12am", suffix: nil), [0])
        XCTAssertEqual(EventSearch.clockMinutes("12pm", suffix: nil), [12 * 60])
        XCTAssertEqual(EventSearch.clockMinutes("3:30", suffix: nil), [3 * 60 + 30, 15 * 60 + 30])
        XCTAssertEqual(EventSearch.clockMinutes("15:00", suffix: nil), [15 * 60])
        XCTAssertEqual(EventSearch.clockMinutes("3", suffix: "pm"), [15 * 60])
        XCTAssertNil(EventSearch.clockMinutes("3", suffix: nil), "a bare number is not a time")
        XCTAssertNil(EventSearch.clockMinutes("pizza", suffix: nil))
        XCTAssertNil(EventSearch.clockMinutes("25:00", suffix: nil))
    }

    func testEditDistance() {
        XCTAssertTrue(EventSearch.isWithinOneEdit("mariachy", "mariachi"))
        XCTAssertTrue(EventSearch.isWithinOneEdit("concrt", "concert"))
        XCTAssertTrue(EventSearch.isWithinOneEdit("concerts", "concert"))
        XCTAssertFalse(EventSearch.isWithinOneEdit("concret", "concert"), "a transposition is two edits")
    }

    func testKeywordsFromQuestion() {
        XCTAssertEqual(EventSearch.keywords(fromQuestion: "When is the Mariachi?"), "mariachi?")
        XCTAssertEqual(EventSearch.keywords(fromQuestion: "What's on tonight"), "tonight")
        XCTAssertTrue(EventSearch.looksLikeQuestion("where can I get tacos"))
        XCTAssertFalse(EventSearch.looksLikeQuestion("tacos"))
    }

    func testSearchTargetReferences() {
        XCTAssertEqual(SearchTarget(reference: "s12"), .scheduleItem(12))
        XCTAssertEqual(SearchTarget(reference: "[L3]"), .location(3))
        XCTAssertNil(SearchTarget(reference: "x1"))
        XCTAssertEqual(SearchTarget.notification(5).reference, "n5")
    }
}
