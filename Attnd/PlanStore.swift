// PlanStore.swift
// Attnd (app + App Clip)
//
// One list (owner, Nov 22, 2026; Attnd-Web docs/specs/one_list_spec.md): My schedule is the only
// stored list; the planner proposes edits to it.
//
//   - PlanStore: the planner's working state for the current event: the derived day view `plan`
//     (computed from My schedule by `AppState.refreshDerivedPlan`, never stored), whether the
//     planner is reading a request and its last error, and the one Undo history over My schedule
//     (`ScheduleHistory`, ≤ 20 snapshots, `attnd-assistant/schedule-history-<id>.json`).
//   - The old stored plan (`pref.plan.<id>`, `pref.planHistory.<id>`, `plan-history-<id>.json`)
//     is read once (`load` → `legacyPlan`), absorbed into My schedule by AppState and deleted.
//   - AppState.makePlan: the on-device model reads the request into preferences, merged with the
//     plain-rule reading; `Planner.propose` plans with My schedule's items as the must-includes and
//     returns the plan to preview; Apply (`applyPlan`) turns it into My schedule edits.
//
// Nothing here runs in screenshot mode (the planner is never offered there and nothing loads).

import Foundation
import Observation

@MainActor
@Observable
final class PlanStore {
    /// The day view of My schedule (nil: nothing timed in it). Derived, never stored.
    fileprivate(set) var plan: Plan?
    /// The on-device model is reading a request.
    fileprivate(set) var isPlanning = false
    /// "Nothing on the schedule fits that. …" (cleared by the next attempt).
    fileprivate(set) var error: String?

    /// The one Undo history over My schedule (plans, edits, versions, swaps, shared plans, hearts).
    fileprivate(set) var history = ScheduleHistory()

    @ObservationIgnored private(set) var eventId: Int?
    /// An older build's stored plan, read by `load` until AppState absorbed it (`takeLegacyPlan`).
    @ObservationIgnored private var legacyPlan: Plan?

    var hasPlan: Bool { plan?.isEmpty == false }
    var canUndo: Bool { history.canUndo }

    private static func legacyKey(_ eventId: Int) -> String { "pref.plan.\(eventId)" }
    private static func legacyHistoryKey(_ eventId: Int) -> String { "pref.planHistory.\(eventId)" }
    private static func legacyHistoryFile(_ eventId: Int) -> String { "plan-history-\(eventId).json" }
    private static func conversationKey(_ eventId: Int) -> String { "pref.assistantConversation.\(eventId)" }
    private static func sharedKey(_ eventId: Int) -> String { "pref.sharedPlans.\(eventId)" }
    /// Files in the App Group container (`AssistantFiles`).
    private static func historyFile(_ eventId: Int) -> String { "schedule-history-\(eventId).json" }
    private static func conversationFile(_ eventId: Int) -> String { "conversation-\(eventId).json" }

    /// The event's Undo history, and an older build's plan for the one-time migration (AppState,
    /// with the event's personal state).
    func load(eventId: Int?) {
        guard self.eventId != eventId else { return }
        self.eventId = eventId
        error = nil
        isPlanning = false
        plan = nil
        legacyPlan = nil
        guard let eventId, !ScreenshotMode.isActive else {
            history = ScheduleHistory()
            return
        }
        history = ScheduleHistory.decode(AssistantFiles.shared.string(Self.historyFile(eventId)))
        let stored = PlanCodec.decode(UserDefaults.standard.data(forKey: Self.legacyKey(eventId)))
        let newest = PlanHistory.decode(AssistantFiles.shared.string(Self.legacyHistoryFile(eventId),
                                                                      legacyKey: Self.legacyHistoryKey(eventId))).plans.last
        legacyPlan = (stored ?? newest).flatMap { $0.eventId == eventId ? $0 : nil }
        if legacyPlan == nil { deleteLegacy(eventId) }
    }

    /// One list §6: the old plan once; AppState absorbs it, saves, then calls `deleteLegacy`.
    func takeLegacyPlan() -> Plan? {
        defer { legacyPlan = nil }
        return legacyPlan
    }

    /// Deletes the old stored plan, its history key and file (idempotent).
    func deleteLegacy(_ eventId: Int) {
        guard !ScreenshotMode.isActive else { return }
        UserDefaults.standard.removeObject(forKey: Self.legacyKey(eventId))
        UserDefaults.standard.removeObject(forKey: Self.legacyHistoryKey(eventId))
        AssistantFiles.shared.set(nil, Self.legacyHistoryFile(eventId))
    }

    func setDerived(_ plan: Plan?) {
        if self.plan != plan { self.plan = plan }
    }

    func push(_ previous: MySchedule) {
        setHistory(history.push(previous))
    }

    func pop() -> MySchedule? {
        guard let popped = history.pop() else { return nil }
        setHistory(popped.rest)
        return popped.schedule
    }

    private func setHistory(_ history: ScheduleHistory) {
        self.history = history
        guard let eventId, !ScreenshotMode.isActive else { return }
        AssistantFiles.shared.set(history.canUndo ? history.encode() : nil, Self.historyFile(eventId))
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
}

// MARK: - Planner actions

extension AppState {
    static let nothingFitsMessage = "Nothing on the schedule fits that. Try another day or fewer limits."
    static let alreadyInScheduleMessage = "Everything that fits is already in your schedule."

    /// My schedule's items (the Live Activity follows them; reminders include them).
    var plannedItemIds: Set<Int> { personal.schedule.itemIds }

    /// Recomputes the day view of My schedule (`planner.plan`): after every change to My
    /// schedule, its check-offs or preferences, a new bundle and loading the event.
    func refreshDerivedPlan() {
        guard let bundle = currentBundle, currentEvent != nil, !ScreenshotMode.isActive else {
            planner.setDerived(nil)
            return
        }
        planner.setDerived(personal.schedule.dayPlan(bundle, preferences: personal.preferences,
                                                     checkedOff: personal.checkedOff, now: .now))
    }

    /// Reads a request into preferences and plans (the request card, Ask, onboarding): the
    /// on-device model reads preferences, the plain-rule reading fills gaps (or replaces it when it
    /// fails), then `Planner.propose` plans from now with My schedule's items as must-includes.
    /// Returns the plan to preview (nothing is applied; empty: nothing fits), or nil when there is
    /// no event, the planner isn't available or one is already running.
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
        let (plan, proposal) = Planner.propose(personal.schedule, preferences: personal.preferences, request: preferences,
                                               text: trimmed, bundle: bundle, now: now)
        let ms = AppSignpost.end(signpost, ["items": .int(plan.itemIds.count)])
        if plan.isEmpty {
            planner.error = Self.nothingFitsMessage
        } else if proposal.isEmpty {
            planner.error = Self.alreadyInScheduleMessage
        }
        PerfMetrics.shared.record(.perfPlannerMs, detail: PerfBucket.planner(ms: ms))
        AppLog.info(.planner, "planner.run", "Plan with \(plan.itemIds.count) items in \(ms) ms", [
            "ms": .int(ms), "items": .int(plan.itemIds.count), "days": .int(plan.days.count),
            "pace": .string(String(describing: preferences.pace)),
        ])
        return proposal.isEmpty ? Plan(eventId: plan.eventId, createdAt: plan.createdAt, request: plan.request,
                                       preferences: plan.preferences, days: [], fingerprints: [:]) : plan
    }

    /// Apply (one list §3): a plan (new, edited, a version, a swap, a sequence, shared) becomes
    /// edits to My schedule: one Undo history entry. `explicit` = items the request asked to drop
    /// (an edit's excluded items); `records` keeps the plan's preferences for later plans.
    @discardableResult
    func applyPlan(_ plan: Plan?, explicit: Set<Int> = [], source: ScheduleEntrySource = .planner, records: Bool = true) -> ScheduleProposal {
        guard let bundle = currentBundle, currentEvent != nil, !ScreenshotMode.isActive, let plan else { return ScheduleProposal() }
        let proposal = personal.schedule.proposal(for: plan, explicit: explicit, bundle)
        if records { setPlannerPreferences(SchedulePreferences(plan.preferences, constraints: plan.constraints)) }
        applyScheduleProposal(proposal, source: source)
        return proposal
    }

    /// Opens Ask Attnd (onboarding, the Live Activity's plan link), closing any sheet.
    /// Without the on-device model (no chat) the Schedule tab instead.
    func showMyPlan() {
        guard currentEvent != nil else { return }
        guard Self.modelReady else {
            select(.schedule)
            return
        }
        openPlanPage()
    }

    /// An onboarding example: a plan request opens Ask Attnd and previews the plan, the question
    /// ("What's on near me right now?") opens it and asks it as a turn.
    func useExample(_ example: PlanExample) {
        showMyPlan()
        if example.isPlan {
            assistant.makePlan(example.text)
        } else {
            assistant.submit(example.text, forced: .ask)
        }
    }
}
