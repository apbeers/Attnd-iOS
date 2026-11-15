// AssistantController.swift
// Attnd (app target only — not in the App Clip)
//
// The event assistant at runtime (assistant spec §1–8), matching Android's
// `ui/assistant/AssistantController.kt`: one conversation per event (`AppState.assistant`).
//
//   - Turns: every typed turn goes through the rule-based `AssistantRouter`, or — when Apple
//     Intelligence's on-device model is available and `AssistantFlow.path` says so — the model
//     (`EventAssistant.assistantTurn`, streamed: blocks appear as they complete; any error or
//     invalid output → the router's answer for that turn, `AssistantModel.resolve`).
//   - Actions: the turn's actions, chips, card buttons and live hints go through
//     `ActionDispatcher` (validation, `confirm` blocks, Undo) to this controller's executor.
//     Plan changes are stored as new versions with their undo stack (`PlanStore.apply`, ≤ 20).
//   - Storage (per event, on the device, kept after leaving like the plan, `PlanStore`): the
//     transcript (`pref.assistant.<id>`, re-validated when shown; old confirmations are
//     dropped), the model's conversation (`pref.assistantConversation.<id>`), the plan history
//     (`pref.planHistory.<id>`) and the shared plans received (`pref.sharedPlans.<id>`).
//   - Live (§6): position samples while a screen tracks the location (never a new permission
//     prompt) → auto check-off, skipped items; running late, gap fillers, organizer changes and
//     the day's recap → `live` (`LiveHintRules`), shown above the conversation.
//   - Shared plan links (`AppState.pendingSharedPlan`, API-015): a read-only turn with
//     "Use this plan" / "Merge with mine".
//
// Logging: `assistant.turn` / `assistant.block` / `assistant.action`, `plan.edit` /
// `plan.undo`, `live.running_late` / `live.checkoff`, `share.created` / `share.opened` (never
// the typed text in production: `LogRedaction.textFields`). Not in screenshot mode (the
// search sheet is shown there instead).

import Foundation
import Observation

@MainActor
@Observable
final class AssistantController {

    /// A shared plan link's offer under its turn.
    struct SharedOffer: Hashable, Sendable {
        var ids: [Int]
        var day: PlanDate?
        var handled = false
    }

    /// One turn of the conversation as shown.
    struct Turn: Identifiable, Hashable {
        var id: Int
        /// What the user typed or the chip they tapped; nil for a turn the app added.
        var input: String?
        var blocks: [AssistantBlock]
        var source: TurnSource = .rules
        /// A write applied with Undo (plan change, like, check-off): Undo / Apply act on it.
        var applied: AssistantAction? = nil
        var undone = false
        /// Indexes of `confirm` blocks already answered (and how).
        var answered: [Int: Bool] = [:]
        /// The model is still writing this turn.
        var streaming = false
        var shared: SharedOffer? = nil
    }

    private(set) var turns: [Turn] = []
    /// The path of the turn being worked on (busy indicator in the input bar).
    private(set) var busy: TurnPath?
    /// The input bar's chosen path (nil = automatic).
    var forced: TurnPath?
    /// The input bar's text (kept while the sheet is closed).
    var draft = ""
    private(set) var live = LiveHints()
    /// Incremented when a turn is added (the screen scrolls to it).
    private(set) var serial = 0
    /// Incremented to put the keyboard up (a request typed elsewhere, "Ask about this").
    private(set) var focusSerial = 0
    /// The plan's walking legs on real paths (MKDirections, per leg).
    let dayRoutes = DayRouteProvider()

    @ObservationIgnored weak var appState: AppState?
    @ObservationIgnored private(set) var eventId: Int?
    @ObservationIgnored private var nextId = 1
    @ObservationIgnored private var modelTask: Task<Void, Never>?
    @ObservationIgnored private var samples: [LocationSample] = []
    @ObservationIgnored private var dismissedSkips: Set<Int> = []
    @ObservationIgnored private var lateLoggedFor: Int?
    @ObservationIgnored private var planSource = "assistant"

    private static let sampleWindow: TimeInterval = 3 * 3600
    private static let maxSamples = 600
    private static let recent: TimeInterval = 5 * 60

    private var dispatcher: ActionDispatcher { ActionDispatcher(executor: AssistantExecutor(controller: self)) }

    // MARK: - Event

    /// The conversation of `eventId` (AppState, with the event's hearts and plan).
    func load(eventId: Int?) {
        guard self.eventId != eventId else { return }
        modelTask?.cancel()
        modelTask = nil
        self.eventId = eventId
        samples = []
        dayRoutes.clear()
        dismissedSkips = []
        lateLoggedFor = nil
        busy = nil
        forced = nil
        draft = ""
        guard let eventId, let appState, !ScreenshotMode.isActive else {
            turns = []
            live = LiveHints()
            return
        }
        let ctx = context()
        turns = appState.planner.transcript(eventId).map { stored in
            // Stored turns are shown again, re-validated; old confirmations can't be answered.
            let blocks = ctx.map { BlockValidator.validate(stored.turn.blocks, $0.blockContext) } ?? stored.turn.blocks
            defer { nextId += 1 }
            return Turn(id: nextId, input: stored.input, blocks: blocks.filter { if case .confirm = $0 { return false } else { return true } })
        }
        refreshLive()
    }

    func clearConversation() {
        guard let eventId, let appState else { return }
        modelTask?.cancel()
        appState.planner.setTranscript([], eventId: eventId)
        appState.planner.setConversation(AssistantConversation(), eventId: eventId)
        turns = []
        busy = nil
        AppLog.debug(.ui, "ui.action", "Assistant conversation cleared", ["name": "assistant_clear"])
    }

    var modelAvailable: Bool { AppState.assistantAvailable }

    /// What the router, the model prompt and the validator use. nil outside an event.
    func context(now: Date = .now) -> RouterContext? {
        guard let appState, let bundle = appState.currentBundle else { return nil }
        let available = modelAvailable
        return RouterContext(
            bundle: bundle,
            likes: appState.likeSet,
            plan: appState.planner.plan.flatMap { $0.isEmpty ? nil : $0 },
            now: now,
            user: userPoint(now: now),
            canPlan: available,
            modelAvailable: available,
            history: appState.planner.history,
            units: DistanceText.usesImperial() ? .imperial : .metric,
            locale: .current
        )
    }

    private func userPoint(now: Date) -> Coordinate? {
        if let last = samples.last, now.timeIntervalSince(last.at) < Self.recent { return last.point }
        guard let appState, appState.userLocation.isAuthorized else { return nil }
        return appState.userLocation.location
    }

    // MARK: - Turns

    /// The input bar's intent chip for `text` (debounced by the screen).
    func predict(_ text: String) -> TurnPath {
        guard let ctx = context(), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return forced ?? .search }
        return AssistantFlow.path(AssistantRouter.route(text, ctx).intent, text, modelAvailable: ctx.modelAvailable, forced: forced)
    }

    /// Cycles the input bar's chip: automatic → Search → Ask (with the model) → Plan → automatic.
    func cycleForced() {
        let order: [TurnPath?] = modelAvailable ? [nil, .search, .ask, .plan] : [nil, .search, .plan]
        let index = order.firstIndex(of: forced) ?? 0
        forced = order[(index + 1) % order.count]
    }

    /// Enter / send: runs the full turn.
    func submit(_ input: String, forced overridden: TurnPath? = nil) {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let ctx = context() else { return }
        let path = overridden ?? forced
        let started = ContinuousClock.now
        if text.isEmpty {
            finish(nil, AssistantRouter.route("", ctx).turn, .rules, .empty, started, ctx)
            return
        }
        let routed = AssistantRouter.route(text, ctx)
        switch AssistantFlow.path(routed.intent, text, modelAvailable: ctx.modelAvailable, forced: path) {
        case .search:
            if path == .search {
                finish(text, AssistantFlow.searchTurn(text, ctx), .rules, .search, started, ctx)
            } else {
                finish(text, routed.turn, .rules, routed.intent, started, ctx)
            }
        case .plan:
            finish(text, AssistantFlow.planTurn(text, routed, ctx), .rules, routed.intent, started, ctx)
        case .ask:
            ask(text, ctx, started)
        }
    }

    /// The model path: streamed blocks, then the validated turn (or the router's on invalid output).
    private func ask(_ text: String, _ ctx: RouterContext, _ started: ContinuousClock.Instant) {
        modelTask?.cancel()
        guard let appState else { return }
        let eventId = ctx.bundle.event.id
        let id = nextId
        nextId += 1
        turns.append(Turn(id: id, input: text, blocks: [], source: .model, streaming: true))
        busy = .ask
        serial += 1
        let retrieved = AssistantModel.retrieve(text, ctx)
        let prompt = AssistantModel.prompt(text, ctx, appState.planner.conversation(eventId), retrieved)
        modelTask = Task { [weak self] in
            var raw: String?
            var toolCalls = 0
            do {
                let reply = try await EventAssistant.assistantTurn(prompt, bundle: ctx.bundle, now: ctx.now) { [weak self] partial in
                    guard let self, let index = self.turns.firstIndex(where: { $0.id == id }) else { return }
                    let shown = AssistantModel.completeBlocks(partial, ctx).filter { !$0.isChips }
                    if shown != self.turns[index].blocks { self.turns[index].blocks = shown }
                }
                raw = reply.raw
                toolCalls = reply.toolCalls
            } catch is CancellationError {
                self?.turns.removeAll { $0.id == id }
                self?.busy = nil
                return
            } catch {
                AppLog.warning(.assistant, "assistant.error", "Assistant turn failed", [
                    "kind": "turn", "error": .string(String(describing: type(of: error))),
                    "domain": .string((error as NSError).domain), "code": .int((error as NSError).code),
                ])
                raw = nil
            }
            guard let self, !Task.isCancelled, self.eventId == eventId else { return }
            let resolved = AssistantModel.resolve(text, raw: raw, ctx)
            self.turns.removeAll { $0.id == id }
            self.finish(text, resolved.turn, resolved.source, resolved.routed?.intent ?? .question, started, ctx,
                        fallback: resolved.source == .rules, modelTried: true, toolCalls: toolCalls)
        }
    }

    /// Adds a finished turn, runs its actions, remembers it and logs it.
    private func finish(
        _ input: String?, _ turn: AssistantTurn, _ source: TurnSource, _ intent: AssistantIntent,
        _ started: ContinuousClock.Instant, _ ctx: RouterContext,
        fallback: Bool = false, modelTried: Bool = false, toolCalls: Int = 0
    ) {
        let actionSource: ActionSource = source == .model ? .model : .rules
        var blocks = turn.blocks
        var applied: AssistantAction?
        for action in turn.actions {
            let result = runQuietly(action, actionSource)
            if let action = result.applied { applied = action }
            // The router's blocks already show the result; the model's may not: add what it lacks.
            if source == .model {
                let types = Set(blocks.map(\.type))
                blocks += result.blocks.filter { !types.contains($0.type) }
                if result.blocks.isEmpty, let message = result.message { blocks.append(.text(message)) }
            }
        }
        let validated = context().map { BlockValidator.validate(blocks, $0.blockContext) } ?? blocks
        append(input, validated, source: source, applied: applied)
        if [.search, .question, .noMatch].contains(intent), input != nil { appState?.track(.search) }
        let ms = (ContinuousClock.now - started).wholeMilliseconds
        var fields: LogFields = [
            "path": .string(source == .model ? "model" : "rules"),
            "intent": .string(Self.intentName(intent)),
            "ms": .int(ms),
            "blocks": .int(validated.count),
            "fallback": .bool(modelTried && fallback),
        ]
        if modelTried { fields["tool_calls"] = .int(toolCalls) }
        if let input { fields.merge(LogRedaction.textFields(input)) { _, new in new } }
        AppLog.info(.assistant, "assistant.turn", "Assistant turn (\(source == .model ? "model" : "rules"))", fields)
        remember(ctx.bundle.event.id, input, AssistantTurn(blocks: validated))
    }

    private func append(_ input: String?, _ blocks: [AssistantBlock], source: TurnSource = .rules,
                        applied: AssistantAction? = nil, shared: SharedOffer? = nil) {
        busy = nil
        if blocks.isEmpty && shared == nil { return }
        for block in blocks {
            AppLog.debug(.assistant, "assistant.block", "Block \(block.type)", ["type": .string(block.type), "ids": .int(AssistantFlow.refs(block).count)])
        }
        turns.append(Turn(id: nextId, input: input, blocks: blocks, source: source, applied: applied, shared: shared))
        nextId += 1
        serial += 1
        persist()
    }

    private func persist() {
        guard let eventId, let appState else { return }
        appState.planner.setTranscript(turns.filter { !$0.streaming }.map { StoredTurn(input: $0.input, turn: AssistantTurn(blocks: $0.blocks)) }, eventId: eventId)
    }

    /// The model's conversation: the user's text and what the assistant answered (text only).
    private func remember(_ eventId: Int, _ input: String?, _ turn: AssistantTurn) {
        guard let appState, let bundle = appState.currentBundle else { return }
        var conversation = appState.planner.conversation(eventId)
        if let input { conversation = conversation.with(ConversationTurn(fromUser: true, text: input)) }
        conversation = conversation.with(ConversationTurn(fromUser: false, text: AssistantFlow.replyText(turn, bundle)))
        appState.planner.setConversation(conversation, eventId: eventId)
    }

    // MARK: - Actions

    private struct Quiet {
        var blocks: [AssistantBlock] = []
        var message: String? = nil
        var applied: AssistantAction? = nil
    }

    private func actionContext(_ ctx: RouterContext) -> ActionContext {
        ActionContext(bundle: ctx.bundle, now: ctx.now, hasLocation: ctx.user != nil, hasPlan: ctx.plan != nil)
    }

    /// A turn's own action: dispatched with its source; the result is returned, not shown as a new turn.
    private func runQuietly(_ action: AssistantAction, _ source: ActionSource) -> Quiet {
        guard let ctx = context() else { return Quiet() }
        if !action.name.mutates && action.name.result != .navigation {
            return Quiet(blocks: AssistantRouter.renderRead(action, ctx))
        }
        switch dispatcher.dispatch(action, context: actionContext(ctx), source: source) {
        case .rejected(let reason):
            logAction(action, "failed")
            return Quiet(message: rejectText(reason))
        case .needsConfirmation(let confirm):
            return Quiet(blocks: [confirm])
        case .executed(let outcome, let undo):
            switch outcome {
            case .done(let message, let blocks):
                logAction(action, "applied")
                return Quiet(blocks: blocks, message: message, applied: undo != nil ? action : nil)
            case .failed(let reason):
                logAction(action, "failed")
                return Quiet(message: reason)
            }
        }
    }

    /// A chip, a card button, the pinned plan or a live hint: runs `action` and shows its result
    /// as a new turn labelled `label`. Reads render with the router's layout; writes go through
    /// the dispatcher (`.rules` confirms chip-confirmed actions first; `.manual` is the person's
    /// own button). Returns the outcome's message.
    @discardableResult
    func run(_ action: AssistantAction, label: String?, source: ActionSource = .rules, confirmed: Bool = false) -> String? {
        guard let ctx = context() else { return nil }
        if !action.name.mutates && action.name.result != .navigation {
            let blocks = AssistantRouter.renderRead(action, ctx)
            append(label, blocks.isEmpty ? [.text("Nothing to show for that.")] : blocks)
            logAction(action, "applied")
            if action.name == .search, label != nil { appState?.track(.search) }
            remember(ctx.bundle.event.id, label, AssistantTurn(blocks: turns.last?.blocks ?? []))
            return nil
        }
        if source == .manual && planSource == "assistant" { planSource = "plan" }
        defer { planSource = "assistant" }
        switch dispatcher.dispatch(action, context: actionContext(ctx), source: source, confirmed: confirmed) {
        case .rejected(let reason):
            logAction(action, "failed")
            let text = rejectText(reason)
            append(label, [.text(text)])
            return text
        case .needsConfirmation(let confirm):
            append(label, [confirm])
            return nil
        case .executed(let outcome, let undo):
            switch outcome {
            case .done(let message, let blocks):
                logAction(action, confirmed ? "confirmed" : "applied", confirm: confirmed ? .chip : action.name.confirm)
                let all = (message.map { [AssistantBlock.text($0)] } ?? []) + blocks
                let validated = BlockValidator.validate(all, (context() ?? ctx).blockContext)
                append(label, validated, applied: undo != nil ? action : nil)
                if !validated.isEmpty { remember(ctx.bundle.event.id, label, AssistantTurn(blocks: validated)) }
                return message
            case .failed(let reason):
                logAction(action, "failed")
                append(label, [.text(reason)])
                return reason
            }
        }
    }

    func chip(_ chip: AssistantChip) {
        run(chip.action, label: chip.label)
    }

    /// A `confirm` block's Yes / Not Now.
    func answer(turnId: Int, index: Int, yes: Bool) {
        guard let t = turns.firstIndex(where: { $0.id == turnId }), turns[t].answered[index] == nil,
              index < turns[t].blocks.count, case .confirm(let action, _) = turns[t].blocks[index] else { return }
        turns[t].answered[index] = yes
        if yes {
            run(action, label: nil, source: .rules, confirmed: true)
        } else {
            logAction(action, "declined", confirm: .chip)
            append(nil, [.text("OK, nothing changed.")])
        }
    }

    /// A turn's Undo: the applied write's inverse (`ActionRegistry.undo(for:)`).
    func undo(turnId: Int) {
        guard let t = turns.firstIndex(where: { $0.id == turnId }), let applied = turns[t].applied, !turns[t].undone,
              let inverse = ActionRegistry.undo(for: applied), let ctx = context() else { return }
        if case .executed(.done, _) = dispatcher.dispatch(inverse, context: actionContext(ctx), source: .manual) {
            logAction(applied, "undone")
            if let i = turns.firstIndex(where: { $0.id == turnId }) { turns[i].undone = true }
        }
    }

    /// Apply again after an Undo.
    func reapply(turnId: Int) {
        guard let t = turns.firstIndex(where: { $0.id == turnId }), let applied = turns[t].applied, turns[t].undone,
              let ctx = context() else { return }
        if case .executed(.done, _) = dispatcher.dispatch(applied, context: actionContext(ctx), source: .manual) {
            logAction(applied, "applied")
            if let i = turns.firstIndex(where: { $0.id == turnId }) { turns[i].undone = false }
        }
    }

    private func rejectText(_ reason: String) -> String {
        switch reason {
        case "no plan": return AssistantRouter.noPlanText
        case "needs location": return "Turn on location to see what's closest."
        default: return "I can't do that here."
        }
    }

    private func logAction(_ action: AssistantAction, _ result: String, confirm: ConfirmKind? = nil) {
        let kind: String
        switch confirm ?? action.name.confirm {
        case .none: kind = "none"
        case .chip: kind = "chip"
        case .sheet: kind = "sheet"
        }
        AppLog.info(.assistant, "assistant.action", "Assistant action \(action.name.key): \(result)", [
            "name": .string(action.name.key), "result": .string(result), "confirm": .string(kind),
        ])
    }

    private static func intentName(_ intent: AssistantIntent) -> String {
        // camelCase → snake_case ("planEdit" → "plan_edit"), as Android logs its enum names.
        String(describing: intent).reduce(into: "") { out, ch in
            if ch.isUppercase { out += "_" + ch.lowercased() } else { out.append(ch) }
        }
    }

    // MARK: - Executor (only validated, confirmed actions arrive here)

    fileprivate func execute(_ action: AssistantAction) -> ActionOutcome {
        guard let appState, let bundle = appState.currentBundle else { return .failed("No event.") }
        let now = Date.now
        let plan = appState.planner.plan.flatMap { $0.isEmpty ? nil : $0 }
        switch action.name {
        case .like, .unlike:
            guard let target = action.likeTarget() else { return .failed("I couldn't find that.") }
            let liked = action.name == .like
            let ref = EntityRef(kind: target.kind == .schedule ? .schedule : .location, id: target.id)
            appState.setHeart(liked, for: ref.kind == .schedule ? .scheduleItem(ref.id) : .location(ref.id))
            let name = ref.name(bundle) ?? "it"
            var blocks: [AssistantBlock] = [BlockValidator.card(ref)]
            if liked, ref.kind == .schedule, let plan, let clash = LiveAssist.likeClash(ref.id, plan, bundle) {
                blocks.append(.chips([clash]))
            }
            refreshLive()
            return .done(message: liked ? "Liked \(name)." : "Unliked \(name).", blocks: blocks)
        case .planEdit:
            guard let plan else { return .failed(AssistantRouter.noPlanText) }
            guard let ops = action.ops(bundle, now: now) else { return .failed("I couldn't read that change.") }
            return applyEdit(PlanEditor.preview(plan, ops, bundle, appState.likeSet, now: now), ops: ops.map(Self.opName))
        case .planVersion:
            guard let plan else { return .failed(AssistantRouter.noPlanText) }
            guard let kind = PlanVersionKind.of(action.string("kind")) else { return .failed("I don't know that version.") }
            return applyEdit(PlanVersions.make(kind, plan, bundle, appState.likeSet, now: now), ops: ["constraint"], prefix: "\(kind.label): ")
        case .planUndo:
            let restored = appState.planner.undo()
            AppLog.info(.planner, "plan.undo", "Plan undo", ["depth": .int(appState.planner.history.plans.count), "ok": .bool(restored != nil)])
            refreshLive()
            return restored == nil ? .failed("There's nothing to undo.") : .done(message: "Undid your last plan change.", blocks: [.plan()])
        case .planMake:
            guard let request = action.string("request") else { return .failed("What should the plan be about?") }
            makePlan(request)
            return .done()
        case .checkoff:
            guard let plan else { return .failed(AssistantRouter.noPlanText) }
            guard let id = action.id("item", prefix: "s") else { return .failed("I couldn't find that.") }
            let done = action.bool("done") != false
            setCheckedOff(plan, id, done, source: "tap")
            let name = bundle.scheduleItem(id)?.name ?? "It"
            return .done(message: done ? "Checked off \(name)." : "\(name) isn't checked off any more.")
        case .followLockScreen:
            let on = action.bool("on") != false
            appState.setFollowOnLockScreen(on)
            return .done(message: on ? "Following your day on the Lock Screen." : "Stopped following on the Lock Screen.",
                         blocks: [.setting(action.name.key)])
        case .reminders, .notifications:
            // On iPhone reminders come with the notification opt-in (and its permission).
            let on = action.bool("on") != false
            let name = action.name
            Task { [weak self] in
                let ok = await appState.setNotificationsEnabled(on)
                if on && !ok {
                    self?.append(nil, [.text("Notifications are off for Attnd. Allow them in Settings → Attnd → Notifications to turn this on.")])
                }
            }
            let text: String
            if name == .reminders {
                text = on ? "Reminders are on: 15 minutes before liked and planned items." : "Reminders are off."
            } else {
                text = on ? "Notifications from the organizer are on." : "Notifications from the organizer are off."
            }
            return .done(message: text, blocks: [.setting(name.key)])
        case .addToCalendar:
            if action.bool("plan") == true {
                guard plan != nil else { return .failed(AssistantRouter.noPlanText) }
                return .done(blocks: [.calendar(plan: true)])
            }
            let ids = action.refs("ids").filter { $0.kind == .schedule }.map(\.id)
            guard !CalendarEntries.forItems(ids, bundle).isEmpty else { return .failed("There's nothing with a time to add.") }
            return .done(blocks: [.calendar(ids: ids)])
        case .sharePlan:
            guard plan != nil else { return .failed(AssistantRouter.noPlanText) }
            return .done(blocks: [.share("plan")])
        case .shareItem:
            guard let id = action.id("id", prefix: "s") else { return .failed("I couldn't find that.") }
            return .done(blocks: [.share("item:s\(id)")])
        case .open:
            appState.openAssistantScreen(action.string("screen") ?? "", EntityRef.of(action.params["id"]))
            return .done()
        case .directions:
            guard let location = action.id("location", prefix: "l").flatMap({ appState.location(id: $0) }), location.coordinate != nil else {
                return .failed("That place has no map position.")
            }
            AppLog.debug(.ui, "ui.action", "Directions", ["name": "directions", "id": .int(location.id)])
            WalkingDirections.open(to: location)
            return .done()
        default:
            return .failed("I can't do that here.")
        }
    }

    private static func opName(_ op: PlanOp) -> String {
        switch op {
        case .replace: return "replace"
        case .remove: return "remove"
        case .add: return "add"
        case .move: return "move"
        case .keep: return "keep"
        case .unkeep: return "unkeep"
        default: return "constraint"
        }
    }

    private func applyEdit(_ edit: PlanEdit, ops: [String], prefix: String = "") -> ActionOutcome {
        guard let appState, let bundle = appState.currentBundle else { return .failed("No event.") }
        let started = ContinuousClock.now
        appState.planner.apply(edit.after)
        AppLog.info(.planner, "plan.edit", "Plan edit applied", [
            "ops": .string(ops.joined(separator: ",")), "source": .string(planSource), "applied": true,
            "removed": .int(edit.diff.removed.count), "added": .int(edit.diff.added.count), "moved": .int(edit.diff.moved.count),
            "ms": .int((ContinuousClock.now - started).wholeMilliseconds),
        ])
        refreshLive()
        return .done(message: prefix + AssistantRouter.describe(edit, bundle), blocks: [
            .planDiff(edit.diff),
            .chips([AssistantChip(label: "Show my plan", action: AssistantAction(name: .plan))]),
        ])
    }

    /// A plan edit from the plan rows (My plan, the pinned plan): dispatched as the person's own
    /// button and shown in the conversation with its Undo.
    func edit(_ ops: [PlanOp], label: String) {
        guard let bundle = appState?.currentBundle else { return }
        run(.planEdit(ops, bundle), label: label, source: .manual)
    }

    // MARK: - Siri (spec §6: "What's next on my plan", "Swap my next thing", "I already ate")

    /// The next planned item (not started, not checked off).
    func nextPlanned(now: Date = .now) -> ScheduleItem? {
        guard let appState, let bundle = appState.currentBundle, let plan = appState.planner.plan, !plan.isEmpty else { return nil }
        return LiveAssist.nextPlanned(plan, bundle, now: now)
    }

    /// "Swap my next thing": the next planned item replaced by its best alternative that is
    /// still ahead (the planner's own swap list). Returns the sentence Siri says.
    func swapNext(now: Date = .now) -> String {
        guard let appState, let bundle = appState.currentBundle, let plan = appState.planner.plan, !plan.isEmpty else {
            return AssistantRouter.noPlanText
        }
        guard let next = LiveAssist.nextPlanned(plan, bundle, now: now),
              let planned = plan.items.first(where: { $0.itemId == next.id }) else { return "Nothing else is in your plan." }
        let planIds = Set(plan.itemIds)
        guard let alternative = planned.alternatives.compactMap({ bundle.scheduleItem($0) })
            .first(where: { !planIds.contains($0.id) && ($0.startTime ?? .distantPast) > now }) else {
            return "There's nothing to swap \(next.name) for."
        }
        return siriEdit([.replace(item: next.id, with: alternative.id)], label: "Swap my next thing")
            ?? "Swapped \(next.name) for \(alternative.name)."
    }

    /// "I already ate": no food for 3 hours, the next meal break done.
    func alreadyAte(now: Date = .now) -> String {
        guard appState?.planner.hasPlan == true else { return AssistantRouter.noPlanText }
        return siriEdit([.noFoodUntil(PlanCalendar.truncatedToMinute(now).addingTimeInterval(3 * 3600))], label: "I already ate")
            ?? "Your plan stays the same."
    }

    private func siriEdit(_ ops: [PlanOp], label: String) -> String? {
        guard let bundle = appState?.currentBundle else { return nil }
        planSource = "siri"
        defer { planSource = "assistant" }
        return run(.planEdit(ops, bundle), label: label, source: .manual)
    }

    // MARK: - Plans

    private func makePlan(_ request: String) {
        guard let appState else { return }
        busy = .plan
        Task { [weak self] in
            let plan = await appState.makePlan(request)
            guard let self else { return }
            guard let plan, !plan.isEmpty, let bundle = appState.currentBundle else {
                self.append(nil, [.text(appState.planner.error ?? AppState.nothingFitsMessage)])
                return
            }
            let blocks: [AssistantBlock] = [
                .text("Here's your plan: \(Planner.summary(plan, timeZone: bundle.event.timeZone))."),
                .plan(),
                .chips([
                    AssistantChip(label: "Share my plan", action: AssistantAction(name: .sharePlan)),
                    AssistantChip(label: "Add my plan to calendar", action: .calendarPlan()),
                    AssistantChip(label: PlanVersionKind.chill.label + " version", action: .planVersion(.chill)),
                    AssistantChip(label: "Undo", action: AssistantAction(name: .planUndo)),
                ]),
            ]
            if let ctx = self.context() {
                let validated = BlockValidator.validate(blocks, ctx.blockContext)
                self.append(nil, validated)
                self.remember(bundle.event.id, nil, AssistantTurn(blocks: validated))
            }
            self.refreshLive()
        }
    }

    /// A shared plan link opened for the joined event (API-015): a read-only turn with Use / Merge.
    func openShared(_ pending: PendingSharedPlan) {
        guard let appState, let bundle = appState.currentBundle,
              pending.eventCode.caseInsensitiveCompare(bundle.event.eventCode) == .orderedSame,
              let payload = PlanShare.decode(pending.payload) else { return }
        let known = payload.isReadable ? PlanShare.resolve(payload, bundle) : []
        let single = payload.ids.count == 1
        AppLog.notice(.ui, "share.opened", "Shared link opened", [
            "target": .string(single ? "item" : "plan"), "items": .int(payload.ids.count), "known": .int(known.count),
            "action": "viewed", "joined": true,
        ])
        guard let ctx = context() else { return }
        if known.isEmpty {
            append(nil, [.text("That shared plan's items aren't on the schedule any more.")])
            return
        }
        if single, let id = known.first {
            let ref = EntityRef(kind: .schedule, id: id)
            append(nil, BlockValidator.validate([
                .text("Someone shared **\(ref.name(bundle) ?? "an item")** with you."),
                .itemCard(id: id),
                .chips(AssistantRouter.entityChips(ref, ctx)),
            ], ctx.blockContext))
            return
        }
        appState.planner.addSharedPlan(known, eventId: bundle.event.id)
        append(nil, BlockValidator.validate([
            .text("Someone shared a plan with \(known.count) items."),
            .timeline(ids: known, title: "Shared plan"),
        ], ctx.blockContext), shared: SharedOffer(ids: known, day: payload.day))
    }

    /// "Use this plan" (merge false) or "Merge with mine" on a shared plan turn.
    func useShared(turnId: Int, merge: Bool) {
        guard let appState, let bundle = appState.currentBundle,
              let t = turns.firstIndex(where: { $0.id == turnId }), let offer = turns[t].shared, !offer.handled else { return }
        let eventId = bundle.event.id
        let now = Date.now
        let own = appState.likeSet
        let plan = merge
            ? SharedPlans.merge(appState.planner.sharedPlans(eventId), own, bundle, current: appState.planner.plan, now: now)
            : SharedPlans.use(offer.ids, day: offer.day, bundle, own, now: now)
        AppLog.notice(.ui, "share.opened", merge ? "Shared plan merged" : "Shared plan used", [
            "target": "plan", "items": .int(offer.ids.count), "known": .int(offer.ids.count),
            "action": .string(merge ? "merge" : "use"), "joined": false,
        ])
        guard let plan else {
            append(nil, [.text("Nothing in that plan is still ahead.")])
            return
        }
        appState.planner.apply(plan)
        turns[t].shared?.handled = true
        let summary = Planner.summary(plan, timeZone: bundle.event.timeZone)
        let blocks: [AssistantBlock] = [
            .text(merge ? "Merged: \(summary)." : "Using the shared plan: \(summary)."),
            .plan(),
            .chips([AssistantChip(label: "Undo", action: AssistantAction(name: .planUndo))]),
        ]
        append(nil, context().map { BlockValidator.validate(blocks, $0.blockContext) } ?? blocks)
        refreshLive()
    }

    /// The link of a `share` block ("plan" or "item:s12"), logged as `share.created` once shown.
    func shareLink(_ target: String) -> (url: URL, title: String, items: Int)? {
        guard let appState, let bundle = appState.currentBundle else { return nil }
        if target == "plan" {
            guard let plan = appState.planner.plan, !plan.isEmpty, let url = URL(string: PlanShare.planLink(plan, bundle)) else { return nil }
            let day = plan.days.first { !$0.items.isEmpty }.map { "My plan for \($0.date.weekdayName)" } ?? "My plan"
            return (url, day, plan.itemIds.count)
        }
        guard let ref = EntityRef.parse(String(target.dropFirst(5))), ref.kind == .schedule,
              let url = URL(string: PlanShare.itemLink(ref.id, bundle)) else { return nil }
        return (url, ref.name(bundle) ?? bundle.event.name, 1)
    }

    func logShare(_ target: String, url: URL, items: Int) {
        AppLog.info(.ui, "share.created", "Share link made", [
            "target": .string(target == "plan" ? "plan" : "item"), "items": .int(items),
            "payload_len": .int(url.lastPathComponent.count), "via": "share_sheet",
        ])
    }

    /// "Ask about this" from a detail screen: "Tell me about X" (the model when available, else
    /// the item's card and chips).
    func askAbout(_ ref: EntityRef) {
        guard let ctx = context(), let text = AssistantFlow.askAbout(ref, ctx.bundle) else { return }
        if ctx.modelAvailable {
            submit(text, forced: .ask)
        } else {
            finish(text, AssistantFlow.aboutTurn(ref, ctx), .rules, .search, ContinuousClock.now, ctx)
        }
    }

    /// Text typed elsewhere (Siri's search, onboarding's question): into the input bar, or run.
    func request(_ text: String, send: Bool) {
        if send {
            submit(text, forced: modelAvailable ? .ask : nil)
        } else {
            draft = text
            focusSerial += 1
        }
    }

    // MARK: - Live (spec §6)

    private func setCheckedOff(_ plan: Plan, _ itemId: Int, _ done: Bool, source: String, minutesNear: Int? = nil) {
        guard let appState else { return }
        var updated = plan
        if done { updated.checkedOff.insert(itemId) } else { updated.checkedOff.remove(itemId) }
        guard updated != plan else { return }
        appState.planner.update(updated)
        var fields: LogFields = ["item_id": .int(itemId), "source": .string(source), "done": .bool(done)]
        if let minutesNear { fields["minutes_near"] = .int(minutesNear) }
        AppLog.info(.live, "live.checkoff", done ? "Checked off" : "Check-off removed", fields)
    }

    /// A check toggle on a plan row (My plan, the assistant's plan block).
    func toggleCheckOff(_ itemId: Int) {
        guard let plan = appState?.planner.plan else { return }
        setCheckedOff(plan, itemId, !plan.checkedOff.contains(itemId), source: "tap")
        refreshLive()
    }

    /// A position sample (only while a screen already tracks the location; never a new prompt).
    func onLocation(_ point: Coordinate?, at: Date = .now) {
        guard let point, eventId != nil, !ScreenshotMode.isActive else { return }
        samples.append(LocationSample(point: point, at: at))
        let cutoff = at.addingTimeInterval(-Self.sampleWindow)
        samples.removeAll { $0.at < cutoff }
        if samples.count > Self.maxSamples { samples.removeFirst(samples.count - Self.maxSamples) }
        if let appState, let bundle = appState.currentBundle, var plan = appState.planner.plan, !plan.isEmpty {
            for id in LiveAssist.checkOffs(plan, bundle, samples: samples, now: at).sorted() {
                setCheckedOff(plan, id, true, source: "auto", minutesNear: Int(LiveAssist.checkoffDwell / 60))
                plan = appState.planner.plan ?? plan
            }
        }
        refreshLive(at)
    }

    func dismissSkipped(_ chip: AssistantChip) {
        guard let bundle = appState?.currentBundle else { return }
        for op in chip.action.ops(bundle, now: .now) ?? [] {
            if case .remove(let item) = op { dismissedSkips.insert(item) }
        }
        refreshLive()
    }

    /// Recomputes the live hints (on samples, plan / like changes and once a minute while visible).
    func refreshLive(_ now: Date = .now) {
        guard let appState, let bundle = appState.currentBundle, !ScreenshotMode.isActive else {
            if !live.isEmpty { live = LiveHints() }
            return
        }
        let plan = appState.planner.plan.flatMap { $0.isEmpty ? nil : $0 }
        let hints = LiveHintRules.of(plan, bundle, appState.likeSet, now: now, user: userPoint(now: now), samples: samples, dismissed: dismissedSkips)
        if let late = hints.runningLate, lateLoggedFor != late.itemId {
            lateLoggedFor = late.itemId
            var fields: LogFields = [
                "item_id": .int(late.itemId), "walk_min": .int(late.walkMinutes),
                "action": .string(late.chips.count > 1 ? "swap_offered" : "shown"),
            ]
            if let start = bundle.scheduleItem(late.itemId)?.startTime { fields["minutes_left"] = .int(Int(start.timeIntervalSince(now) / 60)) }
            AppLog.notice(.live, "live.running_late", "Running late", fields)
        }
        if hints != live { live = hints }
    }
}

/// The dispatcher's executor: `ActionDispatcher` is plain (non-isolated) code, always called on
/// the main actor here.
private struct AssistantExecutor: ActionExecutor {
    let controller: AssistantController

    func execute(_ action: AssistantAction) -> ActionOutcome {
        MainActor.assumeIsolated { controller.execute(action) }
    }
}

// MARK: - AppState glue

extension AppState {
    /// The current event's likes as the assistant's `LikeSet`.
    var likeSet: LikeSet {
        LikeSet(locations: personal.heartedLocations, scheduleItems: personal.heartedScheduleItems)
    }

    /// The assistant is the floating button's target (full app, not in screenshot mode, where the
    /// plain search sheet is shown).
    static var assistantEnabled: Bool { !ScreenshotMode.isActive }

    /// `open(screen, id?)`: a manual screen (closing the assistant when the screen is a tab).
    func openAssistantScreen(_ screen: String, _ ref: EntityRef?) {
        func target(_ ref: EntityRef) -> SearchTarget {
            switch ref.kind {
            case .schedule: return .scheduleItem(ref.id)
            case .location: return .location(ref.id)
            case .update: return .notification(ref.id)
            }
        }
        func tab(_ tab: EventTab) {
            guard tabs.contains(tab) else { return }
            presentedSheet = nil
            selectedTab = tab
        }
        switch screen {
        case "map":
            if let ref, ref.kind == .location {
                if tabs.contains(.map) { showOnMap(locationId: ref.id) } else { navigate(to: .location(ref.id)) }
            } else {
                tab(.map)
            }
        case "locations", "schedule", "updates":
            if let ref {
                navigate(to: target(ref))
            } else {
                tab(screen == "locations" ? .locations : screen == "schedule" ? .schedule : .notifications)
            }
        case "flyer": tab(.flyer)
        case "options": presentedSheet = .options
        case "tour": showTour()
        case "plan": showMyPlan()
        default: break
        }
    }
}
