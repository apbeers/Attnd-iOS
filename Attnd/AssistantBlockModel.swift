// AssistantBlockModel.swift
// Attnd (app + App Clip; unit tested in AssistantBlocksTests)
//
// The assistant's response blocks (assistant spec §2), a port of Android's
// `domain/AssistantBlocks.kt`: ids and options only, the app resolves the data from the bundle
// and the components in `Components/` render them. `BlockJSON` reads and writes the block JSON
// shared by the model path, the router and the tests; `BlockValidator` checks every block
// against the bundle (unknown ids dropped, ≤ 8 blocks, ≤ 5 chips). (Not named
// AssistantBlocks.swift: `Components/AssistantBlocks.swift` holds the views.)

import Foundation

/// A follow-up quick action under an answer.
struct AssistantChip: Hashable, Sendable {
    var label: String
    var action: AssistantAction
}

/// One response block. Cases carry ids and options only.
enum AssistantBlock: Hashable, Sendable {
    /// ≤ 400 characters, plain text with **bold**.
    case text(String)
    case itemCard(id: Int, show: [String] = AssistantBlock.itemShow)
    case placeCard(id: Int, show: [String] = AssistantBlock.placeShow)
    case updateCard(id: Int)
    case list(ids: [EntityRef], title: String? = nil, limit: Int? = nil)
    case carousel(ids: [EntityRef], title: String? = nil)
    /// Time-ordered schedule items with a now line: explicit ids, or source `plan` / `whats_on`.
    case timeline(ids: [Int] = [], source: String? = nil, title: String? = nil)
    /// Location pins (≤ 12) and an optional walking route through locations in order.
    case map(pins: [Int], route: [Int] = [])
    case gallery(ids: [Int] = [], flyer: Bool = false)
    case nowNext(location: Int? = nil)
    case countdown(id: Int)
    /// Two schedule items ("s12") or two plan versions ("plan:chill", "plan:everything").
    case compare(a: String, b: String)
    case planDiff(PlanDiff)
    case plan(day: PlanDate? = nil)
    /// `follow_lock_screen`, `reminders` or `notifications`.
    case setting(String)
    /// `walking`, `recap` or `liked_counts`.
    case summary(String)
    /// `plan` or `item:s12`.
    case share(String)
    case chips([AssistantChip])
    case confirm(action: AssistantAction, prompt: String)

    static let itemShow = ["time", "place", "distance", "like", "actions"]
    static let placeShow = ["image", "distance", "now_next", "like", "actions"]
    static let itemParts: Set<String> = ["time", "place", "image", "distance", "like", "actions"]
    static let placeParts: Set<String> = ["image", "distance", "now_next", "like", "actions"]
    static let settings: Set<String> = ["follow_lock_screen", "reminders", "notifications"]
    static let summaries: Set<String> = ["walking", "recap", "liked_counts"]
    static let types: Set<String> = [
        "text", "item_card", "place_card", "update_card", "list", "carousel", "timeline", "map", "gallery", "now_next",
        "countdown", "compare", "plan_diff", "plan", "setting", "summary", "share", "chips", "confirm",
    ]

    var type: String {
        switch self {
        case .text: return "text"
        case .itemCard: return "item_card"
        case .placeCard: return "place_card"
        case .updateCard: return "update_card"
        case .list: return "list"
        case .carousel: return "carousel"
        case .timeline: return "timeline"
        case .map: return "map"
        case .gallery: return "gallery"
        case .nowNext: return "now_next"
        case .countdown: return "countdown"
        case .compare: return "compare"
        case .planDiff: return "plan_diff"
        case .plan: return "plan"
        case .setting: return "setting"
        case .summary: return "summary"
        case .share: return "share"
        case .chips: return "chips"
        case .confirm: return "confirm"
        }
    }

    var isChips: Bool { if case .chips = self { return true } else { return false } }
}

/// One assistant response: blocks to show and actions to run (writes go through the dispatcher).
struct AssistantTurn: Hashable, Sendable {
    var blocks: [AssistantBlock]
    var actions: [AssistantAction] = []
}

/// The block JSON shared by the model path, the router and tests (spec §2–3).
enum BlockJSON {

    enum Decoded: Hashable, Sendable {
        case ok(AssistantBlock)
        /// A type this build doesn't know: dropped (forward compatible).
        case unknown
        /// A known type without its required props, or with wrong types: the model's turn is invalid.
        case malformed(String)
    }

    static func encode(_ turn: AssistantTurn) -> JSONObject {
        ["blocks": .array(turn.blocks.map { .object(encode($0)) }), "actions": .array(turn.actions.map { .object(encodeAction($0)) })]
    }

    static func encodeAction(_ action: AssistantAction) -> JSONObject {
        ["name": .string(action.name.key), "params": .object(action.params)]
    }

    private static func strings(_ values: [String]) -> JSONValue { .array(values.map(JSONValue.string)) }

    static func encode(_ block: AssistantBlock) -> JSONObject {
        var o: JSONObject = ["type": .string(block.type)]
        switch block {
        case .text(let text): o["text"] = .string(text)
        case .itemCard(let id, let show): o["id"] = .string("s\(id)"); o["show"] = strings(show)
        case .placeCard(let id, let show): o["id"] = .string("l\(id)"); o["show"] = strings(show)
        case .updateCard(let id): o["id"] = .string("u\(id)")
        case .list(let ids, let title, let limit):
            o["ids"] = strings(ids.map(\.code))
            if let title { o["title"] = .string(title) }
            if let limit { o["limit"] = .int(limit) }
        case .carousel(let ids, let title):
            o["ids"] = strings(ids.map(\.code))
            if let title { o["title"] = .string(title) }
        case .timeline(let ids, let source, let title):
            if !ids.isEmpty { o["ids"] = strings(ids.map { "s\($0)" }) }
            if let source { o["source"] = .string(source) }
            if let title { o["title"] = .string(title) }
        case .map(let pins, let route):
            o["pins"] = strings(pins.map { "l\($0)" })
            if !route.isEmpty { o["route"] = strings(route.map { "l\($0)" }) }
        case .gallery(let ids, let flyer):
            o["ids"] = strings(ids.map { "l\($0)" })
            if flyer { o["flyer"] = .bool(true) }
        case .nowNext(let location): if let location { o["location"] = .string("l\(location)") }
        case .countdown(let id): o["id"] = .string("s\(id)")
        case .compare(let a, let b): o["a"] = .string(a); o["b"] = .string(b)
        case .planDiff(let diff): o["diff"] = .object(encodeDiff(diff))
        case .plan(let day): if let day { o["day"] = .string(day.description) }
        case .setting(let setting): o["setting"] = .string(setting)
        case .summary(let kind): o["kind"] = .string(kind)
        case .share(let target): o["target"] = .string(target)
        case .chips(let chips):
            o["chips"] = .array(chips.map { chip in
                .object(["label": .string(chip.label), "action": .string(chip.action.name.key), "params": .object(chip.action.params)])
            })
        case .confirm(let action, let prompt):
            o["action"] = .string(action.name.key)
            o["params"] = .object(action.params)
            o["prompt"] = .string(prompt)
        }
        return o
    }

    static func encodeDiff(_ diff: PlanDiff) -> JSONObject {
        [
            "removed": strings(diff.removed.map { "s\($0)" }),
            "added": strings(diff.added.map { "s\($0)" }),
            "moved": .array(diff.moved.map { strings(["s\($0.from)", "s\($0.to)"]) }),
            "meals_removed": strings(diff.mealsRemoved.map(\.encoded)),
            "meals_added": strings(diff.mealsAdded.map(\.encoded)),
            "meals_moved": strings(diff.mealsMoved.map(\.encoded)),
        ]
    }

    /// Reads one block (Android `BlockJson.decode`): a known type without its required props, or
    /// an id of the wrong form, is malformed; a well-formed id not in the bundle is dropped later
    /// by `BlockValidator`; a chip whose action isn't in the registry is dropped.
    static func decode(_ element: JSONValue?) -> Decoded {
        guard let obj = element?.objectValue,
              let type = obj["type"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        else { return .malformed("?") }
        guard AssistantBlock.types.contains(type) else { return .unknown }
        let malformed = Decoded.malformed(type)
        func str(_ key: String) -> String? { obj[key]?.stringValue }
        func arr(_ key: String) -> [JSONValue]? { obj[key]?.arrayValue }
        func id(_ key: String, _ prefix: Character) -> Int? { EntityRef.id(obj[key], prefix: prefix) }
        func ids(_ key: String, _ prefix: Character) -> [Int]? {
            guard let values = arr(key) else { return nil }
            var out: [Int] = []
            for value in values {
                guard let id = EntityRef.id(value, prefix: prefix) else { return nil }
                out.append(id)
            }
            return out
        }
        func refs(_ key: String) -> [EntityRef]? {
            guard let values = arr(key) else { return nil }
            var out: [EntityRef] = []
            for value in values {
                guard let ref = EntityRef.of(value) else { return nil }
                out.append(ref)
            }
            return out
        }
        func show() -> [String]? { arr("show")?.compactMap { $0.content?.lowercased() } }
        func flag(_ key: String) -> Bool { obj[key]?.boolValue == true || str(key) == "true" }

        let block: AssistantBlock
        switch type {
        case "text":
            guard let text = str("text") else { return malformed }
            block = .text(text)
        case "item_card":
            guard let id = id("id", "s") else { return malformed }
            block = .itemCard(id: id, show: show() ?? AssistantBlock.itemShow)
        case "place_card":
            guard let id = id("id", "l") else { return malformed }
            block = .placeCard(id: id, show: show() ?? AssistantBlock.placeShow)
        case "update_card":
            guard let id = id("id", "u") else { return malformed }
            block = .updateCard(id: id)
        case "list":
            guard let refs = refs("ids") else { return malformed }
            block = .list(ids: refs, title: str("title"), limit: obj["limit"]?.intValue)
        case "carousel":
            guard let refs = refs("ids") else { return malformed }
            block = .carousel(ids: refs, title: str("title"))
        case "timeline":
            var list: [Int] = []
            if obj.contains("ids") {
                guard let read = ids("ids", "s") else { return malformed }
                list = read
            }
            let source = str("source")?.lowercased()
            if list.isEmpty && source == nil { return malformed }
            block = .timeline(ids: list, source: source, title: str("title"))
        case "map":
            guard let pins = ids("pins", "l") else { return malformed }
            var route: [Int] = []
            if obj.contains("route") {
                guard let read = ids("route", "l") else { return malformed }
                route = read
            }
            block = .map(pins: pins, route: route)
        case "gallery":
            let flyer = flag("flyer")
            var list: [Int] = []
            if obj.contains("ids") {
                guard let read = ids("ids", "l") else { return malformed }
                list = read
            }
            if list.isEmpty && !flyer { return malformed }
            block = .gallery(ids: list, flyer: flyer)
        case "now_next":
            if let value = obj["location"], !value.isNull {
                guard let location = id("location", "l") else { return malformed }
                block = .nowNext(location: location)
            } else {
                block = .nowNext(location: nil)
            }
        case "countdown":
            guard let id = id("id", "s") else { return malformed }
            block = .countdown(id: id)
        case "compare":
            guard let a = str("a"), let b = str("b") else { return malformed }
            block = .compare(a: a, b: b)
        case "plan_diff":
            guard let diff = obj["diff"]?.objectValue.flatMap(decodeDiff) else { return malformed }
            block = .planDiff(diff)
        case "plan":
            if let day = str("day") {
                guard let date = PlanDate.parse(day) else { return malformed }
                block = .plan(day: date)
            } else {
                block = .plan(day: nil)
            }
        case "setting":
            guard let setting = str("setting") else { return malformed }
            block = .setting(setting.lowercased())
        case "summary":
            guard let kind = str("kind") else { return malformed }
            block = .summary(kind.lowercased())
        case "share":
            guard let target = str("target") else { return malformed }
            block = .share(target.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        case "chips":
            guard let values = arr("chips") else { return malformed }
            var chips: [AssistantChip] = []
            for value in values {
                guard let chip = value.objectValue, let label = chip["label"]?.content else { return malformed }
                // An action this build doesn't know (or never offers) only drops that chip.
                guard let name = ActionName.of(chip["action"]?.content) else { continue }
                chips.append(AssistantChip(label: label, action: AssistantAction(name: name, params: chip["params"]?.objectValue ?? JSONObject())))
            }
            block = .chips(chips)
        case "confirm":
            guard let name = ActionName.of(str("action")) else { return malformed }
            block = .confirm(action: AssistantAction(name: name, params: obj["params"]?.objectValue ?? JSONObject()), prompt: str("prompt") ?? "")
        default:
            return .unknown
        }
        return .ok(block)
    }

    static func decodeDiff(_ obj: JSONObject) -> PlanDiff? {
        func ids(_ key: String) -> [Int]? {
            guard let values = obj[key]?.arrayValue else { return [] }
            var out: [Int] = []
            for value in values {
                guard let id = EntityRef.id(value, prefix: "s") else { return nil }
                out.append(id)
            }
            return out
        }
        func slots(_ key: String) -> [MealSlot] {
            (obj[key]?.arrayValue ?? []).compactMap { $0.content.flatMap(MealSlot.decode) }
        }
        var moved: [PlanDiff.Move] = []
        for pair in obj["moved"]?.arrayValue ?? [] {
            guard let p = pair.arrayValue,
                  let a = EntityRef.id(p.first, prefix: "s"),
                  let b = EntityRef.id(p.count > 1 ? p[1] : nil, prefix: "s") else { return nil }
            moved.append(PlanDiff.Move(from: a, to: b))
        }
        guard let removed = ids("removed"), let added = ids("added") else { return nil }
        return PlanDiff(removed: removed, added: added, moved: moved,
                        mealsRemoved: slots("meals_removed"), mealsAdded: slots("meals_added"), mealsMoved: slots("meals_moved"))
    }
}

/// What `BlockValidator` checks blocks against.
struct BlockContext: Sendable {
    var bundle: EventBundle
    var plan: Plan?
    var now: Date
}

/// Validation of blocks against the bundle (assistant spec §2), for the model's and the router's
/// output alike (Android `BlockValidator`, rule for rule):
/// - `text`: trimmed, dropped when empty, cut to 399 characters + "…" when longer than 400.
/// - cards / `countdown`: the id must exist (countdown: an item that hasn't started); unknown
///   `show` parts dropped (none left → the defaults).
/// - `list`: existing ids, first occurrence, ≤ 20; `limit` clamped to 1…20.
/// - `carousel`: existing ids, distinct, ≤ 8; one left → that entity's card; none → dropped.
/// - `timeline`: existing schedule ids with a start, distinct, by (start, end, id), ≤ 20; `source`
///   `plan` needs a plan, `whats_on` is fine, anything else is cleared; nothing left → dropped.
/// - `map`: pins with coordinates, distinct, ≤ 12; `route` likewise (≤ 25, kept with ≥ 2 stops).
/// - `gallery`: locations with an image, ≤ 8; `flyer` only when the event has one.
/// - `now_next`: an unknown location is dropped. `compare`: both sides valid and different.
///   `plan_diff`, `plan` (a plan day or none), `share plan` and `summary walking` need a plan;
///   `share item:s12` an existing item; `setting`/`summary` known kinds. (Android's `calendar` block
///   isn't an iOS type: it decodes as unknown and is dropped.)
/// - `chips`: label trimmed, 1–60 characters, valid action, distinct labels, ≤ 5. `confirm`: a
///   valid mutating action; an empty prompt gets `ActionRegistry.confirmPrompt`.
/// Then only the last `chips` block is kept, moved to the end, and the response is cut to 8 blocks.
enum BlockValidator {
    static let maxBlocks = 8
    static let maxChips = 5
    static let maxText = 400
    static let maxCarousel = 8
    static let maxList = 20
    static let maxPins = 12
    static let maxChipLabel = 60

    static func validate(_ blocks: [AssistantBlock], _ ctx: BlockContext) -> [AssistantBlock] {
        let valid = blocks.compactMap { one($0, ctx) }
        let chips = valid.last { $0.isChips }
        let content = valid.filter { !$0.isChips }
        if let chips { return Array(content.prefix(maxBlocks - 1)) + [chips] }
        return Array(content.prefix(maxBlocks))
    }

    private static func distinct<T: Hashable>(_ values: [T]) -> [T] {
        var seen = Set<T>()
        return values.filter { seen.insert($0).inserted }
    }

    private static func cleanTitle(_ title: String?) -> String? {
        guard let t = title?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return t
    }

    private static func one(_ block: AssistantBlock, _ ctx: BlockContext) -> AssistantBlock? {
        let bundle = ctx.bundle
        let hasPlan = ctx.plan != nil
        func item(_ id: Int) -> Bool { bundle.scheduleItem(id) != nil }
        func place(_ id: Int) -> Bool { bundle.location(id) != nil }
        func pinnable(_ id: Int) -> Bool { bundle.location(id)?.coordinate != nil }
        switch block {
        case .text(let raw):
            let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty { return nil }
            if text.count > maxText { return .text(String(text.prefix(maxText - 1)).trimmingTrailingSpaces() + "…") }
            return .text(text)
        case .itemCard(let id, let show):
            return item(id) ? .itemCard(id: id, show: parts(show, AssistantBlock.itemParts, AssistantBlock.itemShow)) : nil
        case .placeCard(let id, let show):
            return place(id) ? .placeCard(id: id, show: parts(show, AssistantBlock.placeParts, AssistantBlock.placeShow)) : nil
        case .updateCard(let id):
            return bundle.notifications.contains { $0.id == id } ? block : nil
        case .list(let ids, let title, let limit):
            let kept = Array(distinct(ids.filter { $0.exists(bundle) }).prefix(maxList))
            if kept.isEmpty { return nil }
            return .list(ids: kept, title: cleanTitle(title), limit: limit.map { min(max($0, 1), maxList) })
        case .carousel(let ids, let title):
            let kept = Array(distinct(ids.filter { $0.exists(bundle) }).prefix(maxCarousel))
            switch kept.count {
            case 0: return nil
            case 1: return card(kept[0])
            default: return .carousel(ids: kept, title: cleanTitle(title))
            }
        case .timeline(let ids, let source, let title):
            let items = distinct(ids).compactMap { bundle.scheduleItem($0) }.filter { $0.startTime != nil }
                .stableSorted(by: Planner.itemOrder).map(\.id)
            let kept = Array(items.prefix(maxList))
            let src = source.flatMap { ($0 == "plan" && hasPlan) || $0 == "whats_on" ? $0 : nil }
            if kept.isEmpty && src == nil { return nil }
            return .timeline(ids: kept, source: src, title: cleanTitle(title))
        case .map(let pins, let route):
            let kept = Array(distinct(pins.filter(pinnable)).prefix(maxPins))
            let stops = Array(route.filter(pinnable).prefix(DayRoutes.maxStops))
            if kept.isEmpty { return nil }
            return .map(pins: kept, route: stops.count >= 2 ? stops : [])
        case .gallery(let ids, let flyer):
            let kept = Array(distinct(ids.filter { bundle.location($0)?.imageUrl != nil }).prefix(maxCarousel))
            let hasFlyer = flyer && bundle.event.flyerUrl != nil
            if kept.isEmpty && !hasFlyer { return nil }
            return .gallery(ids: kept, flyer: hasFlyer)
        case .nowNext(let location):
            return location.map(place) ?? true ? block : nil
        case .countdown(let id):
            guard let start = bundle.scheduleItem(id)?.startTime, start > ctx.now else { return nil }
            return block
        case .compare(let rawA, let rawB):
            func side(_ s: String) -> Bool {
                if s.hasPrefix("plan:") { return hasPlan && PlanVersionKind.of(String(s.dropFirst(5))) != nil }
                guard let ref = EntityRef.parse(s) else { return false }
                return ref.kind == .schedule && ref.exists(bundle)
            }
            let a = rawA.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let b = rawB.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return a != b && side(a) && side(b) ? .compare(a: a, b: b) : nil
        case .planDiff(var diff):
            guard hasPlan else { return nil }
            diff.removed = diff.removed.filter(item)
            diff.added = diff.added.filter(item)
            diff.moved = diff.moved.filter { item($0.from) && item($0.to) }
            return .planDiff(diff)
        case .plan(let day):
            guard let plan = ctx.plan else { return nil }
            return day == nil || plan.days.contains { $0.date == day } ? block : nil
        case .setting(let setting):
            return AssistantBlock.settings.contains(setting) ? block : nil
        case .summary(let kind):
            return AssistantBlock.summaries.contains(kind) && (kind != "walking" || hasPlan) ? block : nil
        case .share(let target):
            if target == "plan" { return hasPlan ? block : nil }
            if target.hasPrefix("item:") {
                guard let ref = EntityRef.parse(String(target.dropFirst(5))), ref.kind == .schedule, ref.exists(bundle) else { return nil }
                return .share("item:\(ref.code)")
            }
            return nil
        case .chips(let chips):
            var seen = Set<String>()
            var kept: [AssistantChip] = []
            for chip in chips {
                let label = chip.label.trimmingCharacters(in: .whitespacesAndNewlines)
                if label.isEmpty || label.count > maxChipLabel || !seen.insert(label.lowercased()).inserted { continue }
                if case .valid(let action) = ActionRegistry.check(chip.action.name.key, chip.action.params, bundle, now: ctx.now) {
                    kept.append(AssistantChip(label: label, action: action))
                }
            }
            kept = Array(kept.prefix(maxChips))
            return kept.isEmpty ? nil : .chips(kept)
        case .confirm(let action, let prompt):
            guard case .valid(let checked) = ActionRegistry.check(action.name.key, action.params, bundle, now: ctx.now),
                  action.name.mutates else { return nil }
            let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
            return .confirm(action: checked, prompt: text.isEmpty ? ActionRegistry.confirmPrompt(checked) : text)
        }
    }

    private static func parts(_ show: [String], _ allowed: Set<String>, _ fallback: [String]) -> [String] {
        let kept = distinct(show.map { $0.lowercased() }.filter { allowed.contains($0) })
        return kept.isEmpty ? fallback : kept
    }

    /// The card for one entity.
    static func card(_ ref: EntityRef) -> AssistantBlock {
        switch ref.kind {
        case .schedule: return .itemCard(id: ref.id)
        case .location: return .placeCard(id: ref.id)
        case .update: return .updateCard(id: ref.id)
        }
    }
}
