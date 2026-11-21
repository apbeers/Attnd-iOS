// AssistantBlockView.swift
// Attnd (app + App Clip)
//
// The block renderer (assistant spec §2): every `AssistantBlock` (ids and options only) is
// resolved against the shown bundle and drawn with the component library
// (`Components/AssistantCards.swift`, `AssistantBlocks.swift`, `ShareCard.swift`). Ids that no longer exist render nothing (the validator ran when the
// turn was made; a content update can still remove items). One small view per block type, so
// no view body grows big enough to slow the type checker.
//
// Also here: `AssistantPlanView` (the `plan` block and the assistant's pinned plan: the day's
// entries with check-offs, walking legs on real paths, meal breaks and the mini map), and the
// rows a `plan_diff` shows.

import SwiftUI

/// One block of a turn (the chat): drawn by `ComponentView`, like every screen component.
struct AssistantBlockView: View {
    let block: AssistantBlock
    let turn: AssistantController.Turn
    let index: Int

    var body: some View {
        ComponentView(component: ComponentCatalogue.component(block), turn: turn, index: index)
    }
}

/// The one renderer of the component catalogue (Component.swift): chat blocks, the Home tab's
/// sections and the screen components a chat answer shows (a place's menu, an item's
/// performers, the FAQ, getting there, My schedule, now / next…). Screen components are drawn by
/// `ScreenComponentView` (ScreenLayoutViews.swift) in Home's style; `turn` is the chat turn (Undo,
/// answered confirmations), nil on screens; `open` pushes a tapped item (Home), nil = the app's
/// default navigation.
struct ComponentView: View {
    let component: Component
    var turn: AssistantController.Turn? = nil
    var index = 0
    var now: Date = .now
    var open: ((SearchTarget) -> Void)? = nil

    @Environment(AppState.self) private var appState

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var content: some View {
        if let block = component.block, AssistantBlock.types.contains(component.type) {
            blockContent(block)
        } else {
            ScreenComponentView(component: component, now: now, open: open ?? { appState.open($0) })
        }
    }

    @ViewBuilder
    private func blockContent(_ block: AssistantBlock) -> some View {
        switch block {
        case .text(let text):
            AssistantTextBlock(text: text)
        case .itemCard(let id, let show):
            if let item = appState.currentBundle?.scheduleItem(id) {
                ItemCard(item: item, show: Set(show.compactMap(ItemCardPart.init(rawValue:))))
            }
        case .placeCard(let id, let show):
            if let location = appState.location(id: id) {
                PlaceCard(location: location, show: Set(show.compactMap(ComponentView.placePart)))
            }
        case .updateCard(let id):
            if let update = appState.notifications.first(where: { $0.id == id }) {
                UpdateCard(notification: update)
            }
        case .list(let ids, let title, let limit):
            CompactList(targets: ids.map(ComponentView.target), title: title, limit: limit)
                .blockCardBackground()
        case .carousel(let ids, let title):
            CardCarousel(targets: ids.map(ComponentView.target), title: title)
        case .timeline(let ids, let source, let title):
            TimelineBlock(ids: ids, source: source, title: title)
        case .map(let pins, let route):
            MapBlock(pins: pins, route: route)
        case .gallery(let ids, let flyer):
            GalleryBlock(ids: ids, flyer: flyer)
        case .nowNext(let location):
            NowNextStrip(locationId: location)
        case .countdown(let id):
            if let item = appState.currentBundle?.scheduleItem(id) {
                Countdown(item: item)
            }
        case .compare(let a, let b):
            CompareBlock(a: a, b: b)
        case .planDiff(let diff):
            if let turn { PlanDiffBlock(diff: diff, turn: turn) }
        case .plan(let day):
            AssistantPlanView(day: day, showsHeader: true)
        case .setting(let setting):
            if let kind = SettingCardKind(rawValue: setting) {
                AppSettingCard(kind: kind)
            }
        case .summary(let kind):
            SummaryBlock(kind: kind)
        case .share(let target):
            ShareBlock(target: target)
        case .chips(let chips):
            ChipsBlock(chips: chips)
        case .confirm(_, let prompt):
            if let turn { ConfirmBlock(prompt: prompt, turnId: turn.id, index: index, answer: turn.answered[index]) }
        case .component(let inner):
            ScreenComponentView(component: inner, now: now, open: open ?? { appState.open($0) })
        }
    }

    static func target(_ ref: EntityRef) -> SearchTarget {
        switch ref.kind {
        case .schedule: return .scheduleItem(ref.id)
        case .location: return .location(ref.id)
        case .update: return .notification(ref.id)
        }
    }

    static func placePart(_ name: String) -> PlaceCardPart? {
        switch name {
        case "image": return .image
        case "distance": return .distance
        case "now_next": return .nowNext
        case "like": return .like
        case "actions": return .actions
        default: return nil
        }
    }
}

// MARK: - Text

/// An assistant sentence: plain text with **bold** (Markdown, inline only).
struct AssistantTextBlock: View {
    let text: String

    var body: some View {
        Text(Self.attributed(text))
            .font(.body)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }

    static func attributed(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}

// MARK: - Timeline, map, gallery

private struct TimelineBlock: View {
    let ids: [Int]
    let source: String?
    let title: String?

    @Environment(AppState.self) private var appState

    var body: some View {
        if let bundle = appState.currentBundle {
            let resolved = BlockData.timeline(ids, source: source, bundle, appState.planner.plan, now: .now)
            let items = resolved.compactMap { bundle.scheduleItem($0) }
            if !items.isEmpty {
                ItemTimeline(items: items, title: title ?? (source == "plan" ? "My plan" : nil))
                    .blockCardBackground()
            }
        }
    }
}

private struct MapBlock: View {
    let pins: [Int]
    let route: [Int]

    @Environment(AppState.self) private var appState

    var body: some View {
        let pinPlaces = pins.compactMap { appState.location(id: $0) }
        let stops = route.compactMap { appState.location(id: $0) }
        MiniMap(pins: pinPlaces, route: stops, routeLines: lines)
            .task(id: route) {
                if let day = dayRoute { await appState.assistant.dayRoutes.load(day) }
            }
    }

    /// When the route is the plan's day route, its walking legs on real paths.
    private var dayRoute: DayRoute? {
        guard route.count >= 2, let bundle = appState.currentBundle, let plan = appState.planner.plan,
              let day = BlockData.planDay(plan, bundle, now: .now),
              let base = DayRoutes.of(plan, bundle, date: day.date),
              base.stops.map(\.locationId) == route else { return nil }
        return base
    }

    private var lines: [[Coordinate]] {
        guard let base = dayRoute else { return [] }
        let routed = appState.assistant.dayRoutes.route(base)
        guard routed.legs.contains(where: { !$0.route.isEstimate }) else { return [] }
        return routed.legs.map(\.route.points)
    }
}

private struct GalleryBlock: View {
    let ids: [Int]
    let flyer: Bool

    @Environment(AppState.self) private var appState

    var body: some View {
        let places = ids.compactMap { appState.location(id: $0) }
        if flyer, let url = appState.currentEvent?.flyerUrl, places.isEmpty {
            Gallery(images: [.flyer(url)])
        } else {
            Gallery(locations: places)
        }
    }
}

// MARK: - Compare

private struct CompareBlock: View {
    let a: String
    let b: String

    @Environment(AppState.self) private var appState

    var body: some View {
        if let left = column(a), let right = column(b) {
            CompareView(a: left, b: right, title: left.id.hasPrefix("plan:") ? "Two ways to do your day" : nil) { chosen in
                choose(chosen)
            }
        }
    }

    private func column(_ side: String) -> CompareColumn? {
        guard let bundle = appState.currentBundle,
              let resolved = BlockData.compare(side, appState.planner.plan, bundle, appState.likeSet, now: .now) else { return nil }
        switch resolved {
        case .item(let item):
            let planned = appState.plannedItemIds.contains(item.id)
            let canAdd = appState.planner.hasPlan && !planned && (item.startTime ?? .distantPast) > .now
            return .item(item, appState: appState, actionTitle: canAdd ? "Add to My Plan" : nil)
        case .version(let kind, let edit):
            var rows = [CompareRow(label: "Changes", value: AssistantRouter.describe(edit, bundle))]
            if let route = DayRoutes.of(edit.after, bundle) {
                let today = PlanDate(.now, in: PlanCalendar.calendar(bundle.event.timeZone))
                rows.append(CompareRow(label: "Walking", value: DayRoutes.totalText(route, today: today, Self.units, locale: .current)))
            }
            return CompareColumn(
                id: "plan:\(kind.key)",
                title: kind.label,
                subtitle: Planner.summary(edit.after, timeZone: bundle.event.timeZone),
                rows: rows,
                actionTitle: "Use This Plan"
            )
        }
    }

    static var units: DistanceUnits { DistanceText.usesImperial() ? .imperial : .metric }

    private func choose(_ column: CompareColumn) {
        let assistant = appState.assistant
        if column.id.hasPrefix("plan:"), let kind = PlanVersionKind.of(String(column.id.dropFirst(5))) {
            assistant.run(.planVersion(kind), label: kind.label, source: .manual)
        } else if let ref = EntityRef.parse(column.id), let bundle = appState.currentBundle {
            assistant.run(.planEdit([.add(item: ref.id)], bundle), label: "Add \(column.title)", source: .manual)
        }
    }
}

// MARK: - Plan diff

private struct PlanDiffBlock: View {
    let diff: PlanDiff
    let turn: AssistantController.Turn

    @Environment(AppState.self) private var appState

    var body: some View {
        let rows = PlanDiffRows.make(diff, appState: appState)
        let applied = turn.applied.map { [ActionName.planEdit, .planVersion].contains($0.name) } ?? false
        let assistant = appState.assistant
        let turnId = turn.id
        if applied && !turn.undone {
            PlanDiffView(rows: rows, status: .applied, onUndo: { assistant.undo(turnId: turnId) })
        } else if applied {
            PlanDiffView(rows: rows, status: .preview, onApply: { assistant.reapply(turnId: turnId) })
        } else {
            PlanDiffView(rows: rows, status: .preview)
        }
    }
}

/// The − / + / moved rows of a `PlanDiff`.
enum PlanDiffRows {
    @MainActor
    static func make(_ diff: PlanDiff, appState: AppState) -> [PlanDiffRow] {
        let zone = appState.timeZone
        func detail(_ id: Int) -> String? {
            guard let item = appState.currentBundle?.scheduleItem(id) else { return nil }
            var parts = [EventTimeFormat.range(start: item.startTime, end: item.endTime, in: zone)]
            if let place = appState.location(id: item.locationId)?.name { parts.append(place) }
            return parts.joined(separator: " · ")
        }
        func name(_ id: Int) -> String { appState.currentBundle?.scheduleItem(id)?.name ?? "An item" }
        func meal(_ slot: MealSlot) -> String { "\(slot.kind.label) on \(slot.date.weekdayName)" }
        var rows: [PlanDiffRow] = []
        rows += diff.removed.map { PlanDiffRow(id: "r\($0)", change: .removed, title: name($0), detail: detail($0)) }
        rows += diff.added.map { PlanDiffRow(id: "a\($0)", change: .added, title: name($0), detail: detail($0)) }
        rows += diff.moved.map { PlanDiffRow(id: "m\($0.from)-\($0.to)", change: .moved, title: name($0.to), detail: detail($0.to).map { "Now \($0)" }) }
        rows += diff.mealsRemoved.map { PlanDiffRow(id: "mr\($0.encoded)", change: .mealRemoved, title: meal($0)) }
        rows += diff.mealsAdded.map { PlanDiffRow(id: "ma\($0.encoded)", change: .mealAdded, title: meal($0)) }
        rows += diff.mealsMoved.map { PlanDiffRow(id: "mm\($0.encoded)", change: .moved, title: meal($0), detail: "At another time") }
        return rows
    }
}

// MARK: - Summary, share

private struct SummaryBlock: View {
    let kind: String

    @Environment(AppState.self) private var appState

    var body: some View {
        switch kind {
        case "walking": walking
        case "recap": recap
        case "liked_counts": SummaryCard(title: MyScheduleText.title, systemImage: "calendar", stats: likedStats())
        default: EmptyView()
        }
    }

    private var units: DistanceUnits { DistanceText.usesImperial() ? .imperial : .metric }

    private var baseRoute: DayRoute? {
        guard let bundle = appState.currentBundle, let plan = appState.planner.plan,
              let day = BlockData.planDay(plan, bundle, now: .now) else { return nil }
        return DayRoutes.of(plan, bundle, date: day.date)
    }

    @ViewBuilder
    private var walking: some View {
        if let base = baseRoute {
            let route = appState.assistant.dayRoutes.route(base)
            let estimated = route.legs.contains { $0.route.isEstimate }
            SummaryCard(title: "Walking", systemImage: "figure.walk", stats: walkingStats(route),
                        footnote: estimated ? "Some walks are estimates." : nil)
                .task { await appState.assistant.dayRoutes.load(base) }
        }
    }

    private func walkingStats(_ route: DayRoute) -> [SummaryStat] {
        let walks = route.legs.count
        return [
            SummaryStat(value: AssistantText.distance(route.totalMeters, units, locale: .current), label: route.date.weekdayName),
            SummaryStat(value: AssistantText.duration(route.totalSeconds), label: "on foot"),
            SummaryStat(value: String(walks), label: walks == 1 ? "walk" : "walks"),
        ]
    }

    private var recapValue: Recap? {
        guard let bundle = appState.currentBundle, let plan = appState.planner.plan else { return nil }
        let now = Date.now
        let today = PlanDate(now, in: PlanCalendar.calendar(bundle.event.timeZone))
        let date = plan.days.last(where: { $0.date <= today })?.date ?? plan.days.first?.date ?? today
        return LiveAssist.recap(plan, bundle, appState.likeSet, date: date, now: now, units: units, locale: .current)
    }

    @ViewBuilder
    private var recap: some View {
        if let recap = recapValue {
            SummaryCard(title: "Your \(recap.date.weekdayName)", systemImage: "sparkles", stats: recapStats(recap), footnote: recap.text)
        }
    }

    private func recapStats(_ recap: Recap) -> [SummaryStat] {
        [
            SummaryStat(value: String(recap.checkedOff.count), label: "seen", systemImage: "checkmark.circle"),
            SummaryStat(value: String(recap.likedCount), label: "added", systemImage: "heart"),
            SummaryStat(value: AssistantText.distance(recap.walkedMeters, units, locale: .current), label: "walked", systemImage: "figure.walk"),
        ]
    }

    private func likedStats() -> [SummaryStat] {
        let likes = appState.likeSet
        let items = likes.scheduleItems.count, places = likes.locations.count
        return [
            SummaryStat(value: String(items), label: items == 1 ? "item" : "items"),
            SummaryStat(value: String(places), label: places == 1 ? "place" : "places"),
        ]
    }
}

private struct ShareBlock: View {
    let target: String

    @Environment(AppState.self) private var appState

    var body: some View {
        if let link = appState.assistant.shareLink(target) {
            ShareCard(title: link.title, url: link.url, subtitle: target == "plan" ? "\(link.items) items, read-only. Friends can use it or merge it with theirs." : nil)
                .task(id: link.url) {
                    appState.assistant.logShare(target, url: link.url, items: link.items)
                }
        }
    }
}

// MARK: - Chips and confirm

private struct ChipsBlock: View {
    let chips: [AssistantChip]

    @Environment(AppState.self) private var appState

    var body: some View {
        let items = chips.enumerated().map { ChipItem(id: String($0.offset), label: $0.element.label, systemImage: Self.symbol($0.element.action.name)) }
        ChipRow(chips: items) { item in
            guard let index = Int(item.id), index < chips.count else { return }
            appState.assistant.chip(chips[index])
        }
    }

    static func symbol(_ name: ActionName) -> String? {
        switch name {
        case .like, .scheduleAdd: return "heart"
        case .unlike, .scheduleRemove: return "heart.slash"
        case .scheduleReminder: return "bell"
        case .scheduleMove: return "clock"
        case .mySchedule: return "calendar"
        case .open: return "arrow.up.right"
        case .directions: return "figure.walk"
        case .planUndo: return "arrow.uturn.backward"
        case .planEdit, .planVersion: return "list.bullet.clipboard"
        case .sharePlan, .shareItem: return "square.and.arrow.up"
        case .planMake: return "sparkles"
        default: return nil
        }
    }
}

private struct ConfirmBlock: View {
    let prompt: String
    let turnId: Int
    let index: Int
    let answer: Bool?

    @Environment(AppState.self) private var appState

    var body: some View {
        let state: ConfirmState = answer.map { $0 ? .confirmed : .declined } ?? .pending
        ConfirmChip(prompt: prompt, state: state) {
            appState.assistant.answerConfirm(turnId: turnId, index: index, yes: true)
        } onCancel: {
            appState.assistant.answerConfirm(turnId: turnId, index: index, yes: false)
        }
    }
}

// MARK: - Plan

/// The plan of one day (`plan` block, the pinned plan): the walking map with numbered stops,
/// the day's entries in order — items (check-off, time, name, place, reason, like), the walk
/// before each ("6 min walk · 0.3 mi", tap → that leg on the full map) and meal breaks — and
/// the day's walking total.
struct AssistantPlanView: View {
    var day: PlanDate? = nil
    var showsHeader = true
    /// How many upcoming entries to show (nil: all).
    var limit: Int? = nil

    @Environment(AppState.self) private var appState

    var body: some View {
        if let bundle = appState.currentBundle, let plan = appState.planner.plan, !plan.isEmpty,
           let planDay = BlockData.planDay(plan, bundle, now: .now, day: day) {
            PlanDayContent(plan: plan, day: planDay, bundle: bundle, showsHeader: showsHeader, limit: limit)
        }
    }
}

private struct PlanDayContent: View {
    let plan: Plan
    let day: PlanDay
    let bundle: EventBundle
    let showsHeader: Bool
    let limit: Int?

    @Environment(AppState.self) private var appState

    var body: some View {
        let base = DayRoutes.of(plan, bundle, date: day.date)
        let route = base.map { appState.assistant.dayRoutes.route($0) }
        let units: DistanceUnits = DistanceText.usesImperial() ? .imperial : .metric
        VStack(alignment: .leading, spacing: 10) {
            if showsHeader {
                Text(plan.days.count > 1 ? "My plan · \(day.date.weekdayName)" : "My plan")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
            }
            if let route, route.stops.count >= 2 {
                MiniMap(
                    pins: [],
                    route: route.stops.compactMap { appState.location(id: $0.locationId) },
                    routeLines: route.legs.contains { !$0.route.isEstimate } ? route.legs.map(\.route.points) : [],
                    height: 150
                )
            }
            PlanEntryList(plan: plan, day: day, route: route, units: units, limit: limit)
            if let route, !route.legs.isEmpty {
                let today = PlanDate(.now, in: PlanCalendar.calendar(bundle.event.timeZone))
                Label(DayRoutes.totalText(route, today: today, units, locale: .current), systemImage: "figure.walk")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .blockCardBackground()
        .task(id: base.map(DayRouteProvider.key)) {
            if let base { await appState.assistant.dayRoutes.load(base) }
        }
    }
}

private struct PlanEntryList: View {
    let plan: Plan
    let day: PlanDay
    let route: DayRoute?
    let units: DistanceUnits
    let limit: Int?

    @Environment(AppState.self) private var appState

    var body: some View {
        let now = Date.now
        let entries = shownEntries(now: now)
        VStack(alignment: .leading, spacing: 8) {
            ForEach(entries, id: \.self) { entry in
                switch entry {
                case .item(let planned):
                    if let leg = route?.legs.first(where: { $0.toItem == planned.itemId }) {
                        LegRow(leg: leg, text: DayRoutes.legText(leg, units, locale: .current))
                    }
                    PlanItemLine(planned: planned, checked: plan.checkedOff.contains(planned.itemId), now: now)
                case .meal(let meal):
                    PlanMealLine(meal: meal)
                }
            }
            if entries.count < day.entries.count {
                Text("\(day.entries.count - entries.count) more in your plan")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func shownEntries(now: Date) -> [PlanEntry] {
        guard let limit else { return day.entries }
        let ahead = day.entries.filter { $0.end > now }
        return Array((ahead.isEmpty ? day.entries : ahead).prefix(limit))
    }
}

struct LegRow: View {
    let leg: RouteLeg
    let text: String

    @Environment(AppState.self) private var appState

    var body: some View {
        Button {
            if appState.shows(.map) { appState.showOnMap(locationId: leg.to.locationId) }
        } label: {
            Label(text, systemImage: "figure.walk")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.leading, 28)
        }
        .buttonStyle(.plain)
        .accessibilityHint("Shows this walk on the map.")
    }
}

struct PlanItemLine: View {
    let planned: PlannedItem
    let checked: Bool
    let now: Date
    /// A proposal's mark (My plan's preview): crossed out, or "Moved".
    var mark: PreviewMark? = nil

    @Environment(AppState.self) private var appState

    var body: some View {
        let item = appState.currentBundle?.scheduleItem(planned.itemId)
        let zone = appState.timeZone
        HStack(alignment: .top, spacing: 8) {
            Button {
                appState.assistant.toggleCheckOff(planned.itemId)
            } label: {
                Image(systemName: checked ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(checked ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(checked ? "Checked off" : "Check off")
            .accessibilityValue(item?.name ?? "")
            Button {
                appState.open(.scheduleItem(planned.itemId))
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(EventTimeFormat.time(planned.start, in: zone)) · \(item?.name ?? "No longer on the schedule")")
                        .font(.subheadline.weight(.semibold))
                        .strikethrough(checked || mark != nil, color: mark != nil ? .red : nil)
                        .foregroundStyle(planned.end <= now ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                    Text([appState.location(id: item?.locationId)?.name, planned.reason].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let mark {
                        PreviewMarkLabel(mark: mark)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            if item != nil {
                HeartButton(target: .scheduleItem(planned.itemId), font: .subheadline)
            }
        }
    }
}

struct PlanMealLine: View {
    let meal: MealBreak
    var mark: PreviewMark? = nil

    @Environment(AppState.self) private var appState

    var body: some View {
        let zone = appState.timeZone
        let place = appState.location(id: meal.locationId)?.name
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(EventTimeFormat.time(meal.start, in: zone)) · \(meal.kind.label)" + (place.map { " · \($0) nearby" } ?? ""))
                    .font(.subheadline)
                    .strikethrough(mark == .removed, color: .red)
                if let mark {
                    PreviewMarkLabel(mark: mark)
                }
            }
        } icon: {
            Image(systemName: "fork.knife").foregroundStyle(.tint)
        }
    }
}

/// "Removed" / "Moved" under a row the shown proposal changes.
struct PreviewMarkLabel: View {
    let mark: PreviewMark

    var body: some View {
        Label(mark == .removed ? "Would be removed" : "Moves to another time",
              systemImage: mark == .removed ? "minus.circle" : "arrow.right.circle")
            .font(.caption.weight(.semibold))
            .foregroundStyle(mark == .removed ? Color.red : Color.orange)
    }
}
