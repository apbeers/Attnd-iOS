// PlanStore.swift
// Attnd (app target only — not in the App Clip)
//
// "My plan" (shared spec §6) at runtime, matching Android's EventViewModel / PlanStore:
//
//   - PlanStore: the current event's plan (UserDefaults `pref.plan.<event id>`, `PlanCodec`
//     JSON, kept after leaving like hearts), whether the planner is working, its last error, and
//     whether the Schedule tab shows My plan. Loaded with the event's hearts (AppState).
//   - AppState.makePlan: the on-device model reads the request into preferences
//     (EventAssistant.planPreferences, validated against the bundle) merged with the plain-rule
//     reading (PlanRequest.heuristic, which alone is used when the model fails); the
//     deterministic Planner then schedules. Offered only while the model is available
//     (`AppState.plannerAvailable`); an existing plan can still be viewed, re-planned from now,
//     swapped and kept without it.
//   - Every stored change updates the Live Activity and reminders (plan > hearts > now/next).
//
// Nothing here runs in screenshot mode (the planner is never offered there and no plan loads).

import Foundation
import Observation

@MainActor
@Observable
final class PlanStore {
    /// The current event's plan (nil: none).
    fileprivate(set) var plan: Plan?
    /// The on-device model is reading a request.
    fileprivate(set) var isPlanning = false
    /// "Nothing on the schedule fits that. …" (cleared by the next attempt).
    fileprivate(set) var error: String?
    /// The Schedule tab shows My plan (its chip; "Open My plan" and onboarding turn it on).
    var showsMyPlan = false

    @ObservationIgnored private var eventId: Int?

    var hasPlan: Bool { plan?.isEmpty == false }

    private static func key(_ eventId: Int) -> String { "pref.plan.\(eventId)" }

    /// The plan saved for `eventId` (AppState, with the event's hearts).
    func load(eventId: Int?) {
        guard self.eventId != eventId else { return }
        self.eventId = eventId
        showsMyPlan = false
        error = nil
        isPlanning = false
        guard let eventId, !ScreenshotMode.isActive else {
            plan = nil
            return
        }
        plan = PlanCodec.decode(UserDefaults.standard.data(forKey: Self.key(eventId))).flatMap { $0.eventId == eventId ? $0 : nil }
    }

    fileprivate func store(_ plan: Plan?) {
        self.plan = plan
        if let eventId, !ScreenshotMode.isActive {
            if let plan, let data = PlanCodec.encode(plan) {
                UserDefaults.standard.set(data, forKey: Self.key(eventId))
            } else {
                UserDefaults.standard.removeObject(forKey: Self.key(eventId))
            }
        }
        // The Live Activity and reminders follow the plan.
        LiveFollowController.shared.setNeedsUpdate()
    }
}

// MARK: - Planner actions

extension AppState {
    static let nothingFitsMessage = "Nothing on the schedule fits that. Try another day or fewer limits."

    /// The planner is offered (make a plan, Ask plans, onboarding's plan chips): only while the
    /// on-device model is available (never in screenshot mode).
    static var plannerAvailable: Bool { assistantAvailable }

    /// The Schedule tab offers "My plan": the planner is available or there is a plan to show.
    var offersMyPlan: Bool { Self.plannerAvailable || planner.hasPlan }

    /// A planned item changed or disappeared in a content update since the plan was made.
    var planChanged: Bool {
        guard let plan = planner.plan, !plan.isEmpty else { return false }
        return Planner.changed(plan, schedule: schedule)
    }

    /// The plan's items (the Live Activity follows them; reminders include them).
    var plannedItemIds: Set<Int> { Set(planner.plan?.itemIds ?? []) }

    private func makePlanner(_ bundle: EventBundle, _ preferences: PlanPreferences) -> Planner {
        Planner(
            bundle: bundle,
            preferences: preferences,
            heartedItems: personal.heartedScheduleItems,
            heartedLocations: personal.heartedLocations
        )
    }

    /// Makes and stores a plan for `request` (the request card, Ask, onboarding): the on-device
    /// model reads preferences, the plain-rule reading fills gaps (or replaces it when it fails),
    /// then the Planner schedules from now. Returns the plan (empty: nothing fits, not stored),
    /// or nil when there is no event, the planner isn't available or one is already running.
    @discardableResult
    func makePlan(_ request: String) async -> Plan? {
        let trimmed = request.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !planner.isPlanning, Self.plannerAvailable, let bundle = currentBundle else { return nil }
        planner.isPlanning = true
        planner.error = nil
        defer { planner.isPlanning = false }
        let now = Date.now
        let rules = PlanRequest.heuristic(trimmed, bundle: bundle, now: now)
        let model = try? await EventAssistant.planPreferences(
            trimmed, bundle: bundle, heartedItems: personal.heartedScheduleItems, now: now
        )
        // The user may have left or switched events while the model was reading.
        guard currentEvent?.id == bundle.event.id else { return nil }
        let preferences = PlanRequest.merge(model, rules)
        let plan = makePlanner(bundle, preferences).plan(
            from: now,
            request: trimmed,
            createdAt: Date(timeIntervalSince1970: now.timeIntervalSince1970.rounded(.down))
        )
        if plan.isEmpty {
            planner.error = Self.nothingFitsMessage
        } else {
            planner.store(plan)
        }
        return plan
    }

    /// "Re-plan from now" (also after a content change): the same preferences from the current time.
    func replanFromNow() {
        guard let bundle = currentBundle, let plan = planner.plan else { return }
        let now = Date.now
        let replanned = makePlanner(bundle, plan.preferences).plan(
            from: now,
            request: plan.request,
            createdAt: Date(timeIntervalSince1970: now.timeIntervalSince1970.rounded(.down))
        )
        if replanned.isEmpty {
            planner.error = "Nothing left on the schedule fits this plan."
        } else {
            planner.error = nil
            planner.store(replanned)
        }
    }

    /// Swap: one of the item's alternatives takes its slot (walks, meals and alternatives rebuilt).
    func swapPlanItem(_ oldId: Int, for newId: Int) {
        guard let bundle = currentBundle, let plan = planner.plan,
              let swapped = makePlanner(bundle, plan.preferences).swap(plan, oldId: oldId, newId: newId) else { return }
        planner.store(swapped)
    }

    /// "Keep as is" after a content change: removed items leave the plan, changed ones are
    /// accepted as they are now.
    func keepChangedPlan() {
        guard let plan = planner.plan else { return }
        let schedule = self.schedule
        var kept = plan
        kept.days = plan.days.map { day in
            var day = day
            day.entries = day.entries.filter { entry in
                guard case .item(let item) = entry else { return true }
                return schedule.contains { $0.id == item.itemId }
            }
            return day
        }
        var prints: [Int: String] = [:]
        for item in kept.items {
            if let current = schedule.first(where: { $0.id == item.itemId }) { prints[item.itemId] = Planner.fingerprint(current) }
        }
        kept.fingerprints = prints
        planner.store(kept)
    }

    /// "New plan": back to the request card.
    func clearPlan() {
        planner.error = nil
        planner.store(nil)
    }

    /// Opens Schedule → My plan (after planning from Ask or onboarding), closing any sheet.
    func showMyPlan() {
        guard currentEvent != nil, tabs.contains(.schedule) else { return }
        presentedSheet = nil
        selectedTab = .schedule
        planner.showsMyPlan = true
    }

    /// An onboarding / plan-card example: a plan request plans (and opens My plan), the
    /// question opens Ask with it.
    func useExample(_ example: PlanExample) {
        if example.isPlan {
            showMyPlan()
            Task { await makePlan(example.text) }
        } else {
            showSearch(example.text, ask: true)
        }
    }
}
