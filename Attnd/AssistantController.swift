// AssistantController.swift
// Attnd (app + App Clip)
//
// The event assistant at runtime behind the plan page (the floating "My plan" button over every
// tab, AssistantView.swift / PlanView.swift, rules in PlanPage.swift and PlanPanel.swift; iOS,
// planner_view_spec Nov 19, 2026 — only with Apple Intelligence's on-device model; Android keeps
// the plan tab spec's My plan tab; the assistant spec's router, blocks, actions, edits, undo and
// live rules are unchanged and shared):
//
//   - The page: `pageOpen` (a full-screen cover over the tabs) and `pagePath` (its own stack:
//     items tapped on the page push their detail there). Links, Siri and notifications close it
//     (`closePage`) so the item's tab is in view; a new proposal opens it so its preview shows.
//   - Phones show only the last answer (`answer`) in a small pane above the text box; wide
//     windows (iPhone Duo unfolded) add a chat column with this session's turns (`transcript`,
//     in memory, ≤ 30).
//   - Turns: no Search / Ask / Plan toggle. Every typed turn goes through `PlanProposals.swap`, the
//     rule-based `AssistantRouter` or — when Apple Intelligence's on-device model is available and
//     `AssistantFlow.path` says so — the model (`EventAssistant.assistantTurn`, streamed; any
//     error or invalid output → the router's answer, `AssistantModel.resolve`).
//   - Search results' inline actions ("Add to plan", "Plan around this"; `PlanPanel`) become
//     proposals like typed edits (`addToPlan`, `planAround`).
//   - Plan edits (router or model, pick chips, like clash, shared plan links) are not applied at
//     once: they become `proposal` (PlanProposal.swift), previewed in the timeline (suggested /
//     crossed-out rows, diff pill). An option row, the pill's Apply or a typed "do it" / "the
//     second one" applies it (`ActionDispatcher`, as the person's own choice) and shows the
//     Undo pill for ~8 s (`undoPill`; "undo" typed works too, ≤ 20 versions in `PlanStore`).
//   - Everything else (questions, search, why-not, now/next, settings, likes) is the **answer
//     card** (`answer`, the last turn only, its blocks compact above the input bar). The model's
//     conversation history is kept as before (`pref.assistantConversation.<id>`).
//   - Live (§6): position samples while a screen tracks the location (never a new permission
//     prompt) → auto check-off, skipped items; running late, gap fillers, organizer changes and
//     the day's recap → `live` (`LiveHintRules`), shown in the timeline.
//
// Logging: `assistant.turn` / `assistant.block` / `assistant.action`, `plan.edit` /
// `plan.undo`, `live.running_late` / `live.checkoff`, `share.created` / `share.opened` (never
// the typed text in production: `LogRedaction.textFields`). Not in screenshot mode.

import Foundation
import Observation
import SwiftUI

@MainActor
@Observable
final class AssistantController {

    /// The answer card: the last non-edit turn.
    struct Turn: Identifiable, Hashable {
        var id: Int
        /// What the user typed or the chip they tapped; nil for a turn the app added.
        var input: String?
        var blocks: [AssistantBlock]
        var source: TurnSource = .rules
        /// A write applied with Undo (like, check-off): Undo / Apply act on it.
        var applied: AssistantAction? = nil
        var undone = false
        /// Indexes of `confirm` blocks already answered (and how).
        var answered: [Int: Bool] = [:]
        /// The model is still writing this turn.
        var streaming = false
    }

    /// "Undo" for ~8 s after a plan change was applied.
    struct UndoPill: Identifiable, Hashable {
        var id: Int
        var text: String
    }

    /// The answer card (nil: none shown).
    private(set) var answer: Turn?
    /// The plan edit shown in the timeline, waiting to be applied (nil: none). A new one opens
    /// the plan page, so its preview is in view.
    private(set) var proposal: PlanProposal? {
        didSet {
            guard proposal != nil, oldValue != proposal, appState?.currentEvent != nil, !pageOpen else { return }
            appState?.showPlanPanel()
        }
    }
    /// This session's turns for the wide layout's chat column (≤ 30, not stored).
    private(set) var transcript: [Turn] = []
    private static let maxTranscript = 30
    /// The Undo pill after a plan change (nil: none).
    private(set) var undoPill: UndoPill?
    /// The path of the turn being worked on (busy indicator in the input bar).
    private(set) var busy: TurnPath?
    /// The input bar's text. A proposal stays while typing (so "the second one" can answer it);
    /// sending anything that isn't an answer to it clears it.
    var draft = ""
    /// The plan page is shown (the floating "My plan" button), over whichever tab is shown.
    private(set) var pageOpen = false
    /// The plan page's own navigation stack (item details pushed from the page).
    var pagePath = NavigationPath()
    /// Incremented to put the keyboard down.
    private(set) var blurSerial = 0
    @ObservationIgnored private var focusPending = false
    private(set) var live = LiveHints()
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

    /// The assistant of `eventId` (AppState, with the event's hearts and plan).
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
        answer = nil
        proposal = nil
        undoPill = nil
        pageOpen = false
        pagePath = NavigationPath()
        transcript = []
        focusPending = false
        draft = ""
        guard eventId != nil, appState != nil, !ScreenshotMode.isActive else {
            live = LiveHints()
            return
        }
        refreshLive()
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
            // Plans are made with or without the model (plan tab spec).
            canPlan: AppState.plannerAvailable,
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

    // MARK: - Screen state

    /// The answer card goes away (typing again, swipe down, the close button).
    func dismissAnswer() {
        guard answer != nil else { return }
        if answer?.streaming == true { modelTask?.cancel() }
        answer = nil
    }

    func clearProposal() {
        proposal = nil
    }

    /// The "My plan" button (and every "show my plan"): opens the plan page. Without a plan the
    /// keyboard comes up.
    func openPage() {
        guard !pageOpen else { return }
        AppLog.debug(.ui, "ui.screen", "Plan page", ["name": "plan"])
        pageOpen = true
        if appState?.planner.hasPlan != true { focusInput() }
    }

    /// The page's Close button, a link elsewhere, the model going away. What was typed stays.
    func closePage() {
        guard pageOpen else { return }
        pageOpen = false
        proposal = nil
        pagePath = NavigationPath()
        blurSerial += 1
    }

    /// The cover's own dismissal (swipe, Esc) as a binding.
    func setPageOpen(_ open: Bool) {
        if open { openPage() } else { closePage() }
    }

    /// The Undo pill's time is up (only the pill with `id`).
    func expireUndo(_ id: Int) {
        if undoPill?.id == id { undoPill = nil }
    }

    /// The preview of the current proposal (nil: none).
    var preview: PlanPreview? {
        guard let proposal, let bundle = appState?.currentBundle else { return nil }
        return PlanPreview.of(proposal, plan: appState?.planner.plan, bundle)
    }

    // MARK: - Turns

    /// Enter / send: answers a pending proposal ("do it", "the second one", "no"), or runs a turn.
    /// The path is the app's choice (`AssistantFlow.path`); `overridden` is only for turns the app
    /// starts itself (Ask about this, a question from onboarding).
    func submit(_ input: String, forced overridden: TurnPath? = nil) {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let ctx = context() else { return }
        if let proposal, !text.isEmpty {
            switch ProposalReply.parse(text, options: proposal.options.count) {
            case .apply(let index):
                applyProposal(index)
                return
            case .cancel:
                clearProposal()
                AppLog.debug(.ui, "ui.action", "Plan proposal dismissed", ["name": "proposal_cancel"])
                return
            case .none:
                clearProposal()
            }
        }
        let path = overridden
        let started = ContinuousClock.now
        if text.isEmpty {
            finish(nil, AssistantRouter.route("", ctx).turn, .rules, .empty, started, ctx)
            return
        }
        if path != .search && path != .ask, let swap = PlanProposals.swap(text, ctx) {
            switch swap {
            case .proposal(let p): propose(p, input: text, started, ctx)
            case .message(let message): finish(text, AssistantTurn(blocks: [.text(message)]), .rules, .planEdit, started, ctx)
            }
            return
        }
        let routed = AssistantRouter.route(text, ctx)
        switch AssistantFlow.path(routed.intent, text, modelAvailable: ctx.modelAvailable, forced: path) {
        case .search:
            if path == .search {
                finish(text, AssistantFlow.searchTurn(text, ctx), .rules, .search, started, ctx)
            } else if let p = PlanProposals.from(routed: routed, ctx) {
                propose(p, input: text, started, ctx)
            } else {
                finish(text, routed.turn, .rules, routed.intent, started, ctx)
            }
        case .plan:
            if let p = PlanProposals.from(routed: routed, ctx) {
                propose(p, input: text, started, ctx)
            } else {
                finish(text, AssistantFlow.planTurn(text, routed, ctx), .rules, routed.intent, started, ctx)
            }
        case .ask:
            ask(text, ctx, started)
        }
    }

    /// Shows a plan edit as the timeline's preview (nothing is applied yet).
    private func propose(_ p: PlanProposal, input: String?, _ started: ContinuousClock.Instant, _ ctx: RouterContext,
                         source: TurnSource = .rules) {
        busy = nil
        answer = nil
        proposal = p
        if let input { record(Turn(id: nextId, input: input, blocks: [.text(p.text)])); nextId += 1 }
        var fields: LogFields = [
            "path": .string(source == .model ? "model" : "rules"), "intent": "plan_edit",
            "ms": .int((ContinuousClock.now - started).wholeMilliseconds), "blocks": 0, "fallback": false,
        ]
        if let input { fields.merge(LogRedaction.textFields(input)) { _, new in new } }
        AppLog.info(.assistant, "assistant.turn", "Assistant turn (plan proposal)", fields)
        if let input { remember(ctx.bundle.event.id, input, AssistantTurn(blocks: [.text(p.text)])) }
    }

    /// The model path: streamed blocks into the answer card, then the validated turn (or the
    /// router's on invalid output); a plan edit becomes a proposal.
    private func ask(_ text: String, _ ctx: RouterContext, _ started: ContinuousClock.Instant) {
        modelTask?.cancel()
        guard let appState else { return }
        let eventId = ctx.bundle.event.id
        let id = nextId
        nextId += 1
        answer = Turn(id: id, input: text, blocks: [], source: .model, streaming: true)
        busy = .ask
        let retrieved = AssistantModel.retrieve(text, ctx)
        let prompt = AssistantModel.prompt(text, ctx, appState.planner.conversation(eventId), retrieved)
        modelTask = Task { [weak self] in
            var raw: String?
            var toolCalls = 0
            do {
                let reply = try await EventAssistant.assistantTurn(prompt, bundle: ctx.bundle, now: ctx.now) { [weak self] partial in
                    guard let self, self.answer?.id == id else { return }
                    let shown = AssistantModel.completeBlocks(partial, ctx).filter { !$0.isChips }
                    if shown != self.answer?.blocks { self.answer?.blocks = shown }
                }
                raw = reply.raw
                toolCalls = reply.toolCalls
            } catch is CancellationError {
                if self?.answer?.id == id { self?.answer = nil }
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
            if self.answer?.id == id { self.answer = nil }
            if let p = PlanProposals.from(actions: resolved.turn.actions, ctx)
                ?? resolved.routed.flatMap({ PlanProposals.from(routed: $0, ctx) }) {
                self.propose(p, input: text, started, ctx, source: resolved.source)
                return
            }
            self.finish(text, resolved.turn, resolved.source, resolved.routed?.intent ?? .question, started, ctx,
                        fallback: resolved.source == .rules, modelTried: true, toolCalls: toolCalls)
        }
    }

    /// Shows a finished (non-edit) turn as the answer card, runs its actions, logs it.
    private func finish(
        _ input: String?, _ turn: AssistantTurn, _ source: TurnSource, _ intent: AssistantIntent,
        _ started: ContinuousClock.Instant, _ ctx: RouterContext,
        fallback: Bool = false, modelTried: Bool = false, toolCalls: Int = 0
    ) {
        let actionSource: ActionSource = source == .model ? .model : .rules
        var blocks = turn.blocks
        var applied: AssistantAction?
        for action in turn.actions where !PlanProposals.isPlanWrite(action) {
            let result = runQuietly(action, actionSource)
            if let action = result.applied { applied = action }
            if action.name == .planUndo { undoPill = nil }
            // The router's blocks already show the result; the model's may not: add what it lacks.
            if source == .model {
                let types = Set(blocks.map(\.type))
                blocks += result.blocks.filter { !types.contains($0.type) }
                if result.blocks.isEmpty, let message = result.message { blocks.append(.text(message)) }
            }
        }
        // A like that clashes with the plan: "Add to plan instead of X?" is an inline preview.
        if proposal == nil, let clash = clashProposal(blocks, ctx) {
            proposal = clash
        }
        if proposal != nil { blocks = blocks.map(Self.withoutPlanChips).filter(Self.isNotEmptyChips) }
        let validated = context().map { BlockValidator.validate(blocks, $0.blockContext) } ?? blocks
        show(input, validated, source: source, applied: applied)
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

    /// A like-clash chip in the turn ("Add to plan instead of X?") as a proposal.
    private func clashProposal(_ blocks: [AssistantBlock], _ ctx: RouterContext) -> PlanProposal? {
        for case .chips(let chips) in blocks {
            if let chip = chips.first(where: { PlanProposals.isPlanWrite($0.action) && $0.label.hasPrefix("Add to plan instead of") }) {
                return PlanProposals.from(chips: [chip], text: chip.label, context() ?? ctx)
            }
        }
        return nil
    }

    private static func isNotEmptyChips(_ block: AssistantBlock) -> Bool {
        if case .chips(let chips) = block { return !chips.isEmpty }
        return true
    }

    private static func withoutPlanChips(_ block: AssistantBlock) -> AssistantBlock {
        if case .chips(let chips) = block { return .chips(chips.filter { !$0.label.hasPrefix("Add to plan instead of") }) }
        return block
    }

    /// The answer card shows `blocks` (replacing the last one).
    private func show(_ input: String?, _ blocks: [AssistantBlock], source: TurnSource = .rules, applied: AssistantAction? = nil) {
        // A plan being made keeps its progress (makePlan clears it).
        if busy != .plan || appState?.planner.isPlanning != true { busy = nil }
        if blocks.isEmpty { return }
        for block in blocks {
            AppLog.debug(.assistant, "assistant.block", "Block \(block.type)", ["type": .string(block.type), "ids": .int(AssistantFlow.refs(block).count)])
        }
        answer = Turn(id: nextId, input: input, blocks: blocks, source: source, applied: applied)
        nextId += 1
        if let answer { record(answer) }
    }

    /// Adds a turn to the chat column (replacing one with the same id).
    private func record(_ turn: Turn) {
        transcript.removeAll { $0.id == turn.id }
        transcript.append(turn)
        if transcript.count > Self.maxTranscript { transcript.removeFirst(transcript.count - Self.maxTranscript) }
    }

    /// The model's conversation: the user's text and what the assistant answered (text only).
    private func remember(_ eventId: Int, _ input: String?, _ turn: AssistantTurn) {
        guard let appState, let bundle = appState.currentBundle else { return }
        var conversation = appState.planner.conversation(eventId)
        if let input { conversation = conversation.with(ConversationTurn(fromUser: true, text: input)) }
        conversation = conversation.with(ConversationTurn(fromUser: false, text: AssistantFlow.replyText(turn, bundle)))
        appState.planner.setConversation(conversation, eventId: eventId)
    }

    // MARK: - Proposals

    /// Applies option `index` of the shown proposal (an option row, the pill, "do it", "the
    /// second one"): dispatched as the person's own choice; the screen stays where it is and the
    /// Undo pill shows.
    func applyProposal(_ index: Int) {
        guard let proposal, index >= 0, index < proposal.options.count, let appState, let ctx = context() else { return }
        let option = proposal.options[index]
        self.proposal = nil
        switch option.apply {
        case .action(let action):
            planSource = "plan"
            defer { planSource = "assistant" }
            switch dispatcher.dispatch(action, context: actionContext(ctx), source: .manual, confirmed: true) {
            case .executed(.done(let message, _), _):
                logAction(action, "applied", confirm: .chip)
                showUndo(message ?? proposal.text)
            case .executed(.failed(let reason), _), .rejected(let reason):
                logAction(action, "failed")
                show(nil, [.text(rejectText(reason))])
            case .needsConfirmation(let confirm):
                show(nil, [confirm])
            }
        case .newPlan(let plan):
            appState.planner.apply(plan)
            AppLog.info(.planner, "plan.edit", "New plan from an inline action", [
                "ops": "add", "source": "plan", "applied": true, "removed": 0,
                "added": .int(plan.itemIds.count), "moved": 0,
            ])
            refreshLive()
            showUndo("Here's your plan: \(Planner.summary(plan, timeZone: appState.timeZone)).")
        case .plan(let plan):
            appState.planner.apply(plan)
            AppLog.notice(.ui, "share.opened", "Shared plan applied", [
                "target": "plan", "items": .int(plan.itemIds.count), "known": .int(plan.itemIds.count),
                "action": .string(index == 0 ? "use" : "merge"), "joined": false,
            ])
            refreshLive()
            showUndo(index == 0 ? "Using the shared plan." : "Merged with your plan.")
        }
    }

    private func showUndo(_ text: String) {
        undoPill = UndoPill(id: nextId, text: text.replacingOccurrences(of: "**", with: ""))
        nextId += 1
    }

    /// The Undo pill: the previous plan version back.
    func undoLastChange() {
        undoPill = nil
        guard let ctx = context() else { return }
        _ = dispatcher.dispatch(AssistantAction(name: .planUndo), context: actionContext(ctx), source: .manual)
    }

    /// A plan row's own edit (its menu: Remove, Keep, Later showing): previewed like a typed one.
    func proposeEdit(_ ops: [PlanOp], label: String) {
        guard let ctx = context(), let p = PlanProposals.from(action: .planEdit(ops, ctx.bundle), label: label, ctx) else { return }
        answer = nil
        proposal = p
    }

    /// A search result's "Add to plan" / a place's "Plan around this" (PlanPanel.swift): the
    /// in-place proposal (add, replace on a clash, or a new plan), or a short answer.
    func addToPlan(_ itemId: Int) {
        guard let ctx = context() else { return }
        inline(PlanPanel.addToPlan(itemId, ctx), "add_to_plan", itemId)
    }

    func planAround(_ locationId: Int) {
        guard let ctx = context() else { return }
        inline(PlanPanel.planAround(locationId, ctx), "plan_around", locationId)
    }

    private func inline(_ change: PanelPlanChange, _ name: String, _ id: Int) {
        AppLog.debug(.ui, "ui.action", "Inline plan action", ["name": .string(name), "id": .int(id)])
        switch change {
        case .proposal(let p):
            answer = nil
            proposal = p
        case .message(let message):
            show(nil, [.text(message)])
        }
    }

    /// A plan row's Swap: its alternatives as option rows under it.
    func proposeSwap(_ itemId: Int) {
        guard let ctx = context(), let name = ctx.bundle.scheduleItem(itemId)?.name else { return }
        switch PlanProposals.swap("swap \(name)", ctx) {
        case .proposal(let p)?:
            answer = nil
            proposal = p
        case .message(let message)?:
            show(nil, [.text(message)])
        case nil:
            show(nil, [.text("There's nothing to swap \(name) for.")])
        }
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

    /// A turn's own action: dispatched with its source; the result is returned, not shown.
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

    /// A chip, a card button or a live hint: runs `action` and shows its result in the answer
    /// card labelled `label`. A plan edit from a chip in the answer card is previewed first
    /// (`propose`); a live hint's or the person's own button (`.manual`) applies at once with the
    /// Undo pill. Reads render with the router's layout. Returns the outcome's message.
    @discardableResult
    func run(_ action: AssistantAction, label: String?, source: ActionSource = .rules, confirmed: Bool = false) -> String? {
        guard let ctx = context() else { return nil }
        if !action.name.mutates && action.name.result != .navigation {
            let blocks = AssistantRouter.renderRead(action, ctx)
            show(label, blocks.isEmpty ? [.text("Nothing to show for that.")] : blocks)
            logAction(action, "applied")
            if action.name == .search, label != nil { appState?.track(.search) }
            remember(ctx.bundle.event.id, label, AssistantTurn(blocks: answer?.blocks ?? []))
            return nil
        }
        if source == .manual && planSource == "assistant" { planSource = "plan" }
        defer { planSource = "assistant" }
        switch dispatcher.dispatch(action, context: actionContext(ctx), source: source, confirmed: confirmed) {
        case .rejected(let reason):
            logAction(action, "failed")
            let text = rejectText(reason)
            show(label, [.text(text)])
            return text
        case .needsConfirmation(let confirm):
            show(label, [confirm])
            return nil
        case .executed(let outcome, let undo):
            switch outcome {
            case .done(let message, let blocks):
                logAction(action, confirmed ? "confirmed" : "applied", confirm: confirmed ? .chip : action.name.confirm)
                if PlanProposals.isPlanWrite(action) || action.name == .planUndo {
                    // Plan changes show in the timeline itself, with the Undo pill.
                    if action.name != .planUndo { showUndo(message ?? "Plan changed.") } else { undoPill = nil }
                    if answer?.streaming != true { answer = nil }
                    return message
                }
                var all = (message.map { [AssistantBlock.text($0)] } ?? []) + blocks
                if let clash = clashProposal(all, context() ?? ctx) {
                    proposal = clash
                    all = all.map(Self.withoutPlanChips)
                }
                let validated = BlockValidator.validate(all, (context() ?? ctx).blockContext)
                show(label, validated, applied: undo != nil ? action : nil)
                if !validated.isEmpty { remember(ctx.bundle.event.id, label, AssistantTurn(blocks: validated)) }
                return message
            case .failed(let reason):
                logAction(action, "failed")
                show(label, [.text(reason)])
                return reason
            }
        }
    }

    /// A chip in the answer card: a plan edit is previewed in the timeline; anything else runs.
    func chip(_ chip: AssistantChip) {
        if PlanProposals.isPlanWrite(chip.action), let ctx = context(),
           let p = PlanProposals.from(chips: [chip], text: chip.label, ctx) {
            answer = nil
            proposal = p
            return
        }
        if chip.action.name == .planMake, let request = chip.action.string("request") {
            answer = nil
            makePlan(request)
            return
        }
        run(chip.action, label: chip.label)
    }

    /// A live hint's chip (running late, gap filler, skipped): applied at once with Undo.
    func hintChip(_ chip: AssistantChip) {
        if PlanProposals.isPlanWrite(chip.action) {
            run(chip.action, label: chip.label, source: .manual)
        } else {
            run(chip.action, label: chip.label)
        }
    }

    /// A `confirm` block's Yes / Not Now (in the answer card).
    func answerConfirm(turnId: Int, index: Int, yes: Bool) {
        guard var turn = answer, turn.id == turnId, turn.answered[index] == nil,
              index < turn.blocks.count, case .confirm(let action, _) = turn.blocks[index] else { return }
        turn.answered[index] = yes
        answer = turn
        if yes {
            run(action, label: nil, source: .rules, confirmed: true)
        } else {
            logAction(action, "declined", confirm: .chip)
            show(nil, [.text("OK, nothing changed.")])
        }
    }

    /// The answer card's Undo: the applied write's inverse (`ActionRegistry.undo(for:)`).
    func undo(turnId: Int) {
        guard let turn = answer, turn.id == turnId, let applied = turn.applied, !turn.undone,
              let inverse = ActionRegistry.undo(for: applied), let ctx = context() else { return }
        if case .executed(.done, _) = dispatcher.dispatch(inverse, context: actionContext(ctx), source: .manual) {
            logAction(applied, "undone")
            if answer?.id == turnId { answer?.undone = true }
        }
    }

    /// Apply again after an Undo.
    func reapply(turnId: Int) {
        guard let turn = answer, turn.id == turnId, let applied = turn.applied, turn.undone,
              let ctx = context() else { return }
        if case .executed(.done, _) = dispatcher.dispatch(applied, context: actionContext(ctx), source: .manual) {
            logAction(applied, "applied")
            if answer?.id == turnId { answer?.undone = false }
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
                    self?.show(nil, [.text("Notifications are off for Attnd. Allow them in Settings → Attnd → Notifications to turn this on.")])
                }
            }
            let text: String
            if name == .reminders {
                text = on ? "Reminders are on: 15 minutes before liked and planned items." : "Reminders are off."
            } else {
                text = on ? "Notifications from the organizer are on." : "Notifications from the organizer are off."
            }
            return .done(message: text, blocks: [.setting(name.key)])
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

    /// Makes a plan in place (progress in the timeline; the model reads the request when available).
    func makePlan(_ request: String) {
        guard let appState else { return }
        busy = .plan
        proposal = nil
        Task { [weak self] in
            let plan = await appState.makePlan(request)
            guard let self else { return }
            self.busy = nil
            guard let plan, !plan.isEmpty, let bundle = appState.currentBundle else {
                self.show(nil, [.text(appState.planner.error ?? AppState.nothingFitsMessage)])
                return
            }
            self.answer = nil
            self.showUndo("Here's your plan: \(Planner.summary(plan, timeZone: bundle.event.timeZone)).")
            self.remember(bundle.event.id, nil, AssistantTurn(blocks: [.text("Made a plan: \(Planner.summary(plan, timeZone: bundle.event.timeZone)).")]))
            self.refreshLive()
        }
    }

    /// A shared plan link opened for the joined event (API-015): a proposal with "Use This Plan" /
    /// "Merge with Mine" (one shared item: its card in the answer card).
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
            show(nil, [.text("That shared plan's items aren't on the schedule any more.")])
            return
        }
        if single, let id = known.first {
            let ref = EntityRef(kind: .schedule, id: id)
            show(nil, BlockValidator.validate([
                .text("Someone shared **\(ref.name(bundle) ?? "an item")** with you."),
                .itemCard(id: id),
                .chips(AssistantRouter.entityChips(ref, ctx)),
            ], ctx.blockContext))
            return
        }
        appState.planner.addSharedPlan(known, eventId: bundle.event.id)
        let now = Date.now
        let own = appState.likeSet
        let current = appState.planner.plan.flatMap { $0.isEmpty ? nil : $0 }
        guard let use = SharedPlans.use(known, day: payload.day, bundle, own, now: now) else {
            show(nil, [.text("Nothing in that plan is still ahead.")])
            return
        }
        let merged = current == nil ? nil
            : SharedPlans.merge(appState.planner.sharedPlans(bundle.event.id), own, bundle, current: current, now: now)
        answer = nil
        proposal = PlanProposals.shared(use: use, merged: merged, current: current, eventId: bundle.event.id, bundle)
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
    /// the item's card and chips) in the answer card.
    func askAbout(_ ref: EntityRef) {
        guard let ctx = context(), let text = AssistantFlow.askAbout(ref, ctx.bundle) else { return }
        proposal = nil
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
            focusInput()
        }
    }

    /// Puts the keyboard up on the plan panel's bar (now, or as soon as the panel is shown).
    func focusInput() {
        focusPending = true
        focusSerial += 1
    }

    /// The panel takes a pending keyboard request (true once per request).
    func consumeFocusRequest() -> Bool {
        guard focusPending, pageOpen else { return false }
        focusPending = false
        return true
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

    /// The assistant runs (full app, not in screenshot mode, with the on-device model): the plan page.
    static var assistantEnabled: Bool { hasPlanPanel }

    /// `open(screen, id?)`: a manual screen (its own tab; the plan panel collapses).
    func openAssistantScreen(_ screen: String, _ ref: EntityRef?) {
        func target(_ ref: EntityRef) -> SearchTarget {
            switch ref.kind {
            case .schedule: return .scheduleItem(ref.id)
            case .location: return .location(ref.id)
            case .update: return .notification(ref.id)
            }
        }
        func tab(_ tab: EventTab) {
            guard shows(tab) else { return }
            presentedSheet = nil
            assistant.closePage()
            select(tab)
        }
        switch screen {
        case "map":
            if let ref, ref.kind == .location {
                if shows(.map) { showOnMap(locationId: ref.id) } else { navigate(to: .location(ref.id)) }
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
        case "options":
            guard assistant.pageOpen else {
                presentedSheet = .options
                return
            }
            assistant.closePage()
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(450))
                self.presentedSheet = .options
            }
        case "tour": showTour()
        case "plan": showMyPlan()
        default: break
        }
    }
}
