// AssistantActions.swift
// Attnd (app + App Clip; unit tested in AssistantBlocksTests)
//
// The event assistant's action layer (assistant spec §1), a port of Android's
// `domain/AssistantActions.kt`: one registry (`ActionName`: name, params, mutates, confirm,
// result, undo, location) used by the assistant (model tool calls and the rule-based router),
// the plan page's buttons and Live Activity buttons. `ActionRegistry.check` validates names and
// params against the bundle; `ActionDispatcher` confirms and runs them through the platform's
// `ActionExecutor` (AssistantController) and hands back the Undo.

import Foundation

/// What an entity id points at: `s12` schedule item, `l3` location, `u9` organizer update.
enum RefKind: Hashable, Sendable, CaseIterable {
    case schedule, location, update

    var prefix: Character {
        switch self {
        case .schedule: return "s"
        case .location: return "l"
        case .update: return "u"
        }
    }

    var searchKind: AssistantSearch.Kind {
        switch self {
        case .schedule: return .schedule
        case .location: return .location
        case .update: return .notification
        }
    }

    static func of(prefix: Character) -> RefKind? {
        allCases.first { $0.prefix == Character(prefix.lowercased()) }
    }

    static func of(_ kind: AssistantSearch.Kind) -> RefKind? {
        allCases.first { $0.searchKind == kind }
    }
}

/// A typed id as blocks and actions carry it: "s12", "l3", "u9" (also read as "S12" or "[s12]").
struct EntityRef: Hashable, Sendable, CustomStringConvertible {
    var kind: RefKind
    var id: Int

    var code: String { "\(kind.prefix)\(id)" }
    var description: String { code }

    func exists(_ bundle: EventBundle) -> Bool {
        switch kind {
        case .schedule: return bundle.scheduleItem(id) != nil
        case .location: return bundle.location(id) != nil
        case .update: return bundle.notifications.contains { $0.id == id }
        }
    }

    func name(_ bundle: EventBundle) -> String? {
        switch kind {
        case .schedule: return bundle.scheduleItem(id)?.name
        case .location: return bundle.location(id)?.name
        case .update: return bundle.notifications.first { $0.id == id }?.title
        }
    }

    static func parse(_ text: String?) -> EntityRef? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines),
              let g = Rx.find(#"^\[?([slu])(\d+)\]?$"#, text.lowercased()),
              let prefix = g[1].first, let kind = RefKind.of(prefix: prefix), let id = Int(g[2]) else { return nil }
        return EntityRef(kind: kind, id: id)
    }

    /// A string JSON value read with `parse`.
    static func of(_ value: JSONValue?) -> EntityRef? {
        guard let text = value?.stringValue else { return nil }
        return parse(text)
    }

    static func of(_ result: AssistantSearch.Result) -> EntityRef? {
        RefKind.of(result.kind).map { EntityRef(kind: $0, id: result.id) }
    }

    /// An id of the kind `prefix` from JSON: a number, "12", or "s12" with a matching prefix
    /// ("l12" when a schedule id is expected → nil).
    static func id(_ value: JSONValue?, prefix: Character) -> Int? {
        guard let value, value.isPrimitive, !value.isNull else { return nil }
        guard let text = value.stringValue else { return value.intValue }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let id = Int(trimmed) { return id }
        guard let ref = parse(trimmed) else { return nil }
        return ref.kind.prefix == prefix ? ref.id : nil
    }
}

/// How a mutating action is confirmed (assistant spec §1–2).
enum ConfirmKind: Hashable, Sendable {
    /// Applies at once (with Undo where it has one).
    case none
    /// A `confirm` block (Yes / No) first.
    case chip
    /// The OS sheet (share) is the confirmation.
    case sheet
}

enum ParamType: Hashable, Sendable {
    case string, int, bool, time, day, kind, scheduleId, locationId, updateId, entity, entities, ops, enumeration
}

struct ActionParam: Hashable, Sendable {
    var name: String
    var type: ParamType
    var required = false
    var values: [String] = []
}

/// What an action gives back (for the model's catalogue and the renderer).
enum ActionResultType: Hashable, Sendable {
    case results, item, location, update, event, nowNext, timeline, liked, plan, explanation, route, dayRoute
    case planDiff, setting, sheet, navigation
}

/// Screens `open(screen, id?)` navigates to.
let assistantOpenScreens = ["map", "locations", "schedule", "updates", "flyer", "options", "tour", "plan"]

/// The action registry (assistant spec §1), in Android's order.
enum ActionName: String, CaseIterable, Hashable, Sendable {
    // Read
    case search, getItem = "get_item", getLocation = "get_location", getUpdate = "get_update", eventInfo = "event_info"
    case nowNext = "now_next", whatsOn = "whats_on", liked, plan, nearMe = "near_me", whyNot = "why_not", route
    case dayRoute = "day_route", mySchedule = "my_schedule"
    // Write
    case like, unlike, planMake = "plan_make", planEdit = "plan_edit", planUndo = "plan_undo", planVersion = "plan_version"
    case checkoff, followLockScreen = "follow_lock_screen", reminders, notifications
    case sharePlan = "share_plan", shareItem = "share_item", open, directions
    // My schedule (iOS, Nov 21, 2026): `target` = "s12" / "l3"; times "HH:MM" in the event's zone.
    case scheduleAdd = "schedule_add", scheduleRemove = "schedule_remove", scheduleMove = "schedule_move"
    case scheduleReminder = "schedule_reminder"
    // App settings from the chat (batch 7, iOS): the location dot, leaving the event (always
    // confirmed; `leave`, not Android's never-available `leave_event`), the test server switch
    // (TestFlight / Xcode installs only). Router only: the model's tools don't offer them.
    case location, leave, switchServer = "switch_server"

    var key: String { rawValue }

    private static func p(_ name: String, _ type: ParamType, _ required: Bool = false, _ values: String...) -> ActionParam {
        ActionParam(name: name, type: type, required: required, values: values)
    }

    var params: [ActionParam] {
        let p = Self.p
        switch self {
        case .search: return [p("query", .string, true), p("kinds", .string, false)]
        case .getItem: return [p("id", .scheduleId, true)]
        case .getLocation: return [p("id", .locationId, true)]
        case .getUpdate: return [p("id", .updateId, true)]
        case .eventInfo, .liked, .planUndo, .sharePlan: return []
        case .nowNext: return [p("at", .time, false), p("location", .locationId, false)]
        case .whatsOn: return [p("from", .time, false), p("to", .time, false), p("day", .day, false)]
        case .plan, .dayRoute: return [p("day", .day, false)]
        case .nearMe: return [p("kind", .string, false)]
        case .whyNot: return [p("item", .scheduleId, true)]
        case .route: return [p("to_location", .locationId, true), p("from", .locationId, false)]
        case .like, .unlike: return [p("kind", .kind, true, "schedule", "location"), p("id", .entity, true)]
        case .planMake: return [p("request", .string, true)]
        case .planEdit: return [p("ops", .ops, true)]
        case .planVersion: return [p("kind", .enumeration, true, "chill", "everything")]
        case .checkoff: return [p("item", .scheduleId, true), p("done", .bool, true)]
        case .followLockScreen, .reminders, .notifications, .location: return [p("on", .bool, true)]
        case .leave: return []
        case .switchServer: return [p("server", .enumeration, true, "production", "dev")]
        case .shareItem: return [p("id", .scheduleId, true)]
        case .open: return [ActionParam(name: "screen", type: .enumeration, required: true, values: assistantOpenScreens), p("id", .entity, false)]
        case .directions: return [p("location", .locationId, true)]
        case .mySchedule: return [p("day", .day, false)]
        case .scheduleAdd: return [p("target", .entity, true), p("time", .time, false), p("minutes", .int, false), p("replace", .entity, false)]
        case .scheduleRemove: return [p("target", .entity, true)]
        case .scheduleMove: return [p("target", .entity, true), p("time", .time, true)]
        case .scheduleReminder: return [p("target", .entity, true), p("minutes", .int, true)]
        }
    }

    var mutates: Bool {
        switch self {
        case .like, .unlike, .planMake, .planEdit, .planUndo, .planVersion, .checkoff, .followLockScreen, .reminders,
             .notifications, .sharePlan, .shareItem, .scheduleAdd, .scheduleRemove, .scheduleMove, .scheduleReminder,
             .location, .leave, .switchServer:
            return true
        default:
            return false
        }
    }

    var confirm: ConfirmKind {
        switch self {
        case .followLockScreen, .reminders, .notifications, .location, .leave, .switchServer: return .chip
        case .sharePlan, .shareItem: return .sheet
        default: return .none
        }
    }

    var result: ActionResultType {
        switch self {
        case .search, .nearMe: return .results
        case .getItem, .like, .unlike, .scheduleAdd, .scheduleRemove, .scheduleMove, .scheduleReminder: return .item
        case .mySchedule: return .liked
        case .getLocation: return .location
        case .getUpdate: return .update
        case .eventInfo: return .event
        case .nowNext: return .nowNext
        case .whatsOn: return .timeline
        case .liked: return .liked
        case .plan, .planMake, .planUndo, .checkoff: return .plan
        case .whyNot: return .explanation
        case .route: return .route
        case .dayRoute: return .dayRoute
        case .planEdit, .planVersion: return .planDiff
        case .followLockScreen, .reminders, .notifications, .location, .leave, .switchServer: return .setting
        case .sharePlan, .shareItem: return .sheet
        case .open, .directions: return .navigation
        }
    }

    /// Applies with an Undo (like ↔ unlike, checkoff ↔ un-checkoff, plan changes → `plan_undo`).
    var undoable: Bool {
        switch self {
        case .like, .unlike, .planMake, .planEdit, .planVersion, .checkoff, .scheduleAdd, .scheduleRemove: return true
        default: return false
        }
    }

    /// Needs the user's location (rejected without it).
    var needsLocation: Bool { self == .nearMe }

    static func of(_ key: String?) -> ActionName? {
        guard let key else { return nil }
        return ActionName(rawValue: key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    /// Manual-only actions: never offered to or accepted from the assistant.
    /// iOS adds `add_to_calendar` (Nov 19, 2026: no Add to Calendar on iOS; Android keeps it).
    static let neverAvailable: Set<String> = ["leave_event", "debug_mode", "copy_support_info", "add_to_calendar"]
}

/// An action call: a registry name and its JSON params (ids as "s12" / "l3" / "u9", or numbers).
struct AssistantAction: Hashable, Sendable {
    var name: ActionName
    var params: JSONObject = JSONObject()

    func string(_ key: String) -> String? {
        guard let value = params[key], !value.isNull else { return nil }
        return value.content
    }

    func bool(_ key: String) -> Bool? {
        guard let value = params[key], value.isPrimitive else { return nil }
        if let b = value.boolValue { return b }
        switch value.content?.lowercased() {
        case "true"?: return true
        case "false"?: return false
        default: return nil
        }
    }

    func id(_ key: String, prefix: Character) -> Int? { EntityRef.id(params[key], prefix: prefix) }

    /// The kind + id of like/unlike.
    func likeTarget() -> (kind: AssistantSearch.Kind, id: Int)? {
        let kind: AssistantSearch.Kind
        switch string("kind")?.lowercased() {
        case "schedule"?: kind = .schedule
        case "location"?: kind = .location
        default: return nil
        }
        return id("id", prefix: kind == .schedule ? "s" : "l").map { (kind, $0) }
    }

    func refs(_ key: String) -> [EntityRef] {
        (params[key]?.arrayValue ?? []).compactMap { EntityRef.of($0) }
    }

    func ops(_ bundle: EventBundle, now: Date) -> [PlanOp]? {
        PlanOpJSON.parse(params["ops"], timeZone: bundle.event.timeZone, now: now)
    }

    static func like(_ kind: AssistantSearch.Kind, _ id: Int, liked: Bool = true) -> AssistantAction {
        let schedule = kind == .schedule
        return AssistantAction(name: liked ? .like : .unlike, params: [
            "kind": .string(schedule ? "schedule" : "location"),
            "id": .string(schedule ? "s\(id)" : "l\(id)"),
        ])
    }

    static func search(_ query: String) -> AssistantAction { AssistantAction(name: .search, params: ["query": .string(query)]) }

    static func open(_ screen: String, _ ref: EntityRef? = nil) -> AssistantAction {
        var params: JSONObject = ["screen": .string(screen)]
        if let ref { params["id"] = .string(ref.code) }
        return AssistantAction(name: .open, params: params)
    }

    static func toggle(_ name: ActionName, on: Bool) -> AssistantAction { AssistantAction(name: name, params: ["on": .bool(on)]) }

    static func planEdit(_ ops: [PlanOp], _ bundle: EventBundle) -> AssistantAction {
        AssistantAction(name: .planEdit, params: ["ops": PlanOpJSON.encode(ops, timeZone: bundle.event.timeZone)])
    }

    static func planMake(_ request: String) -> AssistantAction { AssistantAction(name: .planMake, params: ["request": .string(request)]) }
    static func planVersion(_ kind: PlanVersionKind) -> AssistantAction { AssistantAction(name: .planVersion, params: ["kind": .string(kind.key)]) }
    static func directions(_ locationId: Int) -> AssistantAction { AssistantAction(name: .directions, params: ["location": .string("l\(locationId)")]) }

    /// My schedule: add (a place at "HH:MM" or saved), optionally replacing a clashing entry.
    static func scheduleAdd(_ ref: EntityRef, time: String? = nil, replace: EntityRef? = nil) -> AssistantAction {
        var params: JSONObject = ["target": .string(ref.code)]
        if let time { params["time"] = .string(time) }
        if let replace { params["replace"] = .string(replace.code) }
        return AssistantAction(name: .scheduleAdd, params: params)
    }

    static func scheduleRemove(_ ref: EntityRef) -> AssistantAction {
        AssistantAction(name: .scheduleRemove, params: ["target": .string(ref.code)])
    }

    static func scheduleMove(_ ref: EntityRef, time: String) -> AssistantAction {
        AssistantAction(name: .scheduleMove, params: ["target": .string(ref.code), "time": .string(time)])
    }

    static func scheduleReminder(_ ref: EntityRef, minutes: Int) -> AssistantAction {
        AssistantAction(name: .scheduleReminder, params: ["target": .string(ref.code), "minutes": .int(minutes)])
    }

    /// The schedule target ("s12" / "l3"); never an update.
    func scheduleTarget(_ key: String = "target") -> EntityRef? {
        guard let ref = EntityRef.of(params[key]), ref.kind != .update else { return nil }
        return ref
    }
}

/// Where an action came from: the model and the rule-based router are the assistant; buttons are manual.
enum ActionSource: Hashable, Sendable { case model, rules, manual }

/// What the dispatcher needs to know about the device and screen.
struct ActionContext: Sendable {
    var bundle: EventBundle
    var now: Date
    var hasLocation = false
    var hasPlan = false
}

/// Result of a validation: the action (params checked) or why it was refused.
enum ActionCheck: Hashable, Sendable {
    case valid(AssistantAction)
    case invalid(String)
}

enum ActionRegistry {

    /// Validates `name` + `params` (from the model, the router or a chip): the name must be in the
    /// registry and not `neverAvailable`; every required param present; ids must exist in the
    /// bundle (like/unlike: `id` of the given `kind`); times "HH:MM"; days event days; enums in
    /// their values; `ops` readable plan ops.
    static func check(_ name: String?, _ params: JSONObject?, _ bundle: EventBundle, now: Date) -> ActionCheck {
        if let key = name?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), ActionName.neverAvailable.contains(key) {
            return .invalid("not available to the assistant")
        }
        guard let action = ActionName.of(name) else { return .invalid("unknown action") }
        let values = params ?? JSONObject()
        for param in action.params {
            guard let element = values[param.name], !element.isNull else {
                if param.required { return .invalid("missing \(param.name)") }
                continue
            }
            if !valid(param, element, values, bundle, now) { return .invalid("bad \(param.name)") }
        }
        return .valid(AssistantAction(name: action, params: values))
    }

    private static func valid(_ param: ActionParam, _ element: JSONValue, _ all: JSONObject, _ bundle: EventBundle, _ now: Date) -> Bool {
        let content = element.content
        switch param.type {
        case .string:
            guard let text = element.stringValue else { return false }
            return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && text.count <= 300
        case .int:
            return element.intValue != nil
        case .bool:
            guard let content else { return false }
            return element.boolValue != nil || ["true", "false"].contains(content.lowercased())
        case .time:
            guard let content else { return false }
            return Rx.find(#"^([01]?\d|2[0-3]):[0-5]\d$"#, content.trimmingCharacters(in: .whitespacesAndNewlines)) != nil
        case .day:
            guard let content, let day = PlanDate.parse(content.trimmingCharacters(in: .whitespacesAndNewlines)) else { return false }
            return PlanCalendar.eventDays(bundle, now: now).contains(day)
        case .kind, .enumeration:
            guard let content else { return false }
            return param.values.contains(content.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        case .scheduleId:
            return EntityRef.id(element, prefix: "s").flatMap { bundle.scheduleItem($0) } != nil
        case .locationId:
            return EntityRef.id(element, prefix: "l").flatMap { bundle.location($0) } != nil
        case .updateId:
            guard let id = EntityRef.id(element, prefix: "u") else { return false }
            return bundle.notifications.contains { $0.id == id }
        case .entity:
            let ref: EntityRef?
            switch all["kind"]?.content?.lowercased() {
            case "schedule"?: ref = EntityRef.id(element, prefix: "s").map { EntityRef(kind: .schedule, id: $0) }
            case "location"?: ref = EntityRef.id(element, prefix: "l").map { EntityRef(kind: .location, id: $0) }
            default: ref = EntityRef.of(element)
            }
            return ref?.exists(bundle) == true
        case .entities:
            return element.arrayValue != nil
        case .ops:
            return PlanOpJSON.parse(element, timeZone: bundle.event.timeZone, now: now)?.isEmpty == false
        }
    }

    /// The Undo of an applied action, or nil (like/unlike/checkoff/plan edits apply with Undo).
    static func undo(for action: AssistantAction) -> AssistantAction? {
        switch action.name {
        case .like: return AssistantAction(name: .unlike, params: action.params)
        case .unlike: return AssistantAction(name: .like, params: action.params)
        case .scheduleAdd:
            return action.params["target"].map { AssistantAction(name: .scheduleRemove, params: ["target": $0]) }
        case .scheduleRemove:
            return AssistantAction(name: .scheduleAdd, params: action.params)
        case .checkoff:
            guard let done = action.bool("done") else { return nil }
            var params = action.params
            params["done"] = .bool(!done)
            return AssistantAction(name: .checkoff, params: params)
        case .planMake, .planEdit, .planVersion:
            return AssistantAction(name: .planUndo)
        default:
            return nil
        }
    }

    /// The question a `confirm` block asks before a chip-confirmed action.
    static func confirmPrompt(_ action: AssistantAction) -> String {
        let on = action.bool("on") != false
        switch action.name {
        case .followLockScreen: return on ? "Follow your day on the Lock Screen?" : "Stop following on the Lock Screen?"
        case .reminders: return on ? "Turn on reminders before things in your schedule?" : "Turn off reminders?"
        case .notifications: return on ? "Turn on notifications from the organizer?" : "Turn off notifications from the organizer?"
        case .location: return on ? "Show your location on the map?" : "Stop showing your location on the map?"
        case .leave: return "Leave this event? Your schedule is kept if you join again."
        case .switchServer:
            return action.string("server") == "dev" ? "Switch to the dev server? You'll leave this event." : "Switch to the production server? You'll leave this event."
        default: return "Are you sure?"
        }
    }
}

/// What the platform reports after running an action.
enum ActionOutcome: Hashable, Sendable {
    case done(message: String? = nil, blocks: [AssistantBlock] = [])
    case failed(String)
}

/// The platform side of the action layer (AssistantController). It only runs already-validated,
/// already-confirmed actions.
protocol ActionExecutor {
    func execute(_ action: AssistantAction) -> ActionOutcome
}

/// What `ActionDispatcher.dispatch` did.
enum ActionDispatch: Hashable, Sendable {
    case rejected(String)
    /// Show this `confirm` block; dispatch again with `confirmed: true` on Yes.
    case needsConfirmation(AssistantBlock)
    /// Ran; `undo` is what the Undo button dispatches.
    case executed(ActionOutcome, undo: AssistantAction?)
}

/// Validates, confirms and runs actions. Order: registry check; `needsLocation` without a location
/// → rejected; plan edits / undo / versions /
/// check-offs / share plan need a plan; a chip-confirmed action from the assistant needs
/// `confirmed` (manual buttons are their own confirmation); then the executor, with the Undo when
/// the action has one and succeeded.
struct ActionDispatcher {
    var executor: ActionExecutor

    func dispatch(_ action: AssistantAction, context: ActionContext, source: ActionSource, confirmed: Bool = false) -> ActionDispatch {
        if case .invalid(let reason) = ActionRegistry.check(action.name.key, action.params, context.bundle, now: context.now) {
            return .rejected(reason)
        }
        let name = action.name
        if name.needsLocation && !context.hasLocation { return .rejected("needs location") }
        if [.planEdit, .planUndo, .planVersion, .checkoff, .sharePlan].contains(name) && !context.hasPlan {
            return .rejected("no plan")
        }
        if name.confirm == .chip && source != .manual && !confirmed {
            return .needsConfirmation(.confirm(action: action, prompt: ActionRegistry.confirmPrompt(action)))
        }
        let outcome = executor.execute(action)
        var undo: AssistantAction?
        if name.undoable, case .done = outcome { undo = ActionRegistry.undo(for: action) }
        return .executed(outcome, undo: undo)
    }
}
