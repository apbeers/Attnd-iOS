// Component.swift
// Attnd (app and App Clip; pure, unit tested in ComponentTests)
//
// One component catalogue (iOS, Nov 21, 2026, like the web console's components): the assistant's
// blocks (`AssistantBlock`, spec §2) and the API-024 layout sections (`SectionCatalogue`) are one
// set of `Component` types. Each type says which screens may place it (with what it needs and its
// parts) and whether a chat answer may show it. Server layouts (API-024) and the model's `show`
// tool produce the same `Component` values; `ComponentView` (ComponentView.swift) draws them all.
//
//   - Lenient: unknown types are skipped; older names map across (`aliases`: the Home tab's
//     `plan_today` and `liked` are now `my_schedule`).
//   - `SectionCatalogue.types` (the layout side) is built from this catalogue, so a type added
//     here for a screen is a layout type; a new layout type bumps `SectionCatalogue.version`.
//   - In a chat answer a screen type is the block `.component(Component)`: its subject is in
//     `ids` ("l3" for a place's menu, "s12" for an item's performers, none for event-wide ones).

import Foundation

/// One component: a type and its props (ids, title, limit, parts, conditions). Chat-only payloads
/// (text, chips, confirm, plan diff, compare…) keep their block in `block`.
struct Component: Hashable, Sendable {
    var type: String
    var ids: [EntityRef] = []
    var title: String? = nil
    var limit: Int? = nil
    var show: [String] = []
    var when: [String] = []
    var block: AssistantBlock? = nil

    /// The subject of a detail-style component (a place's menu, an item's performers).
    var subject: EntityRef? { ids.first }
}

/// What one component type is allowed to do.
struct ComponentSpec: Hashable, Sendable {
    /// Screens a layout may place it on, with what it needs there and its parts.
    var screens: [LayoutScreen: SectionType] = [:]
    /// A chat answer may show it.
    var chat = false
    /// The kind of subject it needs in chat (nil: event-wide, no id).
    var subject: RefKind? = nil
}

enum ComponentCatalogue {
    /// Older names that map to a current type (first wins when both are sent).
    static let aliases: [String: String] = ["plan_today": "my_schedule", "liked": "my_schedule"]

    static func canonical(_ type: String) -> String {
        let name = type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return aliases[name] ?? name
    }

    private static func s(_ needs: [String] = [], parts: [String] = [], show: [String]? = nil) -> SectionType {
        SectionType(needs: needs, parts: parts, defaultShow: show ?? parts)
    }

    static let itemHeaderParts = ["time", "status", "tags"]
    static let placeHeaderParts = ["image", "category", "tags", "address", "distance", "now_next"]

    /// Every type. Block types that are chat-only have no screens.
    static let specs: [String: ComponentSpec] = [
        // Chat blocks (assistant spec §2)
        "text": ComponentSpec(chat: true), "item_card": ComponentSpec(chat: true), "place_card": ComponentSpec(chat: true),
        "update_card": ComponentSpec(chat: true), "list": ComponentSpec(chat: true), "carousel": ComponentSpec(chat: true),
        "timeline": ComponentSpec(chat: true), "gallery": ComponentSpec(chat: true), "compare": ComponentSpec(chat: true),
        "plan_diff": ComponentSpec(chat: true), "plan": ComponentSpec(chat: true), "setting": ComponentSpec(chat: true),
        "summary": ComponentSpec(chat: true), "share": ComponentSpec(chat: true), "chips": ComponentSpec(chat: true),
        "confirm": ComponentSpec(chat: true),
        "map": ComponentSpec(screens: [.home: s(["pins"])], chat: true),
        "countdown": ComponentSpec(screens: [.itemDetail: s(["upcoming"]), .home: s(["before_start"])], chat: true),
        "now_next": ComponentSpec(screens: [.placeDetail: s(["items_here"]), .home: s(["schedule"])], chat: true),
        // Screens and chat
        "header": ComponentSpec(screens: [
            .itemDetail: s(parts: itemHeaderParts), .placeDetail: s(parts: placeHeaderParts),
            .eventInfo: s(parts: ["website"]), .optionsEvent: s(), .home: s(),
        ]),
        "about": ComponentSpec(screens: [
            .itemDetail: s(["description", "context.about"]), .placeDetail: s(["description", "context.about"]),
            .eventInfo: s(["description", "context.about"]), .home: s(["description", "context.about"]),
        ], chat: true),
        "performers": ComponentSpec(screens: [.itemDetail: s(["context.performers"])], chat: true, subject: .schedule),
        "good_to_know": ComponentSpec(screens: [
            .itemDetail: s(["context.price", "context.age_limit", "context.accessibility"]),
            .placeDetail: s(["context.age_limit", "context.accessibility"]),
        ]),
        "links": ComponentSpec(screens: [
            .itemDetail: s(["context.links"]), .placeDetail: s(["context.links", "website"]),
            .eventInfo: s(["context.links"]), .home: s(["context.links"]),
        ], chat: true),
        "place_link": ComponentSpec(screens: [.itemDetail: s()]),
        // Removed Nov 21, 2026 (no "Ask About This"): kept so older layouts validate; draws nothing.
        "ask_about": ComponentSpec(screens: [.itemDetail: s(["model_available"]), .placeDetail: s(["model_available"])]),
        "walk_map": ComponentSpec(screens: [.placeDetail: s(["coordinate"])]),
        "directions": ComponentSpec(screens: [.placeDetail: s(["coordinate"])]),
        "hours": ComponentSpec(screens: [.placeDetail: s(["context.hours"])], chat: true, subject: .location),
        "menu": ComponentSpec(screens: [.placeDetail: s(["context.menu"])], chat: true, subject: .location),
        "at_this_location": ComponentSpec(screens: [.placeDetail: s(["items_here"])]),
        "faq": ComponentSpec(screens: [.eventInfo: s(["context.faq"]), .home: s(["context.faq"])], chat: true),
        "amenities": ComponentSpec(screens: [.eventInfo: s(["context.amenities"])], chat: true),
        "getting_there": ComponentSpec(screens: [.eventInfo: s(["context.getting_there"]), .home: s(["context.getting_there"])], chat: true),
        "accessibility": ComponentSpec(screens: [.eventInfo: s(["context.accessibility"])], chat: true),
        "policies": ComponentSpec(screens: [.eventInfo: s(["context.policies"])], chat: true),
        "weather_plan": ComponentSpec(screens: [.eventInfo: s(["context.weather_plan"])], chat: true),
        "website": ComponentSpec(screens: [.optionsEvent: s(["website"]), .home: s(["website"])], chat: true),
        "event_info_link": ComponentSpec(screens: [.optionsEvent: s(["context"])]),
        "now_playing": ComponentSpec(screens: [.mapOverlay: s(["now_playing"])], chat: true),
        "selected_place": ComponentSpec(screens: [.mapOverlay: s()]),
        "urgent": ComponentSpec(screens: [.home: s(["urgent"])], chat: true),
        // My schedule (catalogue version 2): Home's "Up next in my schedule"; empty state when empty.
        "my_schedule": ComponentSpec(screens: [.home: s()], chat: true),
        // The chat's "Here's your day": My schedule's day as a timeline (the plan's, with walks).
        "my_day": ComponentSpec(chat: true),
        "whats_on": ComponentSpec(screens: [.home: s(["schedule"])], chat: true),
        "places": ComponentSpec(screens: [.home: s(["locations"])], chat: true),
        "updates": ComponentSpec(screens: [.home: s(["updates"])], chat: true),
        "flyer": ComponentSpec(screens: [.home: s(["flyer"])], chat: true),
    ]

    /// Screen types a chat answer may show as `.component` (not the chat blocks themselves).
    static var chatScreenTypes: Set<String> {
        Set(specs.filter { $0.value.chat && !AssistantBlock.types.contains($0.key) }.keys)
    }

    /// The layout side: per screen, type → what it needs and its parts.
    static let screenTypes: [LayoutScreen: [String: SectionType]] = {
        var out: [LayoutScreen: [String: SectionType]] = [:]
        for (name, spec) in specs {
            for (screen, type) in spec.screens { out[screen, default: [:]][name] = type }
        }
        return out
    }()

    // MARK: Inputs

    /// A layout section (API-024) as a component; `subject` = the detail screen's item or place.
    static func component(_ section: LayoutSection, subject: EntityRef? = nil) -> Component {
        Component(type: canonical(section.type), ids: subject.map { [$0] } ?? [], title: section.title,
                  limit: section.limit, show: section.show, when: section.when)
    }

    /// A chat block as a component (a `.component` block is its component).
    static func component(_ block: AssistantBlock) -> Component {
        if case .component(let component) = block { return component }
        var ids: [EntityRef] = []
        switch block {
        case .itemCard(let id, _), .countdown(let id): ids = [EntityRef(kind: .schedule, id: id)]
        case .placeCard(let id, _): ids = [EntityRef(kind: .location, id: id)]
        case .updateCard(let id): ids = [EntityRef(kind: .update, id: id)]
        case .list(let refs, _, _), .carousel(let refs, _): ids = refs
        case .timeline(let items, _, _): ids = items.map { EntityRef(kind: .schedule, id: $0) }
        case .map(let pins, _): ids = pins.map { EntityRef(kind: .location, id: $0) }
        case .gallery(let places, _): ids = places.map { EntityRef(kind: .location, id: $0) }
        case .nowNext(let location): ids = location.map { [EntityRef(kind: .location, id: $0)] } ?? []
        default: break
        }
        return Component(type: block.type, ids: ids, block: block)
    }

    /// The model's `show(component, ids, title, limit)` and the block JSON's screen types: a chat
    /// component, or nil (unknown, not allowed in chat, or a subject of the wrong kind / missing).
    static func chat(_ rawType: String, ids: [EntityRef] = [], title: String? = nil, limit: Int? = nil) -> Component? {
        let type = canonical(rawType)
        guard let spec = specs[type], spec.chat, !AssistantBlock.types.contains(type) else { return nil }
        var refs = ids
        if let kind = spec.subject {
            guard let first = ids.first(where: { $0.kind == kind }) else { return nil }
            refs = [first]
        } else {
            refs = []
        }
        let cleanTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        return Component(type: type, ids: refs, title: cleanTitle?.isEmpty == false ? String(cleanTitle!.prefix(60)) : nil,
                         limit: limit.map { min(max($0, 1), ScreenLayout.maxLimit) })
    }

    /// `{"type":"menu","ids":["l3"],"title":"…","limit":3}` (block JSON and tool arguments).
    static func decode(_ obj: JSONObject) -> Component? {
        guard let type = obj["type"]?.stringValue else { return nil }
        var ids = (obj["ids"]?.arrayValue ?? []).compactMap { EntityRef.of($0) }
        if let one = EntityRef.of(obj["id"]) { ids.insert(one, at: 0) }
        return chat(type, ids: ids, title: obj["title"]?.stringValue, limit: obj["limit"]?.intValue)
    }

    static func encode(_ component: Component) -> JSONObject {
        var o: JSONObject = ["type": .string(component.type)]
        if !component.ids.isEmpty { o["ids"] = .array(component.ids.map { .string($0.code) }) }
        if let title = component.title { o["title"] = .string(title) }
        if let limit = component.limit { o["limit"] = .int(limit) }
        return o
    }

    /// A chat component still drawable with this bundle (its subject exists and has the data).
    static func valid(_ component: Component, _ bundle: EventBundle) -> Bool {
        guard let spec = specs[component.type], spec.chat else { return false }
        if spec.subject != nil {
            guard let subject = component.subject, subject.exists(bundle) else { return false }
        }
        let event = bundle.event.context
        switch component.type {
        case "menu": return bundle.location(component.subject?.id)?.context?.menu.isEmpty == false
        case "hours": return bundle.location(component.subject?.id)?.context?.hours.isEmpty == false
        case "performers": return bundle.scheduleItem(component.subject?.id)?.context?.performers.isEmpty == false
        case "faq": return event?.faq.isEmpty == false
        case "amenities": return event?.amenities.isEmpty == false
        case "getting_there": return event?.gettingThere.isEmpty == false
        case "accessibility": return event?.accessibility.isEmpty == false
        case "policies": return event?.policies.isEmpty == false
        case "weather_plan": return event?.weatherPlan.isEmpty == false
        case "links": return event?.links.isEmpty == false
        case "website": return bundle.event.websiteUrl != nil
        case "flyer": return bundle.event.flyerUrl != nil
        case "updates": return !bundle.notifications.isEmpty
        case "places": return !bundle.locations.isEmpty
        default: return true
        }
    }

    /// The type names the model's `show` tool may use, for its description.
    static var chatTypeList: String { chatScreenTypes.sorted().joined(separator: ", ") }
}
