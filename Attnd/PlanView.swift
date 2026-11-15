// PlanView.swift
// Attnd (app target only — not in the App Clip)
//
// Schedule → My plan (shared spec §6; Android's `MyPlanPane`): rows inside the Schedule list,
// shown while its "My plan" chip is on (`PlanStore.showsMyPlan`).
//
//   - No plan: the request card ("Plan your day": a field, "Make my plan", example chips from
//     the event, `PlanRequest.examples`), only while the on-device model is available.
//   - A plan: "Your plan changed" (Re-plan / Keep as is) when a content update moved or removed
//     a planned item; the request and summary with "Re-plan from now" and "New plan"; per day
//     the items with walk legs ("4 min walk"), meal breaks, a heart and a Swap menu (the item's
//     alternatives, hearted "or instead" items first). Items open their detail like any row.

import SwiftUI

struct MyPlanContent: View {
    let now: Date

    @Environment(AppState.self) private var appState

    var body: some View {
        let planner = appState.planner
        if let plan = planner.plan, !plan.isEmpty {
            if appState.planChanged {
                Section {
                    PlanChangedCard()
                }
            }
            Section {
                PlanHeader(plan: plan)
            }
            ForEach(plan.days.filter { !$0.entries.isEmpty }, id: \.date) { day in
                Section {
                    ForEach(PlanRow.rows(for: day)) { row in
                        rowView(row)
                    }
                } header: {
                    if plan.days.count > 1 {
                        Text(EventTimeFormat.dayTitle(day.date.at(PlanClock(hour: 12, minute: 0), in: PlanCalendar.calendar(appState.timeZone)), in: appState.timeZone))
                    }
                }
            }
            Section {
            } footer: {
                Text("Planned on your iPhone. Hearted items are always included when they fit.")
            }
        } else {
            Section {
                PlanRequestCard()
            }
        }
    }

    @ViewBuilder
    private func rowView(_ row: PlanRow) -> some View {
        switch row {
        case .walk(_, let minutes):
            Label("\(minutes) min walk", systemImage: "figure.walk")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.leading, 16)
                .listRowSeparator(.hidden)
        case .item(let entry):
            if let item = appState.schedule.first(where: { $0.id == entry.itemId }) {
                NavigationLink(value: item) {
                    PlanItemRow(entry: entry, item: item, now: now)
                }
            } else {
                PlanItemRow(entry: entry, item: nil, now: now)
            }
        case .meal(let meal):
            PlanMealRow(meal: meal)
        }
    }
}

/// One row of a plan day: a walk leg, an item or a meal break.
enum PlanRow: Identifiable, Hashable {
    case walk(beforeItemId: Int, minutes: Int)
    case item(PlannedItem)
    case meal(MealBreak)

    var id: String {
        switch self {
        case .walk(let id, _):  return "walk-\(id)"
        case .item(let item):   return "item-\(item.itemId)"
        case .meal(let meal):   return "meal-\(meal.kind.rawValue)"
        }
    }

    /// Walk legs only between two items (not after a meal break) and only when there is a walk.
    static func rows(for day: PlanDay) -> [PlanRow] {
        var rows: [PlanRow] = []
        var previousWasItem = false
        for entry in day.entries {
            switch entry {
            case .item(let item):
                if previousWasItem, let walk = item.walkMinutes, walk > 0 {
                    rows.append(.walk(beforeItemId: item.itemId, minutes: walk))
                }
                rows.append(.item(item))
                previousWasItem = true
            case .meal(let meal):
                rows.append(.meal(meal))
                previousWasItem = false
            }
        }
        return rows
    }
}

// MARK: - Request card

private struct PlanRequestCard: View {
    @Environment(AppState.self) private var appState
    @State private var request = ""

    var body: some View {
        let planner = appState.planner
        VStack(alignment: .leading, spacing: 12) {
            Label("Plan your day", systemImage: "wand.and.stars")
                .font(.headline)
            if !AppState.plannerAvailable {
                Text("Planning uses Apple Intelligence on your iPhone, which isn't available right now.")
                    .foregroundStyle(.secondary)
            } else {
                Text("Say what you'd like and your iPhone builds a plan from the schedule, with your hearts and walking times. Nothing leaves your iPhone.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                TextField("Plan my afternoon around live music", text: $request)
                    .textFieldStyle(.roundedBorder)
                    .submitLabel(.done)
                    .onSubmit(make)
                if planner.isPlanning {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text("Planning on your iPhone…")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Button("Make My Plan", systemImage: "sparkles", action: make)
                        .buttonStyle(.borderedProminent)
                        .disabled(request.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                if let error = planner.error {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
                let examples = appState.currentBundle.map { PlanRequest.examples($0, now: .now).filter(\.isPlan) } ?? []
                ForEach(examples) { example in
                    Button {
                        request = example.text
                        appState.useExample(example)
                    } label: {
                        Label(example.text, systemImage: "sparkles")
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.bordered)
                    .disabled(planner.isPlanning)
                }
            }
        }
        .padding(.vertical, 6)
    }

    private func make() {
        let text = request
        Task { await appState.makePlan(text) }
    }
}

// MARK: - Header and "plan changed"

private struct PlanHeader: View {
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
            HStack(spacing: 8) {
                Button("Re-plan from Now", systemImage: "arrow.clockwise") {
                    appState.replanFromNow()
                }
                .buttonStyle(.bordered)
                if AppState.plannerAvailable {
                    Button("New Plan", systemImage: "square.and.pencil") {
                        appState.clearPlan()
                    }
                    .buttonStyle(.bordered)
                }
            }
            .font(.subheadline)
            if let error = appState.planner.error {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct PlanChangedCard: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Your plan changed", systemImage: "exclamationmark.arrow.triangle.2.circlepath")
                .font(.headline)
            Text("The organizers moved or removed something in your plan.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Button("Re-plan") {
                    appState.replanFromNow()
                }
                .buttonStyle(.borderedProminent)
                Button("Keep as Is") {
                    appState.keepChangedPlan()
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Rows

private struct PlanItemRow: View {
    let entry: PlannedItem
    /// nil: the item is no longer on the schedule.
    let item: ScheduleItem?
    let now: Date

    @Environment(AppState.self) private var appState

    var body: some View {
        let timeZone = appState.timeZone
        let ended = item.map { ScheduleTiming.hasEnded($0, at: now) } ?? true
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                if let item {
                    Text(EventTimeFormat.range(start: item.startTime, end: item.endTime, in: timeZone, now: now))
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Text(item?.name ?? "No longer on the schedule")
                    .font(.headline)
                    .foregroundStyle(ended ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                if let item {
                    Text(appState.location(id: item.locationId)?.name ?? item.locationName ?? ScheduleGrouping.generalTitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Text(entry.reason)
                    .font(.caption)
                    .foregroundStyle(.tint)
            }
            Spacer(minLength: 0)
            if let item {
                HeartButton(target: .scheduleItem(item.id), font: .subheadline)
            }
            if !entry.alternatives.isEmpty {
                swapMenu(timeZone: timeZone)
            }
        }
        .padding(.vertical, 4)
    }

    private func swapMenu(timeZone: TimeZone) -> some View {
        Menu {
            Section("Swap for") {
                ForEach(entry.alternatives.compactMap { id in appState.schedule.first { $0.id == id } }) { alternative in
                    Button {
                        appState.swapPlanItem(entry.itemId, for: alternative.id)
                    } label: {
                        Text(alternative.name)
                        Text(subtitle(alternative, timeZone: timeZone))
                    }
                }
            }
        } label: {
            Label("Swap", systemImage: "arrow.left.arrow.right")
                .labelStyle(.iconOnly)
                .font(.subheadline)
                .frame(minWidth: 32, minHeight: 32)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .accessibilityLabel("Swap \(item?.name ?? "item")")
    }

    /// "7:00 – 8:30 PM · Main Stage · hearted".
    private func subtitle(_ alternative: ScheduleItem, timeZone: TimeZone) -> String {
        var parts = [EventTimeFormat.range(start: alternative.startTime, end: alternative.endTime, in: timeZone, now: .now)]
        if let place = appState.location(id: alternative.locationId)?.name { parts.append(place) }
        if entry.orInstead.contains(alternative.id) { parts.append("hearted") }
        return parts.joined(separator: " · ")
    }
}

private struct PlanMealRow: View {
    let meal: MealBreak

    @Environment(AppState.self) private var appState

    var body: some View {
        let timeZone = appState.timeZone
        let place = appState.location(id: meal.locationId)?.name
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(meal.kind.label)
                    .font(.headline)
                Text("\(EventTimeFormat.time(meal.start, in: timeZone)) – \(EventTimeFormat.time(meal.end, in: timeZone))" + (place.map { " · \($0) nearby" } ?? ""))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: "fork.knife")
                .foregroundStyle(.tint)
        }
        .padding(.vertical, 4)
    }
}
