// PlanView.swift
// Attnd (app + App Clip)
//
// The plan page (planner_view_spec §3, iOS, Nov 19, 2026): a trip-style itinerary, the body of
// the full-screen plan page (AssistantView.swift), never a conversation. Rules in PlanPage.swift.
//   - Sticky chips at the top: days ("1 Sat", "2 Sun") for plans over days, else Morning /
//     Afternoon / Evening; a tap scrolls there (ScrollViewReader), the chip of the topmost row
//     is highlighted while scrolling (`scrollPosition(id:)`).
//   - "Your plan changed" (organizer changes, Re-plan / Keep as Is) and the live hints (running
//     late, gap fillers, skipped items, the day's recap).
//   - Per day: the header (date, item count, a
//     one-line on-device summary + "Read more", the route on a mini map), then a timeline rail
//     with an icon per row: item cards (location photo, time, Now / Next / "in 20 min", name,
//     place, tags, the planner's reason, like, check-off once started, Change and Remove), walk
//     legs ("Main Stage → Taco Row · 6 min walk" with a route bar and Change: a closer option /
//     leave earlier), meal breaks (Change: food nearby) and gap rows ("45 min free · 3 ideas
//     nearby", tap for the ideas). The shown proposal is previewed in place: crossed-out /
//     "Moves" rows and dashed suggested rows (tap to apply an add / replace option).
//   - Change opens a sheet of alternatives for that slot (reason, time and walk difference,
//     Compare with the planned item); picking one previews it in place, the pill's Apply
//     commits it with Undo.
//   - `PlanBottomBar` (above the text box): "8 items · 10 AM – 11 PM · 2.1 mi walking", Share,
//     Undo, More (Re-plan from Now, New Plan).
//   - No plan yet: the example requests (`PlanRequest.examples`) and the liked items.
// Rows are small views of their own (the type checker stays fast).

import SwiftUI

struct PlanPageView: View {
    @Environment(AppState.self) private var appState
    /// The topmost row on screen (its chip is highlighted).
    @State private var topRow: String?
    @State private var change: PlanChangeTarget?

    var body: some View {
        let plan = appState.planner.plan.flatMap { $0.isEmpty ? nil : $0 }
        TimelineView(.periodic(from: .now, by: 60)) { context in
            content(plan: plan, now: context.date)
        }
        .sheet(item: $change) { target in
            PlanChangeSheet(target: target)
                .environment(appState)
        }
    }

    @ViewBuilder
    private func content(plan: Plan?, now: Date) -> some View {
        let model = pageModel(plan, now: now)
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    Section {
                        // Days and rows are direct children of the lazy stack, so the scroll
                        // position reports the topmost row (its chip is highlighted).
                        PlanPageTop(plan: plan)
                            .padding(.horizontal, 16)
                            .padding(.bottom, 16)
                        if let plan {
                            ForEach(model.days) { day in
                                PlanDayHeaderRow(plan: plan, day: day)
                                    .id(day.id)
                                    .padding(.horizontal, 16)
                                    .padding(.bottom, 8)
                                ForEach(day.rows) { row in
                                    PlanRailRow(row: row, plan: plan, now: now, isLast: row.id == day.rows.last?.id, onChange: { change = $0 })
                                        .id(row.id)
                                        .padding(.horizontal, 16)
                                }
                            }
                        }
                    } header: {
                        if model.chips.count > 1 {
                            PlanChipsBar(chips: model.chips, current: model.chip(for: topRow)) { chip in
                                withAnimation(.snappy) { proxy.scrollTo(chip.anchor, anchor: .top) }
                            }
                        }
                    }
                }
                .scrollTargetLayout()
            }
            .scrollPosition(id: $topRow, anchor: .top)
            .scrollDismissesKeyboard(.interactively)
        }
    }

    private func pageModel(_ plan: Plan?, now: Date) -> PlanPageModel {
        guard let bundle = appState.currentBundle else { return PlanPageModel(chips: [], days: []) }
        var routes: [PlanDate: DayRoute] = [:]
        if let plan {
            for day in plan.days where !day.items.isEmpty {
                if let base = DayRoutes.of(plan, bundle, date: day.date) { routes[day.date] = appState.assistant.dayRoutes.route(base) }
            }
        }
        return PlanPage.model(
            plan: plan, bundle, likes: appState.likeSet, now: now, preview: appState.assistant.preview, routes: routes,
            units: DistanceText.usesImperial() ? .imperial : .metric, locale: .current
        )
    }
}

/// What a Change sheet is for.
enum PlanChangeTarget: Identifiable, Hashable {
    case item(Int)
    case leg(RouteLeg)
    case meal(MealBreak)

    var id: String {
        switch self {
        case .item(let id): return "item-\(id)"
        case .leg(let leg): return "leg-\(leg.toItem)"
        case .meal(let meal): return "meal-\(meal.kind.rawValue)-\(Int(meal.start.timeIntervalSince1970))"
        }
    }
}

// MARK: - Chips

private struct PlanChipsBar: View {
    let chips: [PlanPageChip]
    let current: String?
    let onTap: (PlanPageChip) -> Void

    var body: some View {
        ScrollView(.horizontal) {
            GlassEffectContainer {
                HStack(spacing: 8) {
                    ForEach(chips) { chip in
                        chipButton(chip)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
        }
        .scrollIndicators(.hidden)
    }

    @ViewBuilder
    private func chipButton(_ chip: PlanPageChip) -> some View {
        if chip.id == current {
            Button(chip.label) { onTap(chip) }
                .buttonStyle(.glassProminent)
                .accessibilityAddTraits(.isSelected)
        } else {
            Button(chip.label) { onTap(chip) }
                .buttonStyle(.glass)
        }
    }
}

// MARK: - Body

private struct PlanPageTop: View {
    let plan: Plan?

    @Environment(AppState.self) private var appState

    var body: some View {
        let assistant = appState.assistant
        VStack(alignment: .leading, spacing: 16) {
            if let plan {
                PlanRequestLine(plan: plan)
                PlanChangesCard()
                LiveHintsSection(hints: assistant.live)
            } else if let preview = assistant.preview, let proposal = assistant.proposal {
                // A shared plan offered before there is a plan of one's own.
                PlanDayPreviewOnly(proposal: proposal, preview: preview)
            } else {
                NoPlanSection()
            }
            if appState.planner.isPlanning || assistant.busy == .plan {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Planning on your iPhone…")
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }
        }
        .padding(.top, 8)
    }
}

/// The request the plan was made for, and the planner's last error.
private struct PlanRequestLine: View {
    let plan: Plan

    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !plan.request.isEmpty {
                Text("“\(plan.request)”")
                    .font(.headline)
            }
            if let error = appState.planner.error {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
    }
}

// MARK: - A day

/// A day's header, loading the day's walking legs on real paths while shown.
private struct PlanDayHeaderRow: View {
    let plan: Plan
    let day: PlanPageDay

    @Environment(AppState.self) private var appState

    var body: some View {
        let base = appState.currentBundle.flatMap { DayRoutes.of(plan, $0, date: day.date) }
        PlanDayHeader(plan: plan, day: day, route: base.map { appState.assistant.dayRoutes.route($0) })
            .task(id: base.map(DayRouteProvider.key)) {
                if let base { await appState.assistant.dayRoutes.load(base) }
            }
    }
}

private struct PlanDayHeader: View {
    let plan: Plan
    let day: PlanPageDay
    let route: DayRoute?

    @Environment(AppState.self) private var appState
    @State private var expanded = false
    @State private var showsMap = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "calendar")
                    .foregroundStyle(.tint)
                Text(PlanPage.dayTitle(day.date, locale: .current))
                    .font(.title3.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 4)
                Text(day.countText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            DaySummaryText(plan: plan, date: day.date, expanded: $expanded)
            if let route, route.stops.count >= 2 {
                Button(showsMap ? "Hide Route" : "Show Route", systemImage: "map") {
                    withAnimation(.snappy) { showsMap.toggle() }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                if showsMap {
                    MiniMap(
                        pins: [],
                        route: route.stops.compactMap { appState.location(id: $0.locationId) },
                        routeLines: route.legs.contains { !$0.route.isEstimate } ? route.legs.map(\.route.points) : [],
                        height: 160
                    )
                    .transition(.opacity)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 18))
    }
}

/// The day's one-line summary (on-device AI, cached; else the plain summary) + "Read more".
private struct DaySummaryText: View {
    let plan: Plan
    let date: PlanDate
    @Binding var expanded: Bool

    @Environment(AppState.self) private var appState

    var body: some View {
        if let bundle = appState.currentBundle {
            let summary = appState.daySummaries.summary(plan, date, bundle)
            VStack(alignment: .leading, spacing: 4) {
                Text(summary.line)
                    .font(.subheadline)
                if !summary.more.isEmpty {
                    if expanded {
                        Text(summary.more)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Button(expanded ? "Show less" : "Read more") {
                        withAnimation(.snappy) { expanded.toggle() }
                    }
                    .font(.footnote.weight(.semibold))
                    .buttonStyle(.borderless)
                }
            }
        }
    }
}

// MARK: - Rail rows

private struct PlanRailRow: View {
    let row: PlanPageRow
    let plan: Plan
    let now: Date
    let isLast: Bool
    let onChange: (PlanChangeTarget) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            RailMarker(kind: row.kind, plan: plan, now: now, isLast: isLast)
            rowContent
                .padding(.bottom, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var rowContent: some View {
        switch row.kind {
        case .item(let planned, let mark):
            PlanItemCard(planned: planned, mark: mark, checked: plan.checkedOff.contains(planned.itemId), now: now, onChange: onChange)
                .contextMenu { PlanItemMenu(planned: planned) }
        case .leg(let leg):
            PlanLegRowView(leg: leg, onChange: onChange)
        case .meal(let meal, let mark):
            PlanMealRowView(meal: meal, mark: mark, onChange: onChange)
        case .gap(let gap):
            PlanGapRowView(gap: gap)
        case .suggestion(let suggestion):
            PageSuggestionRow(suggestion: suggestion)
        }
    }
}

/// The rail: an icon per row (a check toggle on started items) and the line to the next row.
private struct RailMarker: View {
    let kind: PlanPageRowKind
    let plan: Plan
    let now: Date
    let isLast: Bool

    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(spacing: 2) {
            icon
                .frame(width: 28, height: 28)
            if !isLast {
                Rectangle()
                    .fill(.quaternary)
                    .frame(width: 2)
                    .frame(maxHeight: .infinity)
            }
        }
        .frame(width: 28)
    }

    @ViewBuilder
    private var icon: some View {
        switch kind {
        case .item(let planned, _):
            if planned.start <= now {
                let checked = plan.checkedOff.contains(planned.itemId)
                Button {
                    appState.assistant.toggleCheckOff(planned.itemId)
                } label: {
                    Image(systemName: checked ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(checked ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(checked ? "Checked off" : "Check off")
            } else {
                symbol("star.circle.fill", tint: true)
            }
        case .leg: symbol("figure.walk.circle", tint: false)
        case .meal: symbol("fork.knife.circle.fill", tint: true)
        case .gap: symbol("clock.circle", tint: false)
        case .suggestion: symbol("plus.circle", tint: true)
        }
    }

    private func symbol(_ name: String, tint: Bool) -> some View {
        Image(systemName: name)
            .font(.title3)
            .foregroundStyle(tint ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            .accessibilityHidden(true)
    }
}

// MARK: Item card

private struct PlanItemCard: View {
    let planned: PlannedItem
    let mark: PreviewMark?
    let checked: Bool
    let now: Date
    let onChange: (PlanChangeTarget) -> Void

    @Environment(AppState.self) private var appState

    var body: some View {
        let item = appState.currentBundle?.scheduleItem(planned.itemId)
        let location = appState.location(id: item?.locationId)
        VStack(alignment: .leading, spacing: 10) {
            Button {
                appState.open(.scheduleItem(planned.itemId))
            } label: {
                HStack(alignment: .top, spacing: 10) {
                    PlanItemPhoto(url: location?.imageUrl)
                    PlanItemText(planned: planned, item: item, place: location?.name ?? item?.locationName, checked: checked, mark: mark, now: now)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens the item.")
            if item != nil {
                HStack(spacing: 8) {
                    Group {
                        Button("Change", systemImage: "arrow.left.arrow.right") { onChange(.item(planned.itemId)) }
                        Button("Remove", systemImage: "minus.circle") {
                            appState.assistant.proposeEdit([.remove(item: planned.itemId)], label: "Remove \(item?.name ?? "it")")
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    Spacer(minLength: 0)
                    HeartButton(target: .scheduleItem(planned.itemId), font: .subheadline)
                }
            }
        }
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 16))
        .overlay {
            if mark != nil {
                RoundedRectangle(cornerRadius: 16).strokeBorder(mark == .removed ? Color.red.opacity(0.6) : Color.orange.opacity(0.6), lineWidth: 1.5)
            }
        }
    }
}

private struct PlanItemPhoto: View {
    let url: URL?

    var body: some View {
        Group {
            if let url {
                CachedImage(url: url) { image in
                    image.resizable().scaledToFill()
                } placeholder: { _ in
                    Color.secondary.opacity(0.12)
                }
            } else {
                ZStack {
                    Color.accentColor.opacity(0.12)
                    Image(systemName: "music.note").foregroundStyle(.tint)
                }
            }
        }
        .frame(width: 64, height: 64)
        .clipShape(.rect(cornerRadius: 12))
        .accessibilityHidden(true)
    }
}

private struct PlanItemText: View {
    let planned: PlannedItem
    let item: ScheduleItem?
    let place: String?
    let checked: Bool
    let mark: PreviewMark?
    let now: Date

    @Environment(AppState.self) private var appState

    var body: some View {
        let zone = appState.timeZone
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(EventTimeFormat.time(planned.start, in: zone))
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                if let item, let relative = RelativeTimeText.item(item, now: now, timeZone: zone) {
                    Text(relative)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(planned.end <= now ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
                }
            }
            Text(item?.name ?? "No longer on the schedule")
                .font(.headline)
                .strikethrough(checked || mark == .removed, color: mark == .removed ? .red : nil)
                .foregroundStyle(planned.end <= now ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
            if let place {
                Label(place, systemImage: "mappin.and.ellipse")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let tags = item?.tags, !tags.isEmpty {
                Text(TagText.line(Array(tags.prefix(3))))
                    .font(.caption)
                    .foregroundStyle(.tint)
            }
            if !planned.reason.isEmpty {
                Text(planned.reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let mark {
                PreviewMarkLabel(mark: mark)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: Walk leg, meal, gap

private struct PlanLegRowView: View {
    let leg: PlanPageLeg
    let onChange: (PlanChangeTarget) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(leg.title)
                        .font(.subheadline.weight(.semibold))
                    Text(leg.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Button("Change") { onChange(.leg(leg.leg)) }
                    .buttonStyle(.borderless)
                    .font(.caption.weight(.semibold))
                    .accessibilityLabel("Change this walk")
            }
            RouteBar(minutes: AssistantText.minutes(leg.leg.route.durationSeconds), estimate: leg.leg.route.isEstimate)
        }
        .accessibilityElement(children: .combine)
    }
}

/// A thin bar as long as the walk (≤ 20 min fills it); dashed for the straight-line estimate.
private struct RouteBar: View {
    let minutes: Int
    let estimate: Bool

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width * min(1, max(0.1, Double(minutes) / 20))
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                if estimate {
                    Capsule()
                        .stroke(style: StrokeStyle(lineWidth: 2, dash: [4, 3]))
                        .foregroundStyle(.tint)
                        .frame(width: width)
                } else {
                    Capsule().fill(.tint).frame(width: width)
                }
            }
        }
        .frame(height: 4)
        .accessibilityHidden(true)
    }
}

private struct PlanMealRowView: View {
    let meal: MealBreak
    let mark: PreviewMark?
    let onChange: (PlanChangeTarget) -> Void

    @Environment(AppState.self) private var appState

    var body: some View {
        let zone = appState.timeZone
        let place = appState.location(id: meal.locationId)?.name
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(([meal.kind.label.components(separatedBy: " ").first ?? meal.kind.label, EventTimeFormat.time(meal.start, in: zone)] + (place.map { [$0] } ?? []))
                    .joined(separator: " · "))
                    .font(.subheadline.weight(.semibold))
                    .strikethrough(mark == .removed, color: .red)
                if let mark { PreviewMarkLabel(mark: mark) }
            }
            Spacer(minLength: 8)
            Button("Change") { onChange(.meal(meal)) }
                .buttonStyle(.borderless)
                .font(.caption.weight(.semibold))
                .accessibilityLabel("Change this break")
        }
    }
}

private struct PlanGapRowView: View {
    let gap: PlanPageGap

    @Environment(AppState.self) private var appState
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.snappy) { expanded.toggle() }
            } label: {
                HStack {
                    Text(gap.text)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    if !gap.ideas.isEmpty {
                        Image(systemName: expanded ? "chevron.up" : "chevron.down")
                            .font(.caption)
                            .foregroundStyle(.tint)
                    }
                }
            }
            .buttonStyle(.plain)
            .disabled(gap.ideas.isEmpty)
            if expanded {
                ForEach(gap.ideas, id: \.self) { id in
                    GapIdeaRow(itemId: id)
                }
            }
        }
    }
}

private struct GapIdeaRow: View {
    let itemId: Int

    @Environment(AppState.self) private var appState

    var body: some View {
        let item = appState.currentBundle?.scheduleItem(itemId)
        HStack(spacing: 8) {
            Button {
                appState.open(.scheduleItem(itemId))
            } label: {
                VStack(alignment: .leading, spacing: 1) {
                    Text(item?.name ?? "An item").font(.subheadline.weight(.semibold))
                    Text(ideaDetail(item)).font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            Button("Add", systemImage: "plus.circle") {
                appState.assistant.addToPlan(itemId)
            }
            .labelStyle(.iconOnly)
            .font(.title3)
            .buttonStyle(.plain)
            .foregroundStyle(.tint)
            .accessibilityLabel("Add \(item?.name ?? "it") to your plan")
        }
        .padding(10)
        .background {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                .foregroundStyle(.tint)
        }
    }

    private func ideaDetail(_ item: ScheduleItem?) -> String {
        guard let item else { return "" }
        let time = item.startTime.map { EventTimeFormat.time($0, in: appState.timeZone) }
        return [time, appState.location(id: item.locationId)?.name].compactMap { $0 }.joined(separator: " · ")
    }
}

/// A proposal's dashed suggested row on the page.
private struct PageSuggestionRow: View {
    let suggestion: ProposalSuggestion

    @Environment(AppState.self) private var appState

    var body: some View {
        if let proposal = appState.assistant.proposal {
            SuggestionRow(suggestion: suggestion, proposal: proposal)
        }
    }
}

// MARK: - Bottom bar

/// "8 items · 10 AM – 11 PM · 2.1 mi walking" with Share, Undo and More.
struct PlanBottomBar: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        if let bundle = appState.currentBundle, let plan = appState.planner.plan, !plan.isEmpty {
            HStack(spacing: 6) {
                Text(statsText(plan, bundle))
                    .font(.footnote.weight(.semibold))
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                PlanShareButton()
                if appState.planner.canUndo {
                    Button("Undo", systemImage: "arrow.uturn.backward") { appState.assistant.undoLastChange() }
                }
                PlanMoreMenu()
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .padding(.leading, 14)
            .padding(.trailing, 8)
            .padding(.vertical, 8)
            .glassEffect(.regular, in: .capsule)
        }
    }

    private func statsText(_ plan: Plan, _ bundle: EventBundle) -> String {
        var routes: [PlanDate: DayRoute] = [:]
        for day in plan.days where !day.items.isEmpty {
            if let base = DayRoutes.of(plan, bundle, date: day.date) { routes[day.date] = appState.assistant.dayRoutes.route(base) }
        }
        return PlanPage.stats(plan, bundle, routes: routes)
            .text(zone: bundle.event.timeZone, units: DistanceText.usesImperial() ? .imperial : .metric, locale: .current)
    }
}

private struct PlanShareButton: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        if let link = appState.assistant.shareLink("plan") {
            ShareLink(item: link.url, subject: Text(link.title)) {
                Label("Share", systemImage: "square.and.arrow.up")
            }
            .simultaneousGesture(TapGesture().onEnded {
                appState.assistant.logShare("plan", url: link.url, items: link.items)
            })
        }
    }
}

private struct PlanMoreMenu: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        let assistant = appState.assistant
        Menu {
            Button("Re-plan from Now", systemImage: "arrow.clockwise") {
                appState.replanFromNow()
                assistant.refreshLive()
            }
            Button("New Plan", systemImage: "square.and.pencil", role: .destructive) {
                appState.clearPlan()
                assistant.focusInput()
            }
        } label: {
            Label("More", systemImage: "ellipsis.circle")
        }
    }
}

// MARK: - Change sheet

struct PlanChangeSheet: View {
    let target: PlanChangeTarget

    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                content
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "xmark", role: .close) { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var title: String {
        switch target {
        case .item(let id): return "Instead of \(appState.currentBundle?.scheduleItem(id)?.name ?? "this")"
        case .leg: return "Change This Walk"
        case .meal(let meal): return "Change \(meal.kind.label)"
        }
    }

    @ViewBuilder
    private var content: some View {
        if let bundle = appState.currentBundle, let plan = appState.planner.plan {
            switch target {
            case .item(let id):
                ItemChangeOptions(itemId: id, options: PlanPage.changeOptions(id, plan, bundle, appState.likeSet, now: .now), onPick: pick)
            case .leg(let leg):
                LegChangeOptions(leg: leg, options: PlanPage.legOptions(leg, plan, bundle, appState.likeSet, now: .now), onPick: pick)
            case .meal(let meal):
                MealChangeOptions(meal: meal, options: PlanPage.mealOptions(meal, plan, bundle, appState.likeSet, now: .now), onDone: { dismiss() })
            }
        }
    }

    /// Previews `old` → `new` in place (the pill's Apply commits it).
    private func pick(_ old: Int, _ new: Int) {
        let bundle = appState.currentBundle
        let label = "Swap \(bundle?.scheduleItem(old)?.name ?? "it") for \(bundle?.scheduleItem(new)?.name ?? "it")"
        appState.assistant.proposeEdit([.replace(item: old, with: new)], label: label)
        dismiss()
    }
}

private struct ItemChangeOptions: View {
    let itemId: Int
    let options: [PlanChangeOption]
    let onPick: (Int, Int) -> Void

    var body: some View {
        if options.isEmpty {
            Text("Nothing else fits this slot.")
                .foregroundStyle(.secondary)
        } else {
            Section {
                ForEach(options) { option in
                    ChangeOptionRow(currentId: itemId, option: option) { onPick(itemId, option.itemId) }
                }
            } footer: {
                Text("Picking one previews it in your plan; Apply there keeps it (with Undo).")
            }
        }
    }
}

private struct LegChangeOptions: View {
    let leg: RouteLeg
    let options: PlanLegOptions
    let onPick: (Int, Int) -> Void

    @Environment(AppState.self) private var appState

    var body: some View {
        if let leaveBy = options.leaveBy {
            Section {
                Label("Leave by \(EventTimeFormat.time(leaveBy, in: appState.timeZone)) to be there 5 min early",
                      systemImage: "figure.walk.departure")
            }
        }
        Section("A closer option") {
            if options.closer.isEmpty {
                Text("Nothing closer fits.").foregroundStyle(.secondary)
            }
            ForEach(options.closer) { option in
                ChangeOptionRow(currentId: leg.toItem, option: option) { onPick(leg.toItem, option.itemId) }
            }
        }
        Section("Leave earlier") {
            if options.leaveEarlier.isEmpty {
                Text("Nothing that ends earlier fits before this walk.").foregroundStyle(.secondary)
            }
            ForEach(options.leaveEarlier) { option in
                ChangeOptionRow(currentId: leg.fromItem, option: option) { onPick(leg.fromItem, option.itemId) }
            }
        }
    }
}

private struct MealChangeOptions: View {
    let meal: MealBreak
    let options: PlanMealOptions
    let onDone: () -> Void

    @Environment(AppState.self) private var appState

    var body: some View {
        if !options.foodItems.isEmpty {
            Section("Food on the schedule") {
                ForEach(options.foodItems, id: \.self) { id in
                    Button {
                        appState.assistant.addToPlan(id)
                        onDone()
                    } label: {
                        Label(appState.currentBundle?.scheduleItem(id)?.name ?? "An item", systemImage: "plus.circle")
                    }
                }
            }
        }
        Section("Food nearby") {
            ForEach(options.places, id: \.locationId) { place in
                Button {
                    onDone()
                    appState.open(.location(place.locationId))
                } label: {
                    HStack {
                        Text(appState.location(id: place.locationId)?.name ?? "A place")
                        Spacer()
                        if let walk = place.walkMinutes {
                            Text("\(walk) min walk").foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        Section {
            Button("I Already Ate", systemImage: "checkmark.circle") {
                appState.assistant.proposeEdit([.noFoodUntil(PlanCalendar.truncatedToMinute(.now).addingTimeInterval(3 * 3600))],
                                                label: "No food for 3 hours")
                onDone()
            }
        }
    }
}

/// One alternative: name, time and place, reason, time / walk difference; Compare and Pick.
private struct ChangeOptionRow: View {
    let currentId: Int
    let option: PlanChangeOption
    let onPick: () -> Void

    @Environment(AppState.self) private var appState
    @State private var comparing = false

    var body: some View {
        let item = appState.currentBundle?.scheduleItem(option.itemId)
        VStack(alignment: .leading, spacing: 6) {
            Text(item?.name ?? "An item")
                .font(.headline)
            if let item {
                Text(EventTimeFormat.range(start: item.startTime, end: item.endTime, in: appState.timeZone)
                     + (appState.location(id: item.locationId).map { " · \($0.name)" } ?? ""))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Text(([option.reason, option.timeText] + (option.walkText.map { [$0] } ?? [])).joined(separator: " · "))
                .font(.caption)
                .foregroundStyle(.tint)
            HStack(spacing: 8) {
                Button("Pick", action: onPick)
                    .buttonStyle(.borderedProminent)
                Button(comparing ? "Hide Compare" : "Compare") {
                    withAnimation(.snappy) { comparing.toggle() }
                }
                .buttonStyle(.bordered)
            }
            .controlSize(.small)
            if comparing, let item, let current = appState.currentBundle?.scheduleItem(currentId) {
                CompareView(a: .item(current, appState: appState), b: .item(item, appState: appState), title: "Planned vs. this")
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Shared pieces (hints, menus, suggestions, no plan)

/// Organizer changes (spec §6): which planned items moved or went, with Re-plan / Keep as Is.
private struct PlanChangesCard: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        let changed = appState.assistant.live.changed
        if !changed.isEmpty {
            let names = changed.map { appState.currentBundle?.scheduleItem($0)?.name ?? "A removed item" }
            VStack(alignment: .leading, spacing: 8) {
                Label("Your plan changed", systemImage: "exclamationmark.arrow.triangle.2.circlepath")
                    .font(.subheadline.weight(.semibold))
                Text("The organizers moved or removed: " + names.joined(separator: ", ") + ".")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Button("Re-plan") {
                        appState.replanFromNow()
                        appState.assistant.refreshLive()
                    }
                    .buttonStyle(.borderedProminent)
                    Button("Keep as Is") {
                        appState.keepChangedPlan()
                        appState.assistant.refreshLive()
                    }
                    .buttonStyle(.bordered)
                }
                .controlSize(.small)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.12), in: .rect(cornerRadius: 16))
        }
    }
}

// MARK: - Live hints

private struct LiveHintsSection: View {
    let hints: LiveHints

    @Environment(AppState.self) private var appState

    var body: some View {
        if !hints.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                if let late = hints.runningLate {
                    HintCard(
                        text: late.text,
                        systemImage: late.state == .leaveNow ? "figure.walk.motion" : "exclamationmark.triangle.fill",
                        tint: .orange,
                        chips: late.chips
                    )
                }
                ForEach(hints.gaps, id: \.self) { gap in
                    HintCard(text: gap.text, systemImage: "clock.badge.questionmark", tint: .blue, chips: [gap.chip])
                }
                ForEach(hints.skipped, id: \.self) { chip in
                    SkippedHint(chip: chip)
                }
                if hints.recapReady {
                    HintCard(text: "That's your day. Want the recap?", systemImage: "sparkles", tint: .purple,
                             chips: [AssistantChip(label: "Show my recap", action: AssistantAction(name: .plan))],
                             onChip: { _ in appState.assistant.submit("recap", forced: .plan) })
                }
            }
        }
    }
}

private struct HintCard: View {
    let text: String
    let systemImage: String
    let tint: Color
    let chips: [AssistantChip]
    var onChip: ((AssistantChip) -> Void)? = nil

    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(text, systemImage: systemImage)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(tint)
            if !chips.isEmpty {
                ChipRow(chips: chips.enumerated().map { ChipItem(id: String($0.offset), label: $0.element.label) }) { item in
                    guard let i = Int(item.id), i < chips.count else { return }
                    if let onChip { onChip(chips[i]) } else { appState.assistant.hintChip(chips[i]) }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.12), in: .rect(cornerRadius: 16))
    }
}

private struct SkippedHint: View {
    let chip: AssistantChip

    @Environment(AppState.self) private var appState

    var body: some View {
        HStack(spacing: 8) {
            Button(chip.label) { appState.assistant.hintChip(chip) }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .controlSize(.small)
            Button {
                appState.assistant.dismissSkipped(chip)
            } label: {
                Label("Dismiss", systemImage: "xmark").labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
        }
    }
}

/// A shared plan's suggestions before there is a plan of one's own.
private struct PlanDayPreviewOnly: View {
    let proposal: PlanProposal
    let preview: PlanPreview

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(proposal.text, systemImage: "person.2")
                .font(.headline)
            ForEach(preview.suggestions.keys.sorted(), id: \.self) { date in
                ForEach(preview.suggestions[date] ?? [], id: \.self) { suggestion in
                    SuggestionRow(suggestion: suggestion, proposal: proposal)
                }
            }
        }
        .blockCardBackground()
    }
}

/// A plan row's long-press menu: Swap (options under it), Remove, Keep, a later showing.
private struct PlanItemMenu: View {
    let planned: PlannedItem

    @Environment(AppState.self) private var appState

    var body: some View {
        let assistant = appState.assistant
        let name = appState.currentBundle?.scheduleItem(planned.itemId)?.name ?? "it"
        Button("Swap", systemImage: "arrow.left.arrow.right") {
            assistant.proposeSwap(planned.itemId)
        }
        Button("Later Showing", systemImage: "clock.arrow.circlepath") {
            assistant.proposeEdit([.move(item: planned.itemId, later: true)], label: "Move \(name) later")
        }
        Button("Always Keep", systemImage: "pin") {
            assistant.proposeEdit([.keep(item: planned.itemId)], label: "Keep \(name)")
        }
        Button("Remove from Plan", systemImage: "minus.circle", role: .destructive) {
            assistant.proposeEdit([.remove(item: planned.itemId)], label: "Remove \(name)")
        }
    }
}

/// A dashed "suggested" row: tap applies its option (add / replace); a change's rows show what
/// the pill's Apply would add.
private struct SuggestionRow: View {
    let suggestion: ProposalSuggestion
    let proposal: PlanProposal

    @Environment(AppState.self) private var appState

    var body: some View {
        let zone = appState.timeZone
        let option = suggestion.option < proposal.options.count ? proposal.options[suggestion.option] : nil
        let planned = option?.edit.after.items.first { $0.itemId == suggestion.itemId }
        let item = appState.currentBundle?.scheduleItem(suggestion.itemId)
        let title = "\(EventTimeFormat.time(suggestion.start, in: zone)) · \(item?.name ?? "An item")"
        let detail = [appState.location(id: item?.locationId)?.name, planned?.reason].compactMap { $0 }.joined(separator: " · ")
        Button {
            guard proposal.hasOptionRows else { return }
            appState.assistant.applyProposal(suggestion.option)
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: proposal.hasOptionRows ? "plus.circle" : "sparkle")
                    .font(.title3)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                    if !detail.isEmpty {
                        Text(detail).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if proposal.options.count > 1, proposal.hasOptionRows {
                    Text("Option \(suggestion.option + 1)")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(10)
            .background {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                    .foregroundStyle(.tint)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(!proposal.hasOptionRows)
        .accessibilityLabel("Suggested: \(title)" + (detail.isEmpty ? "" : ", \(detail)"))
        .accessibilityHint(proposal.hasOptionRows ? "Adds it to your plan." : "Part of the change shown below.")
    }
}

// MARK: - No plan yet

private struct NoPlanSection: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        let assistant = appState.assistant
        let examples = appState.currentBundle.map { PlanRequest.examples($0, now: .now) } ?? []
        VStack(alignment: .leading, spacing: 12) {
            Label("Plan your day", systemImage: "sparkles")
                .font(.title3.weight(.semibold))
            Text("Say what you'd like below, or try one of these. Your iPhone plans it from the event's schedule, what's in your schedule and walking times. Nothing leaves your iPhone.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if !appState.likeSet.isEmpty {
                // Liked items are must-includes.
                Button {
                    assistant.makePlan("Plan my day around my schedule")
                } label: {
                    Label("Plan my day around my schedule", systemImage: "calendar")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.borderedProminent)
                .disabled(appState.planner.isPlanning)
            }
            ForEach(examples) { example in
                Button {
                    if example.isPlan {
                        assistant.makePlan(example.text)
                    } else {
                        assistant.submit(example.text, forced: .ask)
                    }
                } label: {
                    Label(example.text, systemImage: example.isPlan ? "sparkles" : "questionmark.bubble")
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.bordered)
                .disabled(appState.planner.isPlanning)
            }
            if let error = appState.planner.error {
                Text(error).font(.footnote).foregroundStyle(.red)
            }
            LikedItemsList()
        }
    }
}

private struct LikedItemsList: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        let likes = appState.likeSet
        let items = appState.schedule.filter { likes.scheduleItems.contains($0.id) }
            .sorted { ($0.startTime ?? .distantFuture, $0.id) < ($1.startTime ?? .distantFuture, $1.id) }
            .map { SearchTarget.scheduleItem($0.id) }
        let places = appState.locations.filter { likes.locations.contains($0.id) }.map { SearchTarget.location($0.id) }
        if !items.isEmpty || !places.isEmpty {
            CompactList(targets: items + places, title: "In Your Schedule", limit: 6)
                .blockCardBackground()
        } else {
            Text("Add things to your schedule on the Map, Places or Schedule and they're planned first.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}
