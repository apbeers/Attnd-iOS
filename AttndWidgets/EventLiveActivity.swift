// EventLiveActivity.swift
// AttndWidgets (widget extension)
//
// "Follow on Lock Screen": the event's Live Activity (shared spec §8). The app starts and
// updates it (LiveFollowController); the server only pushes urgent announcements (API-011).
//
//   - Lock Screen (and StandBy): urgent block first, then Now (with a progress bar that
//     ticks by itself), Up next (live countdown, walk minutes, location) and the one after;
//     "Gates open in …" before the event; an end-of-day summary. Buttons: Heart (current),
//     Skip (next), Map (opens the map with the walking route).
//   - Dynamic Island: compact (icon + countdown), minimal (icon or progress ring),
//     expanded (now / next, countdown, buttons; the urgent block when there is one).
//   - Apple Watch Smart Stack and CarPlay: the small family (`supplementalActivityFamilies`).
//
// Countdowns and progress use `Text(timerInterval:)` / `ProgressView(timerInterval:)`, so they
// keep ticking between updates. Links (`widgetURL`, `Link`) are `attnd-live://event/<id>/…`
// (LiveActivityLink), routed by the app. Buttons are LiveActivityIntents that run in the app.
// Times are shown in the EVENT's time zone.

import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

struct EventLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: EventActivityAttributes.self) { context in
            LockScreenActivityView(context: context)
                .activitySystemActionForegroundColor(ActivityStyle.accent(context.attributes))
                .widgetURL(ActivityStyle.primaryURL(context))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    ExpandedLeadingView(context: context)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    ExpandedTrailingView(context: context)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    ExpandedBottomView(context: context)
                }
            } compactLeading: {
                CompactLeadingView(context: context)
            } compactTrailing: {
                CompactTrailingSelector(context: context)
            } minimal: {
                MinimalView(context: context)
            }
            .widgetURL(ActivityStyle.primaryURL(context))
            .keylineTint(ActivityStyle.accent(context.attributes))
        }
        // Apple Watch Smart Stack and CarPlay use the small family.
        .supplementalActivityFamilies([.small])
    }
}

// MARK: - Shared helpers

private typealias Context = ActivityViewContext<EventActivityAttributes>

private enum ActivityStyle {
    /// The event's accent (`#RRGGBB`), else the brand purple from the asset catalog.
    static func accent(_ attributes: EventActivityAttributes) -> Color {
        guard var hex = attributes.accentHex?.trimmingCharacters(in: .whitespaces) else { return Color.accentColor }
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard hex.count == 6, let value = UInt32(hex, radix: 16) else { return Color.accentColor }
        return Color(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }

    /// "7:30 PM" in the event's time zone.
    static func clock(_ date: Date, _ attributes: EventActivityAttributes) -> String {
        var style = Date.FormatStyle.dateTime.hour().minute()
        style.timeZone = TimeZone(identifier: attributes.timeZoneIdentifier) ?? .current
        return date.formatted(style)
    }

    /// The whole activity opens Updates at the urgent announcement, else the item in
    /// progress, else the next one, else My plan (when it follows the plan), else Updates.
    static func primaryURL(_ context: Context) -> URL {
        let eventId = context.attributes.eventId
        let state = context.state
        if let id = state.urgent?.id { return LiveActivityLink.updates(notificationId: id).url(eventId: eventId) }
        if let id = state.current?.id ?? state.next?.id { return LiveActivityLink.item(id).url(eventId: eventId) }
        if state.followsPlan == true { return LiveActivityLink.plan.url(eventId: eventId) }
        return LiveActivityLink.updates(notificationId: nil).url(eventId: eventId)
    }

    /// The item the Heart button acts on: in progress, else the next one.
    static func heartTarget(_ state: EventActivityAttributes.ContentState) -> EventActivityAttributes.Slot? {
        state.current ?? state.next
    }

    static func placeLine(_ slot: EventActivityAttributes.Slot, _ attributes: EventActivityAttributes) -> String {
        var parts: [String] = []
        if let start = slot.start { parts.append(clock(start, attributes)) }
        if let location = slot.location, !location.isEmpty { parts.append(location) }
        return parts.joined(separator: " · ")
    }
}

/// A countdown to `date` that ticks by itself ("12:34", "1:02:03"; 0:00 once reached).
private struct Countdown: View {
    let date: Date

    var body: some View {
        Text(timerInterval: Date.now...max(date, Date.now), countsDown: true)
            .monospacedDigit()
    }
}

/// The in-progress bar for an item, ticking by itself.
private struct SlotProgress: View {
    let slot: EventActivityAttributes.Slot
    let tint: Color

    var body: some View {
        if let start = slot.start, let end = slot.effectiveEnd, start < end {
            ProgressView(timerInterval: start...end, countsDown: false) {
                EmptyView()
            } currentValueLabel: {
                EmptyView()
            }
            .tint(tint)
        }
    }
}

// MARK: - Urgent announcement (API-011)

private struct UrgentBlock: View {
    let urgent: EventActivityAttributes.Urgent
    let eventId: Int
    var compact = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Link(destination: LiveActivityLink.updates(notificationId: urgent.id).url(eventId: eventId)) {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(urgent.title ?? "Urgent update")
                            .font(.headline)
                            .lineLimit(compact ? 1 : 2)
                        if let body = urgent.body, !body.isEmpty {
                            Text(body)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(compact ? 2 : 3)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .accessibilityLabel("Urgent: \(urgent.title ?? "update")")
            if let id = urgent.id {
                Button(intent: DismissUrgentActivityIntent(eventId: eventId, notificationId: id)) {
                    Label("Dismiss", systemImage: "xmark")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(Color.red.opacity(0.18), in: .rect(cornerRadius: 14))
    }
}

// MARK: - Buttons

private struct ActivityButtons: View {
    let context: Context

    var body: some View {
        let state = context.state
        let eventId = context.attributes.eventId
        HStack(spacing: 8) {
            if let target = ActivityStyle.heartTarget(state), let id = target.id {
                Button(intent: HeartActivityItemIntent(eventId: eventId, itemId: id)) {
                    Label(target.hearted == true ? "Liked" : "Like", systemImage: target.hearted == true ? "heart.fill" : "heart")
                }
            }
            if let next = state.next, let id = next.id {
                Button(intent: SkipActivityItemIntent(eventId: eventId, itemId: id)) {
                    Label("Skip", systemImage: "forward")
                }
            }
            if let locationId = (state.next ?? state.current)?.locationId {
                Link(destination: LiveActivityLink.map(locationId: locationId).url(eventId: eventId)) {
                    Label("Map", systemImage: "map")
                }
            }
        }
        .font(.caption.weight(.semibold))
        .buttonStyle(.bordered)
        .tint(ActivityStyle.accent(context.attributes))
    }
}

// MARK: - Lock Screen

private struct LockScreenActivityView: View {
    let context: Context

    @Environment(\.activityFamily) private var family

    var body: some View {
        switch family {
        case .small:
            SmallActivityView(context: context)
        case .medium:
            fullView
        @unknown default:
            fullView
        }
    }

    private var fullView: some View {
        let attributes = context.attributes
        let state = context.state
        let accent = ActivityStyle.accent(attributes)
        return VStack(alignment: .leading, spacing: 8) {
            if let urgent = state.urgent {
                UrgentBlock(urgent: urgent, eventId: attributes.eventId)
            }
            HStack(spacing: 6) {
                Image(systemName: state.followSymbol)
                    .foregroundStyle(accent)
                    .accessibilityHidden(true)
                Text(attributes.eventName)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 4)
                if context.isStale {
                    Text("Open Attnd to update")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            if state.dayComplete == true {
                VStack(alignment: .leading, spacing: 2) {
                    Text("That's a wrap for today")
                        .font(.headline)
                    if let count = state.completedCount, count > 0 {
                        Text(count == 1 ? "1 item on your day" : "\(count) items on your day")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                if let current = state.current {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline) {
                            Text("Now")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(accent)
                            Text(current.name ?? "")
                                .font(.headline)
                                .lineLimit(1)
                            Spacer(minLength: 4)
                            if let end = current.effectiveEnd {
                                Text("ends \(ActivityStyle.clock(end, attributes))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        SlotProgress(slot: current, tint: accent)
                    }
                }
                if let next = state.next {
                    NextRow(next: next, walkMinutes: state.walkMinutesToNext, attributes: attributes)
                } else if let opens = state.opensAt {
                    HStack {
                        Text("Gates open in")
                            .font(.subheadline)
                        Countdown(date: opens)
                            .font(.headline)
                    }
                }
                if let after = state.after, let name = after.name, state.urgent == nil {
                    Text("Then \(after.start.map { ActivityStyle.clock($0, attributes) } ?? "") \(name)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                ActivityButtons(context: context)
            }
        }
        .padding(14)
    }
}

private struct NextRow: View {
    let next: EventActivityAttributes.Slot
    let walkMinutes: Int?
    let attributes: EventActivityAttributes

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Up next")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                Text(next.name ?? "")
                    .font(.headline)
                    .lineLimit(1)
                Text(ActivityStyle.placeLine(next, attributes))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 2) {
                if let start = next.start {
                    Countdown(date: start)
                        .font(.title3.weight(.semibold))
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 96, alignment: .trailing)
                }
                if let walkMinutes {
                    Label("\(walkMinutes) min walk", systemImage: "figure.walk")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// Apple Watch Smart Stack / CarPlay: one line of each.
private struct SmallActivityView: View {
    let context: Context

    var body: some View {
        let state = context.state
        let attributes = context.attributes
        VStack(alignment: .leading, spacing: 4) {
            if let urgent = state.urgent {
                Label(urgent.title ?? "Urgent update", systemImage: "exclamationmark.triangle.fill")
                    .font(.headline)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            } else if state.dayComplete == true {
                Text("That's a wrap for today")
                    .font(.headline)
            } else if let next = state.next {
                Text(next.name ?? "Up next")
                    .font(.headline)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Countdown(date: next.start ?? .now)
                    if let location = next.location {
                        Text("· \(location)")
                            .lineLimit(1)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            } else if let current = state.current {
                Text(current.name ?? "Now")
                    .font(.headline)
                    .lineLimit(1)
                SlotProgress(slot: current, tint: ActivityStyle.accent(attributes))
            } else if let opens = state.opensAt {
                Text("Gates open")
                    .font(.headline)
                Countdown(date: opens)
                    .font(.caption)
            }
        }
        .padding(8)
    }
}

// MARK: - Dynamic Island

private struct CompactLeadingView: View {
    let context: Context

    var body: some View {
        if context.state.urgent != nil {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .accessibilityLabel("Urgent update")
        } else {
            Image(systemName: context.state.followSymbol)
                .foregroundStyle(ActivityStyle.accent(context.attributes))
                .accessibilityLabel(context.attributes.eventName)
        }
    }
}

/// iOS 27 narrows the Dynamic Island in landscape (`isDynamicIslandLimitedInWidth`): an icon
/// instead of the countdown there.
private struct CompactTrailingSelector: View {
    let context: Context

    var body: some View {
        #if IOS27_SDK
        if #available(iOS 27.0, *) {
            WidthAwareCompactTrailing(context: context)
        } else {
            CompactTrailingView(context: context)
        }
        #else
        CompactTrailingView(context: context)
        #endif
    }
}

#if IOS27_SDK
@available(iOS 27.0, *)
private struct WidthAwareCompactTrailing: View {
    let context: Context

    @Environment(\.isDynamicIslandLimitedInWidth) private var isLimitedInWidth

    var body: some View {
        if isLimitedInWidth {
            MinimalView(context: context)
        } else {
            CompactTrailingView(context: context)
        }
    }
}
#endif

private struct CompactTrailingView: View {
    let context: Context

    var body: some View {
        let state = context.state
        if state.urgent != nil {
            Text("Urgent")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.red)
        } else if let start = state.next?.start {
            Countdown(date: start)
                .frame(maxWidth: 52)
                .font(.caption.weight(.semibold))
                .multilineTextAlignment(.trailing)
        } else if let current = state.current {
            MinimalProgress(slot: current, tint: ActivityStyle.accent(context.attributes))
        } else if let opens = state.opensAt {
            Countdown(date: opens)
                .frame(maxWidth: 52)
                .font(.caption.weight(.semibold))
        }
    }
}

private struct MinimalView: View {
    let context: Context

    var body: some View {
        let state = context.state
        if state.urgent != nil {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
        } else if let current = state.current {
            MinimalProgress(slot: current, tint: ActivityStyle.accent(context.attributes))
        } else {
            Image(systemName: state.followSymbol)
                .foregroundStyle(ActivityStyle.accent(context.attributes))
        }
    }
}

/// A small ring that fills while the item is on.
private struct MinimalProgress: View {
    let slot: EventActivityAttributes.Slot
    let tint: Color

    var body: some View {
        if let start = slot.start, let end = slot.effectiveEnd, start < end {
            ProgressView(timerInterval: start...end, countsDown: false) {
                EmptyView()
            } currentValueLabel: {
                EmptyView()
            }
            .progressViewStyle(.circular)
            .tint(tint)
        }
    }
}

private struct ExpandedLeadingView: View {
    let context: Context

    var body: some View {
        let state = context.state
        VStack(alignment: .leading, spacing: 2) {
            if let current = state.current {
                Text("Now")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(ActivityStyle.accent(context.attributes))
                Text(current.name ?? "")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
            } else {
                Text(context.attributes.eventName)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
            }
        }
        .padding(.leading, 4)
    }
}

private struct ExpandedTrailingView: View {
    let context: Context

    var body: some View {
        let state = context.state
        VStack(alignment: .trailing, spacing: 2) {
            if let start = state.next?.start {
                Text("Next in")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Countdown(date: start)
                    .font(.subheadline.weight(.semibold))
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 80, alignment: .trailing)
            } else if let opens = state.opensAt {
                Text("Gates open")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Countdown(date: opens)
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: 80, alignment: .trailing)
            }
        }
        .padding(.trailing, 4)
    }
}

private struct ExpandedBottomView: View {
    let context: Context

    var body: some View {
        let state = context.state
        let attributes = context.attributes
        VStack(alignment: .leading, spacing: 8) {
            if let urgent = state.urgent {
                UrgentBlock(urgent: urgent, eventId: attributes.eventId, compact: true)
            } else if state.dayComplete == true {
                Text("That's a wrap for today")
                    .font(.headline)
            } else {
                if let current = state.current {
                    SlotProgress(slot: current, tint: ActivityStyle.accent(attributes))
                }
                if let next = state.next {
                    HStack(spacing: 6) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(next.name ?? "")
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(1)
                            Text(ActivityStyle.placeLine(next, attributes))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 4)
                        if let walk = state.walkMinutesToNext {
                            Label("\(walk) min", systemImage: "figure.walk")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                ActivityButtons(context: context)
            }
        }
    }
}
