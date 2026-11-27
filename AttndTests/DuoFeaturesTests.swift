// DuoFeaturesTests.swift
// AttndTests
//
// The iPhone Duo rules (DuoFeatures.swift): time-travel map, linked panes, stage vs stage,
// the tabletop glance, flyer places and drag payloads. Fixed now, America/Chicago.

import XCTest
import SwiftUI
@testable import Attnd

final class DuoFeaturesTests: XCTestCase {
    private let zone = TimeZone(identifier: "America/Chicago")!
    /// Sat Nov 14 2026, 2:00 PM in Chicago (20:00 UTC).
    private let now = Date(timeIntervalSince1970: 1_794_686_400)

    private func at(_ minutes: Double) -> Date { now.addingTimeInterval(minutes * 60) }

    private func item(_ id: Int, _ start: Double, _ end: Double?, at location: Int?) -> ScheduleItem {
        ScheduleItem(id: id, name: "Set \(id)", startTime: at(start), endTime: end.map(at), locationId: location)
    }

    private var stages: [Location] {
        [Location(id: 1, name: "Main Stage", sortOrder: 0),
         Location(id: 2, name: "Prairie Tent", sortOrder: 1),
         Location(id: 3, name: "Taco Row", sortOrder: 2)]
    }

    private var schedule: [ScheduleItem] {
        [item(10, -30, 30, at: 1),     // on now at Main Stage
         item(11, 60, 120, at: 1),     // 3:00–4:00 Main
         item(20, 45, 105, at: 2),     // 2:45–3:45 Prairie (clashes with 11)
         item(21, 150, nil, at: 2),    // 4:30, no end (1 h)
         item(30, -120, -60, at: 3),   // ended
         item(40, 30, 90, at: nil)]    // General
    }

    // MARK: Time travel

    func testRangeAndSnapPoints() throws {
        let range = try XCTUnwrap(TimeTravel.range(schedule, now: now))
        XCTAssertEqual(range.lowerBound, now)
        XCTAssertEqual(range.upperBound, at(210))
        XCTAssertEqual(TimeTravel.snapPoints(schedule, in: range), [at(30), at(45), at(60), at(150)])
        XCTAssertNil(TimeTravel.range([item(1, -120, -60, at: 1)], now: now))
        XCTAssertNil(TimeTravel.range([], now: now))
    }

    func testSnapAndNow() throws {
        let points = [at(30), at(45), at(60), at(150)]
        XCTAssertEqual(TimeTravel.snap(at(0.5), to: points, now: now), now)
        XCTAssertEqual(TimeTravel.snap(at(52), to: points, now: now), at(45))
        XCTAssertEqual(TimeTravel.snap(at(140), to: points, now: now), at(150))
        XCTAssertEqual(TimeTravel.snap(at(100), to: points, now: now), at(100))
        XCTAssertTrue(TimeTravel.isNow(at(0.9), now: now))
        XCTAssertFalse(TimeTravel.isNow(at(2), now: now))
    }

    func testLitPinsAtATime() {
        XCTAssertEqual(TimeTravel.litLocationIds(at: now, in: schedule), [1])
        XCTAssertEqual(TimeTravel.litLocationIds(at: at(70), in: schedule), [1, 2])
        XCTAssertEqual(TimeTravel.items(at: at(70), in: schedule).map(\.id), [40, 20, 11])
        XCTAssertEqual(TimeTravel.litLocationIds(at: at(200), in: schedule), [2])
    }

    func testFractionRoundTripAndLabel() throws {
        let range = try XCTUnwrap(TimeTravel.range(schedule, now: now))
        XCTAssertEqual(TimeTravel.fraction(of: at(105), in: range), 0.5, accuracy: 0.0001)
        XCTAssertEqual(TimeTravel.date(at: 0.5, in: range), at(105))
        XCTAssertEqual(TimeTravel.date(at: 2, in: range), range.upperBound)
        XCTAssertEqual(TimeTravel.label(now, now: now, timeZone: zone), "Now")
        // Formatters may put a narrow no-break space before PM.
        let label = TimeTravel.label(at(60), now: now, timeZone: zone, locale: Locale(identifier: "en_US"))
        XCTAssertEqual(label.replacingOccurrences(of: "\u{202F}", with: " "), "Sat 3:00 PM")
    }

    // MARK: Linked panes

    func testPinTapScrollsToThePlacesNextSet() {
        XCTAssertEqual(LinkedPanes.nextItem(at: 1, in: schedule, now: now)?.id, 10)
        XCTAssertEqual(LinkedPanes.nextItem(at: 1, in: schedule, now: at(40))?.id, 11)
        XCTAssertEqual(LinkedPanes.nextItem(at: 3, in: schedule, now: now)?.id, 30)   // only ended → the last one
        XCTAssertNil(LinkedPanes.nextItem(at: 9, in: schedule, now: now))
    }

    // MARK: Stage vs stage

    func testStagesLineupsAndClashes() throws {
        XCTAssertEqual(StageCompare.stages(schedule, locations: stages).map(\.id), [1, 2, 3])
        XCTAssertEqual(StageCompare.lineup(1, in: schedule, now: now).map(\.id), [10, 11])
        XCTAssertEqual(StageCompare.lineup(3, in: schedule, now: now).map(\.id), [30])  // nothing left: the ended one
        let main = StageCompare.lineup(1, in: schedule, now: now)
        let prairie = StageCompare.lineup(2, in: schedule, now: now)
        XCTAssertEqual(StageCompare.clashes(main, prairie), [11, 20])
        let pair = try XCTUnwrap(StageCompare.defaultPair(schedule, locations: stages, now: now))
        XCTAssertEqual(pair.0, 1)
        XCTAssertEqual(pair.1, 2)
        let fromTaco = try XCTUnwrap(StageCompare.defaultPair(schedule, locations: stages, preferring: 3, now: now))
        XCTAssertEqual(fromTaco.0, 3)
        XCTAssertEqual(fromTaco.1, 1)   // no clashes anywhere: the first other stage
        XCTAssertNil(StageCompare.defaultPair([item(1, 0, 60, at: 1)], locations: stages, now: now))
    }

    // MARK: Tabletop

    func testTabletopGlancePrefersMySchedule() {
        let event = TabletopGlance.of(schedule, mine: [], now: now)
        XCTAssertEqual(event.now?.id, 10)
        XCTAssertEqual(event.next?.id, 40)
        XCTAssertFalse(event.nowIsMine)
        let mine = TabletopGlance.of(schedule, mine: [11], now: now)
        XCTAssertEqual(mine.now?.id, 10)
        XCTAssertEqual(mine.next?.id, 11)
        XCTAssertTrue(mine.nextIsMine)
        let later = TabletopGlance.of(schedule, mine: [], now: at(300))
        XCTAssertNil(later.now)
        XCTAssertNil(later.next)
    }

    func testTabletopOfferOnlyOnceWhileLive() {
        XCTAssertTrue(TabletopGlance.isLive(eventStart: at(-60), eventEnd: at(600), schedule: [], now: now))
        XCTAssertFalse(TabletopGlance.isLive(eventStart: at(60), eventEnd: at(600), schedule: schedule, now: now))
        XCTAssertTrue(TabletopGlance.isLive(eventStart: nil, eventEnd: nil, schedule: schedule, now: now))
        XCTAssertFalse(TabletopGlance.isLive(eventStart: nil, eventEnd: nil, schedule: [item(1, 200, 260, at: 1)], now: now))
        XCTAssertTrue(TabletopGlance.shouldOffer(live: true, alreadyOffered: false, modeOn: false))
        XCTAssertFalse(TabletopGlance.shouldOffer(live: true, alreadyOffered: true, modeOn: false))
        XCTAssertFalse(TabletopGlance.shouldOffer(live: false, alreadyOffered: false, modeOn: false))
    }

    // MARK: Flyer places and drags

    func testFlyerPlaces() {
        let lines = ["SATURDAY ON THE MAIN STAGE!", "Tacos all day at Taco-Row", "Prairie"]
        XCTAssertEqual(FlyerPlaces.match(lines: lines, locations: stages), [1, 3])
        XCTAssertEqual(FlyerPlaces.match(lines: [], locations: stages), [])
        XCTAssertEqual(FlyerPlaces.match(lines: ["Café Olé"], locations: [Location(id: 7, name: "Cafe Ole")]), [7])
    }

    func testDragPayloads() {
        XCTAssertEqual(DragPayload.item(12).string, "attnd:item:12")
        XCTAssertEqual(DragPayload.parse("attnd:item:12"), .item(12))
        XCTAssertEqual(DragPayload.parse(" attnd:place:5 "), .place(5))
        XCTAssertNil(DragPayload.parse("attnd:item:x"))
        XCTAssertNil(DragPayload.parse("https://attnd.app"))
        XCTAssertNil(DragPayload.parse("attnd:song:1"))
    }

    // MARK: Undo toast

    func testUndoToastStaysInOnePane() {
        // Folded / phones: the whole width.
        XCTAssertEqual(UndoToastPane.span(containerWidth: 400, fold: nil, windowMidX: nil, touchX: 300), 0...400)
        // Partly folded: the pane that was tapped.
        XCTAssertEqual(UndoToastPane.span(containerWidth: 900, fold: 440...460, windowMidX: nil, touchX: 700), 460...900)
        XCTAssertEqual(UndoToastPane.span(containerWidth: 900, fold: 440...460, windowMidX: nil, touchX: 100), 0...440)
        // No tap position: the primary pane (PanePair puts it leading).
        XCTAssertEqual(UndoToastPane.span(containerWidth: 900, fold: 440...460, windowMidX: nil, touchX: nil), 0...440)
        // Flat open: the middle of the window is the fold.
        XCTAssertEqual(UndoToastPane.span(containerWidth: 640, fold: nil, windowMidX: 330, touchX: nil), 0...330)
        // A "fold" at the very edge isn't one.
        XCTAssertEqual(UndoToastPane.span(containerWidth: 640, fold: nil, windowMidX: 600, touchX: nil), 0...640)
    }

    // MARK: Pane pairs

    func testPanePairSplitsAlongItsAxes() {
        let wide = CGSize(width: 951, height: 669), tall = CGSize(width: 669, height: 951)
        XCTAssertTrue(PanePairRule.isSplit(wanted: true, axes: [.horizontal, .vertical], size: wide))
        XCTAssertTrue(PanePairRule.isSplit(wanted: true, axes: [.horizontal, .vertical], size: tall))
        // Side by side only: a tall container shows the primary alone.
        XCTAssertTrue(PanePairRule.isSplit(wanted: true, axes: .horizontal, size: wide))
        XCTAssertFalse(PanePairRule.isSplit(wanted: true, axes: .horizontal, size: tall))
        // Not wanted, or not laid out yet: the primary alone.
        XCTAssertFalse(PanePairRule.isSplit(wanted: false, axes: .horizontal, size: wide))
        XCTAssertFalse(PanePairRule.isSplit(wanted: true, axes: .horizontal, size: .zero))
    }
}
