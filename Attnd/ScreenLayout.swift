// ScreenLayout.swift
// Attnd (app and App Clip; pure, unit tested in ScreenLayoutTests)
//
// Server-driven screens (API-024, attnd-web `API_V2.md` → Layout): the bundle's `layout` lists, per
// screen, the sections to show in order (`{type, show?, title?, limit?, when?}`), plus overrides per
// place category or tag. The app draws only section types compiled into it (the catalogue below,
// `SectionCatalogue.version`, sent as `X-Attnd-Sections` so the server only sends types this build
// knows) and skips everything else. The rules, pure so they run in the Linux harness too:
//
//   1. Validation (`validate`): types unknown for the screen are dropped, a type appears once (the
//      first wins), `show` parts unknown for the type are dropped (none left → the type's default
//      parts), `title` trimmed and cut to 60 characters, `limit` clamped to 1…20, ≤ 24 sections.
//   2. Fallback: no layout, no entry for the screen, or no section left after validation → the
//      built-in default (`ScreenLayout.defaults`, today's fixed screen as a layout). Screenshot mode
//      always passes no layout, so the store screenshots never change.
//   3. Overrides: the first of ≤ 8 overrides whose `match` fits the subject replaces the sections
//      (`category:<name>`, case-insensitive, against the place's category or a schedule item's
//      place's category; `tag:<tag>` against the subject's tags, as sent: lower case). An override
//      with no valid section left is skipped.
//   4. Visibility (`resolve`): a section shows when the data it draws is there (`SectionType.needs`,
//      any of those facts) and every `when` condition holds. Conditions are a closed set, never
//      code: `has:<fact>`, `has_plan`, `model_available`, `now_playing`, `within_walk`,
//      `before_start` / `during` / `after_end` (the event), `day:YYYY-MM-DD` (today in the event's
//      zone) and `not:<condition>`. An unknown condition is false (the section is skipped).
//   5. `ScreenFacts` computes the facts of an item, a place or the event from the bundle.

import Foundation

/// The screens a layout can describe.
enum LayoutScreen: String, CaseIterable, Hashable, Sendable {
    case home
    case eventInfo = "event_info"
    case itemDetail = "item_detail"
    case placeDetail = "place_detail"
    case mapOverlay = "map_overlay"
    case optionsEvent = "options_event"
}

/// One section of a screen, as sent (before validation) or resolved.
struct LayoutSection: Hashable, Sendable {
    var type: String
    var show: [String] = []
    var title: String? = nil
    var limit: Int? = nil
    var when: [String] = []

    init(_ type: String, show: [String] = [], title: String? = nil, limit: Int? = nil, when: [String] = []) {
        self.type = type
        self.show = show
        self.title = title
        self.limit = limit
        self.when = when
    }

    func shows(_ part: String) -> Bool { show.contains(part) }
}

/// Sections that replace a screen's for subjects of one category or tag.
struct LayoutOverride: Hashable, Sendable {
    var match: String
    var sections: [LayoutSection]
}

struct ScreenSpec: Hashable, Sendable {
    var sections: [LayoutSection]
    var overrides: [LayoutOverride] = []
}

/// `bundle.layout` (API-024).
struct ScreenLayouts: Hashable, Sendable {
    /// The catalogue version the server built it for.
    var catalogue: Int = 0
    var screens: [LayoutScreen: ScreenSpec] = [:]
}

/// What a section type needs and which parts it has.
struct SectionType: Hashable, Sendable {
    /// Any one of these facts makes the section drawable; empty = always.
    var needs: [String] = []
    /// The parts `show` may list, and the default when it lists none.
    var parts: [String] = []
    var defaultShow: [String] = []
}

/// The section types this build draws, per screen: the layout side of the one component
/// catalogue (`ComponentCatalogue`, Component.swift).
enum SectionCatalogue {
    /// Sent as `X-Attnd-Sections`; the server only sends sections of this version or older.
    /// 2 (Nov 21, 2026): `my_schedule` on Home (`plan_today` / `liked` map to it).
    static let version = 2

    static let itemHeaderParts = ComponentCatalogue.itemHeaderParts
    static let placeHeaderParts = ComponentCatalogue.placeHeaderParts

    static var types: [LayoutScreen: [String: SectionType]] { ComponentCatalogue.screenTypes }

    static func type(_ name: String, on screen: LayoutScreen) -> SectionType? {
        ComponentCatalogue.screenTypes[screen]?[ComponentCatalogue.canonical(name)]
    }

    /// Every fact name a `has:` condition may use.
    static let facts: Set<String> = [
        "description", "image", "coordinate", "website", "tags", "category", "flyer", "logo",
        "context", "context.about", "context.menu", "context.hours", "context.accessibility", "context.age_limit",
        "context.price", "context.performers", "context.links", "context.faq", "context.amenities",
        "context.getting_there", "context.policies", "context.weather_plan",
        "items_here", "likes", "plan", "updates", "urgent", "locations", "pins", "schedule", "upcoming",
    ]

    /// Conditions without arguments (each is also a fact of that name).
    static let states: Set<String> = [
        "model_available", "now_playing", "within_walk", "before_start", "during", "after_end",
    ]
}

enum ScreenLayout {
    static let maxSections = 24
    static let maxOverrides = 8
    static let maxTitle = 60
    static let maxLimit = 20

    /// Today's fixed screens, as layouts (also the fallback for anything missing or invalid).
    static let defaults: [LayoutScreen: [LayoutSection]] = [
        .itemDetail: [
            LayoutSection("header", show: SectionCatalogue.itemHeaderParts), LayoutSection("about"),
            LayoutSection("performers"), LayoutSection("good_to_know"), LayoutSection("links"),
            LayoutSection("place_link"),
        ],
        .placeDetail: [
            LayoutSection("header", show: SectionCatalogue.placeHeaderParts), LayoutSection("walk_map"),
            LayoutSection("about"), LayoutSection("hours"), LayoutSection("good_to_know"),
            LayoutSection("menu"), LayoutSection("links"), LayoutSection("at_this_location"),
        ],
        .eventInfo: [
            LayoutSection("header", show: ["website"]), LayoutSection("about"), LayoutSection("faq"),
            LayoutSection("amenities"), LayoutSection("getting_there"), LayoutSection("accessibility"),
            LayoutSection("policies"), LayoutSection("weather_plan"), LayoutSection("links"),
        ],
        .optionsEvent: [LayoutSection("header"), LayoutSection("website"), LayoutSection("event_info_link")],
        .mapOverlay: [LayoutSection("now_playing"), LayoutSection("selected_place")],
        .home: [
            // No now_next by default (owner, Nov 21, 2026: My schedule and the schedule below show
            // it); organizers can still add it.
            LayoutSection("header"), LayoutSection("urgent"), LayoutSection("countdown"),
            LayoutSection("my_schedule"),
            LayoutSection("map"), LayoutSection("updates", limit: 3), LayoutSection("faq", limit: 3),
            LayoutSection("getting_there"), LayoutSection("about"),
        ],
    ]

    /// Who a detail screen is about, for the overrides.
    struct Subject: Hashable, Sendable {
        var category: String? = nil
        var tags: [String] = []

        static let empty = Subject()
    }

    /// Rule 1: known types for the screen, once each, parts / title / limit cleaned, ≤ 24.
    static func validate(_ sections: [LayoutSection], on screen: LayoutScreen) -> [LayoutSection] {
        var seen = Set<String>()
        var out: [LayoutSection] = []
        for raw in sections {
            let name = ComponentCatalogue.canonical(raw.type)
            guard let type = SectionCatalogue.type(name, on: screen), seen.insert(name).inserted else { continue }
            var section = LayoutSection(name)
            var parts = Set<String>()
            let shown = raw.show.map { $0.lowercased() }.filter { type.parts.contains($0) && parts.insert($0).inserted }
            section.show = shown.isEmpty ? type.defaultShow : shown
            if let title = raw.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
                section.title = title.count > maxTitle ? String(title.prefix(maxTitle - 1)) + "…" : title
            }
            section.limit = raw.limit.map { min(max($0, 1), maxLimit) }
            section.when = raw.when.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            out.append(section)
            if out.count == maxSections { break }
        }
        return out
    }

    /// Rules 2–3: the sections for a screen and subject, before the facts decide visibility.
    static func sections(for screen: LayoutScreen, layouts: ScreenLayouts?, subject: Subject = .empty) -> [LayoutSection] {
        let fallback = defaults[screen] ?? []
        guard let spec = layouts?.screens[screen] else { return fallback }
        for override in spec.overrides.prefix(maxOverrides) where matches(override.match, subject) {
            let kept = validate(override.sections, on: screen)
            if !kept.isEmpty { return kept }
        }
        let kept = validate(spec.sections, on: screen)
        return kept.isEmpty ? fallback : kept
    }

    /// Rule 3: `category:<name>` / `tag:<tag>`.
    static func matches(_ match: String, _ subject: Subject) -> Bool {
        let trimmed = match.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let colon = trimmed.firstIndex(of: ":") else { return false }
        let kind = trimmed[..<colon].lowercased()
        let value = trimmed[trimmed.index(after: colon)...].trimmingCharacters(in: .whitespaces).lowercased()
        guard !value.isEmpty else { return false }
        switch kind {
        case "category": return subject.category?.trimmingCharacters(in: .whitespaces).lowercased() == value
        case "tag": return subject.tags.contains { $0.lowercased() == value }
        default: return false
        }
    }

    /// Rules 1–4: the sections to draw, in order.
    static func resolve(
        _ screen: LayoutScreen, layouts: ScreenLayouts?, facts: Set<String>, subject: Subject = .empty
    ) -> [LayoutSection] {
        sections(for: screen, layouts: layouts, subject: subject).filter { section in
            guard let type = SectionCatalogue.type(section.type, on: screen) else { return false }
            if !type.needs.isEmpty && !type.needs.contains(where: facts.contains) { return false }
            return section.when.allSatisfy { holds($0, facts) }
        }
    }

    /// Rule 4: one condition.
    static func holds(_ condition: String, _ facts: Set<String>) -> Bool {
        let c = condition.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if c.hasPrefix("not:") {
            let inner = String(c.dropFirst(4))
            // An unknown condition stays false when negated too (fail closed).
            return isKnown(inner) && !holds(inner, facts)
        }
        if c == "has_plan" { return facts.contains("plan") }
        if c.hasPrefix("has:") {
            let fact = String(c.dropFirst(4))
            return SectionCatalogue.facts.contains(fact) && facts.contains(fact)
        }
        if c.hasPrefix("day:") { return isDate(String(c.dropFirst(4))) && facts.contains(c) }
        return SectionCatalogue.states.contains(c) && facts.contains(c)
    }

    private static func isKnown(_ c: String) -> Bool {
        if c.hasPrefix("not:") { return isKnown(String(c.dropFirst(4))) }
        if c == "has_plan" || SectionCatalogue.states.contains(c) { return true }
        if c.hasPrefix("has:") { return SectionCatalogue.facts.contains(String(c.dropFirst(4))) }
        if c.hasPrefix("day:") { return isDate(String(c.dropFirst(4))) }
        return false
    }

    private static func isDate(_ s: String) -> Bool {
        s.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil
    }
}

/// The facts the visibility rules read, from the bundle (rule 5).
enum ScreenFacts {
    /// What the app knows beyond the bundle.
    struct State: Hashable, Sendable {
        var now: Date
        var modelAvailable = false
        var hasPlan = false
        var hasLikes = false
        /// Within walking range of the subject (8 km, with a position).
        var withinWalk = false
    }

    /// The event-wide facts every screen shares: the event phase, today, the model, plan, likes.
    static func common(_ bundle: EventBundle, _ state: State) -> Set<String> {
        var facts: Set<String> = []
        let event = bundle.event
        let now = state.now
        if let start = event.startTime, now < start { facts.insert("before_start") }
        if let end = event.endTime, now >= end {
            facts.insert("after_end")
        } else if event.startTime.map({ now >= $0 }) ?? false {
            facts.insert("during")
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = event.timeZone
        let d = calendar.dateComponents([.year, .month, .day], from: now)
        if let y = d.year, let m = d.month, let day = d.day {
            facts.insert(String(format: "day:%04d-%02d-%02d", y, m, day))
        }
        if state.modelAvailable { facts.insert("model_available") }
        if state.hasPlan { facts.insert("plan") }
        if state.hasLikes { facts.insert("likes") }
        if state.withinWalk { facts.insert("within_walk") }
        if bundle.schedule.contains(where: { ScheduleTiming.isHappening($0, at: now) && bundle.location($0.locationId)?.coordinate != nil }) {
            facts.insert("now_playing")
        }
        return facts
    }

    static func item(_ item: ScheduleItem, _ bundle: EventBundle, _ state: State) -> Set<String> {
        var facts = common(bundle, state)
        if !item.description.isEmpty { facts.insert("description") }
        if !item.tags.isEmpty { facts.insert("tags") }
        if let start = item.startTime, start > state.now { facts.insert("upcoming") }
        if let location = bundle.location(item.locationId) {
            if location.coordinate != nil { facts.insert("coordinate") }
            if location.category != nil { facts.insert("category") }
        }
        if let c = item.context, !c.isEmpty {
            facts.insert("context")
            if !c.about.isEmpty { facts.insert("context.about") }
            if !c.performers.isEmpty { facts.insert("context.performers") }
            if !c.price.isEmpty { facts.insert("context.price") }
            if !c.ageLimit.isEmpty { facts.insert("context.age_limit") }
            if !c.accessibility.isEmpty { facts.insert("context.accessibility") }
            if !c.links.isEmpty { facts.insert("context.links") }
        }
        return facts
    }

    static func place(_ location: Location, _ bundle: EventBundle, _ state: State) -> Set<String> {
        var facts = common(bundle, state)
        if !location.description.isEmpty { facts.insert("description") }
        if !location.tags.isEmpty { facts.insert("tags") }
        if location.category != nil { facts.insert("category") }
        if location.imageUrl != nil { facts.insert("image") }
        if location.coordinate != nil { facts.insert("coordinate") }
        if location.website != nil { facts.insert("website") }
        if bundle.schedule.contains(where: { $0.locationId == location.id }) { facts.insert("items_here") }
        if let c = location.context, !c.isEmpty {
            facts.insert("context")
            if !c.about.isEmpty { facts.insert("context.about") }
            if !c.menu.isEmpty { facts.insert("context.menu") }
            if !c.hours.isEmpty { facts.insert("context.hours") }
            if !c.ageLimit.isEmpty { facts.insert("context.age_limit") }
            if !c.accessibility.isEmpty { facts.insert("context.accessibility") }
            if !c.links.isEmpty { facts.insert("context.links") }
        }
        return facts
    }

    static func event(_ bundle: EventBundle, _ state: State) -> Set<String> {
        var facts = common(bundle, state)
        let event = bundle.event
        if !event.description.isEmpty { facts.insert("description") }
        if event.websiteUrl != nil { facts.insert("website") }
        if event.flyerUrl != nil { facts.insert("flyer") }
        if event.logoUrl != nil || bundle.display.logoUrl != nil { facts.insert("logo") }
        if event.coordinate != nil { facts.insert("coordinate") }
        if !bundle.schedule.isEmpty { facts.insert("schedule") }
        if !bundle.locations.isEmpty { facts.insert("locations") }
        if bundle.locations.contains(where: { $0.coordinate != nil }) { facts.insert("pins") }
        if !bundle.notifications.isEmpty { facts.insert("updates") }
        if bundle.notifications.contains(where: { n in
            n.isUrgent && (n.sendTime.map { state.now.timeIntervalSince($0) < 12 * 3600 } ?? false)
        }) {
            facts.insert("urgent")
        }
        if let c = event.context, !c.isEmpty {
            facts.insert("context")
            if !c.about.isEmpty { facts.insert("context.about") }
            if !c.faq.isEmpty { facts.insert("context.faq") }
            if !c.amenities.isEmpty { facts.insert("context.amenities") }
            if !c.gettingThere.isEmpty { facts.insert("context.getting_there") }
            if !c.accessibility.isEmpty { facts.insert("context.accessibility") }
            if !c.policies.isEmpty { facts.insert("context.policies") }
            if !c.weatherPlan.isEmpty { facts.insert("context.weather_plan") }
            if !c.links.isEmpty { facts.insert("context.links") }
        }
        return facts
    }

    /// The override subject of a schedule item: its place's category, its own tags.
    static func subject(_ item: ScheduleItem, _ bundle: EventBundle) -> ScreenLayout.Subject {
        ScreenLayout.Subject(category: bundle.location(item.locationId)?.category, tags: item.tags)
    }

    static func subject(_ location: Location) -> ScreenLayout.Subject {
        ScreenLayout.Subject(category: location.category, tags: location.tags)
    }
}

// MARK: - Decoding (lenient: unknown keys ignored, bad entries dropped)

extension LayoutSection: Decodable {
    private enum CodingKeys: String, CodingKey { case type, show, title, limit, when }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let type = c.nonEmptyString(.type) else {
            throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "section without a type")
        }
        self.type = type
        show = c.lossyArray(String.self, .show)
        title = c.nonEmptyString(.title)
        limit = c.lenient(Int.self, .limit)
        if let one = c.nonEmptyString(.when) {
            when = [one]
        } else {
            when = c.lossyArray(String.self, .when)
        }
    }
}

extension LayoutOverride: Decodable {
    private enum CodingKeys: String, CodingKey { case match, sections }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let match = c.nonEmptyString(.match) else {
            throw DecodingError.dataCorruptedError(forKey: .match, in: c, debugDescription: "override without a match")
        }
        self.match = match
        sections = c.lossyArray(LayoutSection.self, .sections)
    }
}

extension ScreenSpec: Decodable {
    private enum CodingKeys: String, CodingKey { case sections, overrides }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sections = c.lossyArray(LayoutSection.self, .sections)
        overrides = c.lossyArray(LayoutOverride.self, .overrides)
    }
}

extension ScreenLayouts: Decodable {
    private enum CodingKeys: String, CodingKey { case catalogue, screens }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        catalogue = c.lenient(Int.self, .catalogue) ?? 0
        let raw = c.lenient(LossyScreens.self, .screens)?.screens ?? [:]
        var screens: [LayoutScreen: ScreenSpec] = [:]
        for (key, spec) in raw {
            if let screen = LayoutScreen(rawValue: key) { screens[screen] = spec }
        }
        self.screens = screens
    }
}

/// `screens` with each entry decoded on its own (a bad screen doesn't lose the others).
private struct LossyScreens: Decodable {
    var screens: [String: ScreenSpec] = [:]

    private struct Key: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        for key in c.allKeys {
            if let spec = try? c.decode(ScreenSpec.self, forKey: key) { screens[key.stringValue] = spec }
        }
    }
}

// MARK: - Two columns on wide containers (iPhone Duo unfolded)

/// Detail screens in two columns from a container width of 700 pt (the inner display of an
/// unfolded iPhone Duo; never a device check): the header and the "where / when" parts leading,
/// everything else trailing, each in layout order. nil = one column.
enum DetailColumns {
    static let minWidth = 700.0

    static let leadingTypes: [LayoutScreen: Set<String>] = [
        .placeDetail: ["header", "walk_map", "directions", "now_next"],
        .itemDetail: ["header", "place_link", "countdown"],
    ]

    static func split(_ sections: [LayoutSection], screen: LayoutScreen, width: Double)
        -> (leading: [LayoutSection], trailing: [LayoutSection])? {
        guard width >= minWidth, let types = leadingTypes[screen] else { return nil }
        let leading = sections.filter { types.contains($0.type) }
        let trailing = sections.filter { !types.contains($0.type) }
        guard !leading.isEmpty, !trailing.isEmpty else { return nil }
        return (leading, trailing)
    }
}

/// Home in tabletop posture (iPhone Duo partly folded, the fold across the middle): the top half
/// for viewing (header, urgent, countdown, now / next, the map), the bottom half the rest as a
/// list. nil = nothing for one of the halves (one scroll view as usual).
enum TabletopSplit {
    static let topTypes: Set<String> = ["header", "urgent", "countdown", "now_next", "map"]

    static func home(_ sections: [LayoutSection]) -> (top: [LayoutSection], bottom: [LayoutSection])? {
        let top = sections.filter { topTypes.contains($0.type) }
        let bottom = sections.filter { !topTypes.contains($0.type) }
        guard !top.isEmpty, !bottom.isEmpty else { return nil }
        return (top, bottom)
    }
}

/// An "About" section's text from the description and the API-018 `context.about`, once: the
/// same or contained text isn't shown twice (owner, Nov 21, 2026). The context's about wins; the
/// description joins it only when it says something more.
enum AboutText {
    static func merged(description: String, about: String?) -> String {
        let d = description.trimmingCharacters(in: .whitespacesAndNewlines)
        let a = (about ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if a.isEmpty { return d }
        if d.isEmpty { return a }
        let nd = normalized(d), na = normalized(a)
        if na.contains(nd) { return a }
        if nd.contains(na) { return d }
        return a + "\n\n" + d
    }

    private static func normalized(_ text: String) -> String {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
