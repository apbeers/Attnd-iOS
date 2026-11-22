// AssistantCards.swift
// Attnd (app + App Clip)
//
// The event assistant's component library, part 1 (assistant spec §2): native views for the
// response blocks, driven by resolved models (a `ScheduleItem`, a `Location`, ids that the
// caller has already checked against the bundle), never by JSON. The assistant screen builds
// on them; the manual screens reuse them where the swap changes nothing.
//
//   - ItemCard (`item_card`), PlaceCard (`place_card`), UpdateCard (`update_card`)
//   - CompactList (`list`), CardCarousel (`carousel`)
//   - ItemTimeline (`timeline`, with the now line and walk legs; not "TimelineView", which
//     is SwiftUI's)
//   - NowNextStrip (`now_next`), Countdown (`countdown`)
//
// Rules for every component: content, not controls, so no Liquid Glass (cards sit on the
// grouped secondary background); every interactive part is a real Button with a label for
// VoiceOver; text uses Dynamic Type styles and wraps; times are in the EVENT's time zone;
// distances come from `DistanceBadge`, which shows nothing in screenshot mode (the tracker
// never runs there); live countdowns become static text in screenshot mode.

import CoreLocation
import MapKit
import SwiftUI

// MARK: - Shared styling

extension View {
    /// The background of an assistant card: a rounded tile on the grouped secondary background.
    func blockCardBackground(padding: CGFloat = 12) -> some View {
        modifier(BlockCardBackground(padding: padding))
    }
}

/// The card surface; with an event theme (API-023) a light wash of its secondary colour.
private struct BlockCardBackground: ViewModifier {
    let padding: CGFloat

    @Environment(\.themeSoft) private var soft

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 18)
                    .fill(Color(.secondarySystemGroupedBackground))
                    .overlay {
                        if let soft {
                            RoundedRectangle(cornerRadius: 18).fill(soft.opacity(0.12))
                        }
                    }
            }
    }
}

/// An optional heading above a block ("Food near you", "Tonight").
struct BlockTitle: View {
    let title: String?

    var body: some View {
        if let title, !title.isEmpty {
            Text(title)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
        }
    }
}

/// Opening walking directions in Maps (never navigation inside the app).
enum WalkingDirections {
    @MainActor
    static func open(to location: Location) {
        guard let coordinate = location.coordinate else { return }
        let mapItem = MKMapItem(
            location: CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude),
            address: nil
        )
        mapItem.name = location.name
        mapItem.openInMaps(launchOptions: [
            MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeWalking
        ])
    }
}

// MARK: - Item card

/// What an `ItemCard` shows (the `item_card` block's `show` list).
enum ItemCardPart: String, CaseIterable, Hashable, Sendable {
    case time, place, image, distance, like, actions
}

/// One schedule item, rich: the location's image, name, time with the relative text and the
/// progress bar while it runs, place + distance, a like button and Open / Show on Map.
struct ItemCard: View {
    let item: ScheduleItem
    var show: Set<ItemCardPart> = Set(ItemCardPart.allCases)
    /// Opens the item; nil = `AppState.open(_:)` (its tab, or the search sheet).
    var onOpen: (() -> Void)? = nil

    @Environment(AppState.self) private var appState

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            card(now: context.date)
        }
        // Drag between panes (iPhone Duo unfolded): onto the map, My schedule or the plan.
        .draggable(DragPayload.item(item.id).string)
    }

    private func card(now: Date) -> some View {
        let location = appState.location(id: item.locationId)
        let timeZone = appState.timeZone
        return VStack(alignment: .leading, spacing: 8) {
            if show.contains(.image), appState.display.showLocationImages, let url = location?.imageUrl {
                LocationImage(url: url)
                    .frame(maxWidth: .infinity)
                    .frame(height: 120)
                    .clipShape(.rect(cornerRadius: 12))
                    .accessibilityHidden(true)
            }
            HStack(alignment: .top, spacing: 8) {
                Button(action: open) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.name)
                            .font(.headline)
                            .multilineTextAlignment(.leading)
                        if show.contains(.time) {
                            Text(EventTimeFormat.range(start: item.startTime, end: item.endTime, in: timeZone, now: now))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                            if let relative = RelativeTimeText.item(item, now: now, timeZone: timeZone) {
                                Text(relative)
                                    .font(.subheadline.bold())
                                    .foregroundStyle(ScheduleTiming.hasEnded(item, at: now) ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
                            }
                        }
                        if show.contains(.place) {
                            Label(location?.name ?? item.locationName ?? ScheduleGrouping.generalTitle, systemImage: "mappin.and.ellipse")
                                .font(.subheadline)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityHint("Opens the schedule item.")
                if show.contains(.like) {
                    HeartButton(target: .scheduleItem(item.id))
                }
            }
            if show.contains(.time), let progress = ScheduleTiming.progress(item, at: now) {
                ItemProgressBar(progress: progress)
            }
            if show.contains(.distance) {
                DistanceBadge(target: location?.coordinate, font: .subheadline)
            }
            if show.contains(.actions) {
                CardActions(target: .scheduleItem(item.id), mapLocation: location, onOpen: open)
            }
        }
        .blockCardBackground()
    }

    private func open() {
        if let onOpen { onOpen() } else { appState.open(.scheduleItem(item.id)) }
    }
}

/// Open / Show on Map (/ Directions) under a card.
private struct CardActions: View {
    let target: SearchTarget
    let mapLocation: Location?
    var showsDirections = false
    let onOpen: () -> Void

    @Environment(AppState.self) private var appState

    var body: some View {
        // Wraps onto a second line at large text sizes instead of truncating.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { buttons }
            VStack(alignment: .leading, spacing: 8) { buttons }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    @ViewBuilder
    private var buttons: some View {
        Button("Open", systemImage: "arrow.up.right", action: onOpen)
        if let location = mapLocation, location.coordinate != nil, appState.shows(.map) {
            Button("Show on Map", systemImage: "map") {
                appState.showOnMap(locationId: location.id)
            }
        }
        if showsDirections, let location = mapLocation, location.coordinate != nil {
            Button("Directions", systemImage: "figure.walk") {
                WalkingDirections.open(to: location)
            }
        }
    }
}

// MARK: - Place card

/// What a `PlaceCard` shows (the `place_card` block's `show` list).
enum PlaceCardPart: String, CaseIterable, Hashable, Sendable {
    case image, distance, nowNext, like, actions
}

/// One location, rich: image, name, category and snippet, "Now: X · Next 8:30 Y", distance with
/// the compass arrow, a like button and Open / Show on Map / Directions.
struct PlaceCard: View {
    let location: Location
    var show: Set<PlaceCardPart> = Set(PlaceCardPart.allCases)
    /// Opens the place; nil = `AppState.open(_:)`.
    var onOpen: (() -> Void)? = nil

    @Environment(AppState.self) private var appState

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            card(now: context.date)
        }
        .draggable(DragPayload.place(location.id).string)
    }

    private func card(now: Date) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if show.contains(.image), appState.display.showLocationImages, let url = location.imageUrl {
                LocationImage(url: url)
                    .frame(maxWidth: .infinity)
                    .frame(height: 140)
                    .clipShape(.rect(cornerRadius: 12))
                    .accessibilityHidden(true)
            }
            HStack(alignment: .top, spacing: 8) {
                Button(action: open) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(location.name)
                            .font(.headline)
                            .multilineTextAlignment(.leading)
                        if let category = location.category {
                            Text(category)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.tint)
                        }
                        if !location.snippet.isEmpty {
                            Text(location.snippet)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(3)
                                .multilineTextAlignment(.leading)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityHint("Opens the place.")
                if show.contains(.like) {
                    HeartButton(target: .location(location.id))
                }
            }
            if show.contains(.nowNext) {
                LocationGlanceLine(location: location, now: now)
            }
            if show.contains(.distance) {
                DistanceBadge(target: location.coordinate, font: .subheadline)
            }
            if show.contains(.actions) {
                CardActions(target: .location(location.id), mapLocation: location, showsDirections: true, onOpen: open)
            }
        }
        .blockCardBackground()
    }

    private func open() {
        if let onOpen { onOpen() } else { appState.open(.location(location.id)) }
    }
}

// MARK: - Update card

/// An organizer update; urgent ones (API-011) in red with a warning sign. Tap opens it in Updates.
struct UpdateCard: View {
    let notification: AppNotification
    var onOpen: (() -> Void)? = nil

    @Environment(AppState.self) private var appState

    var body: some View {
        Button {
            if let onOpen { onOpen() } else { appState.open(.notification(notification.id)) }
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                if notification.isUrgent {
                    Label("Urgent", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption.bold())
                        .foregroundStyle(.red)
                } else {
                    Label("Update", systemImage: "bell")
                        .font(.caption.bold())
                        .foregroundStyle(.tint)
                }
                Text(notification.title)
                    .font(.headline)
                    .multilineTextAlignment(.leading)
                if !notification.body.isEmpty {
                    Text(notification.body)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }
                if let sent = notification.sendTime {
                    Text(EventTimeFormat.shortDayTime(sent, in: appState.timeZone))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .blockCardBackground()
        .overlay {
            if notification.isUrgent {
                RoundedRectangle(cornerRadius: 18)
                    .fill(Color.red.opacity(0.12))
                    .allowsHitTesting(false)
            }
        }
        .accessibilityHint("Opens the update.")
    }
}

// MARK: - Compact list

/// Compact rows for mixed ids (`list` block): schedule items, places and updates in the order
/// given, each with the search row's inline info, places with the distance, items and places
/// with a like button. `limit` shows the first n with "Show All".
struct CompactList: View {
    let targets: [SearchTarget]
    var title: String? = nil
    var limit: Int? = nil
    /// A tapped row; nil = `AppState.open(_:)`.
    var onSelect: ((SearchTarget) -> Void)? = nil

    @Environment(AppState.self) private var appState
    @State private var expanded = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let rows = targets.compactMap { appState.searchIndex?.result(for: $0, now: context.date) }
            let shown = (expanded || limit == nil) ? rows : Array(rows.prefix(limit ?? rows.count))
            VStack(alignment: .leading, spacing: 4) {
                BlockTitle(title: title)
                ForEach(shown) { result in
                    row(result)
                    if result.id != shown.last?.id { Divider() }
                }
                if shown.count < rows.count {
                    Button("Show All (\(rows.count))") { expanded = true }
                        .font(.subheadline)
                        .padding(.top, 4)
                }
            }
            .blockCardBackground()
        }
    }

    private func row(_ result: EventSearchResult) -> some View {
        HStack(spacing: 8) {
            Button {
                if let onSelect { onSelect(result.target) } else { appState.open(result.target) }
            } label: {
                SearchResultRow(result: result)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            switch result.target {
            case .location(let id):
                DistanceBadge(target: appState.location(id: id)?.coordinate)
                HeartButton(target: result.target, font: .subheadline)
            case .scheduleItem:
                HeartButton(target: result.target, font: .subheadline)
            case .notification, .event:
                EmptyView()
            }
        }
    }
}

// MARK: - Carousel

/// Horizontal cards (`carousel` block, 2–8): item cards, place cards and update cards side by side,
/// snapping card by card. Each card is about 80 % of the width, so the next one peeks in.
struct CardCarousel: View {
    let targets: [SearchTarget]
    var title: String? = nil
    var onSelect: ((SearchTarget) -> Void)? = nil

    @Environment(AppState.self) private var appState

    /// The `carousel` block's cap.
    static let maxCards = 8

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            BlockTitle(title: title)
            CarouselRow(items: Array(targets.prefix(Self.maxCards)), id: \.self) { target in
                card(target)
            }
        }
    }

    @ViewBuilder
    private func card(_ target: SearchTarget) -> some View {
        let open: (() -> Void)? = onSelect.map { select in { select(target) } }
        switch target {
        case .scheduleItem(let id):
            if let item = appState.schedule.first(where: { $0.id == id }) {
                ItemCard(item: item, show: [.time, .place, .image, .like], onOpen: open)
            }
        case .location(let id):
            if let location = appState.location(id: id) {
                PlaceCard(location: location, show: [.image, .nowNext, .distance, .like], onOpen: open)
            }
        case .notification(let id):
            if let notification = appState.notifications.first(where: { $0.id == id }) {
                UpdateCard(notification: notification, onOpen: open)
            }
        case .event:
            EmptyView()
        }
    }
}

// MARK: - Timeline

/// Time-ordered schedule items (`timeline` block, and the plan's day) with a "Now" line where
/// the current time falls and optional walk legs between items ("6 min walk · 0.3 mi", keyed
/// by the id of the item the walk leads to). `highlightedLegItemId` marks one leg (the walking
/// map's selection).
struct ItemTimeline: View {
    let items: [ScheduleItem]
    var title: String? = nil
    var walkLegs: [Int: String] = [:]
    var highlightedLegItemId: Int? = nil
    var onSelect: ((ScheduleItem) -> Void)? = nil

    @Environment(AppState.self) private var appState

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let now = context.date
            let sorted = items
                .filter { $0.startTime != nil }
                .sorted { ($0.startTime!, $0.id) < ($1.startTime!, $1.id) }
            let nowIndex = Self.nowLineIndex(sorted, now: now)
            VStack(alignment: .leading, spacing: 0) {
                BlockTitle(title: title)
                    .padding(.bottom, 6)
                ForEach(Array(sorted.enumerated()), id: \.element.id) { index, item in
                    if index == nowIndex { NowLine(now: now, timeZone: appState.timeZone) }
                    if let leg = walkLegs[item.id], index > 0 {
                        Label(leg, systemImage: "figure.walk")
                            .font(.caption)
                            .foregroundStyle(item.id == highlightedLegItemId ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                            .fontWeight(item.id == highlightedLegItemId ? .semibold : .regular)
                            .padding(.leading, 64)
                            .padding(.vertical, 4)
                    }
                    row(item, now: now)
                }
                if nowIndex == sorted.count, !sorted.isEmpty {
                    NowLine(now: now, timeZone: appState.timeZone)
                }
            }
            .blockCardBackground()
        }
    }

    /// Where the now line goes: before the first item that hasn't started, once something has
    /// started (`count` = after the last one, while the last one is over but not long ago);
    /// nil before the first start or when everything ended over an hour ago.
    static func nowLineIndex(_ sorted: [ScheduleItem], now: Date) -> Int? {
        guard let first = sorted.first?.startTime, now >= first else { return nil }
        if let index = sorted.firstIndex(where: { ($0.startTime ?? now) > now }) { return index }
        let lastEnd = sorted.compactMap(ScheduleTiming.effectiveEnd(of:)).max() ?? first
        return now.timeIntervalSince(lastEnd) < 3600 ? sorted.count : nil
    }

    private func row(_ item: ScheduleItem, now: Date) -> some View {
        let timeZone = appState.timeZone
        let happening = ScheduleTiming.isHappening(item, at: now)
        let ended = ScheduleTiming.hasEnded(item, at: now)
        return HStack(alignment: .top, spacing: 12) {
            Button {
                if let onSelect { onSelect(item) } else { appState.open(.scheduleItem(item.id)) }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(item.startTime.map { EventTimeFormat.time($0, in: timeZone) } ?? "")
                        .font(.subheadline.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(ended ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
                        .frame(minWidth: 52, alignment: .leading)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            if happening {
                                Circle().fill(.red).frame(width: 7, height: 7).accessibilityHidden(true)
                            }
                            Text(item.name)
                                .font(.body.weight(happening ? .semibold : .regular))
                                .foregroundStyle(ended ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                                .multilineTextAlignment(.leading)
                        }
                        Text(appState.location(id: item.locationId)?.name ?? item.locationName ?? ScheduleGrouping.generalTitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if happening, let progress = ScheduleTiming.progress(item, at: now) {
                            ItemProgressBar(progress: progress)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityValue(happening ? "Happening now" : (ended ? "Ended" : ""))
            HeartButton(target: .scheduleItem(item.id), font: .subheadline)
        }
        .padding(.vertical, 6)
    }
}

/// The red "Now 2:14 PM" rule in a timeline.
private struct NowLine: View {
    let now: Date
    let timeZone: TimeZone

    var body: some View {
        HStack(spacing: 6) {
            Text("Now \(EventTimeFormat.time(now, in: timeZone))")
                .font(.caption2.bold())
                .foregroundStyle(.red)
            Rectangle().fill(.red).frame(height: 1.5)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Now, \(EventTimeFormat.time(now, in: timeZone))")
    }
}

// MARK: - Now / next strip

/// What's on now and next (`now_next` block): at one location, or across the event. Each part
/// opens its item.
struct NowNextStrip: View {
    var locationId: Int? = nil

    @Environment(AppState.self) private var appState

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let now = context.date
            let candidates = appState.schedule.filter { item in
                item.startTime != nil && (locationId == nil || item.locationId == locationId)
            }
            let current = candidates
                .filter { ScheduleTiming.isHappening($0, at: now) }
                .sorted { ($0.startTime!, $0.id) < ($1.startTime!, $1.id) }
            let next = candidates
                .filter { $0.startTime! > now }
                .min { ($0.startTime!, $0.id) < ($1.startTime!, $1.id) }
            VStack(alignment: .leading, spacing: 8) {
                if let locationId, let location = appState.location(id: locationId) {
                    BlockTitle(title: location.name)
                }
                if current.isEmpty, next == nil {
                    Text("Nothing else is scheduled here.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                ForEach(current.prefix(3)) { item in
                    part(label: "Now", item: item, live: true, now: now)
                }
                if let next {
                    part(label: "Next \(EventTimeFormat.shortDayTime(next.startTime!, in: appState.timeZone, now: now))", item: next, live: false, now: now)
                }
            }
            .blockCardBackground()
        }
    }

    private func part(label: String, item: ScheduleItem, live: Bool, now: Date) -> some View {
        Button {
            appState.open(.scheduleItem(item.id))
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                HStack(spacing: 4) {
                    if live { Circle().fill(.red).frame(width: 7, height: 7).accessibilityHidden(true) }
                    Text(label)
                        .font(.caption.bold())
                        .foregroundStyle(live ? AnyShapeStyle(Color.red) : AnyShapeStyle(.tint))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name).font(.subheadline.weight(.semibold))
                    if locationId == nil {
                        Text(appState.location(id: item.locationId)?.name ?? item.locationName ?? ScheduleGrouping.generalTitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Countdown

/// Counts down to an item's start (`countdown` block); "Happening now · ends in …" while it
/// runs, "Ended" after. The digits tick by themselves; screenshot mode shows the relative text.
struct Countdown: View {
    let item: ScheduleItem

    @Environment(AppState.self) private var appState

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let now = context.date
            let timeZone = appState.timeZone
            let relative = RelativeTimeText.item(item, now: now, timeZone: timeZone) ?? ""
            Button {
                appState.open(.scheduleItem(item.id))
            } label: {
                VStack(alignment: .leading, spacing: 6) {
                    Text(item.name)
                        .font(.headline)
                        .multilineTextAlignment(.leading)
                    if let start = item.startTime, let end = ScheduleTiming.effectiveEnd(of: item) {
                        if start > now {
                            Text("Starts in").font(.caption.bold()).foregroundStyle(.secondary)
                            ticking(to: start, fallback: relative)
                            Text(EventTimeFormat.shortDayTime(start, in: timeZone, now: now))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        } else if end > now {
                            Text("Happening now · ends in").font(.caption.bold()).foregroundStyle(.red)
                            ticking(to: end, fallback: relative)
                        } else {
                            Text("Ended").font(.title2.bold()).foregroundStyle(.secondary)
                        }
                    } else {
                        Text("Time TBA").font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(item.name), \(relative)")
            .accessibilityHint("Opens the schedule item.")
            .blockCardBackground()
        }
    }

    @ViewBuilder
    private func ticking(to date: Date, fallback: String) -> some View {
        if ScreenshotMode.isActive || date.timeIntervalSinceNow > 24 * 3600 {
            Text(fallback).font(.title.bold()).foregroundStyle(.tint)
        } else {
            Text(timerInterval: Date.now...max(date, Date.now), countsDown: true)
                .font(.largeTitle.bold())
                .monospacedDigit()
                .foregroundStyle(.tint)
        }
    }
}

// MARK: - Carousel row

extension EnvironmentValues {
    /// True inside one column of a multi-column layout (Home unfolded on iPhone Duo): carousels
    /// clip to their column so cards never run under the other column (Duo simulator feedback
    /// after build 181).
    @Entry var carouselContained = false
}

/// A horizontal row of cards sized from the row's own measured width (not the nearest container,
/// which inside Home's columns resolved to the whole scroll view and made the cards overflow into
/// the other column). Not lazy (≤ 8 cards): the row is as tall as its tallest card and every card
/// takes that height (build 167).
struct CarouselRow<Item, ID: Hashable, Card: View>: View {
    let items: [Item]
    let id: KeyPath<Item, ID>
    var fraction: CGFloat = 0.8
    var maxCardWidth: CGFloat = 420
    @ViewBuilder let card: (Item) -> Card

    @Environment(\.carouselContained) private var contained
    @State private var width: CGFloat = 0

    private var cardWidth: CGFloat {
        let base = width > 0 ? width : 320
        return items.count == 1 && fraction >= 1 ? base : min(base * fraction, maxCardWidth)
    }

    var body: some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 12) {
                ForEach(items, id: id) { item in
                    card(item)
                        .frame(width: cardWidth)
                        .frame(maxHeight: .infinity, alignment: .top)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .scrollTargetLayout()
        }
        .frame(maxWidth: .infinity)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .scrollTargetBehavior(.viewAligned)
        .scrollIndicators(.hidden)
        // Single column: cards peek past the screen edge as before. In a column: clipped to it.
        .scrollClipDisabled(!contained)
    }
}
