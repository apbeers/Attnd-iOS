// PlanWidget.swift
// AttndWidgets (widget extension)
//
// "Now / Next in my plan" (assistant spec §6): Home Screen (small, medium) and Lock Screen
// (rectangular, inline, circular) widget. It reads the App Group file the app writes
// (PlanWidgetModel.swift: the plan's items, else liked items, else the event's own schedule)
// and makes one timeline entry per item start and end, so Now and Next move on without the app.
// The app reloads the timeline whenever that file changes. Tap opens the item (current, else
// next) through the Live Activity's link scheme (`attnd-live://event/<id>/item/<item>`, routed
// by the app); the medium size links each half. Times are in the EVENT's time zone.

import SwiftUI
import WidgetKit

struct PlanWidgetEntry: TimelineEntry, Sendable {
    let date: Date
    let snapshot: PlanWidgetSnapshot?

    var current: PlanWidgetSnapshot.Item? { snapshot?.current(at: date) }
    var next: PlanWidgetSnapshot.Item? { snapshot?.next(after: date) }
}

struct PlanWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> PlanWidgetEntry {
        PlanWidgetEntry(date: .now, snapshot: .placeholder)
    }

    func getSnapshot(in context: Context, completion: @escaping (PlanWidgetEntry) -> Void) {
        let stored = PlanWidgetStore.read()
        completion(PlanWidgetEntry(date: .now, snapshot: stored ?? (context.isPreview ? .placeholder : nil)))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<PlanWidgetEntry>) -> Void) {
        let now = Date.now
        let snapshot = PlanWidgetStore.read()
        let boundaries = snapshot?.boundaries(after: now) ?? []
        let entries = ([now] + boundaries).map { PlanWidgetEntry(date: $0, snapshot: snapshot) }
        // After the last boundary nothing changes until the app writes again (it reloads us).
        completion(Timeline(entries: entries, policy: boundaries.isEmpty ? .never : .atEnd))
    }
}

struct PlanWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: PlanWidgetStore.kind, provider: PlanWidgetProvider()) { entry in
            PlanWidgetView(entry: entry)
        }
        .configurationDisplayName("Now & Next")
        .description("What's on now and next in your plan, or from what you've liked, with the walk to it.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular, .accessoryInline, .accessoryCircular])
    }
}

// MARK: - Style

private enum PlanWidgetStyle {
    /// The event's accent (`#RRGGBB`), else the brand purple from the asset catalog.
    static func accent(_ snapshot: PlanWidgetSnapshot?) -> Color {
        guard var hex = snapshot?.accentHex?.trimmingCharacters(in: .whitespaces) else { return Color.accentColor }
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard hex.count == 6, let value = UInt32(hex, radix: 16) else { return Color.accentColor }
        return Color(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }

    /// "7:30 PM" on the entry's day, else "Sat 7:30 PM" (event time zone).
    static func time(_ date: Date, relativeTo now: Date, in timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        var style = calendar.isDate(date, inSameDayAs: now)
            ? Date.FormatStyle.dateTime.hour().minute()
            : Date.FormatStyle.dateTime.weekday(.abbreviated).hour().minute()
        style.timeZone = timeZone
        return date.formatted(style)
    }

    /// "7:30" (no AM/PM) for the circular family.
    static func clock(_ date: Date, in timeZone: TimeZone) -> String {
        var style = Date.FormatStyle.dateTime.hour(.defaultDigits(amPM: .omitted)).minute()
        style.timeZone = timeZone
        return date.formatted(style)
    }

    static func title(_ snapshot: PlanWidgetSnapshot) -> String {
        switch snapshot.source {
        case .plan:  return "My plan"
        case .likes: return "Liked"
        case .event: return snapshot.eventName
        }
    }

    static func symbol(_ snapshot: PlanWidgetSnapshot) -> String {
        switch snapshot.source {
        case .plan:  return "list.bullet.clipboard"
        case .likes: return "heart.fill"
        case .event: return "calendar"
        }
    }

    static func url(_ item: PlanWidgetSnapshot.Item?, _ snapshot: PlanWidgetSnapshot?) -> URL? {
        guard let snapshot, snapshot.eventId > 0 else { return nil }
        if let item { return LiveActivityLink.item(item.id).url(eventId: snapshot.eventId) }
        return snapshot.source == .plan ? LiveActivityLink.plan.url(eventId: snapshot.eventId) : nil
    }
}

// MARK: - Views

struct PlanWidgetView: View {
    let entry: PlanWidgetEntry

    @Environment(\.widgetFamily) private var family

    var body: some View {
        content
            .widgetURL(PlanWidgetStyle.url(entry.current ?? entry.next, entry.snapshot))
            .containerBackground(.background, for: .widget)
            .tint(PlanWidgetStyle.accent(entry.snapshot))
    }

    @ViewBuilder
    private var content: some View {
        switch family {
        case .accessoryInline:
            InlinePlanView(entry: entry)
        case .accessoryCircular:
            CircularPlanView(entry: entry)
        case .accessoryRectangular:
            RectangularPlanView(entry: entry)
        case .systemMedium:
            MediumPlanView(entry: entry)
        default:
            SmallPlanView(entry: entry)
        }
    }
}

/// Nothing to show: no event joined, or nothing left.
private struct EmptyPlanView: View {
    let snapshot: PlanWidgetSnapshot?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Image(systemName: "calendar.badge.clock")
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text(snapshot == nil ? "Join an event in Attnd" : "Nothing more scheduled")
                .font(.subheadline.weight(.semibold))
            if snapshot != nil {
                Text("Open Attnd to plan your day.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// One item: "NOW" / "NEXT · in 12 min", name, place, walk.
private struct PlanItemBlock: View {
    let label: String
    let item: PlanWidgetSnapshot.Item
    let entryDate: Date
    let timeZone: TimeZone
    let isNow: Bool
    var nameLines = 2

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                if isNow {
                    Circle().fill(.red).frame(width: 6, height: 6).accessibilityHidden(true)
                }
                Text(label)
                    .font(.caption2.bold())
                    .foregroundStyle(isNow ? AnyShapeStyle(Color.red) : AnyShapeStyle(.tint))
                    .textCase(.uppercase)
                if !isNow, item.start > entryDate, item.start.timeIntervalSince(entryDate) < 6 * 3600 {
                    Text(item.start, style: .relative)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            Text(item.name)
                .font(.headline)
                .lineLimit(nameLines)
                .minimumScaleFactor(0.8)
            Text(isNow
                 ? "until \(PlanWidgetStyle.time(item.end, relativeTo: entryDate, in: timeZone))"
                 : PlanWidgetStyle.time(item.start, relativeTo: entryDate, in: timeZone))
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            if let location = item.location {
                Text(location)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if !isNow, let walk = item.walkText {
                Label(walk, systemImage: "figure.walk")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct SmallPlanView: View {
    let entry: PlanWidgetEntry

    var body: some View {
        if let snapshot = entry.snapshot, entry.current != nil || entry.next != nil {
            VStack(alignment: .leading, spacing: 6) {
                Label(PlanWidgetStyle.title(snapshot), systemImage: PlanWidgetStyle.symbol(snapshot))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tint)
                    .lineLimit(1)
                    .widgetAccentable()
                if let current = entry.current {
                    PlanItemBlock(label: "Now", item: current, entryDate: entry.date, timeZone: snapshot.timeZone, isNow: true)
                    if let next = entry.next {
                        Spacer(minLength: 0)
                        Text("Next \(PlanWidgetStyle.time(next.start, relativeTo: entry.date, in: snapshot.timeZone)) · \(next.name)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                } else if let next = entry.next {
                    PlanItemBlock(label: "Next", item: next, entryDate: entry.date, timeZone: snapshot.timeZone, isNow: false, nameLines: 3)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            EmptyPlanView(snapshot: entry.snapshot)
        }
    }
}

private struct MediumPlanView: View {
    let entry: PlanWidgetEntry

    var body: some View {
        if let snapshot = entry.snapshot, entry.current != nil || entry.next != nil {
            VStack(alignment: .leading, spacing: 8) {
                Label(PlanWidgetStyle.title(snapshot), systemImage: PlanWidgetStyle.symbol(snapshot))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tint)
                    .lineLimit(1)
                    .widgetAccentable()
                HStack(alignment: .top, spacing: 12) {
                    half(label: "Now", item: entry.current, isNow: true, snapshot: snapshot)
                    Divider()
                    half(label: "Next", item: entry.next, isNow: false, snapshot: snapshot)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            EmptyPlanView(snapshot: entry.snapshot)
        }
    }

    @ViewBuilder
    private func half(label: String, item: PlanWidgetSnapshot.Item?, isNow: Bool, snapshot: PlanWidgetSnapshot) -> some View {
        Group {
            if let item {
                Link(destination: PlanWidgetStyle.url(item, snapshot) ?? LiveActivityLink.plan.url(eventId: snapshot.eventId)) {
                    PlanItemBlock(label: label, item: item, entryDate: entry.date, timeZone: snapshot.timeZone, isNow: isNow)
                }
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text(label).font(.caption2.bold()).textCase(.uppercase).foregroundStyle(.secondary)
                    Text(isNow ? "Nothing on right now" : "Nothing after this")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

private struct RectangularPlanView: View {
    let entry: PlanWidgetEntry

    var body: some View {
        if let snapshot = entry.snapshot, let item = entry.next ?? entry.current {
            let isNow = entry.next == nil
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Image(systemName: PlanWidgetStyle.symbol(snapshot)).accessibilityHidden(true)
                    Text(isNow ? "Now" : "Next \(PlanWidgetStyle.time(item.start, relativeTo: entry.date, in: snapshot.timeZone))")
                        .monospacedDigit()
                }
                .font(.caption.bold())
                .widgetAccentable()
                Text(item.name)
                    .font(.headline)
                    .lineLimit(1)
                Text([item.location, isNow ? nil : item.walkText].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
        } else {
            Text(entry.snapshot == nil ? "Join an event in Attnd" : "Nothing more scheduled")
                .font(.caption)
        }
    }
}

private struct InlinePlanView: View {
    let entry: PlanWidgetEntry

    var body: some View {
        if let snapshot = entry.snapshot, let item = entry.next ?? entry.current {
            let time = entry.next == nil ? "Now" : PlanWidgetStyle.clock(item.start, in: snapshot.timeZone)
            Label("\(time) \(item.name)", systemImage: PlanWidgetStyle.symbol(snapshot))
        } else {
            Label("Nothing scheduled", systemImage: "calendar")
        }
    }
}

private struct CircularPlanView: View {
    let entry: PlanWidgetEntry

    var body: some View {
        ZStack {
            AccessoryWidgetBackground()
            if let snapshot = entry.snapshot, let next = entry.next {
                VStack(spacing: 0) {
                    Text("Next").font(.caption2)
                    Text(PlanWidgetStyle.clock(next.start, in: snapshot.timeZone))
                        .font(.headline)
                        .monospacedDigit()
                        .minimumScaleFactor(0.6)
                }
                .widgetAccentable()
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Next: \(next.name) at \(PlanWidgetStyle.time(next.start, relativeTo: entry.date, in: snapshot.timeZone))")
            } else {
                Image(systemName: "calendar")
                    .font(.title3)
                    .accessibilityLabel("Nothing scheduled")
            }
        }
    }
}
