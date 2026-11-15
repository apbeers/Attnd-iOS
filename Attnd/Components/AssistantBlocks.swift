// AssistantBlocks.swift
// Attnd (app + App Clip)
//
// The event assistant's component library, part 2 (assistant spec §2; part 1 is
// AssistantCards.swift, the share block is ShareCard.swift, the calendar block CalendarCard.swift):
//
//   - MiniMap (`map`: pins, a numbered walking route, the user's dot; tap → the full map)
//   - Gallery (`gallery`: location images or the flyer)
//   - CompareView (`compare`: two items or two plan versions side by side)
//   - PlanDiffView (`plan_diff`: − / + rows with Apply / Undo)
//   - SettingCard / AppSettingCard (`setting`: Follow on Lock Screen, reminders, notifications)
//   - SummaryCard (`summary`: walking, recap, liked counts)
//   - ChipRow (`chips`: ≤ 5 follow-up actions), ConfirmChip (`confirm`: Yes / Not Now)
//
// Inputs are plain values (resolved models, labels, closures); the assistant phase maps its
// blocks and actions onto them. Same rules as part 1: no glass on content, real buttons,
// Dynamic Type, nothing location-based in screenshot mode.

import MapKit
import SwiftUI

// MARK: - Mini map

/// A small, non-interactive map (`map` block): pins for `pins` (≤ 12, only those with
/// coordinates), `route` drawn as numbered stops joined in the accent colour (straight legs
/// for now; the walking-map phase upgrades them to real routes), and the user's dot when
/// location is allowed. Tapping it opens the full Map tab on the first stop or pin.
struct MiniMap: View {
    let pins: [Location]
    var route: [Location] = []
    var showsUser = true
    var height: CGFloat = 180
    /// nil = the Map tab at the first stop / pin (`AppState.showOnMap`), or that place's
    /// detail when the Map tab is hidden.
    var onOpen: (() -> Void)? = nil

    /// The `map` block's cap.
    static let maxPins = 12

    @Environment(AppState.self) private var appState

    var body: some View {
        let stops = route.filter { $0.coordinate != nil }
        let stopIds = Set(stops.map(\.id))
        let others = Array(pins.filter { $0.coordinate != nil && !stopIds.contains($0.id) }.prefix(max(0, Self.maxPins - stops.count)))
        if stops.isEmpty, others.isEmpty {
            EmptyView()
        } else {
            Button {
                open(first: stops.first ?? others.first)
            } label: {
                Map(initialPosition: .automatic, interactionModes: []) {
                    if stops.count > 1 {
                        MapPolyline(coordinates: stops.compactMap { $0.coordinate?.clCoordinate })
                            .stroke(.tint, style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
                    }
                    ForEach(Array(stops.enumerated()), id: \.element.id) { index, stop in
                        Annotation(stop.name, coordinate: stop.coordinate!.clCoordinate) {
                            NumberedPin(number: index + 1)
                        }
                    }
                    ForEach(others) { location in
                        Marker(location.name, coordinate: location.coordinate!.clCoordinate)
                            .tint(.accentColor)
                    }
                    if showsUser, appState.userLocation.isAuthorized, !ScreenshotMode.isActive {
                        UserAnnotation()
                    }
                }
                .mapStyle(.standard(pointsOfInterest: .excludingAll))
                .allowsHitTesting(false)
                // A new set of pins frames itself again.
                .id((stops + others).map(\.id))
                .frame(height: height)
                .clipShape(.rect(cornerRadius: 18))
                .overlay(alignment: .bottomTrailing) {
                    Label("Open Map", systemImage: "arrow.up.left.and.arrow.down.right")
                        .labelStyle(.iconOnly)
                        .font(.caption.bold())
                        .padding(8)
                        .background(.regularMaterial, in: .circle)
                        .padding(8)
                        .accessibilityHidden(true)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(accessibilityText(stops: stops, others: others))
            .accessibilityHint("Opens the map.")
        }
    }

    private func accessibilityText(stops: [Location], others: [Location]) -> String {
        if stops.count > 1 {
            let names = stops.enumerated().map { "\($0.offset + 1), \($0.element.name)" }.joined(separator: "; ")
            return "Walking route map: \(names)"
        }
        return "Map of " + (stops + others).map(\.name).joined(separator: ", ")
    }

    private func open(first: Location?) {
        if let onOpen { return onOpen() }
        guard let first else { return }
        if appState.tabs.contains(.map) {
            appState.showOnMap(locationId: first.id)
        } else {
            appState.navigate(to: .location(first.id))
        }
    }
}

/// A route stop: its number in a filled accent circle.
private struct NumberedPin: View {
    let number: Int

    var body: some View {
        Text("\(number)")
            .font(.caption.bold())
            .monospacedDigit()
            .foregroundStyle(.white)
            .frame(minWidth: 24, minHeight: 24)
            .background(Circle().fill(Color.accentColor))
            .overlay(Circle().stroke(.white, lineWidth: 2))
            .accessibilityHidden(true)
    }
}

// MARK: - Gallery

/// One picture in a `Gallery`.
struct GalleryImage: Identifiable, Hashable, Sendable {
    var id: String
    var url: URL
    var caption: String?
    /// What a tap opens (a location); nil for the flyer, which opens the Flyer tab.
    var target: SearchTarget?

    /// The event's flyer (`flyer_url`; a PDF shows a placeholder and still opens the tab).
    static func flyer(_ url: URL) -> GalleryImage {
        GalleryImage(id: "flyer", url: url, caption: "Flyer", target: nil)
    }
}

/// Images side by side (`gallery` block): location images (from the offline cache) or the
/// flyer. Tap opens the place, or the Flyer tab.
struct Gallery: View {
    let images: [GalleryImage]
    var title: String? = nil
    var onSelect: ((GalleryImage) -> Void)? = nil

    @Environment(AppState.self) private var appState

    init(images: [GalleryImage], title: String? = nil, onSelect: ((GalleryImage) -> Void)? = nil) {
        self.images = images
        self.title = title
        self.onSelect = onSelect
    }

    /// The images of `locations` that have one, captioned with the place's name.
    init(locations: [Location], title: String? = nil, onSelect: ((GalleryImage) -> Void)? = nil) {
        self.init(
            images: locations.compactMap { location in
                location.imageUrl.map { GalleryImage(id: "l\(location.id)", url: $0, caption: location.name, target: .location(location.id)) }
            },
            title: title,
            onSelect: onSelect
        )
    }

    var body: some View {
        if !images.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                BlockTitle(title: title)
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: 12) {
                        ForEach(images) { image in
                            tile(image)
                                .containerRelativeFrame(.horizontal) { width, _ in images.count == 1 ? width : width * 0.65 }
                        }
                    }
                    .scrollTargetLayout()
                }
                .scrollTargetBehavior(.viewAligned)
                .scrollIndicators(.hidden)
                .scrollClipDisabled()
            }
        }
    }

    private func tile(_ image: GalleryImage) -> some View {
        Button {
            select(image)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                CachedImage(url: image.url) { loaded in
                    loaded.resizable().scaledToFill()
                } placeholder: { failed in
                    Color(.systemGray5).overlay {
                        if failed {
                            Image(systemName: image.target == nil ? "doc.richtext" : "photo").foregroundStyle(.secondary)
                        } else {
                            ProgressView()
                        }
                    }
                }
                .frame(height: 160)
                .frame(maxWidth: .infinity)
                .clipShape(.rect(cornerRadius: 14))
                if let caption = image.caption {
                    Text(caption)
                        .font(.subheadline)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(image.caption ?? "Image")
        .accessibilityAddTraits(.isImage)
        .accessibilityHint(image.target == nil ? "Opens the flyer." : "Opens the place.")
    }

    private func select(_ image: GalleryImage) {
        if let onSelect { return onSelect(image) }
        if let target = image.target {
            appState.navigate(to: target)
        } else if appState.tabs.contains(.flyer) {
            appState.presentedSheet = nil
            appState.selectedTab = .flyer
        }
    }
}

// MARK: - Compare

/// One line of a `CompareColumn` ("When" · "Sat 3:00 – 4:00 PM").
struct CompareRow: Hashable, Sendable {
    var label: String
    var value: String
}

/// One side of a comparison: an item, or a plan version ("Chill", "See everything").
struct CompareColumn: Identifiable, Hashable, Sendable {
    var id: String
    var title: String
    var subtitle: String? = nil
    var rows: [CompareRow] = []
    /// The choose button's title ("Use This Plan"); nil = no button.
    var actionTitle: String? = nil
}

extension CompareColumn {
    /// A schedule item: when, where, tags.
    @MainActor
    static func item(_ item: ScheduleItem, appState: AppState, actionTitle: String? = nil) -> CompareColumn {
        var rows = [CompareRow(label: "When", value: EventTimeFormat.range(start: item.startTime, end: item.endTime, in: appState.timeZone))]
        rows.append(CompareRow(label: "Where", value: appState.location(id: item.locationId)?.name ?? item.locationName ?? ScheduleGrouping.generalTitle))
        if !item.tags.isEmpty { rows.append(CompareRow(label: "Tags", value: TagText.line(item.tags))) }
        return CompareColumn(id: "s\(item.id)", title: item.name, rows: rows, actionTitle: actionTitle)
    }
}

/// Two options side by side (`compare` block); stacked at accessibility text sizes.
struct CompareView: View {
    let a: CompareColumn
    let b: CompareColumn
    var title: String? = nil
    var onChoose: ((CompareColumn) -> Void)? = nil

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
            : AnyLayout(HStackLayout(alignment: .top, spacing: 12))
        VStack(alignment: .leading, spacing: 8) {
            BlockTitle(title: title)
            layout {
                column(a)
                column(b)
            }
        }
    }

    private func column(_ column: CompareColumn) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(column.title)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            if let subtitle = column.subtitle {
                Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
            }
            ForEach(column.rows, id: \.self) { row in
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.label).font(.caption).foregroundStyle(.secondary)
                    Text(row.value).font(.subheadline)
                }
                .accessibilityElement(children: .combine)
            }
            Spacer(minLength: 0)
            if let actionTitle = column.actionTitle, let onChoose {
                Button(actionTitle) { onChoose(column) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .blockCardBackground()
    }
}

// MARK: - Plan diff

/// What happened to one row of a plan edit.
enum PlanDiffChange: String, Hashable, Sendable {
    case removed, added, moved, mealRemoved, mealAdded

    var systemImage: String {
        switch self {
        case .removed:     return "minus.circle.fill"
        case .added:       return "plus.circle.fill"
        case .moved:       return "arrow.up.arrow.down.circle.fill"
        case .mealRemoved: return "fork.knife.circle"
        case .mealAdded:   return "fork.knife.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .removed, .mealRemoved: return .red
        case .added, .mealAdded:     return .green
        case .moved:                 return .orange
        }
    }

    /// Spoken before the row ("Removed: Kolache masterclass").
    var spokenName: String {
        switch self {
        case .removed:     return "Removed"
        case .added:       return "Added"
        case .moved:       return "Moved"
        case .mealRemoved: return "Meal break removed"
        case .mealAdded:   return "Meal break added"
        }
    }
}

/// One row of a `PlanDiffView` ("Kolache masterclass" · "Sat 3:00 PM · Trinity Stage").
struct PlanDiffRow: Identifiable, Hashable, Sendable {
    var id: String
    var change: PlanDiffChange
    var title: String
    var detail: String? = nil
}

enum PlanDiffStatus: Hashable, Sendable {
    /// Proposed: Apply.
    case preview
    /// Applied: Undo.
    case applied
    /// Undone after applying.
    case undone
}

/// A proposed or applied plan edit (`plan_diff` block): − / + / moved rows, then Apply (a
/// preview) or Undo (applied).
struct PlanDiffView: View {
    let rows: [PlanDiffRow]
    var title: String = "Changes to Your Plan"
    var summary: String? = nil
    var status: PlanDiffStatus = .preview
    var onApply: (() -> Void)? = nil
    var onUndo: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: "list.bullet.clipboard")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            if let summary {
                Text(summary).font(.subheadline).foregroundStyle(.secondary)
            }
            if rows.isEmpty {
                Text("No changes to your plan.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            ForEach(rows) { row in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: row.change.systemImage)
                        .foregroundStyle(row.change.color)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.title)
                            .font(.subheadline.weight(.semibold))
                            .strikethrough(row.change == .removed || row.change == .mealRemoved)
                        if let detail = row.detail {
                            Text(detail).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(row.change.spokenName): \(row.title)" + (row.detail.map { ", \($0)" } ?? ""))
            }
            HStack(spacing: 8) {
                switch status {
                case .preview:
                    if let onApply, !rows.isEmpty {
                        Button("Apply", systemImage: "checkmark", action: onApply)
                            .buttonStyle(.borderedProminent)
                    }
                case .applied:
                    Label("Applied", systemImage: "checkmark.circle.fill")
                        .font(.subheadline)
                        .foregroundStyle(.green)
                    if let onUndo {
                        Button("Undo", systemImage: "arrow.uturn.backward", action: onUndo)
                            .buttonStyle(.bordered)
                    }
                case .undone:
                    Label("Undone", systemImage: "arrow.uturn.backward.circle")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .controlSize(.small)
            .padding(.top, 4)
        }
        .blockCardBackground()
    }
}

// MARK: - Setting card

/// The settings the assistant may offer to turn on (`setting` block).
enum SettingCardKind: String, CaseIterable, Hashable, Sendable {
    case followLockScreen = "follow_lock_screen"
    case reminders
    case notifications

    var title: String {
        switch self {
        case .followLockScreen: return "Follow on Lock Screen"
        case .reminders:        return "Reminders"
        case .notifications:    return "Notifications"
        }
    }

    var detail: String {
        switch self {
        case .followLockScreen:
            return "What's on now and next from your plan or your likes, on the Lock Screen and in the Dynamic Island."
        case .reminders:
            return "A reminder 15 minutes before anything you've liked or planned. Comes with notifications."
        case .notifications:
            return "Set-time changes and urgent news from the organizers."
        }
    }

    var systemImage: String {
        switch self {
        case .followLockScreen: return "lock.iphone"
        case .reminders:        return "alarm"
        case .notifications:    return "bell.badge"
        }
    }
}

/// A toggle card for one setting, driven by plain inputs.
struct SettingCard: View {
    let kind: SettingCardKind
    let isOn: Bool
    var isBusy = false
    var note: String? = nil
    let onChange: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: Binding(get: { isOn }, set: { onChange($0) })) {
                Label(kind.title, systemImage: kind.systemImage)
                    .font(.headline)
            }
            .disabled(isBusy)
            Text(kind.detail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if let note {
                Text(note).font(.caption).foregroundStyle(.secondary)
            }
        }
        .blockCardBackground()
    }
}

/// A `SettingCard` wired to AppState: Follow on Lock Screen (full app only), and the
/// notification opt-in, which also carries reminders on iOS (asks for permission when needed).
struct AppSettingCard: View {
    let kind: SettingCardKind

    @Environment(AppState.self) private var appState
    @State private var busy = false

    var body: some View {
        switch kind {
        case .followLockScreen:
            #if APP_CLIP
            EmptyView()
            #else
            SettingCard(kind: kind, isOn: appState.followsOnLockScreen) { on in
                appState.setFollowOnLockScreen(on)
            }
            #endif
        case .reminders, .notifications:
            SettingCard(kind: kind, isOn: appState.notificationsEnabled, isBusy: busy) { on in
                busy = true
                Task {
                    _ = await appState.setNotificationsEnabled(on)
                    busy = false
                }
            }
        }
    }
}

// MARK: - Summary

/// One figure in a `SummaryCard` ("2.8 mi" · "walking today").
struct SummaryStat: Identifiable, Hashable, Sendable {
    var value: String
    var label: String
    var systemImage: String? = nil
    var id: String { label }
}

/// A stats card (`summary` block: walking, the day's recap, liked counts).
struct SummaryCard: View {
    let title: String
    var systemImage: String = "chart.bar.fill"
    let stats: [SummaryStat]
    var footnote: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: systemImage)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), alignment: .topLeading)], alignment: .leading, spacing: 12) {
                ForEach(stats) { stat in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 4) {
                            if let symbol = stat.systemImage {
                                Image(systemName: symbol).foregroundStyle(.tint).accessibilityHidden(true)
                            }
                            Text(stat.value)
                                .font(.title2.bold())
                                .monospacedDigit()
                        }
                        Text(stat.label)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            if let footnote {
                Text(footnote).font(.caption).foregroundStyle(.secondary)
            }
        }
        .blockCardBackground()
    }
}

// MARK: - Chips

/// One follow-up action chip; `id` is the caller's action key.
struct ChipItem: Identifiable, Hashable, Sendable {
    var id: String
    var label: String
    var systemImage: String? = nil
}

/// Quick follow-up actions (`chips` block), at most five, in one scrolling row.
struct ChipRow: View {
    let chips: [ChipItem]
    let onTap: (ChipItem) -> Void

    /// The `chips` block's cap.
    static let maxChips = 5

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(Array(chips.prefix(Self.maxChips))) { chip in
                    Button {
                        onTap(chip)
                    } label: {
                        if let symbol = chip.systemImage {
                            Label(chip.label, systemImage: symbol)
                        } else {
                            Text(chip.label)
                        }
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .controlSize(.small)
                }
            }
        }
        .scrollIndicators(.hidden)
        .scrollClipDisabled()
    }
}

/// The state of a `ConfirmChip`.
enum ConfirmState: Hashable, Sendable {
    case pending, confirmed, declined
}

/// Yes / Not Now for an action that changes something (`confirm` block: turning on reminders,
/// Follow on Lock Screen, notifications). After a choice it shows the outcome instead.
struct ConfirmChip: View {
    let prompt: String
    var confirmTitle = "Yes"
    var cancelTitle = "Not Now"
    var state: ConfirmState = .pending
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(prompt)
                .font(.subheadline)
            switch state {
            case .pending:
                HStack(spacing: 8) {
                    Button(confirmTitle, action: onConfirm)
                        .buttonStyle(.borderedProminent)
                    Button(cancelTitle, action: onCancel)
                        .buttonStyle(.bordered)
                }
                .buttonBorderShape(.capsule)
                .controlSize(.small)
            case .confirmed:
                Label("Done", systemImage: "checkmark.circle.fill")
                    .font(.subheadline)
                    .foregroundStyle(.green)
            case .declined:
                Label("Not changed", systemImage: "xmark.circle")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .blockCardBackground()
    }
}
