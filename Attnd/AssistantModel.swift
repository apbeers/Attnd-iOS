// AssistantModel.swift
// Attnd (app target only — not in the App Clip; unit tested in AssistantBlocksTests)
//
// The model path (assistant spec §3), a port of Android's `domain/AssistantModel.kt`: the
// on-device model only understands and picks components. It sees the event facts, the plan
// summary, likes, the conversation and ≤ 12 retrieved items (`retrieve`, `prompt`); its reply is
// `{"blocks":[…],"actions":[…]}` (`parse`: the first `{` to the last `}`), validated against the
// bundle; anything invalid → the rule-based `AssistantRouter` for that turn (`resolve`). On iOS
// the Foundation Models session (EventAssistant.swift, UI phase) produces the same JSON shape;
// `completeBlocks` renders blocks of a streamed partial reply as they complete.

import Foundation

/// One turn of the assistant conversation, stored with the plan per event (on the device only).
struct ConversationTurn: Hashable, Sendable, Codable {
    var fromUser: Bool
    var text: String
}

/// The conversation: the model sees the last 6 turns verbatim (each ≤ 200 characters) and, beyond
/// them, one line with ≤ 10 distinct keywords of the earlier user turns. ≤ 40 turns are kept.
struct AssistantConversation: Hashable, Sendable {
    static let shown = 6
    static let maxStored = 40

    var turns: [ConversationTurn] = []

    func with(_ turn: ConversationTurn) -> AssistantConversation {
        AssistantConversation(turns: Array((turns + [turn]).suffix(Self.maxStored)))
    }

    func promptLines() -> [String] {
        let shownTurns = turns.suffix(Self.shown)
        let earlier = turns.dropLast(Self.shown).filter(\.fromUser)
        var lines: [String] = []
        if !earlier.isEmpty {
            var words: [String] = []
            for turn in earlier {
                for word in AssistantSearch.words(AssistantSearch.keywords(turn.text))
                where !AssistantSearch.stopWords.contains(word) && !words.contains(word) {
                    words.append(word)
                }
            }
            let about = words.prefix(10).joined(separator: ", ")
            lines.append("(earlier: \(earlier.count) more requests about \(about.isEmpty ? "other things" : about))")
        }
        for turn in shownTurns {
            let flat = Rx.replace(#"\s+"#, turn.text, with: " ").trimmingCharacters(in: .whitespaces)
            lines.append((turn.fromUser ? "Attendee: " : "Assistant: ") + String(flat.prefix(200)))
        }
        return lines
    }

    func encode() -> String {
        (try? JSONEncoder().encode(turns)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
    }

    static func decode(_ text: String?) -> AssistantConversation {
        guard let data = text?.data(using: .utf8), let turns = try? JSONDecoder().decode([ConversationTurn].self, from: data) else {
            return AssistantConversation()
        }
        return AssistantConversation(turns: Array(turns.suffix(maxStored)))
    }
}

/// The model's reply read against the bundle: a turn, or why it was rejected (then the router answers).
enum ModelReply: Hashable, Sendable {
    case valid(AssistantTurn)
    case invalid(String)
}

/// Which path answered a turn.
enum TurnSource: Hashable, Sendable { case model, rules }

struct ResolvedTurn: Hashable, Sendable {
    var source: TurnSource
    var turn: AssistantTurn
    var routed: RoutedTurn?
}

enum AssistantModel {
    static let maxItems = 12

    /// ≤ 12 items: when the keywords contain time words, the schedule items matching only those
    /// (not ended, by start) first; then the any-token matches of the keywords, then what's on now
    /// / next; distinct.
    static func retrieve(_ input: String, _ ctx: RouterContext) -> [AssistantSearch.Result] {
        let keywords = AssistantSearch.keywords(AssistantRouter.command(input))
        let parsed = AssistantSearch.parse(keywords)
        var timed: [AssistantSearch.Result] = []
        if !parsed.time.isEmpty {
            let words = AssistantSearch.words(keywords).filter { AssistantSearch.parse($0).isTimeOnly }.joined(separator: " ")
            timed = AssistantSearch.search(ctx.bundle, words.isEmpty ? keywords : words, now: ctx.now)
                .filter { $0.kind == .schedule && $0.timing != .ended }
                .stableSorted { a, b in
                    guard let x = ctx.bundle.scheduleItem(a.id), let y = ctx.bundle.scheduleItem(b.id) else { return false }
                    return Planner.itemOrder(x, y)
                }
        }
        var seen = Set<String>()
        return Array((timed + context(ctx.bundle, input, now: ctx.now)).filter { seen.insert("\($0.kind.rawValue):\($0.id)").inserted }.prefix(maxItems))
    }

    /// Android `AssistantPrompt.context`: any-token matches first, then what is on now / next.
    static func context(_ bundle: EventBundle, _ question: String, now: Date) -> [AssistantSearch.Result] {
        let matches = AssistantSearch.search(bundle, AssistantSearch.keywords(question), now: now, mode: .anyToken, limit: maxItems)
        if matches.count >= maxItems { return matches }
        let seen = Set(matches.map { "\($0.kind.rawValue):\($0.id)" })
        let sorted = bundle.schedule.stableSorted { a, b in
            switch (a.startTime, b.startTime) {
            case (nil, nil): return a.id < b.id
            case (nil, _): return false
            case (_, nil): return true
            case let (sa?, sb?): return sa != sb ? sa < sb : a.id < b.id
            }
        }
        let live = sorted.compactMap { item -> AssistantSearch.Result? in
            guard let timing = AssistantSearch.timing(item, now: now), timing != .ended else { return nil }
            return AssistantSearch.Result(kind: .schedule, id: item.id, title: item.name, score: 0, timing: timing)
        }
        .stableSorted { ($0.timing?.rawValue ?? 0) < ($1.timing?.rawValue ?? 0) }
        .filter { !seen.contains("\($0.kind.rawValue):\($0.id)") }
        return Array((matches + live).prefix(maxItems))
    }

    static func prompt(_ input: String, _ ctx: RouterContext, _ conversation: AssistantConversation, _ retrieved: [AssistantSearch.Result]) -> String {
        let bundle = ctx.bundle
        let zone = bundle.event.timeZone
        let nowText = AssistantText.format(ctx.now, "EEEE, MMMM d, h:mm a", zone, ctx.locale)
        let writes = ActionName.allCases.filter(\.mutates).map(describe).joined(separator: ", ")
        let reads = ActionName.allCases.filter { !$0.mutates }.map(describe).joined(separator: ", ")
        var lines: [String] = []
        lines.append("You are the assistant in the Attnd app for the event \"\(clean(bundle.event.name))\".")
        lines.append("Choose how to answer the attendee. Reply with only one JSON object and no other text:")
        lines.append(#"{"blocks":[{"type":"text","text":"…"}],"actions":[]}"#)
        lines.append("BLOCKS (use ids from ITEMS only, like \"s12\", \"l3\", \"u9\"):")
        lines.append("text{text} item_card{id} place_card{id} update_card{id} list{ids,title} carousel{ids,title} timeline{ids} map{pins,route} gallery{ids} now_next{location} countdown{id} compare{a,b} plan{} setting{setting} summary{kind} share{target} calendar{ids|plan} chips{chips:[{label,action,params}]} confirm{action,params,prompt}")
        lines.append("READ ACTIONS: \(reads)")
        lines.append("WRITE ACTIONS (the app asks or offers Undo): \(writes)")
        lines.append("Rules: at most 8 blocks; text at most 400 characters; end with at most 5 chips; one card for one result, a carousel for 2–8; never invent ids, times or facts.")
        lines.append("All times are local to the event (\(zone.identifier)). NOW: \(nowText).")
        lines.append("EVENT: \(clean(bundle.event.name)) — \(AssistantSearch.eventDetail(bundle.event, locale: ctx.locale))")
        if let info = eventInfo(bundle) { lines.append("EVENT INFO: " + info) }
        if !ctx.weather.isEmpty { lines.append("FORECAST: " + ctx.weather.joined(separator: "; ")) }
        if let plan = ctx.plan {
            lines.append("PLAN: " + Planner.summary(plan, timeZone: zone, locale: ctx.locale) + " — " + plan.items.map { "s\($0.itemId)" }.joined(separator: "; "))
        } else {
            lines.append("PLAN: none")
        }
        let liked = AssistantSearch.liked(bundle, ctx.likes, now: ctx.now).compactMap { r in EntityRef.of(r).map { "\($0.code) \(clean(r.title))" } }
        lines.append("LIKED: " + (liked.isEmpty ? "none" : liked.joined(separator: "; ")))
        let history = conversation.promptLines()
        if !history.isEmpty {
            lines.append("CONVERSATION:")
            lines += history
        }
        lines.append("ITEMS:")
        lines += retrieved.prefix(maxItems).compactMap { line($0, ctx) }
        lines.append("INPUT: \(clean(input, max: 300))")
        return lines.joined(separator: "\n") + "\nJSON:"
    }

    private static func describe(_ name: ActionName) -> String {
        name.key + "(" + name.params.map { $0.name + ($0.required ? "" : "?") }.joined(separator: ",") + ")"
    }

    private static func line(_ result: AssistantSearch.Result, _ ctx: RouterContext) -> String? {
        guard let ref = EntityRef.of(result) else { return nil }
        let bundle = ctx.bundle
        let detail = AssistantSearch.detail(result, bundle, locale: ctx.locale)
        var marks: [String] = []
        if ref.kind == .schedule && ctx.likes.has(.schedule, ref.id) { marks.append("liked") }
        if ref.kind == .location && ctx.likes.has(.location, ref.id) { marks.append("liked") }
        if ref.kind == .schedule && ctx.plan?.itemIds.contains(ref.id) == true { marks.append("in plan") }
        if let timing = result.timing { marks.append(timing.label.lowercased()) }
        let tags: [String]
        switch ref.kind {
        case .schedule: tags = bundle.scheduleItem(ref.id)?.tags ?? []
        case .location: tags = bundle.location(ref.id)?.tags ?? []
        case .update: tags = []
        }
        var text = "[\(ref.code)] " + clean(result.title)
        if !detail.isEmpty { text += " — " + clean(detail) }
        if !tags.isEmpty { text += " — tags: " + clean(tags.joined(separator: ", ")) }
        if !marks.isEmpty { text += " — " + marks.joined(separator: ", ") }
        if let extra = contextLine(ref, bundle) { text += " — " + extra }
        return text
    }

    /// API-018 for an ITEMS line, compact: performers with genres, price, age limit (items);
    /// hours, age limit, the first menu entries (places).
    static func contextLine(_ ref: EntityRef, _ bundle: EventBundle) -> String? {
        var parts: [String] = []
        switch ref.kind {
        case .schedule:
            guard let context = bundle.scheduleItem(ref.id)?.context else { return nil }
            if !context.performers.isEmpty {
                let names = context.performers.prefix(3).map { p in p.genres.isEmpty ? p.name : "\(p.name) (\(p.genres.prefix(3).joined(separator: ", ")))" }
                parts.append("performers: " + names.joined(separator: ", "))
            }
            if !context.price.isEmpty { parts.append("price: " + context.price) }
            if !context.ageLimit.isEmpty { parts.append("age: " + context.ageLimit) }
        case .location:
            guard let context = bundle.location(ref.id)?.context else { return nil }
            if !context.hours.isEmpty { parts.append("hours: " + context.hours) }
            if !context.ageLimit.isEmpty { parts.append("age: " + context.ageLimit) }
            if !context.menu.isEmpty {
                parts.append("menu: " + context.menu.prefix(4).map { $0.price.isEmpty ? $0.name : "\($0.name) \($0.price)" }.joined(separator: ", "))
            }
        case .update:
            return nil
        }
        return parts.isEmpty ? nil : clean(parts.joined(separator: " — "), max: 240)
    }

    /// API-018 event facts for the prompt (≤ 400 characters): amenities and the start of the FAQ.
    static func eventInfo(_ bundle: EventBundle) -> String? {
        guard let context = bundle.event.context else { return nil }
        var parts: [String] = []
        if !context.amenities.isEmpty {
            parts.append("amenities: " + context.amenities.prefix(8).map { a in
                bundle.location(a.locationId).map { "\(a.name) at l\($0.id)" } ?? a.name
            }.joined(separator: ", "))
        }
        if !context.faq.isEmpty { parts.append("FAQ: " + context.faq.prefix(3).map { "\($0.question) \($0.answer)" }.joined(separator: " ")) }
        return parts.isEmpty ? nil : clean(parts.joined(separator: " — "), max: 400)
    }

    private static func clean(_ text: String, max: Int = 160) -> String {
        let flat = Rx.replace(#"\s+"#, text.replacingOccurrences(of: "[", with: "(").replacingOccurrences(of: "]", with: ")"), with: " ")
            .trimmingCharacters(in: .whitespaces)
        return flat.count <= max ? flat : String(flat.prefix(max)).trimmingTrailingSpaces() + "…"
    }

    static func parse(_ raw: String, _ ctx: RouterContext) -> ModelReply {
        guard let start = raw.firstIndex(of: "{"), let end = raw.lastIndex(of: "}"), start < end else { return .invalid("no json") }
        guard let obj = JSONValue.parse(String(raw[start...end]))?.objectValue else { return .invalid("not an object") }
        guard let array = obj["blocks"]?.arrayValue else { return .invalid("no blocks") }
        var blocks: [AssistantBlock] = []
        for element in array {
            switch BlockJSON.decode(element) {
            case .ok(let block): blocks.append(block)
            case .unknown: break
            case .malformed(let type): return .invalid("malformed \(type)")
            }
        }
        var actions: [AssistantAction] = []
        for element in obj["actions"]?.arrayValue ?? [] {
            guard let a = element.objectValue else { return .invalid("bad action") }
            let name = a["name"]?.content
            switch ActionRegistry.check(name, a["params"]?.objectValue, ctx.bundle, now: ctx.now) {
            case .invalid(let reason): return .invalid("action \(name ?? ""): \(reason)")
            case .valid(let action): actions.append(action)
            }
        }
        let reads = actions.filter { !$0.name.mutates && $0.name.result != .navigation }
        let writes = actions.filter { $0.name.mutates || $0.name.result == .navigation }
        let asked = Set(blocks.compactMap { block -> ActionName? in if case .confirm(let action, _) = block { return action.name } else { return nil } })
        let confirms = writes.filter { $0.name.confirm == .chip && !asked.contains($0.name) }
            .map { AssistantBlock.confirm(action: $0, prompt: ActionRegistry.confirmPrompt($0)) }
        let direct = writes.filter { $0.name.confirm != .chip }
        let chips = blocks.filter(\.isChips)
        let content = blocks.filter { !$0.isChips } + reads.flatMap { AssistantRouter.renderRead($0, ctx).filter { !$0.isChips } } + confirms
        let validated = BlockValidator.validate(content + chips, ctx.blockContext)
        if validated.isEmpty && direct.isEmpty { return .invalid("nothing left") }
        return .valid(AssistantTurn(blocks: validated, actions: direct))
    }

    /// One turn: the model's reply when valid, else the rule-based router (also without a reply).
    static func resolve(_ input: String, raw: String?, _ ctx: RouterContext) -> ResolvedTurn {
        if let raw, case .valid(let turn) = parse(raw, ctx) { return ResolvedTurn(source: .model, turn: turn, routed: nil) }
        let routed = AssistantRouter.route(input, ctx)
        return ResolvedTurn(source: .rules, turn: routed.turn, routed: routed)
    }

    /// For logs: the turn's shape only (types and counts, never text).
    static func shape(_ turn: AssistantTurn) -> [String: String] {
        ["blocks": String(turn.blocks.count), "types": turn.blocks.map(\.type).joined(separator: ","), "actions": turn.actions.map(\.name.key).joined(separator: ",")]
    }

    /// Blocks that are complete in a partial reply (`{"blocks":[ {...}, {...}`), for streaming.
    static func completeBlocks(_ partial: String, _ ctx: RouterContext) -> [AssistantBlock] {
        let chars = Array(partial)
        guard let keyRange = partial.range(of: "\"blocks\"") else { return [] }
        let keyOffset = partial.distance(from: partial.startIndex, to: keyRange.lowerBound)
        guard let open = chars[keyOffset...].firstIndex(of: "[") else { return [] }
        var found: [AssistantBlock] = []
        var depth = 0, objStart = -1
        var inString = false, escape = false
        var i = open + 1
        loop: while i < chars.count {
            let ch = chars[i]
            if inString {
                if escape { escape = false } else if ch == "\\" { escape = true } else if ch == "\"" { inString = false }
                i += 1
                continue
            }
            switch ch {
            case "\"": inString = true
            case "{":
                if depth == 0 { objStart = i }
                depth += 1
            case "}":
                depth -= 1
                if depth == 0 && objStart >= 0 {
                    if case .ok(let block) = BlockJSON.decode(JSONValue.parse(String(chars[objStart...i]))) { found.append(block) }
                    objStart = -1
                }
            case "]":
                if depth == 0 { break loop }
            default: break
            }
            i += 1
        }
        let lastIsChips = found.last?.isChips == true
        return BlockValidator.validate(found, ctx.blockContext).filter { !$0.isChips || lastIsChips }
    }
}
