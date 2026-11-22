// ContextDecodingTests.swift
// AttndTests
//
// API-018 rich context (`event.context`, `location.context`, `schedule_item.context`): lenient
// decoding exactly as the contract says — every key optional, unknown keys ignored, lossy lists,
// https-only links, unknown amenity kinds → other, empty objects → nil.

import XCTest
@testable import Attnd

final class ContextDecodingTests: XCTestCase {

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }

    func testEventContextFull() throws {
        let event = try decode(Event.self, """
        {"id":1,"name":"Fair","event_code":"FAIR","context":{
          "about":" A two-day fair. ",
          "faq":[{"q":"Bags?","a":"Clear bags only."},{"q":"","a":"dropped"},{"q":"Re-entry?"},"junk",{"q":"Pets?","a":"Service animals only.","x":1}],
          "amenities":[
            {"kind":"restrooms","name":"Restrooms","location_id":3,"note":"By the gate"},
            {"kind":"first_aid","name":"","location_id":null},
            {"kind":"teleporter","name":"Beam me up"},
            {"name":"","note":"nothing"},
            {"kind":"ACCESSIBLE_ENTRANCE","name":"Ramp","location_id":"7"}
          ],
          "accessibility":"Step-free paths.","policies":"No glass.","getting_there":"Bus 12.",
          "weather_plan":"Rain or shine.",
          "links":[{"title":"Bag policy","url":"https://fair.example/bags"},{"title":"Old","url":"http://fair.example"},
                   {"url":"https://fair.example/map"},{"title":"Relative","url":"/x"}],
          "future":{"a":1}
        }}
        """)
        let context = try XCTUnwrap(event.context)
        XCTAssertEqual(context.about, "A two-day fair.")
        XCTAssertEqual(context.faq, [FAQEntry(question: "Bags?", answer: "Clear bags only."),
                                     FAQEntry(question: "Pets?", answer: "Service animals only.")])
        XCTAssertEqual(context.amenities.map(\.kind), [.restrooms, .firstAid, .other, .accessibleEntrance])
        XCTAssertEqual(context.amenities.map(\.name), ["Restrooms", "First aid", "Beam me up", "Ramp"])
        XCTAssertEqual(context.amenities[0].locationId, 3)
        XCTAssertEqual(context.amenities[0].note, "By the gate")
        XCTAssertNil(context.amenities[1].locationId)
        XCTAssertNil(context.amenities[3].locationId, "a string id is not an id")
        XCTAssertEqual(context.accessibility, "Step-free paths.")
        XCTAssertEqual(context.policies, "No glass.")
        XCTAssertEqual(context.gettingThere, "Bus 12.")
        XCTAssertEqual(context.weatherPlan, "Rain or shine.")
        XCTAssertEqual(context.links.map(\.title), ["Bag policy", "fair.example"])
        XCTAssertEqual(context.links.map(\.url.absoluteString), ["https://fair.example/bags", "https://fair.example/map"])
    }

    func testMissingNullOrEmptyContextIsNil() throws {
        XCTAssertNil(try decode(Event.self, #"{"id":1}"#).context)
        XCTAssertNil(try decode(Event.self, #"{"id":1,"context":null}"#).context)
        XCTAssertNil(try decode(Event.self, #"{"id":1,"context":{}}"#).context)
        XCTAssertNil(try decode(Event.self, #"{"id":1,"context":{"about":"  ","faq":[]}}"#).context)
        XCTAssertNil(try decode(Event.self, #"{"id":1,"context":"text"}"#).context, "wrong type: ignored")
        XCTAssertNil(try decode(Location.self, #"{"id":1,"context":[]}"#).context)
        XCTAssertNil(try decode(ScheduleItem.self, #"{"id":1,"context":{"performers":[{"bio":"no name"}]}}"#).context)
    }

    func testLocationContext() throws {
        let location = try decode(Location.self, """
        {"id":4,"name":"BBQ Pit","context":{"about":"Smoked daily.",
          "menu":[{"name":"Brisket plate","price":"$14","note":"Gluten-free"},{"name":"Rib","price":12.5},{"price":"$3"},{"name":"Tea"}],
          "hours":"11 AM – 9 PM","accessibility":"Step-free.","age_limit":"All ages",
          "links":[{"title":"Menu","url":"https://bbq.example/menu"}]}}
        """)
        let context = try XCTUnwrap(location.context)
        XCTAssertEqual(context.about, "Smoked daily.")
        XCTAssertEqual(context.menu, [
            MenuEntry(name: "Brisket plate", price: "$14", note: "Gluten-free"),
            MenuEntry(name: "Rib", price: "12.5"),
            MenuEntry(name: "Tea"),
        ])
        XCTAssertEqual(context.hours, "11 AM – 9 PM")
        XCTAssertEqual(context.accessibility, "Step-free.")
        XCTAssertEqual(context.ageLimit, "All ages")
        XCTAssertEqual(context.links.count, 1)
    }

    func testScheduleItemContext() throws {
        let item = try decode(ScheduleItem.self, """
        {"id":101,"name":"The Prairie Lights","context":{"about":"Headliners.",
          "performers":[{"name":"The Prairie Lights","bio":"Texas country band.","genres":["country"," Texas swing ","",3]},
                        {"name":"Guest","genres":"rock"},{"name":"  "},{"name":"DJ Two","genres":["Country","dj"]}],
          "age_limit":"21+","price":"Free","accessibility":"ASL interpreted.",
          "links":[{"title":"Band","url":"https://band.example"}]}}
        """)
        let context = try XCTUnwrap(item.context)
        XCTAssertEqual(context.about, "Headliners.")
        XCTAssertEqual(context.performers.map(\.name), ["The Prairie Lights", "Guest", "DJ Two"])
        XCTAssertEqual(context.performers[0].genres, ["country", "Texas swing"])
        XCTAssertEqual(context.performers[1].genres, [], "not a list")
        XCTAssertEqual(context.genres, ["country", "Texas swing", "dj"], "distinct, case-insensitive")
        XCTAssertEqual(context.ageLimit, "21+")
        XCTAssertEqual(context.price, "Free")
        XCTAssertEqual(context.accessibility, "ASL interpreted.")
        XCTAssertEqual(context.links.first?.title, "Band")
    }

    /// API-030: `apple_music_url` only as an https Apple Music link; anything else is ignored.
    func testPerformerAppleMusicURL() throws {
        let performers = try decode([Performer].self, """
        [{"name":"Juniper Lane","apple_music_url":"https://music.apple.com/us/artist/juniper-lane/123"},
         {"name":"Old Link","apple_music_url":"http://music.apple.com/us/artist/x/1"},
         {"name":"Elsewhere","apple_music_url":"https://open.example.com/artist/1"},
         {"name":"Blank","apple_music_url":""},
         {"name":"Number","apple_music_url":42},
         {"name":"None"}]
        """)
        XCTAssertEqual(performers.map(\.appleMusicURL?.absoluteString),
                       ["https://music.apple.com/us/artist/juniper-lane/123", nil, nil, nil, nil, nil])
        XCTAssertNil(Performer.appleMusicLink(URL(string: "https://music.apple.com.evil.example/x")))
        XCTAssertNotNil(Performer.appleMusicLink(URL(string: "https://beta.music.apple.com/x")))
    }

    func testBundleWithContextRoundTripsFromRawJSON() throws {
        // The offline copy stores the raw bundle JSON, so context comes back from disk unchanged.
        let json = """
        {"event":{"id":1,"name":"Fair","context":{"about":"Hi"}},
         "locations":[{"id":2,"name":"Stage","context":{"hours":"All day"}}],
         "schedule":[{"id":3,"name":"Show","context":{"price":"$5"}}]}
        """
        let bundle = try decode(EventBundle.self, json)
        XCTAssertEqual(bundle.event.context?.about, "Hi")
        XCTAssertEqual(bundle.locations.first?.context?.hours, "All day")
        XCTAssertEqual(bundle.schedule.first?.context?.price, "$5")
    }

    // MARK: - Search over the context (assistant retrieval)

    func testAssistantSearchFindsPerformersAndGenres() {
        var bundle = PlannerFixture.bundle
        let index = bundle.schedule.firstIndex { $0.id == 104 }!
        bundle.schedule[index].context = ScheduleItemContext(performers: [Performer(name: "Lone Star Collective", bio: "Vinyl-only sets.", genres: ["house", "disco"])])
        let now = PlannerFixture.now
        XCTAssertEqual(AssistantSearch.search(bundle, "disco", now: now).first?.id, 104)
        XCTAssertEqual(AssistantSearch.search(bundle, "collective", now: now).first?.id, 104)
        XCTAssertEqual(AssistantSearch.search(bundle, "vinyl", now: now).first?.id, 104)
        XCTAssertTrue(AssistantSearch.search(PlannerFixture.bundle, "disco", now: now).isEmpty)
        var ctx = AssistantFixture.ctx()
        ctx.bundle = bundle
        XCTAssertEqual(AssistantModel.retrieve("any disco sets?", ctx).first?.id, 104)
    }
}
