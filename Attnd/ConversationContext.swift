// ConversationContext.swift
// Attnd (app and App Clip; pure, unit tested in ConversationContextTests)
//
// The assistant's memory of what it showed (iOS, Nov 21, 2026; iOS diverges from Android): each
// answer records the entities it showed, in order, the focus entity (what the turn acted on, else
// the first shown) and the last action. The router resolves references against it before its other
// rules: "it" / "that" / "this one" / "there" / "here" → the focus; "them" / "both" → the shown
// ones; "the first" / "second" / "last" / "option 3" / "number 2" → by position; a description
// ("the taco place") → the shown entity it fits. Stored per event with the conversation (≤ 40 turns).

import Foundation

struct ConversationContext: Hashable, Sendable {
    static let maxShown = 12

    /// Entities of the last answer that showed any, in order.
    var shown: [EntityRef] = []
    /// What the last turn was about (an action's target, else the first shown).
    var focus: EntityRef? = nil
    /// The last action's name ("schedule_add").
    var lastAction: String? = nil

    var isEmpty: Bool { shown.isEmpty && focus == nil }

    // MARK: Recording

    /// Records an answer: its blocks' entities in order and the focus. A turn that shows nothing
    /// (a sentence, chips) keeps the earlier entities, so "add it" still works after "When?".
    mutating func record(_ turn: AssistantTurn) {
        var seen = Set<EntityRef>()
        let refs = turn.blocks.flatMap(Self.refs).filter { seen.insert($0).inserted }
        let acted = turn.actions.compactMap(Self.target).first
        if !refs.isEmpty { shown = Array(refs.prefix(Self.maxShown)) }
        if let acted {
            focus = acted
        } else if let first = refs.first {
            focus = first
        }
        if let action = turn.actions.first { lastAction = action.name.key }
    }

    /// The entities a block shows, in order (cards, lists, timelines, pins, chips' targets).
    static func refs(_ block: AssistantBlock) -> [EntityRef] {
        switch block {
        case .nowNext(let location): return location.map { [EntityRef(kind: .location, id: $0)] } ?? []
        case .compare(let a, let b): return [a, b].compactMap(EntityRef.parse)
        case .component(let component): return component.ids
        case .chips(let chips): return chips.compactMap { target($0.action) }
        case .confirm(let action, _): return target(action).map { [$0] } ?? []
        default: return AssistantFlow.refs(block)
        }
    }

    /// The entity an action is about (`target`, `id` with `kind`, `item`, `location`).
    static func target(_ action: AssistantAction) -> EntityRef? {
        if let ref = EntityRef.of(action.params["target"]) { return ref }
        if let like = action.likeTarget() { return EntityRef(kind: RefKind.of(like.kind) ?? .schedule, id: like.id) }
        if let id = action.id("item", prefix: "s") { return EntityRef(kind: .schedule, id: id) }
        if let id = action.id("location", prefix: "l") { return EntityRef(kind: .location, id: id) }
        return nil
    }

    // MARK: Resolution

    private static let singular: Set<String> = [
        "it", "that", "this", "this one", "that one", "the one", "there", "here", "that place", "this place",
        "that thing", "this thing", "the place", "that show", "this show", "that spot", "it there",
    ]
    private static let plural: Set<String> = ["them", "both", "both of them", "those", "these", "all of them", "all of those", "all three", "all"]
    private static let ordinals: [String: Int] = [
        "first": 0, "1st": 0, "second": 1, "2nd": 1, "third": 2, "3rd": 2, "fourth": 3, "4th": 3, "fifth": 4, "5th": 4,
        "sixth": 5, "6th": 5, "seventh": 6, "eighth": 7, "ninth": 8, "tenth": 9,
    ]
    private static let numbers: [String: Int] = ["one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8]
    /// Words a description may carry that say nothing about which entity it is.
    private static let generic: Set<String> = ["the", "a", "an", "one", "place", "spot", "thing", "that", "this", "show", "option", "of", "those", "these"]

    /// The entities `phrase` refers to (of `kinds`), nil when it isn't a reference to what was shown.
    func resolve(_ phrase: String, kinds: Set<RefKind>, _ bundle: EventBundle) -> [EntityRef]? {
        let text = AssistantRouter.command(phrase)
        guard !text.isEmpty, !shown.isEmpty || focus != nil else { return nil }
        let candidates = shown.filter { kinds.contains($0.kind) && $0.exists(bundle) }
        if Self.singular.contains(text) {
            if let focus, kinds.contains(focus.kind), focus.exists(bundle) { return [focus] }
            return candidates.first.map { [$0] }
        }
        if Self.plural.contains(text) {
            if candidates.isEmpty { return nil }
            return text.hasPrefix("both") ? Array(candidates.prefix(2)) : candidates
        }
        if let index = Self.position(text, count: shown.count) {
            guard shown.indices.contains(index) else { return nil }
            let ref = shown[index]
            return kinds.contains(ref.kind) && ref.exists(bundle) ? [ref] : nil
        }
        // A description: every content word appears in a shown entity's name, category or tags.
        let words = text.split(separator: " ").map(String.init).filter { !Self.generic.contains($0) }
        guard text.hasPrefix("the ") || text.hasPrefix("that ") || text.hasPrefix("this "), !words.isEmpty else { return nil }
        let fits = candidates.filter { ref in
            let haystack = AssistantSearch.normalize(Self.description(ref, bundle))
            let hay = Set(AssistantSearch.words(haystack))
            return words.allSatisfy { word in
                hay.contains(word) || hay.contains(word + "s") || (word.hasSuffix("s") && hay.contains(String(word.dropLast())))
                    || haystack.contains(word)
            }
        }
        return fits.isEmpty ? nil : fits
    }

    /// "the first (one)", "second", "the last one", "option 3", "number 2", "#2" → index (a bare
    /// "3" is not a position).
    static func position(_ text: String, count: Int) -> Int? {
        var words = text.split(separator: " ").map(String.init)
        let explicit = words.contains("option") || words.contains("number")
        words.removeAll { ["the", "please", "option", "number", "no"].contains($0) }
        if explicit, words == ["one"] { return 0 }
        words.removeAll { $0 == "one" }
        guard words.count == 1, let word = words.first else { return nil }
        if word == "last" { return count > 0 ? count - 1 : nil }
        if let index = ordinals[word] { return index }
        if explicit, let n = Int(word) ?? numbers[word], n >= 1 { return n - 1 }
        return nil
    }

    private static func description(_ ref: EntityRef, _ bundle: EventBundle) -> String {
        switch ref.kind {
        case .schedule:
            guard let item = bundle.scheduleItem(ref.id) else { return "" }
            return ([item.name, item.locationName ?? "", bundle.location(item.locationId)?.name ?? ""] + item.tags).joined(separator: " ")
        case .location:
            guard let location = bundle.location(ref.id) else { return "" }
            return ([location.name, location.category ?? "", location.snippet] + location.tags).joined(separator: " ")
        case .update:
            return bundle.notifications.first { $0.id == ref.id }?.title ?? ""
        }
    }

    // MARK: Codec (stored with the conversation)

    func encode() -> JSONObject {
        var o: JSONObject = ["shown": .array(shown.map { .string($0.code) })]
        if let focus { o["focus"] = .string(focus.code) }
        if let lastAction { o["last_action"] = .string(lastAction) }
        return o
    }

    static func decode(_ value: JSONValue?) -> ConversationContext {
        guard let obj = value?.objectValue else { return ConversationContext() }
        return ConversationContext(
            shown: Array((obj["shown"]?.arrayValue ?? []).compactMap { EntityRef.of($0) }.prefix(maxShown)),
            focus: EntityRef.of(obj["focus"]),
            lastAction: obj["last_action"]?.stringValue
        )
    }
}
