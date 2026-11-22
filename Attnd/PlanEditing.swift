// PlanEditing.swift
// Attnd (app + App Clip; unit tested in PlanEditingTests)
//
// Plan edits (assistant spec §4), a port of Android's `domain/PlanEditing.kt`: `PlanOp`s become
// `PlanConstraints` plus one re-solve (`Planner.replan`, rule 20), never hand-moved entries.
// `PlanDiff` is what an edit changed (the `plan_diff` block), `PlanHistory` the undo stack
// (≤ 20 per plan), `PlanVersionKind` Chill / See everything, `PlanOpJSON` the ops' JSON form.

import Foundation

/// One plan edit (the `plan_edit(ops[])` action). Item ids are schedule item ids.
enum PlanOp: Hashable, Sendable {
    /// Swap `item` out for `with`, else the best fitting item like `like`, else the best fitting item tagged `tag`.
    case replace(item: Int, with: Int? = nil, like: Int? = nil, tag: String? = nil)
    case remove(item: Int)
    case add(item: Int)
    /// Another showing of the same item (same name) later / earlier the same event.
    case move(item: Int, later: Bool)
    case keep(item: Int)
    case unkeep(item: Int)
    /// "I already ate": `until` = now + 3 h; also marks the next meal break done.
    case noFoodUntil(Date)
    case doneBy(PlanClock)
    case startAt(PlanClock)
    case maxWalk(Int)
    case pace(PlanPace)
    /// "I'm at <place>": the plan restarts from that location now.
    case fromLocation(Int)
    case moreTag(String)
    case lessTag(String)
}

/// What an edit changed: removed and added items in plan order, moved pairs (old id → new id
/// with the same name: another showing), and meal breaks removed / added / moved.
struct PlanDiff: Hashable, Sendable {
    struct Move: Hashable, Sendable {
        var from: Int
        var to: Int
    }

    var removed: [Int] = []
    var added: [Int] = []
    var moved: [Move] = []
    var mealsRemoved: [MealSlot] = []
    var mealsAdded: [MealSlot] = []
    var mealsMoved: [MealSlot] = []

    var isEmpty: Bool {
        removed.isEmpty && added.isEmpty && moved.isEmpty && mealsRemoved.isEmpty && mealsAdded.isEmpty && mealsMoved.isEmpty
    }

    /// `before` → `after`: removed / added in their plan's order; then each removed item is paired
    /// with the first unpaired added item whose normalised name is equal (moved); meals by
    /// (day, kind): gone, new, or another start.
    static func between(_ before: Plan, _ after: Plan, _ bundle: EventBundle) -> PlanDiff {
        let oldIds = before.itemIds, newIds = after.itemIds
        var removed = oldIds.filter { !newIds.contains($0) }
        var added = newIds.filter { !oldIds.contains($0) }
        var moved: [Move] = []
        for r in removed {
            guard let name = bundle.scheduleItem(r).map({ PlanText.normalize($0.name) }),
                  let match = added.first(where: { a in bundle.scheduleItem(a).map { PlanText.normalize($0.name) } == name }) else { continue }
            moved.append(Move(from: r, to: match))
            removed.removeAll { $0 == r }
            added.removeAll { $0 == match }
        }
        func meals(_ plan: Plan) -> [MealSlot: Date] {
            var result: [MealSlot: Date] = [:]
            for day in plan.days { for meal in day.meals { result[MealSlot(date: day.date, kind: meal.kind)] = meal.start } }
            return result
        }
        let oldMeals = meals(before), newMeals = meals(after)
        return PlanDiff(
            removed: removed,
            added: added,
            moved: moved,
            mealsRemoved: oldMeals.keys.filter { newMeals[$0] == nil }.sorted(by: <),
            mealsAdded: newMeals.keys.filter { oldMeals[$0] == nil }.sorted(by: <),
            mealsMoved: oldMeals.filter { slot, start in newMeals[slot].map { $0 != start } ?? false }.keys.sorted(by: <)
        )
    }
}

/// A previewed edit: the plan before and after, what changed and anything that could not be done.
struct PlanEdit: Hashable, Sendable {
    var before: Plan
    var after: Plan
    var diff: PlanDiff
    /// Plain sentences such as "Nothing like Neon Armadillo fits there".
    var notes: [String]
}

/// Applies `PlanOp`s (Android `PlanEditor`, same rules): ops are read in order against the plan as
/// it was, each changing the accumulated constraints; then the plan is re-solved once at `now`.
/// - Replace removes `item` (excluded, unpinned) and pins the replacement: `with`; else the slot's
///   best candidate (the day's candidates not planned, not the item, not `like`, not excluded,
///   fitting between the item's planned neighbours): `like` → highest similarity (ties score desc,
///   start, id), `tag` → items with that tag by (score desc, start, id). Nothing fits → only the
///   removal and a note. An item that isn't planned → no change, "<name> isn't in your plan".
/// - Remove excludes and unpins. Add / Keep pin and un-exclude (started and not planned → note
///   "<name> has already started"). Unkeep unpins. Move → another showing (same normalised name,
///   after / before, not started, not planned) replaces it, else "<name> has no later time".
/// - NoFoodUntil sets it and marks the plan's next meal (first ending after now) done. DoneBy,
///   StartAt, MaxWalk (> 0), Pace set theirs. FromLocation = (location, now). MoreTag / LessTag
///   add the lower-case tag to one set and remove it from the other.
/// - Afterwards every item an op pinned that didn't make it gets "<name> doesn't fit your plan".
enum PlanEditor {

    static func preview(_ plan: Plan, _ ops: [PlanOp], _ bundle: EventBundle, _ likes: LikeSet, now: Date) -> PlanEdit {
        var c = plan.constraints
        var notes: [String] = []
        var pinnedByOps: [Int] = []
        func name(_ id: Int) -> String { bundle.scheduleItem(id)?.name ?? "That item" }
        func started(_ id: Int) -> Bool { bundle.scheduleItem(id)?.startTime.map { $0 < now } ?? true }
        func pin(_ id: Int) {
            c.pinned.insert(id)
            c.excluded.remove(id)
            pinnedByOps.append(id)
        }
        func drop(_ id: Int) {
            c.pinned.remove(id)
            c.excluded.insert(id)
        }
        let planned = plan.itemIds

        for op in ops {
            switch op {
            case .replace(let item, let with, let like, let tag):
                if !planned.contains(item) {
                    notes.append("\(name(item)) isn't in your plan")
                    continue
                }
                let replacement = with.flatMap { bundle.scheduleItem($0) != nil ? $0 : nil }
                    ?? slotChoice(plan, item: item, like: like, tag: tag, bundle, likes, c)
                drop(item)
                if let replacement {
                    pin(replacement)
                } else if let like {
                    notes.append("Nothing like \(name(like)) fits there")
                } else if let tag {
                    notes.append("Nothing tagged \(tag.lowercased()) fits there")
                }
            case .remove(let item):
                if !planned.contains(item) { notes.append("\(name(item)) isn't in your plan") }
                drop(item)
            case .add(let id), .keep(let id):
                if bundle.scheduleItem(id) == nil { continue }
                if started(id) && !planned.contains(id) {
                    notes.append("\(name(id)) has already started")
                    continue
                }
                pin(id)
            case .unkeep(let item):
                c.pinned.remove(item)
            case .move(let item, let later):
                guard let other = otherShowing(bundle, item, later: later, now: now, planned: Set(planned)) else {
                    notes.append("\(name(item)) has no \(later ? "later" : "earlier") time")
                    continue
                }
                drop(item)
                pin(other)
            case .noFoodUntil(let until):
                let next = plan.days.flatMap { day in day.meals.map { (day.date, $0) } }.first { $0.1.end > now }
                c.noFoodUntil = until
                if let next { c.mealsDone.insert(MealSlot(date: next.0, kind: next.1.kind)) }
            case .doneBy(let time): c.doneBy = time
            case .startAt(let time): c.startAt = time
            case .maxWalk(let minutes): if minutes > 0 { c.maxWalkMinutes = minutes }
            case .pace(let pace): c.pace = pace
            case .fromLocation(let id): if bundle.location(id) != nil { c.origin = PlanOrigin(locationId: id, at: now) }
            case .moreTag(let tag):
                let t = tag.lowercased()
                c.moreTags.insert(t)
                c.lessTags.remove(t)
            case .lessTag(let tag):
                let t = tag.lowercased()
                c.lessTags.insert(t)
                c.moreTags.remove(t)
            }
        }
        let after = Planner(bundle: bundle, preferences: plan.preferences, heartedItems: likes.scheduleItems,
                            heartedLocations: likes.locations, constraints: c).replan(plan, from: now)
        var noted = Set<Int>()
        for id in pinnedByOps where noted.insert(id).inserted && !after.itemIds.contains(id) && c.pinned.contains(id) {
            notes.append("\(name(id)) doesn't fit your plan")
        }
        return PlanEdit(before: plan, after: after, diff: PlanDiff.between(plan, after, bundle), notes: notes)
    }

    /// The replacement for a like / tag replace in its slot, or nil.
    private static func slotChoice(
        _ plan: Plan, item: Int, like: Int?, tag: String?, _ bundle: EventBundle, _ likes: LikeSet, _ c: PlanConstraints
    ) -> Int? {
        if like == nil && tag == nil { return nil }
        guard let day = plan.days.first(where: { d in d.items.contains { $0.itemId == item } }),
              let index = day.items.firstIndex(where: { $0.itemId == item }) else { return nil }
        let planner = Planner(bundle: bundle, preferences: plan.preferences, heartedItems: likes.scheduleItems,
                              heartedLocations: likes.locations, constraints: c)
        let previous = index > 0 ? bundle.scheduleItem(day.items[index - 1].itemId) : nil
        let next = index + 1 < day.items.count ? bundle.scheduleItem(day.items[index + 1].itemId) : nil
        let planned = Set(plan.itemIds)
        let pool = planner.dayCandidates(day).filter { cand in
            !planned.contains(cand.id) && cand.id != item && cand.id != like && !c.excluded.contains(cand.id)
                && (previous.map { planner.canFollow($0, cand) } ?? true) && (next.map { planner.canFollow(cand, $0) } ?? true)
        }
        func byScore(_ a: ScheduleItem, _ b: ScheduleItem) -> Bool {
            let sa = planner.score(a), sb = planner.score(b)
            if sa != sb { return sa > sb }
            if a.startTime != b.startTime { return (a.startTime ?? .distantPast) < (b.startTime ?? .distantPast) }
            return a.id < b.id
        }
        if let like {
            guard let target = bundle.scheduleItem(like) else { return nil }
            let similarity = TfIdfSimilarity(bundle)
            return pool.map { ($0, similarity.similarity($0, target)) }
                .stableSorted { a, b in a.1 != b.1 ? a.1 > b.1 : byScore(a.0, b.0) }
                .first?.0.id
        }
        let wanted = (tag ?? "").lowercased()
        return pool.filter { $0.tags.contains { $0.lowercased() == wanted } }.stableSorted(by: byScore).first?.id
    }

    /// Move: another showing (same normalised name) after / before `id`, not started at `now`, not planned.
    static func otherShowing(_ bundle: EventBundle, _ id: Int, later: Bool, now: Date, planned: Set<Int> = []) -> Int? {
        guard let item = bundle.scheduleItem(id), let start = item.startTime else { return nil }
        let name = PlanText.normalize(item.name)
        let showings = bundle.schedule.filter {
            $0.id != id && !planned.contains($0.id) && PlanText.normalize($0.name) == name && ($0.startTime.map { $0 >= now } ?? false)
        }.stableSorted(by: Planner.itemOrder)
        if later { return showings.first { ($0.startTime ?? .distantPast) > start }?.id }
        return showings.last { ($0.startTime ?? .distantFuture) < start }?.id
    }
}

/// Plan versions: Chill = relaxed pace + walks ≤ 10 min, See everything = packed.
enum PlanVersionKind: String, CaseIterable, Hashable, Sendable {
    case chill, everything

    static let chillMaxWalk = 10

    var key: String { rawValue }

    var label: String {
        switch self {
        case .chill: return "Chill"
        case .everything: return "See everything"
        }
    }

    var ops: [PlanOp] {
        switch self {
        case .chill: return [.pace(.relaxed), .maxWalk(Self.chillMaxWalk)]
        case .everything: return [.pace(.packed)]
        }
    }

    static func of(_ value: String?) -> PlanVersionKind? {
        value.flatMap { PlanVersionKind(rawValue: $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) }
    }
}

enum PlanVersions {
    static func make(_ kind: PlanVersionKind, _ plan: Plan, _ bundle: EventBundle, _ likes: LikeSet, now: Date) -> PlanEdit {
        PlanEditor.preview(plan, kind.ops, bundle, likes, now: now)
    }
}

/// The undo stack of one plan (≤ 20 earlier versions, newest last) of older builds. Since the
/// one-list change (Nov 22, 2026) it is only read once, for the migration (`PlanStore.load`); the
/// Undo history is `ScheduleHistory` over My schedule.
struct PlanHistory: Hashable, Sendable {
    static let max = 20

    var plans: [Plan] = []

    var canUndo: Bool { !plans.isEmpty }

    func push(_ previous: Plan) -> PlanHistory { PlanHistory(plans: Array((plans + [previous]).suffix(Self.max))) }

    /// The plan to restore and the remaining history; nil when there is nothing to undo.
    func pop() -> (plan: Plan, rest: PlanHistory)? {
        guard let last = plans.last else { return nil }
        return (last, PlanHistory(plans: Array(plans.dropLast())))
    }

    /// A JSON array of `PlanCodec` texts.
    func encode() -> String {
        let texts = plans.compactMap { PlanCodec.encode($0).flatMap { String(data: $0, encoding: .utf8) } }
        return JSONValue.array(texts.map(JSONValue.string)).encoded
    }

    /// Lenient: unreadable entries are skipped, a broken text is an empty history.
    static func decode(_ text: String?) -> PlanHistory {
        guard let text, let array = JSONValue.parse(text)?.arrayValue else { return PlanHistory() }
        return PlanHistory(plans: Array(array.compactMap { $0.stringValue.flatMap { PlanCodec.decode($0) } }.suffix(max)))
    }
}

/// The JSON form of `PlanOp`s inside actions and model turns: `{"op":"replace","item":"s103","like":"s114"}`,
/// `{"op":"remove","item":103}`, `{"op":"move","item":"s3","direction":"later"}` (or `"later":true`),
/// `{"op":"constraint","no_food_until":"13:00"}` (also `done_by`, `start_at` "HH:MM"; `max_walk_min`,
/// `pace`, `from_location` "l6", `more_tag`, `less_tag`). Clock times are today in the event's
/// zone (an ISO instant is accepted for `no_food_until`). Unreadable ops → nil.
enum PlanOpJSON {

    static func parse(_ element: JSONValue?, timeZone: TimeZone, now: Date) -> [PlanOp]? {
        guard let array = element?.arrayValue else { return nil }
        var ops: [PlanOp] = []
        for value in array {
            guard let obj = value.objectValue, let op = parseOne(obj, timeZone, now) else { return nil }
            ops.append(op)
        }
        return ops
    }

    private static func parseOne(_ obj: JSONObject, _ zone: TimeZone, _ now: Date) -> PlanOp? {
        func str(_ key: String) -> String? {
            guard let value = obj[key], !value.isNull else { return nil }
            return value.content?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        func id(_ key: String) -> Int? { EntityRef.id(obj[key], prefix: "s") }
        let item = id("item")
        switch str("op")?.lowercased() {
        case "replace"?:
            return item.map { .replace(item: $0, with: id("with"), like: id("like"), tag: str("tag")?.lowercased()) }
        case "remove"?: return item.map { .remove(item: $0) }
        case "add"?: return item.map { .add(item: $0) }
        case "move"?:
            guard let item else { return nil }
            if str("later") == "true" || str("direction") == "later" { return .move(item: item, later: true) }
            if str("earlier") == "true" || str("direction") == "earlier" { return .move(item: item, later: false) }
            return nil
        case "keep"?: return item.map { .keep(item: $0) }
        case "unkeep"?: return item.map { .unkeep(item: $0) }
        case "constraint"?:
            if obj.contains("no_food_until") { return instantOrClock(str("no_food_until"), zone, now).map { .noFoodUntil($0) } }
            if obj.contains("done_by") { return clock(str("done_by")).map { .doneBy($0) } }
            if obj.contains("start_at") { return clock(str("start_at")).map { .startAt($0) } }
            if obj.contains("max_walk_min") {
                guard let minutes = obj["max_walk_min"]?.intValue, minutes > 0 else { return nil }
                return .maxWalk(minutes)
            }
            if obj.contains("pace") { return str("pace").flatMap { PlanPace(rawValue: $0.lowercased()) }.map { .pace($0) } }
            if obj.contains("from_location") { return EntityRef.id(obj["from_location"], prefix: "l").map { .fromLocation($0) } }
            if obj.contains("more_tag") { return str("more_tag").flatMap { $0.isEmpty ? nil : .moreTag($0.lowercased()) } }
            if obj.contains("less_tag") { return str("less_tag").flatMap { $0.isEmpty ? nil : .lessTag($0.lowercased()) } }
            return nil
        default:
            return nil
        }
    }

    static func encode(_ ops: [PlanOp], timeZone: TimeZone) -> JSONValue { .array(ops.map { .object(encodeOne($0)) }) }

    private static func encodeOne(_ op: PlanOp) -> JSONObject {
        func s(_ id: Int) -> JSONValue { .string("s\(id)") }
        switch op {
        case .replace(let item, let with, let like, let tag):
            var o: JSONObject = ["op": "replace", "item": s(item)]
            if let with { o["with"] = s(with) }
            if let like { o["like"] = s(like) }
            if let tag { o["tag"] = .string(tag) }
            return o
        case .remove(let item): return ["op": "remove", "item": s(item)]
        case .add(let item): return ["op": "add", "item": s(item)]
        case .move(let item, let later): return ["op": "move", "item": s(item), "direction": .string(later ? "later" : "earlier")]
        case .keep(let item): return ["op": "keep", "item": s(item)]
        case .unkeep(let item): return ["op": "unkeep", "item": s(item)]
        case .noFoodUntil(let until): return ["op": "constraint", "no_food_until": .string(ISODate.string(from: until))]
        case .doneBy(let time): return ["op": "constraint", "done_by": .string(time.description)]
        case .startAt(let time): return ["op": "constraint", "start_at": .string(time.description)]
        case .maxWalk(let minutes): return ["op": "constraint", "max_walk_min": .int(minutes)]
        case .pace(let pace): return ["op": "constraint", "pace": .string(pace.rawValue)]
        case .fromLocation(let id): return ["op": "constraint", "from_location": .string("l\(id)")]
        case .moreTag(let tag): return ["op": "constraint", "more_tag": .string(tag)]
        case .lessTag(let tag): return ["op": "constraint", "less_tag": .string(tag)]
        }
    }

    private static func clock(_ text: String?) -> PlanClock? {
        guard let text, let g = Rx.find(#"^(\d{1,2}):(\d{2})"#, text), let h = Int(g[1]), let m = Int(g[2]),
              (0...23).contains(h), (0...59).contains(m) else { return nil }
        return PlanClock(hour: h, minute: m)
    }

    private static func instantOrClock(_ text: String?, _ zone: TimeZone, _ now: Date) -> Date? {
        guard let text else { return nil }
        if let date = ISODate.parse(text) { return date }
        guard let time = clock(text) else { return nil }
        let calendar = PlanCalendar.calendar(zone)
        return PlanDate(now, in: calendar).at(time, in: calendar)
    }
}
