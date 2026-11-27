// DuoFeatures.swift
// Attnd (app + App Clip)
//
// Pure, unit-tested rules for the iPhone Duo screens (batch 7 "premium experience",
// `DuoFeaturesTests`): the time-travel map, linked panes, stage vs stage, the tabletop
// "at the event" glance, flyer places and drag payloads. No SwiftUI here; the views are in
// DuoViews.swift. Everything works offline from the bundle on the device.

import Foundation

// MARK: - Time-travel map

/// The map's time scrubber (unfolded): drag through the event's times and the pins of what's on
/// then light up. Snaps to set starts, "Now" is marked, and it resets to now.
enum TimeTravel {
    /// A drag within this of a set start snaps to it.
    static let snapTolerance: TimeInterval = 10 * 60
    /// Within this of now the scrubber reads "Now".
    static let nowTolerance: TimeInterval = 60

    /// From now to the last end (the past isn't scrubbed); nil without a timed item or once
    /// everything has ended.
    static func range(_ schedule: [ScheduleItem], now: Date) -> ClosedRange<Date>? {
        guard let last = schedule.compactMap(ScheduleTiming.effectiveEnd(of:)).max(), last > now else { return nil }
        return now...last
    }

    /// Distinct set starts inside the range, in order (the snap points).
    static func snapPoints(_ schedule: [ScheduleItem], in range: ClosedRange<Date>) -> [Date] {
        Array(Set(schedule.compactMap(\.startTime).filter { range.contains($0) })).sorted()
    }

    /// The nearest set start within `snapTolerance`, or now within `nowTolerance`; else the time itself.
    static func snap(_ date: Date, to points: [Date], now: Date) -> Date {
        if abs(date.timeIntervalSince(now)) <= nowTolerance { return now }
        let nearest = points.min { abs($0.timeIntervalSince(date)) < abs($1.timeIntervalSince(date)) }
        if let nearest, abs(nearest.timeIntervalSince(date)) <= snapTolerance { return nearest }
        return date
    }

    /// Whether the scrubber is at now (the map shows the live state).
    static func isNow(_ date: Date, now: Date) -> Bool {
        abs(date.timeIntervalSince(now)) <= nowTolerance
    }

    /// Items in progress at `date`, by start then id.
    static func items(at date: Date, in schedule: [ScheduleItem]) -> [ScheduleItem] {
        schedule.filter { ScheduleTiming.isHappening($0, at: date) }
            .sorted { ($0.startTime ?? .distantPast, $0.id) < ($1.startTime ?? .distantPast, $1.id) }
    }

    /// The places with something on at `date` (their pins light up).
    static func litLocationIds(at date: Date, in schedule: [ScheduleItem]) -> Set<Int> {
        Set(items(at: date, in: schedule).compactMap(\.locationId))
    }

    /// 0…1 position of `date` in the range (the slider's value).
    static func fraction(of date: Date, in range: ClosedRange<Date>) -> Double {
        let span = range.upperBound.timeIntervalSince(range.lowerBound)
        guard span > 0 else { return 0 }
        return min(max(date.timeIntervalSince(range.lowerBound) / span, 0), 1)
    }

    static func date(at fraction: Double, in range: ClosedRange<Date>) -> Date {
        let span = range.upperBound.timeIntervalSince(range.lowerBound)
        return range.lowerBound.addingTimeInterval(span * min(max(fraction, 0), 1))
    }

    /// "Now", else "Sat 7:30 PM" in the event's zone.
    static func label(_ date: Date, now: Date, timeZone: TimeZone, locale: Locale = .current) -> String {
        if isNow(date, now: now) { return "Now" }
        var style = Date.FormatStyle.dateTime.weekday(.abbreviated).hour().minute()
        style.timeZone = timeZone
        style.locale = locale
        return date.formatted(style)
    }
}

// MARK: - Linked panes

enum LinkedPanes {
    /// A pin tapped on the map: the place's set on now or next (by start), else its last one.
    static func nextItem(at locationId: Int, in items: [ScheduleItem], now: Date) -> ScheduleItem? {
        let here = items.filter { $0.locationId == locationId }
            .sorted { ($0.startTime ?? .distantFuture, $0.id) < ($1.startTime ?? .distantFuture, $1.id) }
        return here.first { !ScheduleTiming.hasEnded($0, at: now) } ?? here.last
    }
}

// MARK: - Stage vs stage

/// Two stages' line-ups side by side, to choose between clashing sets.
enum StageCompare {
    /// Places with at least one timed set, the busiest first (then the organizer's order, id).
    static func stages(_ schedule: [ScheduleItem], locations: [Location]) -> [Location] {
        var counts: [Int: Int] = [:]
        for item in schedule where item.startTime != nil {
            if let id = item.locationId { counts[id, default: 0] += 1 }
        }
        return locations.filter { counts[$0.id] != nil }
            .sorted { (-(counts[$0.id] ?? 0), $0.sortOrder, $0.id) < (-(counts[$1.id] ?? 0), $1.sortOrder, $1.id) }
    }

    /// A stage's sets in time order; ended ones dropped unless nothing is left.
    static func lineup(_ locationId: Int, in schedule: [ScheduleItem], now: Date) -> [ScheduleItem] {
        let all = schedule.filter { $0.locationId == locationId && $0.startTime != nil }
            .sorted { ($0.startTime ?? .distantPast, $0.id) < ($1.startTime ?? .distantPast, $1.id) }
        let ahead = all.filter { !ScheduleTiming.hasEnded($0, at: now) }
        return ahead.isEmpty ? all : ahead
    }

    /// Ids of sets in `a` and `b` that overlap a set on the other side.
    static func clashes(_ a: [ScheduleItem], _ b: [ScheduleItem]) -> Set<Int> {
        var ids = Set<Int>()
        for x in a {
            for y in b where overlaps(x, y) {
                ids.insert(x.id)
                ids.insert(y.id)
            }
        }
        return ids
    }

    static func overlaps(_ x: ScheduleItem, _ y: ScheduleItem) -> Bool {
        guard let xs = x.startTime, let xe = ScheduleTiming.effectiveEnd(of: x),
              let ys = y.startTime, let ye = ScheduleTiming.effectiveEnd(of: y) else { return false }
        return xs < ye && ys < xe
    }

    /// The two stages to open with: the given one (else the busiest) and the stage whose upcoming
    /// sets clash most with it (ties: the stages' order). nil with fewer than two stages.
    static func defaultPair(_ schedule: [ScheduleItem], locations: [Location], preferring locationId: Int? = nil,
                            now: Date) -> (Int, Int)? {
        let all = stages(schedule, locations: locations)
        guard all.count >= 2 else { return nil }
        let first = all.first { $0.id == locationId } ?? all[0]
        let base = lineup(first.id, in: schedule, now: now)
        let others = all.filter { $0.id != first.id }
        let best = others.max { a, b in
            let ca = clashes(base, lineup(a.id, in: schedule, now: now)).count
            let cb = clashes(base, lineup(b.id, in: schedule, now: now)).count
            if ca != cb { return ca < cb }
            // Equal: the earlier stage in the list wins (max picks the last "largest").
            return (others.firstIndex(of: a) ?? 0) > (others.firstIndex(of: b) ?? 0)
        }
        return best.map { (first.id, $0.id) }
    }
}

// MARK: - Tabletop "at the event"

/// What the tabletop glance shows: Now and Next, from My schedule first, else the event's own.
struct TabletopGlance: Equatable, Sendable {
    var now: ScheduleItem?
    var next: ScheduleItem?
    /// Whether Now / Next came from My schedule.
    var nowIsMine = false
    var nextIsMine = false

    static func of(_ schedule: [ScheduleItem], mine: Set<Int>, now: Date) -> TabletopGlance {
        let timed = schedule.filter { $0.startTime != nil }
        let byStart: (ScheduleItem, ScheduleItem) -> Bool = {
            ($0.startTime ?? .distantPast, $0.id) < ($1.startTime ?? .distantPast, $1.id)
        }
        let onNow = timed.filter { ScheduleTiming.isHappening($0, at: now) }.sorted(by: byStart)
        let upcoming = timed.filter { ($0.startTime ?? .distantPast) > now }.sorted(by: byStart)
        // Mine: the one that started last; the event's: the earliest started.
        let myNow = onNow.filter { mine.contains($0.id) }.last
        let myNext = upcoming.first { mine.contains($0.id) }
        return TabletopGlance(
            now: myNow ?? onNow.first,
            next: myNext ?? upcoming.first,
            nowIsMine: myNow != nil,
            nextIsMine: myNext != nil
        )
    }

    /// The tabletop mode is offered once, the first time the phone is half-folded while the event
    /// is on (between its start and end, else while a set is on or starts within 2 h).
    static func isLive(eventStart: Date?, eventEnd: Date?, schedule: [ScheduleItem], now: Date) -> Bool {
        if let start = eventStart, let end = eventEnd, end > start { return start <= now && now < end }
        return schedule.contains {
            ScheduleTiming.isHappening($0, at: now)
                || (($0.startTime ?? .distantPast) > now && ($0.startTime ?? .distantPast) <= now.addingTimeInterval(2 * 3600))
        }
    }

    static func shouldOffer(live: Bool, alreadyOffered: Bool, modeOn: Bool) -> Bool {
        live && !alreadyOffered && !modeOn
    }
}

// MARK: - Flyer places

/// Places whose names are printed on the flyer (on-device text recognition), so they can be found
/// on the map beside it. Pure: the recognised lines in, location ids out (the organizer's order).
enum FlyerPlaces {
    static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US"))
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// A place matches when its whole name (≥ 4 characters) appears word-for-word in the flyer text.
    static func match(lines: [String], locations: [Location]) -> [Int] {
        let text = " " + lines.map(normalized).joined(separator: " ") + " "
        return locations
            .sorted { ($0.sortOrder, $0.id) < ($1.sortOrder, $1.id) }
            .filter { location in
                let name = normalized(location.name)
                return name.count >= 4 && text.contains(" " + name + " ")
            }
            .map(\.id)
    }
}

// MARK: - Drag between panes

/// What a dragged row carries between panes (a plain string, so it needs no custom type):
/// "attnd:item:12" / "attnd:place:5".
enum DragPayload: Equatable, Sendable {
    case item(Int)
    case place(Int)

    var string: String {
        switch self {
        case .item(let id): return "attnd:item:\(id)"
        case .place(let id): return "attnd:place:\(id)"
        }
    }

    static func parse(_ string: String) -> DragPayload? {
        let parts = string.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ":")
        guard parts.count == 3, parts[0] == "attnd", let id = Int(parts[2]), id >= 0 else { return nil }
        switch parts[1] {
        case "item": return .item(id)
        case "place": return .place(id)
        default: return nil
        }
    }
}

// MARK: - Undo toast pane

/// Which part of the width the Undo toast may use: one pane of an unfolded iPhone Duo (the one
/// the action was tapped in, else the primary pane, which `PanePair` always places leading),
/// never across the fold. `fold` is the
/// reported `.division` (partly folded); `windowMidX` the middle of a flat-open inner display.
enum UndoToastPane {
    static func span(containerWidth width: CGFloat, fold: ClosedRange<CGFloat>?, windowMidX: CGFloat?,
                     touchX: CGFloat?) -> ClosedRange<CGFloat> {
        let full: ClosedRange<CGFloat> = 0...max(width, 0)
        guard let split = fold ?? windowMidX.map({ $0...$0 }),
              split.lowerBound > 120, split.upperBound < width - 120 else { return full }
        let leading: ClosedRange<CGFloat> = 0...split.lowerBound
        let trailing: ClosedRange<CGFloat> = split.upperBound...width
        if let x = touchX {
            if x < split.lowerBound { return leading }
            if x > split.upperBound { return trailing }
        }
        return leading
    }
}
