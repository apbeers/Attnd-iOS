// PlanStore.swift
// Attnd (app + App Clip)
//
// "My plan" (shared spec §6) at runtime, matching Android's EventViewModel / PlanStore:
//
//   - PlanStore: the current event's plan (UserDefaults `pref.plan.<event id>`, `PlanCodec`
//     JSON, kept after leaving like hearts), whether the planner is working and its last error. Loaded with the event's hearts (AppState).
//   - AppState.makePlan: the on-device model reads the request into preferences
//     (EventAssistant.planPreferences, validated against the bundle) merged with the plain-rule
//     reading (PlanRequest.heuristic, which alone is used when the model fails); the
//     deterministic Planner then schedules. Offered only where the plan page exists
//     (`AppState.modelReady`: Apple Intelligence's on-device model is available;
//     planner_view_spec §1); when the model fails for a request the plain-rule reading plans alone.
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

    /// The plan's undo stack (≤ 20 earlier versions, `PlanHistory`), stored next to the plan.
    fileprivate(set) var history = PlanHistory()

    @ObservationIgnored private(set) var eventId: Int?
    /// My schedule follows every applied plan and undo (AppState.applyPlanToSchedule): the plan
    /// fills My schedule; it is kept only as the planner's arrangement of the day.
    @ObservationIgnored var onApply: (@MainActor (_ plan: Plan?, _ previous: Plan?) -> Void)?

    var hasPlan: Bool { plan?.isEmpty == false }
    var canUndo: Bool { history.canUndo }

    private static func key(_ eventId: Int) -> String { "pref.plan.\(eventId)" }
    private static func historyKey(_ eventId: Int) -> String { "pref.planHistory.\(eventId)" }
    private static func conversationKey(_ eventId: Int) -> String { "pref.assistantConversation.\(eventId)" }
    private static func sharedKey(_ eventId: Int) -> String { "pref.sharedPlans.\(eventId)" }
    /// Files in the App Group container (Nov 22, 2026; the keys above are older builds', moved on
    /// first read): `AssistantFiles`.
    private static func historyFile(_ eventId: Int) -> String { "plan-history-\(eventId).json" }
    private static func conversationFile(_ eventId: Int) -> String { "conversation-\(eventId).json" }

    /// The plan saved for `eventId` (AppState, with the event's hearts).
    func load(eventId: Int?) {
        guard self.eventId != eventId else { return }
        self.eventId = eventId
        error = nil
        isPlanning = false
        guard let eventId, !ScreenshotMode.isActive else {
            plan = nil
            history = PlanHistory()
            return
        }
        plan = PlanCodec.decode(UserDefaults.standard.data(forKey: Self.key(eventId))).flatMap { $0.eventId == eventId ? $0 : nil }
        history = PlanHistory.decode(AssistantFiles.shared.string(Self.historyFile(eventId), legacyKey: Self.historyKey(eventId)))
    }

    /// Stores `plan` as a new version: the plan it replaces goes onto the undo stack (assistant
    /// spec §4; every plan change: edits, versions, new plans, swaps, re-plans, shared plans).
    func apply(_ plan: Plan?) {
        let previous = self.plan
        if let previous, !previous.isEmpty, previous != plan {
            setHistory(history.push(previous))
        }
        store(plan)
        onApply?(plan, previous)
    }

    /// `plan_undo`: the previous version back (nil when there is nothing to undo).
    @discardableResult
    func undo() -> Plan? {
        guard let popped = history.pop() else { return nil }
        let previous = plan
        setHistory(popped.rest)
        store(popped.plan)
        onApply?(popped.plan, previous)
        return popped.plan
    }

    /// Changes the plan in place, without a new version (check-offs).
    func update(_ plan: Plan) {
        store(plan)
    }

    private func setHistory(_ history: PlanHistory) {
        self.history = history
        guard let eventId, !ScreenshotMode.isActive else { return }
        if history.canUndo {
            AssistantFiles.shared.set(history.encode(), Self.historyFile(eventId))
        } else {
            AssistantFiles.shared.set(nil, Self.historyFile(eventId))
        }
    }

    // MARK: Assistant storage (per event, on the device, kept after leaving like the plan)

    func conversation(_ eventId: Int) -> AssistantConversation {
        AssistantConversation.decode(AssistantFiles.shared.string(Self.conversationFile(eventId), legacyKey: Self.conversationKey(eventId)))
    }

    func setConversation(_ conversation: AssistantConversation, eventId: Int) {
        guard !ScreenshotMode.isActive else { return }
        AssistantFiles.shared.set(conversation.encode(), Self.conversationFile(eventId))
    }

    /// Shared plans received for the event (for "Merge with mine").
    func sharedPlans(_ eventId: Int) -> [[Int]] {
        SharedPlans.decode(UserDefaults.standard.string(forKey: Self.sharedKey(eventId)))
    }

    func addSharedPlan(_ ids: [Int], eventId: Int) {
        guard !ScreenshotMode.isActive else { return }
        UserDefaults.standard.set(SharedPlans.encode(SharedPlans.adding(ids, to: sharedPlans(eventId))), forKey: Self.sharedKey(eventId))
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

    /// The plan's items (the Live Activity follows them; reminders include them).
    var plannedItemIds: Set<Int> { Set(planner.plan?.itemIds ?? []) }

    /// My schedule's items are the planner's must-includes (hearted, rule 7); a timed food place
    /// in My schedule covers that day's lunch or dinner break.
    private func makePlanner(_ bundle: EventBundle, _ preferences: PlanPreferences, constraints: PlanConstraints = .none) -> Planner {
        var constraints = constraints
        constraints.mealsDone.formUnion(mySchedule.mealsCovered(bundle))
        return Planner(
            bundle: bundle,
            preferences: preferences,
            heartedItems: personal.heartedScheduleItems,
            heartedLocations: personal.heartedLocations,
            constraints: constraints
        )
    }

    /// Makes and stores a plan for `request` (the request card, Ask, onboarding): the on-device
    /// model reads preferences, the plain-rule reading fills gaps (or replaces it when it fails),
    /// then the Planner schedules from now. Returns the plan (empty: nothing fits, not stored),
    /// or nil when there is no event, the planner isn't available or one is already running.
    @discardableResult
    func makePlan(_ request: String) async -> Plan? {
        let trimmed = request.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !planner.isPlanning, Self.modelReady, let bundle = currentBundle else { return nil }
        planner.isPlanning = true
        planner.error = nil
        defer { planner.isPlanning = false }
        AppLog.info(.planner, "planner.request", "Plan request", LogRedaction.textFields(trimmed))
        let now = Date.now
        let rules = PlanRequest.heuristic(trimmed, bundle: bundle, now: now)
        let modelStarted = ContinuousClock.now
        var model: PlanPreferences?
        // The model reads the request; when it fails the plain-rule reading alone plans.
        do {
            model = try await EventAssistant.planPreferences(
                trimmed, bundle: bundle, heartedItems: personal.heartedScheduleItems, now: now
            )
        } catch {
            AppLog.caught(error, .planner, "plan_preferences", level: .notice)
            model = nil
        }
        let modelMs = (ContinuousClock.now - modelStarted).wholeMilliseconds
        AppLog.info(.planner, "planner.extract", "Preferences read in \(modelMs) ms", [
            "ms": .int(modelMs), "ok": .bool(model != nil), "model": .string(model != nil ? "foundation_models" : "rules"),
            "liked_tags": .int(model?.likedTags.count ?? rules.likedTags.count),
            "disliked_tags": .int(model?.dislikedTags.count ?? rules.dislikedTags.count),
            "days": .int(model?.days.count ?? rules.days.count),
        ])
        // The user may have left or switched events while the model was reading.
        guard currentEvent?.id == bundle.event.id else { return nil }
        let preferences = PlanRequest.merge(model, rules)
        // perf_planner_ms times the Planner run only (not the model's reading).
        let signpost = AppSignpost.begin(.planner)
        let plan = makePlanner(bundle, preferences).plan(
            from: now,
            request: trimmed,
            createdAt: Date(timeIntervalSince1970: now.timeIntervalSince1970.rounded(.down))
        )
        let ms = AppSignpost.end(signpost, ["items": .int(plan.itemIds.count)])
        if plan.isEmpty {
            planner.error = Self.nothingFitsMessage
        } else {
            planner.apply(plan)
        }
        PerfMetrics.shared.record(.perfPlannerMs, detail: PerfBucket.planner(ms: ms))
        AppLog.info(.planner, "planner.run", "Plan with \(plan.itemIds.count) items in \(ms) ms", [
            "ms": .int(ms), "items": .int(plan.itemIds.count), "days": .int(plan.days.count),
            "pace": .string(String(describing: preferences.pace)),
        ])
        return plan
    }

    /// "Re-plan from now" (also after a content change): the same preferences from the current time.
    func replanFromNow() {
        guard let bundle = currentBundle, let plan = planner.plan else { return }
        AppLog.debug(.ui, "ui.action", "Re-plan from now", ["name": "replan"])
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
            planner.apply(replanned)
        }
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
        planner.apply(kept)
    }

    /// "New plan": back to the request card.
    func clearPlan() {
        planner.error = nil
        planner.apply(nil)
    }

    /// Opens the plan page (onboarding, the Live Activity's plan link), closing any sheet.
    /// Without the on-device model (no plan page) the Schedule tab instead.
    func showMyPlan() {
        guard currentEvent != nil else { return }
        guard Self.modelReady else {
            select(.schedule)
            return
        }
        openPlanPage()
    }

    /// An onboarding / plan-card example: a plan request plans (and opens My plan), the
    /// question ("What's on near me right now?") opens the plan page and asks it as a turn.
    func useExample(_ example: PlanExample) {
        if example.isPlan {
            showMyPlan()
            Task { await makePlan(example.text) }
        } else {
            showMyPlan()
            assistant.submit(example.text, forced: .ask)
        }
    }
}
