// AssistantEval.swift
// AttndTests
//
// The event assistant question eval (attnd-web docs/assistant_eval/README.md): the shared,
// platform-neutral catalogue of what attendees ask (questions.json) run against the DEMO bundle
// (demo_bundle.json), both embedded in AssistantEvalData.swift by
// scripts/assistant_eval/sync_data.py. One runner for both modes:
//   - router: the rule-based path only (no model), deterministic; runs in XCTest and the Linux
//     SwiftPM harness (scripts/linux_harness.sh).
//   - model: the real on-device path (`EventAssistant.assistantTurn`), only where Apple
//     Intelligence is available (AssistantEvalModelTests.swift).
// Each question runs in a fresh conversation; its `follows` questions run first (ungraded), so
// "add it" has something to refer to. A turn mirrors `AssistantController.submit`: a pending
// proposal's reply, "swap …", sequences, the router, `AssistantFlow.path`, the model (router as
// fallback). Actions are recorded, never executed (My schedule stays the fixture's).

import Foundation
@testable import Attnd

// MARK: - Catalogue

struct EvalExpect: Decodable {
    var entitiesAny: [String]?
    var entitiesAll: [String]?
    var entitiesNone: [String]?
    var componentsAny: [String]?
    var chipsAny: [String]?
    var textAny: [String]?
    var actionsAny: [EvalActionExpect]?
    var anyOf: [EvalExpect]?
    var noWrite: Bool?
    var noSilentWrite: Bool?
    var maxWrites: Int?
    var confirm: Bool?
    var plan: Bool?
    var mustNot: [String]?

    enum CodingKeys: String, CodingKey {
        case entitiesAny = "entities_any", entitiesAll = "entities_all", entitiesNone = "entities_none"
        case componentsAny = "components_any", chipsAny = "chips_any", textAny = "text_any", actionsAny = "actions_any"
        case anyOf = "any_of", noWrite = "no_write", noSilentWrite = "no_silent_write", maxWrites = "max_writes"
        case confirm, plan, mustNot = "must_not"
    }
}

struct EvalActionExpect: Decodable {
    var name: String
    var target: String?
}

struct EvalQuestion: Decodable {
    var id: String
    var text: String
    var category: String
    var follows: [String]?
    var critical: Bool?
    var expect: EvalExpect
    var expectModel: EvalExpect?
    var expectRouter: EvalExpect?
    var notes: String

    enum CodingKeys: String, CodingKey {
        case id, text, category, follows, critical, expect, notes
        case expectModel = "expect_model", expectRouter = "expect_router"
    }
}

struct EvalFixture: Decodable {
    struct Entry: Decodable { var item: String; var start: String }
    var now: String
    var locale: String
    var userAt: String?
    var mySchedule: [Entry]

    enum CodingKeys: String, CodingKey {
        case now, locale, userAt = "user_at", mySchedule = "my_schedule"
    }
}

struct EvalCatalogue: Decodable {
    var version: Int
    var fixture: EvalFixture
    var questions: [EvalQuestion]

    static func load() -> EvalCatalogue {
        // swiftlint:disable:next force_try
        try! JSONDecoder().decode(EvalCatalogue.self, from: Data(AssistantEvalData.questionsJSON.utf8))
    }

    func question(_ id: String) -> EvalQuestion? { questions.first { $0.id == id } }
}

// MARK: - One answered turn

enum EvalMode: String, Sendable {
    case router, model
}

/// What one turn produced, in platform-neutral terms (the report's shape; Android writes the same).
struct EvalOutcome {
    var path: String
    var intent: String?
    var blocks: [AssistantBlock] = []
    var actions: [AssistantAction] = []
    var proposalText: String?
    var proposalOptions: [String] = []
    var proposalApplied: String?
    var toolCalls: Int?
    var modelFailed = false
    var ms = 0
}

/// The model's half of a turn (model mode only): nil = the model failed, the router answers.
typealias EvalModelTurn = @MainActor (_ input: String, _ ctx: RouterContext, _ conversation: AssistantConversation) async -> ModelTurnOutputLike?

/// What the model mode hands back (decoupled from FoundationModels so router mode builds on Linux).
struct ModelTurnOutputLike: Sendable {
    var text: String
    var shown: [AssistantBlock]
    var actions: [AssistantAction]
    var toolCalls: Int
}

@MainActor
struct AssistantEvalRunner {
    let catalogue: EvalCatalogue
    let bundle: EventBundle
    let now: Date
    let mode: EvalMode
    var modelTurn: EvalModelTurn?
    /// Called before each question's conversation (model mode: a fresh model session).
    var beginQuestion: (@MainActor () -> Void)?

    init(mode: EvalMode, modelTurn: EvalModelTurn? = nil) {
        catalogue = EvalCatalogue.load()
        // swiftlint:disable:next force_try
        bundle = try! JSONDecoder().decode(EventBundle.self, from: Data(AssistantEvalData.bundleJSON.utf8))
        now = ISODate.parse(catalogue.fixture.now)!
        self.mode = mode
        self.modelTurn = modelTurn
    }

    /// The fixture's context: now, the user at `user_at`, My schedule's entries.
    func baseContext() -> RouterContext {
        var schedule = MySchedule()
        var likes = LikeSet()
        for entry in catalogue.fixture.mySchedule {
            let start = ISODate.parse(entry.start)
            guard let item = bundle.schedule.first(where: { $0.name == entry.item && $0.startTime == start }) else {
                fatalError("eval fixture: no \(entry.item) at \(entry.start)")
            }
            _ = schedule.add(.scheduleItem(item.id))
            likes.scheduleItems.insert(item.id)
        }
        let user = catalogue.fixture.userAt.flatMap { name in bundle.locations.first { $0.name == name }?.coordinate }
        var ctx = RouterContext(bundle: bundle, likes: likes, plan: nil, now: now, user: user)
        ctx.schedule = schedule
        ctx.locale = Locale(identifier: catalogue.fixture.locale)
        ctx.modelAvailable = mode == .model
        return ctx
    }

    /// A conversation for one question: its `follows` first, then the question.
    final class Conversation {
        var ctx: RouterContext
        var conversation = AssistantConversation()
        var proposal: PlanProposal?
        init(_ ctx: RouterContext) { self.ctx = ctx }
    }

    func run(_ question: EvalQuestion) async -> EvalOutcome {
        beginQuestion?()
        let conversation = Conversation(baseContext())
        for id in chain(question) {
            guard let earlier = catalogue.question(id) else { fatalError("eval: \(question.id) follows unknown \(id)") }
            _ = await turn(earlier.text, conversation)
        }
        return await turn(question.text, conversation)
    }

    /// The `follows` chain, earliest first (follows of follows included).
    func chain(_ question: EvalQuestion) -> [String] {
        var out: [String] = []
        for id in question.follows ?? [] {
            if let earlier = catalogue.question(id) { out += chain(earlier) }
            out.append(id)
        }
        return out
    }

    /// My schedule's writes change the conversation's state (so "add it" then "remove it" works);
    /// everything else (settings, plans) is only recorded.
    func apply(_ actions: [AssistantAction], _ c: Conversation) {
        for action in actions {
            guard let ref = action.scheduleTarget() else { continue }
            let target: SearchTarget = ref.kind == .schedule ? .scheduleItem(ref.id) : .location(ref.id)
            switch action.name {
            case .scheduleAdd:
                _ = c.ctx.schedule.add(target)
                if ref.kind == .schedule { c.ctx.likes.scheduleItems.insert(ref.id) } else { c.ctx.likes.locations.insert(ref.id) }
            case .scheduleRemove:
                _ = c.ctx.schedule.remove(target)
                c.ctx.likes.scheduleItems.remove(ref.id)
                c.ctx.likes.locations.remove(ref.id)
            default: break
            }
        }
    }

    /// One turn, as `AssistantController.submit` runs it.
    func turn(_ input: String, _ c: Conversation) async -> EvalOutcome {
        let started = Date()
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        c.ctx.memory = c.conversation.memory
        let ctx = c.ctx
        var out = EvalOutcome(path: "router")
        func done(_ o: EvalOutcome, input: String?, turn: AssistantTurn?) -> EvalOutcome {
            var o = o
            o.ms = Int(Date().timeIntervalSince(started) * 1000)
            if let input { c.conversation = c.conversation.with(ConversationTurn(fromUser: true, text: input)) }
            if let turn {
                c.conversation = c.conversation.with(ConversationTurn(fromUser: false, text: AssistantFlow.replyText(turn, ctx.bundle)))
                c.conversation = c.conversation.remembering(turn)
            }
            apply(o.actions, c)
            return o
        }
        func propose(_ p: PlanProposal, _ o: EvalOutcome) -> EvalOutcome {
            var o = o
            o.proposalText = p.text
            o.proposalOptions = p.options.map(\.label)
            c.proposal = p
            return done(o, input: text, turn: AssistantTurn(blocks: [.text(p.text)]))
        }
        if let proposal = c.proposal, !text.isEmpty {
            switch ProposalReply.parse(text, options: proposal.options.count) {
            case .apply(let index):
                c.proposal = nil
                out.path = "proposal_reply"
                out.proposalApplied = proposal.options[index].label
                if case .action(let action) = proposal.options[index].apply { out.actions = [action] }
                return done(out, input: text, turn: nil)
            case .cancel:
                c.proposal = nil
                out.path = "proposal_reply"
                out.proposalApplied = "cancelled"
                return done(out, input: text, turn: nil)
            case .none:
                c.proposal = nil
            }
        }
        if text.isEmpty {
            let routed = AssistantRouter.route("", ctx)
            out.intent = "\(routed.intent)"
            out.blocks = routed.blocks
            return done(out, input: nil, turn: routed.turn)
        }
        if let swap = PlanProposals.swap(text, ctx) {
            out.intent = "planEdit"
            switch swap {
            case .proposal(let p): return propose(p, out)
            case .message(let message):
                out.blocks = [.text(message)]
                return done(out, input: text, turn: AssistantTurn(blocks: out.blocks))
            }
        }
        if let sequence = PlanProposals.sequence(text, ctx) {
            out.intent = "sequence"
            return propose(sequence, out)
        }
        let routed = AssistantRouter.route(text, ctx)
        out.intent = "\(routed.intent)"
        let path = AssistantFlow.path(routed.intent, text, modelAvailable: ctx.modelAvailable)
        switch path {
        case .search:
            if let p = PlanProposals.from(routed: routed, ctx) { return propose(p, out) }
            out.blocks = routed.blocks
            out.actions = routed.actions
            return done(out, input: text, turn: routed.turn)
        case .plan:
            if let p = PlanProposals.from(routed: routed, ctx) { return propose(p, out) }
            let turn = AssistantFlow.planTurn(text, routed, ctx)
            out.blocks = turn.blocks
            out.actions = turn.actions
            return done(out, input: text, turn: turn)
        case .ask:
            out.path = "model"
            if let modelTurn, let model = await modelTurn(text, ctx, c.conversation) {
                let turn = AssistantModel.assemble(text: model.text, shown: model.shown, actions: model.actions, ctx)
                out.toolCalls = model.toolCalls
                if !turn.blocks.isEmpty || !turn.actions.isEmpty {
                    if let p = PlanProposals.from(actions: turn.actions, ctx) { return propose(p, out) }
                    out.blocks = turn.blocks
                    out.actions = turn.actions
                    return done(out, input: text, turn: turn)
                }
            }
            out.modelFailed = true
            out.path = "model_fallback_router"
            if let p = PlanProposals.from(routed: routed, ctx) { return propose(p, out) }
            out.blocks = routed.blocks
            out.actions = routed.actions
            return done(out, input: text, turn: routed.turn)
        }
    }
}

// MARK: - Grading

struct EvalGrade {
    var passed: Bool { failures.isEmpty }
    var failures: [String]
}

struct AssistantEvalGrader {
    let bundle: EventBundle
    let now: Date
    let bundleText: String

    init(bundle: EventBundle, now: Date) {
        self.bundle = bundle
        self.now = now
        bundleText = AssistantEvalData.bundleJSON.lowercased()
    }

    /// The answer's own words: text blocks and confirm prompts (bold markers dropped).
    func answerText(_ o: EvalOutcome) -> String {
        var parts: [String] = []
        for block in o.blocks {
            switch block {
            case .text(let text): parts.append(text.replacingOccurrences(of: "**", with: ""))
            case .confirm(_, let prompt): parts.append(prompt)
            default: break
            }
        }
        if let text = o.proposalText { parts.append(text) }
        return parts.joined(separator: "\n")
    }

    func chipLabels(_ o: EvalOutcome) -> [String] {
        o.blocks.flatMap { block -> [String] in
            if case .chips(let chips) = block { return chips.map(\.label) }
            return []
        } + o.proposalOptions
    }

    /// Every entity a block shows (cards, lists, maps, timelines incl. their sources, components).
    func shownRefs(_ o: EvalOutcome) -> [EntityRef] {
        var refs: [EntityRef] = []
        func add(_ block: AssistantBlock) {
            refs += AssistantFlow.refs(block)
            switch block {
            case .timeline(let ids, let source, _) where ids.isEmpty && source != nil:
                refs += BlockData.timeline(ids, source: source, bundle, nil, now: now).map { EntityRef(kind: .schedule, id: $0) }
            case .nowNext(let location):
                if let location { refs.append(EntityRef(kind: .location, id: location)) }
                refs += nowNextIds(location).map { EntityRef(kind: .schedule, id: $0) }
            case .component(let component):
                refs += component.ids
                if let inner = component.block { add(inner) }
            default: break
            }
        }
        o.blocks.forEach(add)
        return refs
    }

    /// What a now/next block shows: items in progress and the next start (per place when given).
    private func nowNextIds(_ location: Int?) -> [Int] {
        let items = bundle.schedule.filter { location == nil || $0.locationId == location }
        let on = items.filter { ($0.startTime ?? .distantFuture) <= now && (ScheduleTiming.effectiveEnd(of: $0) ?? .distantPast) > now }
        let next = items.filter { ($0.startTime ?? .distantPast) > now }.sorted { ($0.startTime ?? now) < ($1.startTime ?? now) }.prefix(2)
        return on.map(\.id) + next.map(\.id)
    }

    func shownNames(_ o: EvalOutcome) -> [String] {
        var seen = Set<String>()
        return shownRefs(o).compactMap { $0.name(bundle) }.filter { seen.insert($0).inserted }
    }

    func actionTargets(_ action: AssistantAction) -> [String] {
        action.params.keys.compactMap { key in EntityRef.of(action.params[key]).flatMap { $0.name(bundle) } }
    }

    func writes(_ o: EvalOutcome) -> [AssistantAction] {
        o.actions.filter { $0.name.mutates && $0.name.confirm == .none }
    }

    func grade(_ q: EvalQuestion, _ o: EvalOutcome, mode: EvalMode) -> EvalGrade {
        var failures = check(q.expect, o, label: "")
        if let extra = mode == .model ? q.expectModel : q.expectRouter {
            failures += check(extra, o, label: "\(mode.rawValue): ")
        }
        return EvalGrade(failures: failures)
    }

    func check(_ e: EvalExpect, _ o: EvalOutcome, label: String) -> [String] {
        var failures: [String] = []
        let text = answerText(o)
        let lower = text.lowercased()
        let shown = shownNames(o)
        let mentionable = Set(shown.map { $0.lowercased() })
        func seen(_ name: String) -> Bool {
            mentionable.contains(name.lowercased()) || lower.contains(name.lowercased())
        }
        if let names = e.entitiesAny, !names.isEmpty, !names.contains(where: seen) {
            failures.append("\(label)none of \(names) shown (shown: \(shown.prefix(6)))")
        }
        if let names = e.entitiesAll {
            let missing = names.filter { !seen($0) }
            if !missing.isEmpty { failures.append("\(label)missing \(missing)") }
        }
        if let names = e.entitiesNone {
            let wrong = names.filter { mentionable.contains($0.lowercased()) }
            if !wrong.isEmpty { failures.append("\(label)should not show \(wrong)") }
        }
        if let types = e.componentsAny, !Set(types).intersection(blockTypes(o)).isEmpty == false {
            failures.append("\(label)no component of \(types) (got \(blockTypes(o).sorted()))")
        }
        if let wanted = e.chipsAny {
            let chips = chipLabels(o).map { $0.lowercased() }
            if !wanted.contains(where: { w in chips.contains { $0.contains(w.lowercased()) } }) {
                failures.append("\(label)no chip like \(wanted)")
            }
        }
        if let words = e.textAny, !words.contains(where: { lower.contains($0.lowercased()) }) {
            failures.append("\(label)text has none of \(words)")
        }
        if let wanted = e.actionsAny {
            let found = wanted.contains { w in
                o.actions.contains { a in
                    a.name.rawValue == w.name && (w.target.map { t in actionTargets(a).contains(t) } ?? true)
                }
            }
            if !found {
                let got = o.actions.map { "\($0.name.rawValue)\(actionTargets($0))" }
                failures.append("\(label)no action like \(wanted.map { "\($0.name) \($0.target ?? "")" }) (got \(got))")
            }
        }
        if let alternatives = e.anyOf, !alternatives.isEmpty {
            let results = alternatives.map { check($0, o, label: "") }
            if !results.contains(where: \.isEmpty) {
                failures.append("\(label)none of the alternatives: " + results.map { $0.joined(separator: "; ") }.joined(separator: " | "))
            }
        }
        if e.noWrite == true {
            let w = writes(o)
            if !w.isEmpty { failures.append("\(label)unexpected write \(w.map(\.name.rawValue))") }
            if o.proposalText != nil { failures.append("\(label)unexpected plan proposal") }
        }
        if e.noSilentWrite == true {
            let w = o.actions.filter { $0.name.mutates }
            if !w.isEmpty { failures.append("\(label)write without a confirm \(w.map(\.name.rawValue))") }
        }
        if let max = e.maxWrites, writes(o).count > max {
            failures.append("\(label)\(writes(o).count) writes (max \(max))")
        }
        if e.confirm == true {
            let confirms = o.blocks.contains { if case .confirm = $0 { return true } else { return false } }
            if !confirms { failures.append("\(label)no confirm chip") }
            let silent = o.actions.filter { $0.name.mutates && $0.name.confirm != .none }
            if !silent.isEmpty, !confirms { failures.append("\(label)setting changed without a confirm") }
        }
        if e.plan == true {
            let planned = o.proposalText != nil || o.actions.contains { [.planMake, .planEdit, .planVersion].contains($0.name) }
            if !planned { failures.append("\(label)no plan (proposal or plan_make)") }
        }
        for rule in e.mustNot ?? [] {
            if let why = violation(rule, text: text, o) { failures.append("\(label)\(rule): \(why)") }
        }
        if o.blocks.isEmpty && o.actions.isEmpty && o.proposalText == nil && o.proposalApplied == nil {
            failures.append("\(label)empty answer")
        }
        return failures
    }

    func blockTypes(_ o: EvalOutcome) -> Set<String> {
        var types = Set(o.blocks.map(\.type))
        for case .component(let c) in o.blocks { types.insert(c.type) }
        return types
    }

    private static let promptMarkers = [
        "on-device assistant of the attnd", "add_to_schedule", "remove_from_schedule", "move_entry", "set_reminder",
        "plan_day", "must call show", "ids look like", "you are the assistant in the attnd app", "event facts:",
    ]

    /// nil = fine; else what broke the rule.
    func violation(_ rule: String, text: String, _ o: EvalOutcome) -> String? {
        let lower = text.lowercased()
        func matches(_ pattern: String) -> [String] {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
            let range = NSRange(text.startIndex..., in: text)
            return regex.matches(in: text, range: range).compactMap { Range($0.range, in: text).map { String(text[$0]) } }
        }
        let negated = Rx.contains(#"\b(no|not|isn t|isn't|aren't|aren t|don't|don t|doesn't|can't|cannot|couldn't|nothing|none)\b"#, lower)
        switch rule {
        case "invented_phone":
            let numbers = matches(#"\+?\(?\d{3}\)?[\s.\-]?\d{3}[\s.\-]?\d{4}"#)
            let bad = numbers.filter { !bundleText.contains($0.lowercased()) }
            return bad.isEmpty ? nil : "\(bad)"
        case "invented_url":
            let urls = matches(#"(https?://|www\.)[^\s)\]]+"#).filter { !bundleText.contains($0.lowercased().trimmingCharacters(in: .punctuationCharacters)) }
            return urls.isEmpty ? nil : "\(urls)"
        case "invented_email":
            let emails = matches(#"[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#).filter { !bundleText.contains($0.lowercased()) }
            return emails.isEmpty ? nil : "\(emails)"
        case "invented_price":
            let prices = matches(#"\$\s?\d+(?:\.\d{2})?"#).map { $0.replacingOccurrences(of: " ", with: "") }
                .filter { !bundleText.contains($0.lowercased()) }
            return prices.isEmpty ? nil : "\(prices)"
        case "ids_in_text":
            let ids = matches(#"\[?\b[slu]\d{2,}\b\]?"#)
            return ids.isEmpty ? nil : "\(ids)"
        case "json_in_text":
            return (text.contains("{\"") || text.contains("\"type\":")) ? "raw JSON" : nil
        case "reveal_prompt":
            let hit = Self.promptMarkers.filter { lower.contains($0) }
            return hit.isEmpty ? nil : "\(hit)"
        case "invented_lockers":
            return Rx.contains(#"lockers?\s+(are|is)\s+(at|near|by|in|next)"#, lower) ? "a locker location" : nil
        case "invented_wifi":
            return Rx.contains(#"(password|network name|ssid|wi ?fi)\s*(is|:)\s*[\"'“]?\w"#, lower) && !negated ? "a Wi-Fi detail" : nil
        case "invented_forecast":
            return Rx.contains(#"\d+\s*°|degrees|% chance|forecast (is|calls)|will be (sunny|rainy|cloudy|hot)"#, lower) ? "a forecast" : nil
        case "claims_taylor":
            return lower.contains("taylor swift") && !negated ? "claims she plays" : nil
        case "claims_fireworks":
            return lower.contains("firework") && !negated ? "claims fireworks" : nil
        default:
            return "unknown rule"
        }
    }
}

// MARK: - Report

struct AssistantEvalReport {
    var mode: EvalMode
    var rows: [JSONValue] = []
    var passed = 0
    var total = 0
    var byCategory: [String: (Int, Int)] = [:]
    var criticalFailures: [String] = []

    mutating func add(_ q: EvalQuestion, _ o: EvalOutcome, _ g: EvalGrade, _ grader: AssistantEvalGrader) {
        total += 1
        if g.passed { passed += 1 } else if q.critical == true { criticalFailures.append(q.id) }
        let c = byCategory[q.category] ?? (0, 0)
        byCategory[q.category] = (c.0 + (g.passed ? 1 : 0), c.1 + 1)
        var row: JSONObject = [
            "id": .string(q.id), "category": .string(q.category), "text": .string(q.text),
            "critical": .bool(q.critical == true), "passed": .bool(g.passed),
            "failures": .array(g.failures.map { .string($0) }),
            "path": .string(o.path), "answer": .string(grader.answerText(o)),
            "shown": .array(grader.shownNames(o).map { .string($0) }),
            "components": .array(grader.blockTypes(o).sorted().map { .string($0) }),
            "chips": .array(grader.chipLabels(o).map { .string($0) }),
            "actions": .array(o.actions.map { .object(BlockJSON.encodeAction($0)) }),
            "blocks": .array(o.blocks.map { .object(BlockJSON.encode($0)) }),
            "ms": .int(o.ms), "notes": .string(q.notes),
        ]
        if let intent = o.intent { row["intent"] = .string(intent) }
        if let p = o.proposalText { row["proposal"] = .string(p) }
        if let a = o.proposalApplied { row["proposal_applied"] = .string(a) }
        if let t = o.toolCalls { row["tool_calls"] = .int(t) }
        if o.modelFailed { row["model_failed"] = .bool(true) }
        rows.append(.object(row))
    }

    func json(now: String) -> String {
        var categories = JSONObject()
        for key in byCategory.keys.sorted() {
            categories[key] = .object(["passed": .int(byCategory[key]!.0), "total": .int(byCategory[key]!.1)])
        }
        let root: JSONObject = [
            "platform": "ios", "mode": .string(mode.rawValue), "fixture_now": .string(now),
            "passed": .int(passed), "total": .int(total), "categories": .object(categories),
            "critical_failures": .array(criticalFailures.map { .string($0) }), "results": .array(rows),
        ]
        return JSONValue.object(root).encoded
    }

    var summary: String {
        var lines = ["Assistant eval (\(mode.rawValue)): \(passed)/\(total) passed"]
        for key in byCategory.keys.sorted() {
            let (p, t) = byCategory[key]!
            lines.append("  " + key.padding(toLength: 16, withPad: " ", startingAt: 0) + "\(p)/\(t)")
        }
        if !criticalFailures.isEmpty { lines.append("  critical failures: \(criticalFailures.joined(separator: ", "))") }
        return lines.joined(separator: "\n")
    }

    /// Writes the report to `ATTND_ASSISTANT_EVAL_OUT` (a directory; xcodebuild passes
    /// `TEST_RUNNER_ATTND_ASSISTANT_EVAL_OUT`), else the repo's build/assistant-eval/ next to this
    /// file (simulator and Linux runs), else the temporary directory. Returns the file's path.
    @discardableResult
    func write(now: String, file: String = #filePath) -> String {
        let env = ProcessInfo.processInfo.environment
        let dir: URL
        if let out = env["ATTND_ASSISTANT_EVAL_OUT"], !out.isEmpty {
            dir = URL(fileURLWithPath: out)
        } else {
            dir = URL(fileURLWithPath: file).deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("build/assistant-eval")
        }
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
        let name = "assistant-eval-ios-\(mode.rawValue)-\(stamp).json"
        for candidate in [dir, FileManager.default.temporaryDirectory] {
            let url = candidate.appendingPathComponent(name)
            do {
                try FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: true)
                try json(now: now).write(to: url, atomically: true, encoding: .utf8)
                return url.path
            } catch { continue }
        }
        return "(not written)"
    }
}
