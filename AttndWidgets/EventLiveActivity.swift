// EventLiveActivity.swift
// AttndWidgets, AttndClipWidgets (widget extensions)
//
// "Follow on Lock Screen": the event's Live Activity (shared spec §8). The app starts and
// updates it (LiveFollowController); the server only pushes urgent announcements (API-011).
//
// Now and Next are always shown together (owner, Nov 21, 2026): Now = My schedule's entry in
// progress, else what's on at the event ("At the event"); Next = My schedule's next entry, else
// the event's. Between entries "Free until 3:00 · Next: X at Y"; before the gates "Gates open
// 10:00 · First: X". An urgent announcement always comes first.
//
//   - Lock Screen (and StandBy): urgent block, Now (progress that ticks by itself), Next
//     (place, start time, live countdown, "↗ 0.4 mi · 8 min walk" from the last position, which
//     the app computed: the activity can't read location), "Then: X", buttons Skip and Map.
//     No Add / heart button (owner).
//   - Dynamic Island: compact leading = Now's name (short), trailing = Next's countdown (or its
//     clock time where the island is narrow, iPhone Duo's vertical island); minimal = a progress
//     ring; expanded = Now on top, Next with countdown, direction and walk, then the buttons.
//     The compact trailing region is never empty (iOS 27–27.2 layout bug on iPhone Duo).
//   - Apple Watch Smart Stack and CarPlay: the small family, two lines (Now / Next).
//
// Colours (API-023, `attributes.theme`): primary for progress, buttons and the island's tint,
// secondary for soft backgrounds, tertiary for highlights (the "Now" label, the countdown), each
// with its light and dark variant; without a theme the event's accent, else the brand purple.
// Urgent stays red.
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
                .activitySystemActionForegroundColor(ActivityPalette(context.attributes, dark: false).primary)
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
                CompactLeadingSelector(context: context)
            } compactTrailing: {
                CompactTrailingSelector(context: context)
            } minimal: {
                MinimalView(context: context)
            }
            .widgetURL(ActivityStyle.primaryURL(context))
            // The island is always dark.
            .keylineTint(ActivityPalette(context.attributes, dark: true).primary)
        }
        // Apple Watch Smart Stack and CarPlay use the small family.
        .supplementalActivityFamilies([.small])
    }
}

// MARK: - Shared helpers

private typealias Context = ActivityViewContext<EventActivityAttributes>

/// The activity's colours for one appearance (API-023).
private struct ActivityPalette {
    var primary: Color
    var soft: Color
    var highlight: Color

    init(_ attributes: EventActivityAttributes, dark: Bool) {
        let accent = Self.color(attributes.accentHex) ?? Color.accentColor
        let theme = attributes.theme
        let main = Self.color(theme?.hex(\.primary, dark: dark)) ?? accent
        primary = main
        soft = Self.color(theme?.hex(\.secondary, dark: dark)).map { $0.opacity(dark ? 0.35 : 0.5) }
            ?? main.opacity(0.12)
        highlight = Self.color(theme?.hex(\.tertiary, dark: dark)) ?? main
    }

    /// `#RRGGBB` → a colour; nil for anything else.
    static func color(_ hex: String?) -> Color? {
        guard var hex = hex?.trimmingCharacters(in: .whitespaces) else { return nil }
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard hex.count == 6, let value = UInt32(hex, radix: 16) else { return nil }
        return Color(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}

/// The palette for the current appearance (Lock Screen, StandBy, Watch follow it).
private struct PaletteReader<Content: View>: View {
    let attributes: EventActivityAttributes
    @ViewBuilder var content: (ActivityPalette) -> Content

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        content(ActivityPalette(attributes, dark: colorScheme == .dark))
    }
}

private enum ActivityStyle {
    /// "7:30 PM" in the event's time zone.
    static func clock(_ date: Date, _ attributes: EventActivityAttributes) -> String {
        var style = Date.FormatStyle.dateTime.hour().minute()
        style.timeZone = TimeZone(identifier: attributes.timeZoneIdentifier) ?? .current
        return date.formatted(style)
    }

    /// "3:00" (no AM/PM): the narrow places.
    static func shortClock(_ date: Date, _ attributes: EventActivityAttributes) -> String {
        var style = Date.FormatStyle.dateTime.hour(.defaultDigits(amPM: .omitted)).minute()
        style.timeZone = TimeZone(identifier: attributes.timeZoneIdentifier) ?? .current
        return date.formatted(style)
    }

    /// The whole activity opens Updates at the urgent announcement, else Now, else Next, else
    /// My plan (when it follows the plan), else Updates.
    static func primaryURL(_ context: Context) -> URL {
        let eventId = context.attributes.eventId
        let state = context.state
        if let id = state.urgent?.id { return LiveActivityLink.updates(notificationId: id).url(eventId: eventId) }
        if let link = state.current?.link ?? state.next?.link { return link.url(eventId: eventId) }
        if state.followsPlan == true { return LiveActivityLink.plan.url(eventId: eventId) }
        return LiveActivityLink.updates(notificationId: nil).url(eventId: eventId)
    }

    /// "7:30 PM · Main Stage".
    static func placeLine(_ slot: EventActivityAttributes.Slot, _ attributes: EventActivityAttributes) -> String {
        var parts: [String] = []
        if let start = slot.start { parts.append(clock(start, attributes)) }
        if let location = slot.location, !location.isEmpty, location != slot.name { parts.append(location) }
        return parts.joined(separator: " · ")
    }

    /// "Free until 2:00" / "Gates open 10:00", nil otherwise (Next's name and place are on its
    /// own row and are never repeated here).
    static func gapLine(_ state: EventActivityAttributes.ContentState, _ attributes: EventActivityAttributes) -> String? {
        if let opens = state.opensAt { return "Gates open \(shortClock(opens, attributes))" }
        if let free = state.freeUntil, state.next != nil { return "Free until \(shortClock(free, attributes))" }
        return nil
    }

    /// "Now" or "At the event".
    static func nowLabel(_ state: EventActivityAttributes.ContentState) -> String {
        state.nowIsFromEvent ? "At the event" : "Now"
    }

    /// The first word or two of a name, for the compact island (≤ 12 characters).
    static func short(_ name: String?) -> String {
        guard let name, !name.isEmpty else { return "" }
        if name.count <= 12 { return name }
        var result = ""
        for word in name.split(separator: " ") {
            let candidate = result.isEmpty ? String(word) : result + " " + word
            if candidate.count > 12 { break }
            result = candidate
        }
        return result.isEmpty ? String(name.prefix(11)) + "…" : result
    }
}

/// A countdown to `date` that ticks by itself ("12:34", "1:02:03"; 0:00 once reached).
private struct Countdown: View {
    let date: Date

    var body: some View {
        // The activity now starts on join, maybe days ahead (batch 7): a ticking clock for the
        // last hour, a self-updating "2 hr, 5 min" / "2 days" before that.
        if date.timeIntervalSinceNow > 3600 {
            Text(date, style: .relative)
                .monospacedDigit()
        } else {
            Text(timerInterval: Date.now...max(date, Date.now), countsDown: true)
                .monospacedDigit()
        }
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

/// "↗ 0.4 mi · 8 min walk" (north-relative arrow), VoiceOver "Northeast, 0.4 miles, 8 min walk".
private struct DirectionLine: View {
    let state: EventActivityAttributes.ContentState

    var body: some View {
        if let line = state.nextDirectionLine {
            Text(line)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .accessibilityLabel(accessibility)
        }
    }

    private var accessibility: String {
        var parts: [String] = []
        if let label = state.nextDirectionLabel { parts.append(label) }
        if let walk = state.walkMinutesToNext { parts.append("\(walk) min walk") }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Urgent announcement (API-011)

private struct UrgentBlock: View {
    let urgent: EventActivityAttributes.Urgent
    let eventId: Int
    var compact = false
    /// The body line (dropped first when the Lock Screen's height budget is tight).
    var showsBody = true

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
                        if showsBody, let body = urgent.body, !body.isEmpty {
                            Text(body)
                                .font(compact ? .caption : .subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(compact ? 1 : 3)
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
        .padding(compact ? 8 : 10)
        .background(Color.red.opacity(0.18), in: .rect(cornerRadius: 12))
    }
}

// MARK: - Buttons (Skip, Map)

private struct ActivityButtons: View {
    let context: Context
    let palette: ActivityPalette

    var body: some View {
        let state = context.state
        let eventId = context.attributes.eventId
        HStack(spacing: 8) {
            if state.showsButton("skip"), let next = state.next, !next.isPlace, let id = next.id {
                Button(intent: SkipActivityItemIntent(eventId: eventId, itemId: id)) {
                    Label("Skip", systemImage: "forward")
                }
            }
            if state.showsButton("map"), let locationId = (state.next ?? state.current)?.locationId {
                Link(destination: LiveActivityLink.map(locationId: locationId).url(eventId: eventId)) {
                    Label("Map", systemImage: "map")
                }
            }
        }
        .font(.caption.weight(.semibold))
        .buttonStyle(.bordered)
        .controlSize(.small)
        .tint(palette.primary)
    }
}

// MARK: - Lock Screen

private struct LockScreenActivityView: View {
    let context: Context

    @Environment(\.activityFamily) private var family

    var body: some View {
        PaletteReader(attributes: context.attributes) { palette in
            switch family {
            case .small:
                SmallActivityView(context: context, palette: palette)
            case .medium:
                FullActivityView(context: context, palette: palette)
            @unknown default:
                FullActivityView(context: context, palette: palette)
            }
        }
    }
}

/// The Lock Screen (and StandBy) layout. Apple's limit is 84–160 pt tall (HIG, Live Activities;
/// 371 pt wide on a 6.1" iPhone, 408 pt on the largest) with 14 pt margins, so the content gets at
/// most `contentLimit` and a fixed budget: one header row (event name + the gap / gates / stale
/// label, or the urgent block), the Now row, the Next block, then one row with "Then:" and the
/// buttons. When that doesn't fit (larger Dynamic Type, an urgent block) `ViewThatFits` drops
/// lines in order — the "Then:" text, the direction, the Now row's place, the Now row, Next's
/// detail line — never Next itself or the buttons.
private struct FullActivityView: View {
    let context: Context
    let palette: ActivityPalette

    /// 160 pt minus the 14 pt margins, with a little room to spare.
    static let contentLimit: CGFloat = 126

    var body: some View {
        let state = context.state
        Group {
            if state.dayComplete == true {
                VStack(alignment: .leading, spacing: 6) {
                    if let urgent = state.urgent {
                        UrgentBlock(urgent: urgent, eventId: context.attributes.eventId, compact: true)
                    } else {
                        header
                    }
                    Text("That's a wrap for today")
                        .font(.headline)
                    if let count = state.completedCount, count > 0 {
                        Text(count == 1 ? "1 item on your day" : "\(count) items on your day")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                ViewThatFits(in: .vertical) {
                    layout(.full)
                    layout(.noThen)
                    layout(.noDirection)
                    layout(.noNowPlace)
                    layout(.noNow)
                    layout(.minimal)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: Self.contentLimit, alignment: .topLeading)
        .padding(14)
    }

    enum Level: Int {
        case full, noThen, noDirection, noNowPlace, noNow, minimal
    }

    private func layout(_ level: Level) -> some View {
        let state = context.state
        let attributes = context.attributes
        return VStack(alignment: .leading, spacing: 6) {
            if let urgent = state.urgent {
                UrgentBlock(urgent: urgent, eventId: attributes.eventId, compact: true, showsBody: level != .minimal)
            } else {
                header
            }
            if state.urgent == nil, level.rawValue < Level.noNow.rawValue, let current = state.current {
                NowRow(current: current, state: state, attributes: attributes, palette: palette,
                       showsPlace: level.rawValue < Level.noNowPlace.rawValue)
            }
            if let next = state.next {
                NextRow(next: next, state: state, attributes: attributes, palette: palette,
                        showsDirection: level.rawValue < Level.noDirection.rawValue && state.urgent == nil,
                        compact: level == .minimal || state.urgent != nil)
            }
            HStack(alignment: .center, spacing: 8) {
                if level == .full, state.urgent == nil, let after = state.after, let name = after.name {
                    Text("Then: \(after.start.map { ActivityStyle.shortClock($0, attributes) + " " } ?? "")\(name)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                ActivityButtons(context: context, palette: palette)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    /// Icon, the event's name and, trailing, "Free until 2:00" / "Gates open 10:00" / the stale note.
    private var header: some View {
        let state = context.state
        let attributes = context.attributes
        return HStack(spacing: 6) {
            Image(systemName: state.followSymbol)
                .foregroundStyle(palette.primary)
                .accessibilityHidden(true)
            Text(attributes.eventName)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
            Spacer(minLength: 4)
            if context.isStale {
                Text(state.staleText ?? "Open Attnd to update")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else if let label = ActivityStyle.gapLine(state, attributes) {
                Text(label)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(palette.highlight)
                    .lineLimit(1)
            } else if let hint = state.hint {
                Text(hint)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
        }
    }
}

private struct NowRow: View {
    let current: EventActivityAttributes.Slot
    let state: EventActivityAttributes.ContentState
    let attributes: EventActivityAttributes
    let palette: ActivityPalette
    var showsPlace = true

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(ActivityStyle.nowLabel(state))
                    .font(.caption.weight(.bold))
                    .foregroundStyle(palette.highlight)
                Text(nowName)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 4)
                if let end = current.effectiveEnd {
                    Text("ends \(ActivityStyle.shortClock(end, attributes))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            SlotProgress(slot: current, tint: palette.primary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(palette.soft, in: .rect(cornerRadius: 10))
    }

    /// "Juniper Lane · Main Stage" (the place only while it fits the budget).
    private var nowName: String {
        let name = current.name ?? ""
        guard showsPlace, let place = current.location, !place.isEmpty, place != name else { return name }
        return "\(name) · \(place)"
    }
}

private struct NextRow: View {
    let next: EventActivityAttributes.Slot
    let state: EventActivityAttributes.ContentState
    let attributes: EventActivityAttributes
    let palette: ActivityPalette
    var showsDirection = true
    /// One line only (an urgent block above, or the tightest level).
    var compact = false

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if let late = state.lateText {
                        Text(late)
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.orange)
                    } else {
                        Text(state.opensAt != nil ? "First" : "Next")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.secondary)
                    }
                    Text(next.name ?? "")
                        .font(compact ? .subheadline.weight(.semibold) : .headline)
                        .lineLimit(1)
                }
                if !compact {
                    Text(detailLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .accessibilityLabel(detailAccessibility)
                }
            }
            Spacer(minLength: 4)
            if let start = next.start {
                Countdown(date: start)
                    .font(compact ? .subheadline.weight(.semibold) : .title3.weight(.semibold))
                    .foregroundStyle(palette.highlight)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 84, alignment: .trailing)
            }
        }
    }

    /// "2:00 PM · Taco Loco · ↗ 0.4 mi · 8 min walk".
    private var detailLine: String {
        var parts = [ActivityStyle.placeLine(next, attributes)].filter { !$0.isEmpty }
        if showsDirection, let direction = state.nextDirectionLine { parts.append(direction) }
        return parts.joined(separator: " · ")
    }

    private var detailAccessibility: String {
        var parts = [ActivityStyle.placeLine(next, attributes)].filter { !$0.isEmpty }
        if showsDirection {
            if let label = state.nextDirectionLabel { parts.append(label) }
            if let walk = state.walkMinutesToNext { parts.append("\(walk) min walk") }
        }
        return parts.joined(separator: ", ")
    }
}

/// Apple Watch Smart Stack / CarPlay: two lines, Now and Next.
private struct SmallActivityView: View {
    let context: Context
    let palette: ActivityPalette

    var body: some View {
        let state = context.state
        let attributes = context.attributes
        VStack(alignment: .leading, spacing: 3) {
            if let urgent = state.urgent {
                Label(urgent.title ?? "Urgent update", systemImage: "exclamationmark.triangle.fill")
                    .font(.headline)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            } else if state.dayComplete == true {
                Text("That's a wrap for today")
                    .font(.headline)
            } else {
                if let current = state.current {
                    HStack(spacing: 4) {
                        Text(state.nowIsFromEvent ? "Event" : "Now")
                            .foregroundStyle(palette.highlight)
                        Text(current.name ?? "")
                            .lineLimit(1)
                    }
                    .font(.caption.weight(.semibold))
                    SlotProgress(slot: current, tint: palette.primary)
                } else if let gap = ActivityStyle.gapLine(state, attributes) {
                    Text(gap)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(palette.highlight)
                        .lineLimit(1)
                } else {
                    // Watch audit (batch 7): never an empty first line; the event's name.
                    Text(attributes.eventName)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                }
                if let next = state.next {
                    HStack(spacing: 4) {
                        Text(next.name ?? "Next")
                            .lineLimit(1)
                        Spacer(minLength: 2)
                        if let start = next.start {
                            Countdown(date: start)
                                .foregroundStyle(palette.highlight)
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                                .frame(maxWidth: 64, alignment: .trailing)
                        }
                    }
                    .font(.caption)
                } else if state.current == nil, let hint = state.hint {
                    Text(hint)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
        .padding(8)
    }
}

// MARK: - Dynamic Island

/// Leading: Now's name (short); an icon where the island is narrow (iPhone Duo).
private struct CompactLeadingSelector: View {
    let context: Context

    var body: some View {
        if #available(iOS 27.0, *) {
            WidthAwareCompactLeading(context: context)
        } else {
            CompactLeadingView(context: context, narrow: false)
        }
    }
}

private struct CompactLeadingView: View {
    let context: Context
    let narrow: Bool

    var body: some View {
        let state = context.state
        let palette = ActivityPalette(context.attributes, dark: true)
        if state.urgent != nil {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .accessibilityLabel("Urgent update")
        } else if let current = state.current, !narrow {
            Text(ActivityStyle.short(current.name))
                .font(.caption.weight(.semibold))
                .foregroundStyle(palette.highlight)
                .lineLimit(1)
                .frame(maxWidth: 84, alignment: .leading)
                .accessibilityLabel("\(ActivityStyle.nowLabel(state)): \(current.name ?? "")")
        } else if let current = state.current {
            MinimalProgress(slot: current, tint: palette.primary)
                .accessibilityLabel("\(ActivityStyle.nowLabel(state)): \(current.name ?? "")")
        } else {
            Image(systemName: state.followSymbol)
                .foregroundStyle(palette.primary)
                .accessibilityLabel(context.attributes.eventName)
        }
    }
}

/// Trailing: Next's countdown; Next's clock time where the island is narrow.
private struct CompactTrailingSelector: View {
    let context: Context

    var body: some View {
        if #available(iOS 27.0, *) {
            WidthAwareCompactTrailing(context: context)
        } else {
            CompactTrailingView(context: context, narrow: false)
        }
    }
}

@available(iOS 27.0, *)
private struct WidthAwareCompactLeading: View {
    let context: Context

    @Environment(\.isDynamicIslandLimitedInWidth) private var isLimitedInWidth

    var body: some View {
        CompactLeadingView(context: context, narrow: isLimitedInWidth)
    }
}

@available(iOS 27.0, *)
private struct WidthAwareCompactTrailing: View {
    let context: Context

    @Environment(\.isDynamicIslandLimitedInWidth) private var isLimitedInWidth

    var body: some View {
        CompactTrailingView(context: context, narrow: isLimitedInWidth)
    }
}

private struct CompactTrailingView: View {
    let context: Context
    let narrow: Bool

    var body: some View {
        let state = context.state
        let attributes = context.attributes
        let palette = ActivityPalette(attributes, dark: true)
        if state.urgent != nil {
            if narrow {
                // iPhone Duo's vertical island: one bold symbol reads at a glance.
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.callout.weight(.bold))
                    .foregroundStyle(.red)
                    .accessibilityLabel("Urgent")
            } else {
                Text("Urgent")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.red)
            }
        } else if let start = state.next?.start {
            Group {
                if narrow {
                    // Batch 7 polish: rounded, bold, tabular digits, shrinking rather than truncating.
                    Text(ActivityStyle.shortClock(start, attributes))
                        .font(.system(.callout, design: .rounded).weight(.bold))
                        .monospacedDigit()
                        .minimumScaleFactor(0.7)
                        .lineLimit(1)
                } else {
                    Countdown(date: start)
                        .frame(maxWidth: 52)
                        .multilineTextAlignment(.trailing)
                        .font(.caption.weight(.semibold))
                }
            }
            .foregroundStyle(palette.highlight)
            .accessibilityLabel("Next: \(state.next?.name ?? "") at \(ActivityStyle.clock(start, attributes))")
        } else if let current = state.current {
            MinimalProgress(slot: current, tint: palette.primary)
        } else if let opens = state.opensAt {
            Text(ActivityStyle.shortClock(opens, attributes))
                .font(.caption.weight(.semibold))
                .foregroundStyle(palette.highlight)
        } else {
            // Never an empty region: on iOS 27–27.2 an empty compact trailing view breaks the
            // layout where `isDynamicIslandLimitedInWidth` is true (iPhone Duo).
            Image(systemName: state.followSymbol)
                .foregroundStyle(palette.primary)
        }
    }
}

private struct MinimalView: View {
    let context: Context

    var body: some View {
        let state = context.state
        let palette = ActivityPalette(context.attributes, dark: true)
        if state.urgent != nil {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
        } else if let current = state.current {
            MinimalProgress(slot: current, tint: palette.primary)
        } else {
            Image(systemName: state.followSymbol)
                .foregroundStyle(palette.primary)
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
        } else {
            // Always content (the compact trailing / minimal regions must never be empty).
            Image(systemName: "circle.dotted")
                .foregroundStyle(tint)
        }
    }
}

private struct ExpandedLeadingView: View {
    let context: Context

    var body: some View {
        let state = context.state
        let palette = ActivityPalette(context.attributes, dark: true)
        VStack(alignment: .leading, spacing: 2) {
            if let current = state.current {
                Text(ActivityStyle.nowLabel(state))
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(palette.highlight)
                Text(current.name ?? "")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
            } else if let gap = ActivityStyle.gapLine(state, context.attributes) {
                Text(gap)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(palette.highlight)
                    .lineLimit(2)
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
        let palette = ActivityPalette(context.attributes, dark: true)
        VStack(alignment: .trailing, spacing: 2) {
            if let start = state.next?.start {
                Text("Next in")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Countdown(date: start)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(palette.highlight)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 80, alignment: .trailing)
            } else if let opens = state.opensAt {
                Text("Gates open")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Countdown(date: opens)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(palette.highlight)
                    .frame(maxWidth: 80, alignment: .trailing)
            } else {
                Image(systemName: state.followSymbol)
                    .foregroundStyle(palette.primary)
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
        let palette = ActivityPalette(attributes, dark: true)
        VStack(alignment: .leading, spacing: 6) {
            if let urgent = state.urgent {
                UrgentBlock(urgent: urgent, eventId: attributes.eventId, compact: true)
            } else if state.dayComplete == true {
                Text("That's a wrap for today")
                    .font(.headline)
            } else {
                if let current = state.current {
                    SlotProgress(slot: current, tint: palette.primary)
                }
                if let next = state.next {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(next.name ?? "")
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        Text(ActivityStyle.placeLine(next, attributes))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        DirectionLine(state: state)
                    }
                }
                if let after = state.after, let name = after.name {
                    Text("Then: \(name)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                ActivityButtons(context: context, palette: palette)
            }
        }
    }
}

#if DEBUG
// Previews: Lock Screen and the island's presentations, with and without a theme.
private let previewAttributes = EventActivityAttributes(
    eventId: 1, eventName: "Prairie Fest", accentHex: "#431F86",
    timeZoneIdentifier: "America/Chicago", dayStart: .now,
    theme: .init(light: .init(primary: "#0B6E4F", secondary: "#CDEBDD", tertiary: "#C4471B"),
                 dark: .init(primary: "#5FD3A6", secondary: "#173B2E", tertiary: "#FF9A6B"))
)

private let previewState = EventActivityAttributes.ContentState(
    current: .init(id: 2, name: "Juniper Lane", location: "Main Stage", locationId: 10,
                   start: .now.addingTimeInterval(-1200), end: .now.addingTimeInterval(1800)),
    next: .init(id: 4, name: "Midnight Choir", location: "Barn Stage", locationId: 11,
                start: .now.addingTimeInterval(2400), end: .now.addingTimeInterval(6000)),
    after: .init(id: 5, name: "Late Set", start: .now.addingTimeInterval(9000)),
    walkMinutesToNext: 8, nowSource: "event", nextSource: "schedule",
    nextPoint: 1, nextDistance: "0.4 mi", nextDirectionLabel: "Northeast, 0.4 miles"
)

// Every Lock Screen state, to check the 160 pt limit (also at larger Dynamic Type in the canvas).
private let previewGap = EventActivityAttributes.ContentState(
    next: .init(id: 7, name: "Hot sauce contest", location: "Taco Loco", locationId: 12,
                start: .now.addingTimeInterval(1860), end: .now.addingTimeInterval(5400)),
    after: .init(id: 8, name: "Band: The Crossroads", start: .now.addingTimeInterval(12_600)),
    walkMinutesToNext: 8, followsHearts: true, nextSource: "schedule", freeUntil: .now.addingTimeInterval(1860),
    nextPoint: 1, nextDistance: "0.4 mi", nextDirectionLabel: "Northeast, 0.4 miles"
)

private let previewGates = EventActivityAttributes.ContentState(
    next: .init(id: 1, name: "Gates open", start: .now.addingTimeInterval(3600)),
    after: .init(id: 2, name: "Juniper Lane", start: .now.addingTimeInterval(7200)),
    opensAt: .now.addingTimeInterval(3600)
)

private var previewUrgent: EventActivityAttributes.ContentState {
    var state = previewState
    state.urgent = .init(id: 9, title: "Main Stage closed: storm on the way",
                         body: "Head to the Barn Stage; sets move there from 3 PM. Stay away from the trees.",
                         sentAt: "2026-11-21T19:40:00Z")
    return state
}

private let previewWrap = EventActivityAttributes.ContentState(dayComplete: true, completedCount: 6)

/// Started on join, two days ahead, nothing in My schedule yet (batch 7).
private var previewJoined: EventActivityAttributes.ContentState {
    var state = EventActivityAttributes.ContentState(
        next: .init(id: 1, name: "Juniper Lane", location: "Main Stage", start: .now.addingTimeInterval(2 * 86_400)),
        nextSource: "event"
    )
    state.hint = "Tap ♥ on anything and it shows here"
    return state
}

#Preview("Lock Screen", as: .content, using: previewAttributes) {
    EventLiveActivity()
} contentStates: {
    previewState
    previewGap
    previewGates
    previewUrgent
    previewWrap
    previewJoined
}

#Preview("Compact", as: .dynamicIsland(.compact), using: previewAttributes) {
    EventLiveActivity()
} contentStates: {
    previewState
}

#Preview("Expanded", as: .dynamicIsland(.expanded), using: previewAttributes) {
    EventLiveActivity()
} contentStates: {
    previewState
}
#endif
