// PlanWidgetSync.swift
// Attnd (app target only)
//
// Writes the "Now / Next in my plan" widget's file (PlanWidgetModel.swift) into the App Group
// container and reloads the widget's timeline, but only when the content changed (WidgetKit
// budgets reloads). LiveFollowController.update() calls it, so it follows every applied bundle,
// like, plan change, and leaving the event (the file is removed). Never in screenshot mode.

import Foundation
import WidgetKit

@MainActor
enum PlanWidgetSync {
    /// The last data written (or found) this launch: skip identical writes.
    private static var lastWritten: Data?
    private static var checkedDisk = false

    /// Brings the widget's file in line with the joined event (nil: no event → removed).
    static func update(bundle: EventBundle?, liked: Set<Int>, plan: Plan?, accentHex: String?, now: Date = .now) {
        guard !ScreenshotMode.isActive, let url = PlanWidgetStore.fileURL else { return }
        if !checkedDisk {
            checkedDisk = true
            lastWritten = try? Data(contentsOf: url)
        }
        let content = bundle.map { Self.snapshot(bundle: $0, liked: liked, plan: plan, accentHex: accentHex, now: now) }
        let data = content.flatMap(PlanWidgetStore.encode)
        guard data != lastWritten else { return }
        do {
            if let data {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            } else if FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
                try FileManager.default.removeItem(at: url)
            }
            lastWritten = data
            WidgetCenter.shared.reloadTimelines(ofKind: PlanWidgetStore.kind)
        } catch {
            AppLog.caught(error, .storage, "widget.write")
        }
    }

    /// What the widget lists (pure; see PlanWidgetModel.swift): the plan's items while one is
    /// left, else liked items while one is left, else the event's upcoming items; not ended at
    /// `now`, by start then id, at most `PlanWidgetSnapshot.maxItems`.
    static func snapshot(bundle: EventBundle, liked: Set<Int>, plan: Plan?, accentHex: String?, now: Date) -> PlanWidgetSnapshot {
        let byId = Dictionary(bundle.schedule.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let locations = Dictionary(bundle.locations.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        func open(_ items: [ScheduleItem]) -> [ScheduleItem] {
            items
                .filter { $0.startTime != nil && !ScheduleTiming.hasEnded($0, at: now) }
                .sorted { ($0.startTime!, $0.id) < ($1.startTime!, $1.id) }
        }

        var source = PlanWidgetSnapshot.Source.event
        var chosen: [ScheduleItem] = []
        var planWalks: [Int: Int] = [:]
        if let plan {
            // Planned ids still in the bundle (times from the bundle: the organizer may have moved them).
            chosen = open(plan.itemIds.compactMap { byId[$0] })
            for planned in plan.items { planWalks[planned.itemId] = planned.walkMinutes }
            if !chosen.isEmpty { source = .plan }
        }
        if chosen.isEmpty {
            chosen = open(bundle.schedule.filter { liked.contains($0.id) })
            if !chosen.isEmpty { source = .likes }
        }
        if chosen.isEmpty {
            chosen = open(bundle.schedule)
            source = .event
        }
        chosen = Array(chosen.prefix(PlanWidgetSnapshot.maxItems))

        var items: [PlanWidgetSnapshot.Item] = []
        var previous: ScheduleItem?
        for item in chosen {
            let location = item.locationId.flatMap { locations[$0] }
            var walk: String?
            switch source {
            case .plan:
                if let minutes = planWalks[item.id], minutes > 0 { walk = "\(minutes) min walk" }
            case .likes:
                if let previous, previous.locationId != item.locationId,
                   let from = previous.locationId.flatMap({ locations[$0]?.coordinate }),
                   let to = location?.coordinate {
                    let meters = Compass.distance(from, to)
                    if WalkTime.isWithinWalkingRange(meters) { walk = WalkTime.rowText(straightMeters: meters) }
                }
            case .event:
                walk = nil
            }
            items.append(PlanWidgetSnapshot.Item(
                id: item.id,
                name: item.name,
                location: location?.name ?? item.locationName ?? ScheduleGrouping.generalTitle,
                start: item.startTime!,
                end: ScheduleTiming.effectiveEnd(of: item) ?? item.startTime!.addingTimeInterval(ScheduleTiming.defaultDuration),
                walkText: walk,
                liked: liked.contains(item.id)
            ))
            previous = item
        }
        return PlanWidgetSnapshot(
            eventId: bundle.event.id,
            eventName: bundle.event.name,
            accentHex: accentHex,
            timeZoneIdentifier: bundle.event.timeZone.identifier,
            source: source,
            items: items
        )
    }
}
