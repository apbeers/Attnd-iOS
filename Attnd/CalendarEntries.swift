// CalendarEntries.swift
// Attnd (app target only — not in the App Clip; unit tested in AssistantExtrasTests)
//
// `add_to_calendar(items | plan)` (assistant spec §7), a port of Android's
// `domain/CalendarEntries.kt`: one entry per schedule item, in the event's time zone. End = the
// item's end or start + 1 h; items without a start are skipped. Place = the location's name and
// its address (else the event's) joined by " · ", or the event's address alone; notes = the
// item's description, then the event's name. `Components/CalendarCard.swift` (EventKit) writes them.

import Foundation

struct CalendarEntry: Hashable, Sendable {
    var itemId: Int
    var title: String
    var start: Date
    var end: Date
    /// IANA zone of the event, e.g. "America/Chicago".
    var timeZone: String
    /// "Main Stage · Panther Island, Fort Worth, TX".
    var location: String
    var notes: String
}

enum CalendarEntries {
    static func forItem(_ itemId: Int, _ bundle: EventBundle) -> CalendarEntry? {
        guard let item = bundle.scheduleItem(itemId), let start = item.startTime, let end = ScheduleTiming.effectiveEnd(of: item) else { return nil }
        let event = bundle.event
        let location = bundle.location(item.locationId)
        let own = location?.address.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let address = own.isEmpty ? event.address.trimmingCharacters(in: .whitespacesAndNewlines) : own
        let name = location?.name ?? item.locationName.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        let place = [name, address.isEmpty ? nil : address].compactMap { $0 }.joined(separator: " · ")
        let notes = [item.description.trimmingCharacters(in: .whitespacesAndNewlines), event.name].filter { !$0.isEmpty }.joined(separator: "\n\n")
        return CalendarEntry(itemId: item.id, title: item.name, start: start, end: end, timeZone: event.timeZone.identifier, location: place, notes: notes)
    }

    static func forItems(_ ids: [Int], _ bundle: EventBundle) -> [CalendarEntry] {
        var seen = Set<Int>()
        return ids.filter { seen.insert($0).inserted }.compactMap { forItem($0, bundle) }
    }

    static func forPlan(_ plan: Plan, _ bundle: EventBundle) -> [CalendarEntry] { forItems(plan.itemIds, bundle) }
}
