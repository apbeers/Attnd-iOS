// PlanView.swift
// Attnd (app target only — not in the App Clip)
//
// The plan timeline, edited in place — the scrolling body of the plan panel (AssistantView.swift,
// medium and large heights), never a conversation:
//   - Header: the request and summary, Share, Undo, Re-plan from Now, New Plan; a day switcher
//     when the plan spans days.
//   - "Your plan changed" (organizer changes) and the live hints (running late, gap fillers,
//     skipped items, the day's recap).
//   - The day: mini map of the walking route, then the entries (check-off, time, name, place,
//     reason, like; walk legs; meal breaks) with the shown proposal previewed in place: rows it
//     removes crossed out / "Moved", dashed suggested rows where they would go (an add's or a
//     replace's options are tapped to apply), the planner's progress while a plan is made.
//   - No plan yet: the example requests (`PlanRequest.examples`) and the liked items.
// Rows are small views of their own (the type checker stays fast).

import SwiftUI

struct PlanTimeline: View {
    @Environment(AppState.self) private var appState
    @State private var selectedDay: PlanDate?

    var body: some View {
        let assistant = appState.assistant
        let plan = appState.planner.plan.flatMap { $0.isEmpty ? nil : $0 }
        let preview = assistant.preview
        VStack(alignment: .leading, spacing: 16) {
            if let plan {
                PlanTimelineHeader(plan: plan)
                PlanChangesCard()
                LiveHintsSection(hints: assistant.live)
                let days = Self.days(plan, preview)
                if days.count > 1 {
                    PlanDaySwitcher(days: days, selection: daySelection(days, plan))
                }
                if let day = resolvedDay(days, plan) {
                    PlanDayTimeline(plan: plan, date: day, preview: preview)
                }
            } else if let preview, let proposal = assistant.proposal {
                // A shared plan offered before there is a plan of one's own.
                PlanDayPreviewOnly(proposal: proposal, preview: preview)
            } else {
                NoPlanSection()
            }
            if appState.planner.isPlanning || assistant.busy == .plan {
                HStack(spacing: 10) {
                    ProgressView()
                    Text(assistant.modelAvailable ? "Planning on your iPhone…" : "Planning from your likes…")
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }
        }
    }

    /// The plan's days with entries plus any day a suggestion falls on.
    static func days(_ plan: Plan, _ preview: PlanPreview?) -> [PlanDate] {
        let own = plan.days.filter { !$0.entries.isEmpty }.map(\.date)
        let suggested = preview.map { Array($0.suggestions.keys) } ?? []
        return Array(Set(own + suggested)).sorted()
    }

    private func resolvedDay(_ days: [PlanDate], _ plan: Plan) -> PlanDate? {
        if let selectedDay, days.contains(selectedDay) { return selectedDay }
        guard let bundle = appState.currentBundle else { return days.first }
        return BlockData.planDay(plan, bundle, now: .now)?.date ?? days.first
    }

    private func daySelection(_ days: [PlanDate], _ plan: Plan) -> Binding<PlanDate> {
        let fallback = resolvedDay(days, plan) ?? days[0]
        return Binding(get: { selectedDay.flatMap { days.contains($0) ? $0 : nil } ?? fallback }, set: { selectedDay = $0 })
    }
}

// MARK: - Header

private struct PlanTimelineHeader: View {
    let plan: Plan

    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !plan.request.isEmpty {
                Text("“\(plan.request)”")
                    .font(.headline)
            }
            Text(Planner.summary(plan, timeZone: appState.timeZone))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { buttons }
                VStack(alignment: .leading, spacing: 8) { buttons }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            if let error = appState.planner.error {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
    }

    @ViewBuilder
    private var buttons: some View {
        let assistant = appState.assistant
        Button("Share", systemImage: "square.and.arrow.up") {
            assistant.run(AssistantAction(name: .sharePlan), label: "Share my plan", source: .manual)
        }
        if appState.planner.canUndo {
            Button("Undo", systemImage: "arrow.uturn.backward") {
                assistant.undoLastChange()
            }
        }
        Menu {
            Button("Re-plan from Now", systemImage: "arrow.clockwise") {
                appState.replanFromNow()
                assistant.refreshLive()
            }
            Button("Add to Calendar", systemImage: "calendar.badge.plus") {
                assistant.run(.calendarPlan(), label: "Add my plan to calendar", source: .manual)
            }
            Button("New Plan", systemImage: "square.and.pencil", role: .destructive) {
                appState.clearPlan()
                assistant.focusInput()
            }
        } label: {
            Label("More", systemImage: "ellipsis")
        }
    }
}

private struct PlanDaySwitcher: View {
    let days: [PlanDate]
    @Binding var selection: PlanDate

    var body: some View {
        Picker("Day", selection: $selection) {
            ForEach(days, id: \.self) { day in
                Text(day.weekdayName).tag(day)
            }
        }
        .pickerStyle(.segmented)
    }
}

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

// MARK: - The day

/// One row of a day in the timeline.
enum PlanTimelineRow: Identifiable, Hashable {
    case leg(RouteLeg)
    case item(PlannedItem, PreviewMark?)
    case meal(MealBreak, PreviewMark?)
    case suggestion(ProposalSuggestion)

    var id: String {
        switch self {
        case .leg(let leg): return "leg-\(leg.toItem)"
        case .item(let item, _): return "item-\(item.itemId)"
        case .meal(let meal, _): return "meal-\(meal.kind.rawValue)"
        case .suggestion(let s): return "suggestion-\(s.option)-\(s.itemId)"
        }
    }

    /// The day's entries with walk legs, marks and the suggested rows after the item they follow
    /// (`after == nil`: before the first item).
    static func rows(_ day: PlanDay?, route: DayRoute?, preview: PlanPreview?) -> [PlanTimelineRow] {
        let suggestions = day.flatMap { preview?.suggestions[$0.date] } ?? []
        var rows: [PlanTimelineRow] = suggestions.filter { $0.after == nil }.map(PlanTimelineRow.suggestion)
        for entry in day?.entries ?? [] {
            switch entry {
            case .item(let planned):
                if let leg = route?.legs.first(where: { $0.toItem == planned.itemId }) { rows.append(.leg(leg)) }
                rows.append(.item(planned, preview?.marks[planned.itemId]))
                rows += suggestions.filter { $0.after == planned.itemId }.map(PlanTimelineRow.suggestion)
            case .meal(let meal):
                let slot = day.map { MealSlot(date: $0.date, kind: meal.kind) }
                rows.append(.meal(meal, slot.flatMap { preview?.mealMarks[$0] }))
            }
        }
        return rows
    }
}

private struct PlanDayTimeline: View {
    let plan: Plan
    let date: PlanDate
    let preview: PlanPreview?

    @Environment(AppState.self) private var appState

    var body: some View {
        let day = plan.days.first { $0.date == date }
        let base = appState.currentBundle.flatMap { DayRoutes.of(plan, $0, date: date) }
        let route = base.map { appState.assistant.dayRoutes.route($0) }
        VStack(alignment: .leading, spacing: 10) {
            if let route, route.stops.count >= 2 {
                MiniMap(
                    pins: [],
                    route: route.stops.compactMap { appState.location(id: $0.locationId) },
                    routeLines: route.legs.contains { !$0.route.isEstimate } ? route.legs.map(\.route.points) : [],
                    height: 150
                )
            }
            PlanRowsList(plan: plan, rows: PlanTimelineRow.rows(day, route: route, preview: preview))
            if let route, !route.legs.isEmpty, let bundle = appState.currentBundle {
                let units: DistanceUnits = DistanceText.usesImperial() ? .imperial : .metric
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

private struct PlanRowsList: View {
    let plan: Plan
    let rows: [PlanTimelineRow]

    @Environment(AppState.self) private var appState

    var body: some View {
        let now = Date.now
        let units: DistanceUnits = DistanceText.usesImperial() ? .imperial : .metric
        VStack(alignment: .leading, spacing: 8) {
            ForEach(rows) { row in
                switch row {
                case .leg(let leg):
                    LegRow(leg: leg, text: DayRoutes.legText(leg, units, locale: .current))
                case .item(let planned, let mark):
                    PlanItemLine(planned: planned, checked: plan.checkedOff.contains(planned.itemId), now: now, mark: mark)
                        .contextMenu { PlanItemMenu(planned: planned) }
                case .meal(let meal, let mark):
                    PlanMealLine(meal: meal, mark: mark)
                case .suggestion(let suggestion):
                    if let proposal = appState.assistant.proposal {
                        SuggestionRow(suggestion: suggestion, proposal: proposal)
                    }
                }
            }
        }
        .animation(.snappy, value: rows)
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
            Text(assistant.modelAvailable
                 ? "Say what you'd like below, or try one of these. Your iPhone plans it from the schedule, your likes and walking times. Nothing leaves your iPhone."
                 : "Try one of these, or type what you'd like. Your plan is made from the schedule, your likes and walking times, on your iPhone.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if !appState.likeSet.isEmpty {
                // Liked items are must-includes: a plan around them works without on-device AI too.
                Button {
                    assistant.makePlan("Plan my day around what I liked")
                } label: {
                    Label("Plan my day around what I liked", systemImage: "heart")
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
                        assistant.submit(example.text, forced: assistant.modelAvailable ? .ask : .search)
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
            CompactList(targets: items + places, title: "Your likes", limit: 6)
                .blockCardBackground()
        } else {
            Text("Like things on the Map, Places or Schedule and they're planned first.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}
