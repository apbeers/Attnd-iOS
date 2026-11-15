// PlannerFixture.swift
// AttndTests
//
// The planner / Live Activity fixture (shared spec §6–8; Android's `unit/PlannerFixture.kt` has
// the same data and expectations): a DEMO-like festival in America/Chicago (CST, UTC−6) on
// Sat Nov 14 – Sun Nov 15, 2026, gates at 10:00 AM Saturday. "now" is Sat 10:00 AM local
// (16:00 UTC). Coordinates are the DEMO layout's; the Info Booth has none.
//
// Hearted: The Prairie Lights (101, 7–8:30 PM) and Neon Armadillo (114, 8–9 PM), which clash.

import Foundation
@testable import Attnd

enum PlannerFixture {

    static let now = date("2026-11-14T16:00:00Z")
    static let chicago = TimeZone(identifier: "America/Chicago")!

    static func date(_ iso: String) -> Date {
        guard let d = ISODate.parse(iso) else { fatalError("bad fixture date \(iso)") }
        return d
    }

    static func sat(_ time: String) -> Date { date("2026-11-14T\(time):00-06:00") }
    static func sun(_ time: String) -> Date { date("2026-11-15T\(time):00-06:00") }

    private static func location(_ id: Int, _ name: String, _ category: String, _ tags: [String], _ lat: Double?, _ lng: Double?) -> Location {
        Location(id: id, name: name, category: category, latitude: lat, longitude: lng, sortOrder: id, tags: tags)
    }

    private static func item(
        _ id: Int, _ name: String, _ start: Date, _ end: Date?, _ locationId: Int?, _ tags: [String], description: String = ""
    ) -> ScheduleItem {
        ScheduleItem(
            id: id, name: name, description: description, startTime: start, endTime: end,
            locationId: locationId, locationName: locations.first { $0.id == locationId }?.name, tags: tags
        )
    }

    static let locations: [Location] = [
        location(1, "Main Stage", "Stage", ["live music", "headliners", "free"], 32.750039, -97.3320272),
        location(2, "Trinity Stage", "Stage", ["live music", "local bands", "acoustic", "free"], 32.7487814, -97.3303183),
        location(3, "Panther Island Pavilion", "Stage", ["live music", "dj", "late night"], 32.7507576, -97.3294638),
        location(4, "Chef Demo Kitchen", "Food", ["food", "cooking demo", "free tastings"], 32.7495898, -97.3309591),
        location(5, "BBQ Pit Lane", "Food", ["food", "bbq"], 32.7485119, -97.3318136),
        location(6, "Taco Row", "Food", ["food", "tacos", "vegetarian"], 32.7492305, -97.3325613),
        location(7, "Kids Zone", "Family", ["kid-friendly", "family", "games"], 32.750578, -97.3327749),
        location(8, "Craft Beer Garden", "Drinks", ["drinks", "beer", "21+"], 32.7503085, -97.3309591),
        location(9, "Info Booth", "Services", ["services", "maps"], nil, nil),
    ]

    static let schedule: [ScheduleItem] = [
        item(111, "Gates open", sat("10:00"), sat("10:30"), nil, ["general", "free"], description: "Welcome! Grab a map at the Info Booth."),
        item(109, "Juniper Lane", sat("11:00"), sat("12:00"), 1, ["live music", "folk"]),
        item(108, "Face painting & games", sat("11:00"), sat("13:00"), 7, ["family", "kid-friendly", "free"]),
        item(106, "Brisket 101", sat("12:00"), sat("12:45"), 4, ["food", "demo", "bbq"], description: "Low and slow Texas brisket."),
        item(102, "Ana Morales Trio", sat("13:00"), sat("14:00"), 2, ["live music", "jazz"]),
        item(107, "Street tacos at home", sat("14:15"), sat("15:00"), 4, ["food", "demo", "tacos"]),
        item(103, "Big Sky Radio", sat("15:00"), sat("16:00"), 2, ["live music", "country"], description: "Texas country radio hits."),
        item(110, "Kolache masterclass", sat("16:15"), sat("17:00"), 4, ["food", "demo", "desserts"]),
        item(105, "Velvet Mesquite", sat("17:00"), sat("18:00"), 1, ["live music", "blues"]),
        item(112, "Beer tasting", sat("18:00"), sat("19:00"), 8, ["drinks", "beer", "21+"]),
        item(113, "Sundown Choir", sat("18:15"), sat("18:45"), 2, ["live music", "gospel"]),
        item(101, "The Prairie Lights", sat("19:00"), sat("20:30"), 1, ["live music", "country"], description: "Texas country headliners."),
        item(114, "Neon Armadillo", sat("20:00"), sat("21:00"), 2, ["live music", "rock"]),
        item(104, "DJ Lone Star", sat("21:00"), sat("23:00"), 3, ["live music", "dj"]),
        item(203, "Morning yoga", sun("09:00"), sun("10:00"), nil, ["general", "free"]),
        item(201, "Los Hermanos Flores", sun("12:00"), sun("13:00"), 1, ["live music", "tejano"]),
        item(202, "Kid Rodeo", sun("14:00"), sun("15:00"), 1, ["live music", "rock"]),
    ]

    static let heartedItems: Set<Int> = [101, 114]

    static let bundle = EventBundle(
        contentVersion: 3,
        event: Event(
            id: 42, name: "Fort Worth Food & Music Festival", eventCode: "DEMO",
            description: "Food and music downtown.", address: "Panther Island, Fort Worth, TX",
            latitude: 32.7495, longitude: -97.3316, startTime: sat("10:00"), endTime: sun("18:00"),
            timeZoneIdentifier: "America/Chicago", isDemo: true, contentVersion: 3
        ),
        categories: ["Stage", "Food", "Family", "Drinks", "Services"],
        locations: locations,
        schedule: schedule,
        notifications: [
            AppNotification(id: 31, title: "Set time change", body: "Velvet Mesquite moves to 8:30 pm on the Main Stage.",
                            sendTime: sat("09:20"), priority: .urgent),
        ]
    )
}
