// AssistantSearch.swift
// Attnd (app target only — not in the App Clip; unit tested through AssistantRouterTests)
//
// The event assistant's search and text helpers, ported 1:1 from Android (`EventSearch.kt`,
// `SearchQuery.kt`, `SearchText.kt`, `Walking.kt`, `Geo.kt` DistanceFormat, `RelativeTime.kt`)
// so the rule-based router resolves names, ranks results and words its answers exactly like
// Android (the shared fixtures compare the JSON). The search sheet keeps `EventSearch`; the
// router's thresholds ("base score ≥ 3 × tokens", ties) depend on Android's exact scoring and
// sort order (ended last, score, kind, lower-cased title, id) and its time words (`noon`,
// `midnight`, weekday abbreviations only when no text uses them, clock windows inclusive), so
// they live here rather than in the search sheet's index.
//
//   - LikeSet: the liked schedule items and locations (Android `Hearts`).
//   - AssistantSearch: fold / query parsing (tokens + time words) / keywords / time matching /
//     all-token and any-token search / timing / suggestions / the liked list / detail lines.
//   - AssistantText: Android's distance format, walk texts and relative start ("in 1 h").
//   - Rx: small NSRegularExpression helpers with Kotlin `Regex` semantics.

import Foundation

// MARK: - Likes

/// What the attendee liked (hearted) in one event: schedule items and locations.
struct LikeSet: Hashable, Sendable {
    var locations: Set<Int> = []
    var scheduleItems: Set<Int> = []

    static let none = LikeSet()

    var isEmpty: Bool { locations.isEmpty && scheduleItems.isEmpty }

    func has(_ kind: AssistantSearch.Kind, _ id: Int) -> Bool {
        switch kind {
        case .location: return locations.contains(id)
        case .schedule: return scheduleItems.contains(id)
        default: return false
        }
    }

    /// Liked (`liked` true) or not; other kinds are ignored.
    func with(_ kind: AssistantSearch.Kind, _ id: Int, liked: Bool) -> LikeSet {
        var copy = self
        switch kind {
        case .location: if liked { copy.locations.insert(id) } else { copy.locations.remove(id) }
        case .schedule: if liked { copy.scheduleItems.insert(id) } else { copy.scheduleItems.remove(id) }
        default: break
        }
        return copy
    }
}

// MARK: - Bundle lookups

extension EventBundle {
    func scheduleItem(_ id: Int?) -> ScheduleItem? {
        guard let id else { return nil }
        return schedule.first { $0.id == id }
    }

    func location(_ id: Int?) -> Location? {
        guard let id else { return nil }
        return locations.first { $0.id == id }
    }
}

// MARK: - Regular expressions (Kotlin `Regex` semantics)

enum Rx {
    private static func regex(_ pattern: String) -> NSRegularExpression? {
        try? NSRegularExpression(pattern: pattern)
    }

    /// The first match's groups (`groupValues`: index 0 the whole match, "" for a group that didn't take part).
    static func find(_ pattern: String, _ text: String) -> [String]? {
        all(pattern, text).first
    }

    static func all(_ pattern: String, _ text: String) -> [[String]] {
        guard let regex = regex(pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).map { match in
            (0..<match.numberOfRanges).map { index in
                Range(match.range(at: index), in: text).map { String(text[$0]) } ?? ""
            }
        }
    }

    /// The whole text matches (`Regex.matches`).
    static func matches(_ pattern: String, _ text: String) -> Bool {
        find("^(?:" + pattern + ")$", text) != nil
    }

    static func contains(_ pattern: String, _ text: String) -> Bool { find(pattern, text) != nil }

    static func replace(_ pattern: String, _ text: String, with template: String) -> String {
        guard let regex = regex(pattern) else { return text }
        return regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }

    /// Replaces each match with `transform(groupValues)`.
    static func replace(_ pattern: String, _ text: String, _ transform: ([String]) -> String) -> String {
        guard let regex = regex(pattern) else { return text }
        var out = ""
        var last = text.startIndex
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let whole = Range(match.range, in: text) else { continue }
            out += text[last..<whole.lowerBound]
            let groups = (0..<match.numberOfRanges).map { index in
                Range(match.range(at: index), in: text).map { String(text[$0]) } ?? ""
            }
            out += transform(groups)
            last = whole.upperBound
        }
        out += text[last...]
        return out
    }
}

/// A stable sort (Kotlin's `sortedWith` keeps equal elements in order).
extension Array {
    func stableSorted(by less: (Element, Element) -> Bool) -> [Element] {
        enumerated().sorted { a, b in
            if less(a.element, b.element) { return true }
            if less(b.element, a.element) { return false }
            return a.offset < b.offset
        }.map(\.element)
    }
}

// MARK: - Search

enum AssistantSearch {

    /// What a result points at; the order is the tie-break order.
    enum Kind: Int, Hashable, Sendable, Comparable {
        case schedule, location, notification, event
        static func < (a: Kind, b: Kind) -> Bool { a.rawValue < b.rawValue }
    }

    /// Live state of a schedule item (event time zone); the order is Android's ordinal.
    enum Timing: Int, Hashable, Sendable {
        case now, next, ended

        var label: String {
            switch self {
            case .now: return "Now"
            case .next: return "Next"
            case .ended: return "Ended"
            }
        }
    }

    struct Result: Hashable, Sendable {
        var kind: Kind
        /// Schedule item / location / notification id; the event id for `.event`.
        var id: Int
        var title: String
        var score: Double
        var timing: Timing? = nil
    }

    enum Mode: Sendable { case allTokens, anyToken }

    static let weightPrimary = 3.0
    static let weightSecondary = 2.0
    static let weightTertiary = 1.0
    static let boostNow = 8.0
    static let boostNext = 4.0
    static let penaltyEnded = -1000.0

    static let generalTitle = "General"
    static let timeTBATitle = "Time TBA"
    static let nowTitle = "Happening now"
    static let nextTitle = "Up next"
    static let likedTitle = "Liked"
    static let upNextWindow: TimeInterval = 2 * 3600
    static let tonightStartsHour = 17
    static let clockWindow: TimeInterval = 30 * 60

    // MARK: Text

    /// Lower case and diacritics stripped (NFD, combining marks dropped), punctuation kept.
    static func fold(_ value: String) -> String {
        var out = String.UnicodeScalarView()
        for scalar in value.decomposedStringWithCanonicalMapping.unicodeScalars
        where scalar.properties.generalCategory != .nonspacingMark {
            out.append(scalar)
        }
        return String(out).lowercased()
    }

    static func normalize(_ value: String) -> String { PlanText.normalize(value) }
    static func words(_ value: String) -> [String] { PlanText.words(value) }
    static var stopWords: Set<String> { PlanText.stopWords }

    // MARK: Query

    enum DayWord: Hashable, Sendable {
        case today, tomorrow
        /// Calendar weekday, 1 = Sunday … 7 = Saturday.
        case weekday(Int)
    }

    struct TimeFilter: Hashable, Sendable {
        var now = false
        var next = false
        var tonight = false
        var days: [DayWord] = []
        var clocks: [PlanClock] = []

        var isEmpty: Bool { !now && !next && !tonight && days.isEmpty && clocks.isEmpty }
    }

    struct Query: Hashable, Sendable {
        var tokens: [String]
        var time: TimeFilter

        var isEmpty: Bool { tokens.isEmpty && time.isEmpty }
        var isTimeOnly: Bool { tokens.isEmpty && !time.isEmpty }
    }

    private static let weekdays: [String: Int] = [
        "monday": 2, "tuesday": 3, "wednesday": 4, "thursday": 5, "friday": 6, "saturday": 7, "sunday": 1,
    ]
    private static let weekdayAbbreviations: [String: Int] = [
        "mon": 2, "tue": 3, "tues": 3, "wed": 4, "thu": 5, "thur": 5, "thurs": 5, "fri": 6, "sat": 7, "sun": 1,
    ]

    /// Android `SearchQuery.parse`: clock times (3pm, 3:30 pm, 15:00, 3:30 → AM and PM, noon,
    /// midnight) and time words (now, happening now, next, up next, soon, today, tonight, tomorrow,
    /// weekdays; abbreviations only when `vocabulary` doesn't use them) split from the tokens.
    static func parse(_ query: String, vocabulary: Set<String> = []) -> Query {
        var rest = fold(query)
        var clocks: [PlanClock] = []
        rest = Rx.replace(#"(?<![\w:])(\d{1,2})(?::([0-5]\d))?\s*([ap])\.?\s?m\.?(?![\w])"#, rest) { g in
            guard let hour = Int(g[1]), (1...12).contains(hour) else { return g[0] }
            let minute = Int(g[2]) ?? 0
            let pm = g[3] == "p"
            let hour24 = hour == 12 ? (pm ? 12 : 0) : (pm ? hour + 12 : hour)
            clocks.append(PlanClock(hour: hour24, minute: minute))
            return " "
        }
        rest = Rx.replace(#"(?<![\w:])([01]?\d|2[0-3]):([0-5]\d)(?![\w:])"#, rest) { g in
            let hour = Int(g[1]) ?? 0, minute = Int(g[2]) ?? 0
            clocks.append(PlanClock(hour: hour, minute: minute))
            if (1...11).contains(hour) { clocks.append(PlanClock(hour: hour + 12, minute: minute)) }
            return " "
        }
        rest = Rx.replace(#"(?<![\w])noon(?![\w])"#, rest) { _ in clocks.append(PlanClock(hour: 12, minute: 0)); return " " }
        rest = Rx.replace(#"(?<![\w])midnight(?![\w])"#, rest) { _ in clocks.append(.midnight); return " " }

        let words = words(rest)
        var tokens: [String] = []
        var filter = TimeFilter()
        var i = 0
        func addDay(_ day: DayWord) { if !filter.days.contains(day) { filter.days.append(day) } }
        while i < words.count {
            let word = words[i]
            let following = i + 1 < words.count ? words[i + 1] : nil
            if word == "happening" && following == "now" { filter.now = true; i += 1 }
            else if word == "now" { filter.now = true }
            else if word == "up" && following == "next" { filter.next = true; i += 1 }
            else if word == "next" || word == "soon" { filter.next = true }
            else if word == "today" { addDay(.today) }
            else if word == "tonight" { filter.tonight = true }
            else if word == "tomorrow" { addDay(.tomorrow) }
            else if let day = weekdays[word] { addDay(.weekday(day)) }
            else if let day = weekdayAbbreviations[word], !vocabulary.contains(word) { addDay(.weekday(day)) }
            else { tokens.append(word) }
            i += 1
        }
        var distinctClocks: [PlanClock] = []
        for clock in clocks where !distinctClocks.contains(clock) { distinctClocks.append(clock) }
        filter.clocks = distinctClocks
        var distinctTokens: [String] = []
        for token in tokens where !distinctTokens.contains(token) { distinctTokens.append(token) }
        return Query(tokens: distinctTokens, time: filter)
    }

    /// Android `SearchQuery.keywords`: the question's whitespace pieces (folded) that aren't only
    /// stop words; the question unchanged when nothing is left.
    static func keywords(_ question: String) -> String {
        let pieces = fold(question).split(whereSeparator: { $0.isWhitespace }).map(String.init)
        let kept = pieces.filter { piece in !words(piece).allSatisfy { stopWords.contains($0) } }
        return kept.isEmpty ? question : kept.joined(separator: " ")
    }

    // MARK: Time matching

    /// Android `TimeMatcher`, in the event's zone.
    struct TimeMatcher {
        let filter: TimeFilter
        let calendar: Calendar
        let now: Date
        let eventDays: [PlanDate]
        let today: PlanDate
        let namedDays: Set<PlanDate>?

        init(_ filter: TimeFilter, timeZone: TimeZone, now: Date, eventDays: [PlanDate]) {
            self.filter = filter
            calendar = PlanCalendar.calendar(timeZone)
            self.now = now
            self.eventDays = eventDays
            let today = PlanDate(now, in: calendar)
            self.today = today
            if filter.days.isEmpty {
                namedDays = nil
            } else {
                var days = Set<PlanDate>()
                for day in filter.days {
                    switch day {
                    case .today: days.insert(today)
                    case .tomorrow: days.insert(today.adding(days: 1))
                    case .weekday(let weekday):
                        let matching = eventDays.filter { $0.weekday == weekday }
                        if matching.isEmpty {
                            if let next = (0...6).map({ today.adding(days: $0) }).first(where: { $0.weekday == weekday }) { days.insert(next) }
                        } else {
                            days.formUnion(matching)
                        }
                    }
                }
                namedDays = days
            }
        }

        func matches(_ item: ScheduleItem) -> Bool {
            if filter.isEmpty { return true }
            guard let start = item.startTime, let end = ScheduleTiming.effectiveEnd(of: item) else { return false }
            if filter.now || filter.next {
                let isNow = start <= now && end > now
                let isNext = start > now && start <= now.addingTimeInterval(AssistantSearch.upNextWindow)
                if !((filter.now && isNow) || (filter.next && isNext)) { return false }
            }
            if filter.tonight {
                let local = calendar.dateComponents([.hour], from: start)
                if PlanDate(start, in: calendar) != today || (local.hour ?? 0) < AssistantSearch.tonightStartsHour { return false }
            }
            if !filter.clocks.isEmpty {
                let days = namedDays ?? (filter.tonight ? [today] : Set(eventDays))
                let atClock = days.contains { day in
                    filter.clocks.contains { clock in
                        let moment = day.at(clock, in: calendar)
                        let inProgress = start <= moment && end > moment
                        let soonAfter = start >= moment && start <= moment.addingTimeInterval(AssistantSearch.clockWindow)
                        return inProgress || soonAfter
                    }
                }
                if !atClock { return false }
            } else if let namedDays {
                let overlaps = namedDays.contains { day in
                    let dayStart = day.at(.midnight, in: calendar)
                    let dayEnd = day.adding(days: 1).at(.midnight, in: calendar)
                    return start < dayEnd && end > dayStart
                }
                if !overlaps { return false }
            }
            return true
        }
    }

    // MARK: Search

    private struct Field {
        var weight: Double
        var words: [String]
    }

    private struct Candidate {
        var kind: Kind
        var id: Int
        var title: String
        var fields: [Field]
        var item: ScheduleItem?
    }

    private static func field(_ text: String, _ weight: Double) -> Field { Field(weight: weight, words: words(text)) }

    private static func candidates(_ bundle: EventBundle) -> [Candidate] {
        var result: [Candidate] = []
        for item in bundle.schedule {
            let locationName = item.locationName.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
                ?? bundle.location(item.locationId)?.name ?? generalTitle
            result.append(Candidate(kind: .schedule, id: item.id, title: item.name, fields: [
                field(item.name, weightPrimary),
                field(item.tags.joined(separator: " "), weightSecondary),
                field(locationName, weightSecondary),
                field(item.description, weightTertiary),
            ], item: item))
        }
        for location in bundle.locations {
            var fields = [field(location.name, weightPrimary)]
            if let category = location.category { fields.append(field(category, weightSecondary)) }
            fields += [
                field(location.tags.joined(separator: " "), weightSecondary),
                field(location.snippet, weightSecondary),
                field(location.address, weightSecondary),
                field(location.description, weightTertiary),
            ]
            result.append(Candidate(kind: .location, id: location.id, title: location.name, fields: fields))
        }
        for notification in bundle.notifications {
            result.append(Candidate(kind: .notification, id: notification.id, title: notification.title, fields: [
                field(notification.title, weightPrimary), field(notification.body, weightTertiary),
            ]))
        }
        let event = bundle.event
        result.append(Candidate(kind: .event, id: event.id, title: event.name, fields: [
            field(event.name, weightPrimary), field(event.eventCode, weightSecondary),
            field(event.address, weightSecondary), field(event.description, weightTertiary),
        ]))
        return result
    }

    static func search(_ bundle: EventBundle, _ query: String, now: Date, mode: Mode = .allTokens, limit: Int = .max) -> [Result] {
        let candidates = candidates(bundle)
        var vocabulary = Set<String>()
        for candidate in candidates { for field in candidate.fields { vocabulary.formUnion(field.words) } }
        let parsed = parse(query, vocabulary: vocabulary)
        if parsed.isEmpty { return [] }
        let matcher = TimeMatcher(parsed.time, timeZone: bundle.event.timeZone, now: now, eventDays: PlanCalendar.eventDays(bundle, now: now))
        var results: [Result] = []
        for candidate in candidates {
            if parsed.isTimeOnly && candidate.kind != .schedule { continue }
            if let item = candidate.item, !matcher.matches(item) { continue }
            guard let matched = Self.score(candidate, parsed.tokens, mode) else { continue }
            let live: Timing? = candidate.item.flatMap { Self.timing($0, now: now) }
            let boost: Double
            switch live {
            case .now?: boost = boostNow
            case .next?: boost = boostNext
            case .ended?: boost = penaltyEnded
            case nil: boost = 0
            }
            results.append(Result(kind: candidate.kind, id: candidate.id, title: candidate.title, score: matched + boost, timing: live))
        }
        let sorted = results.stableSorted { a, b in
            let ea = a.timing == .ended, eb = b.timing == .ended
            if ea != eb { return !ea }
            if a.score != b.score { return a.score > b.score }
            if a.kind != b.kind { return a.kind < b.kind }
            let ta = a.title.lowercased(), tb = b.title.lowercased()
            if ta != tb { return ta < tb }
            return a.id < b.id
        }
        return Array(sorted.prefix(limit))
    }

    private static func score(_ candidate: Candidate, _ tokens: [String], _ mode: Mode) -> Double? {
        if tokens.isEmpty { return 0 }
        var total = 0.0
        var matched = 0
        for token in tokens {
            var best = 0.0
            for field in candidate.fields {
                for word in field.words {
                    let q = quality(token, word)
                    if q > 0 { best = max(best, field.weight * q) }
                }
            }
            if best == 0 {
                if mode == .allTokens { return nil }
            } else {
                matched += 1
                total += best
            }
        }
        return matched == 0 ? nil : total
    }

    /// Exact word 4, prefix 3, substring 2, one edit away (tokens of 5+ characters) 1, else 0.
    static func quality(_ token: String, _ word: String) -> Double {
        if word == token { return 4 }
        if word.hasPrefix(token) { return 3 }
        if word.contains(token) { return 2 }
        if token.count >= 5, withinOneEdit(token, word) { return 1 }
        return 0
    }

    /// Levenshtein distance ≤ 1.
    static func withinOneEdit(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        let x = Array(a), y = Array(b)
        let (short, long) = x.count <= y.count ? (x, y) : (y, x)
        if long.count - short.count > 1 { return false }
        var i = 0, j = 0, edits = 0
        while i < short.count, j < long.count {
            if short[i] == long[j] { i += 1; j += 1; continue }
            edits += 1
            if edits > 1 { return false }
            if short.count == long.count { i += 1 }
            j += 1
        }
        return edits + (long.count - j) + (short.count - i) <= 1
    }

    /// NOW / NEXT (starts within 2 h) / ENDED, or nil for later and untimed items.
    static func timing(_ item: ScheduleItem, now: Date) -> Timing? {
        guard let start = item.startTime, let end = ScheduleTiming.effectiveEnd(of: item) else { return nil }
        if end <= now { return .ended }
        if start <= now { return .now }
        if start <= now.addingTimeInterval(upNextWindow) { return .next }
        return nil
    }

    // MARK: Suggestions and the liked list

    /// "Happening now" / "Up next" (when something is), then the location categories in use.
    static func suggestions(_ bundle: EventBundle, now: Date) -> [(label: String, query: String)] {
        var result: [(label: String, query: String)] = []
        let timings = Set(bundle.schedule.compactMap { timing($0, now: now) })
        if timings.contains(.now) { result.append((nowTitle, "now")) }
        if timings.contains(.next) { result.append((nextTitle, "next")) }
        var used: [String] = []
        for location in bundle.locations {
            if let category = location.category?.trimmingCharacters(in: .whitespacesAndNewlines), !category.isEmpty, !used.contains(category) {
                used.append(category)
            }
        }
        for category in bundle.categories.filter({ used.contains($0) }) + used.filter({ !bundle.categories.contains($0) }) {
            result.append((category, category))
        }
        return result
    }

    /// Liked schedule items in time order (untimed last), then liked locations in the organizer's order.
    static func liked(_ bundle: EventBundle, _ likes: LikeSet, now: Date) -> [Result] {
        let items = bundle.schedule.filter { likes.scheduleItems.contains($0.id) }.stableSorted { a, b in
            switch (a.startTime, b.startTime) {
            case (nil, nil): return a.id < b.id
            case (nil, _): return false
            case (_, nil): return true
            case let (sa?, sb?): return sa != sb ? sa < sb : a.id < b.id
            }
        }
        let places = bundle.locations.filter { likes.locations.contains($0.id) }
            .stableSorted { $0.sortOrder != $1.sortOrder ? $0.sortOrder < $1.sortOrder : $0.id < $1.id }
        return items.map { Result(kind: .schedule, id: $0.id, title: $0.name, score: 0, timing: timing($0, now: now)) }
            + places.map { Result(kind: .location, id: $0.id, title: $0.name, score: 0) }
    }

    // MARK: Detail lines

    /// schedule → "Sat 7:30–8:30 PM · Main Stage"; location → "Food · Street tacos"; update →
    /// "Sat 3:55 PM · body…"; event → "Nov 14–15 · address" (event time zone).
    static func detail(_ result: Result, _ bundle: EventBundle, locale: Locale) -> String {
        let zone = bundle.event.timeZone
        switch result.kind {
        case .schedule:
            return bundle.scheduleItem(result.id).map { scheduleDetail($0, bundle, locale: locale) } ?? ""
        case .location:
            guard let location = bundle.location(result.id) else { return "" }
            let parts = [location.category?.trimmingCharacters(in: .whitespacesAndNewlines), location.snippet.trimmingCharacters(in: .whitespacesAndNewlines)]
                .compactMap { $0 }.filter { !$0.isEmpty }
            return parts.isEmpty ? location.address.trimmingCharacters(in: .whitespacesAndNewlines) : parts.joined(separator: " · ")
        case .notification:
            guard let notification = bundle.notifications.first(where: { $0.id == result.id }) else { return "" }
            var parts: [String] = []
            if let sent = notification.sendTime { parts.append(AssistantText.format(sent, "EEE h:mm a", zone, locale)) }
            let preview = preview(notification.body)
            if !preview.isEmpty { parts.append(preview) }
            return parts.joined(separator: " · ")
        case .event:
            return eventDetail(bundle.event, locale: locale)
        }
    }

    static func scheduleDetail(_ item: ScheduleItem, _ bundle: EventBundle, locale: Locale) -> String {
        let zone = bundle.event.timeZone
        let time: String
        if let start = item.startTime {
            time = "\(AssistantText.format(start, "EEE", zone, locale)) \(compactTimeRange(start, item.endTime, zone, locale))"
        } else {
            time = timeTBATitle
        }
        let place = item.locationName.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
            ?? bundle.location(item.locationId)?.name ?? generalTitle
        return time + " · " + place
    }

    /// "Nov 14–15 · Panther Island, Fort Worth, TX".
    static func eventDetail(_ event: Event, locale: Locale) -> String {
        let address = event.address.trimmingCharacters(in: .whitespacesAndNewlines)
        return [eventDates(event, locale: locale), address.isEmpty ? nil : address].compactMap { $0 }.joined(separator: " · ")
    }

    /// "Sat, Nov 14", "Nov 14–15", "Nov 30 – Dec 2"; nil without a start.
    static func eventDates(_ event: Event, locale: Locale) -> String? {
        guard let startTime = event.startTime else { return nil }
        let calendar = PlanCalendar.calendar(event.timeZone)
        let start = PlanDate(startTime, in: calendar)
        let end = event.endTime.map { PlanDate($0, in: calendar) }.flatMap { $0 > start ? $0 : nil }
        let zone = event.timeZone
        guard let end, let endTime = event.endTime else { return AssistantText.format(startTime, "EEE, MMM d", zone, locale) }
        if end.year == start.year && end.month == start.month {
            return "\(AssistantText.format(startTime, "MMM d", zone, locale))–\(end.day)"
        }
        return "\(AssistantText.format(startTime, "MMM d", zone, locale)) – \(AssistantText.format(endTime, "MMM d", zone, locale))"
    }

    /// "7:30–8:30 PM", "11:30 AM–12:30 PM", "9:00 PM–Sun 1:00 AM", or the start alone.
    static func compactTimeRange(_ start: Date, _ end: Date?, _ zone: TimeZone, _ locale: Locale) -> String {
        let full = AssistantText.format(start, "h:mm a", zone, locale)
        guard let end, end > start else { return full }
        let calendar = PlanCalendar.calendar(zone)
        if PlanDate(start, in: calendar) != PlanDate(end, in: calendar) {
            return "\(full)–\(AssistantText.format(end, "EEE h:mm a", zone, locale))"
        }
        let sameHalf = (calendar.component(.hour, from: start) < 12) == (calendar.component(.hour, from: end) < 12)
        return sameHalf
            ? "\(AssistantText.format(start, "h:mm", zone, locale))–\(AssistantText.format(end, "h:mm a", zone, locale))"
            : "\(full)–\(AssistantText.format(end, "h:mm a", zone, locale))"
    }

    private static func preview(_ body: String) -> String {
        let flat = Rx.replace(#"\s+"#, body.trimmingCharacters(in: .whitespacesAndNewlines), with: " ")
        return flat.count <= 80 ? flat : String(flat.prefix(80)).trimmingTrailingSpaces() + "…"
    }
}

extension String {
    /// Kotlin `trimEnd()`.
    func trimmingTrailingSpaces() -> String {
        var s = Substring(self)
        while let last = s.last, last.isWhitespace { s.removeLast() }
        return String(s)
    }
}

// MARK: - Texts (Android's formats)

/// Distances shown by the assistant (Android `DistanceUnits`).
enum DistanceUnits: Hashable, Sendable {
    case imperial, metric
}

enum AssistantText {

    /// `date` in `zone` with a fixed pattern ("h:mm a", "EEE", "EEEE, MMMM d, h:mm a").
    static func format(_ date: Date, _ pattern: String, _ zone: TimeZone, _ locale: Locale) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = zone
        formatter.dateFormat = pattern
        return formatter.string(from: date)
    }

    /// "1:00 PM" for a clock time.
    static func clock(_ clock: PlanClock, locale: Locale) -> String {
        let utc = TimeZone(identifier: "UTC") ?? TimeZone(secondsFromGMT: 0) ?? .current
        let date = PlanDate(year: 2000, month: 1, day: 1).at(clock, in: PlanCalendar.calendar(utc))
        return format(date, "h:mm a", utc, locale)
    }

    /// "Saturday" in `locale`.
    static func weekdayName(_ day: PlanDate, locale: Locale) -> String {
        let utc = TimeZone(identifier: "UTC") ?? TimeZone(secondsFromGMT: 0) ?? .current
        return format(day.at(PlanClock(hour: 12, minute: 0), in: PlanCalendar.calendar(utc)), "EEEE", utc, locale)
    }

    // MARK: Distance (Android `DistanceFormat`)

    static let metersPerMile = 1609.344
    static let metersPerFoot = 0.3048

    /// "500 ft", "0.6 mi", "12 mi"; "350 m", "1.2 km", "12 km".
    static func distance(_ meters: Double, _ units: DistanceUnits, locale: Locale) -> String {
        let safe = meters.isFinite && meters > 0 ? meters : 0
        switch units {
        case .imperial:
            let miles = safe / metersPerMile
            if miles < 0.1 { return "\(roundToTen(safe / metersPerFoot)) ft" }
            return "\(large(miles, locale)) mi"
        case .metric:
            let rounded = roundToTen(safe)
            if rounded < 1000 { return "\(rounded) m" }
            return "\(large(safe / 1000, locale)) km"
        }
    }

    private static func roundHalfUp(_ value: Double) -> Int { Int((value + 0.5).rounded(.down)) }

    private static func roundToTen(_ value: Double) -> Int { max(roundHalfUp(value / 10) * 10, 10) }

    private static func large(_ value: Double, _ locale: Locale) -> String {
        let tenths = roundHalfUp(value * 10)
        if tenths < 100 { return String(format: "%.1f", locale: locale, Double(tenths) / 10) }
        return String(roundHalfUp(value))
    }

    // MARK: Walking (Android `Walking`)

    static let nearbyMeters = 8_000.0
    static let maxRouteRatio = 2.5

    /// The straight line × 1.2 at 1.3 m/s, whole seconds.
    static func estimateSeconds(_ straightMeters: Double) -> Int {
        roundHalfUp(max(straightMeters, 0) * WalkTime.detourFactor / WalkTime.speed)
    }

    /// Whole minutes, rounded up, at least 1.
    static func minutes(_ seconds: Int) -> Int { max(1, (seconds + 59) / 60) }

    /// "8 min", "1 h", "1 h 6 min".
    static func duration(_ seconds: Int) -> String {
        let total = minutes(seconds)
        let hours = total / 60, rest = total % 60
        if hours == 0 { return "\(total) min" }
        return rest == 0 ? "\(hours) h" : "\(hours) h \(rest) min"
    }

    /// "8 min walk".
    static func walk(_ seconds: Int) -> String { "\(duration(seconds)) walk" }

    static func acceptsRoute(routeMeters: Double, straightMeters: Double) -> Bool {
        routeMeters.isFinite && routeMeters >= 0 && (straightMeters < 1 || routeMeters <= straightMeters * maxRouteRatio)
    }

    // MARK: Relative start (Android `RelativeTime.relativeStart`)

    static func relativeStart(_ start: Date, end: Date?, now: Date, zone: TimeZone, locale: Locale) -> String {
        let effectiveEnd = end.flatMap { $0 > start ? $0 : nil } ?? start.addingTimeInterval(3600)
        if effectiveEnd <= now { return "Ended" }
        if start <= now {
            let minutes = Int(now.timeIntervalSince(start) / 60)
            if minutes < 1 { return "Started just now" }
            return minutes < 60 ? "Started \(minutes) min ago" : "Now"
        }
        let until = start.timeIntervalSince(now)
        let minutes = Int(until / 60)
        if minutes < 1 { return "Starting now" }
        if minutes < 60 { return "in \(minutes) min" }
        if until < 6 * 3600 {
            let hours = minutes / 60, rest = minutes % 60
            return rest == 0 ? "in \(hours) h" : "in \(hours) h \(rest) min"
        }
        let calendar = PlanCalendar.calendar(zone)
        let today = calendar.startOfDay(for: now)
        let day = calendar.startOfDay(for: start)
        let days = calendar.dateComponents([.day], from: today, to: day).day ?? 0
        let time = format(start, "h:mm a", zone, locale)
        func plural(_ n: Int, _ unit: String) -> String { "in \(n) \(unit)\(n == 1 ? "" : "s")" }
        if days <= 0 { return "today \(time)" }
        if days == 1 { return "tomorrow \(time)" }
        if days < 7 { return "in \(days) days" }
        if days < 35 { return plural(days / 7, "week") }
        let months = max(calendar.dateComponents([.month], from: today, to: day).month ?? 1, 1)
        if months < 12 { return plural(months, "month") }
        return plural(max(calendar.dateComponents([.year], from: today, to: day).year ?? 1, 1), "year")
    }
}
