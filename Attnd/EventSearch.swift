// EventSearch.swift
// Attnd
//
// Local search across the joined event (the same rules as the Android app): schedule items,
// locations, organizer updates and the event itself, from the bundle already on the device.
// Works offline; the query never leaves the device. Pure and unit-tested (DisplayLogicTests).
//
// Rules:
//   - Both sides are normalised: lower case, diacritics folded (é → e), punctuation, `&`
//     and `-` treated as spaces.
//   - Every query token must match somewhere in the item (AND across fields). A token
//     matches a word that equals it (best), starts with it, contains it, or — for tokens of
//     5+ characters — is within edit distance 1 of it (a typo, lowest).
//   - Time words filter schedule items, in the EVENT's time zone: now / happening now,
//     next / up next / soon (starting within 2 h), today, tonight (starts at 17:00 or later
//     today), tomorrow, weekday names (saturday, sat), clock times (3pm, 3 pm, 3:30, 15:00,
//     noon: in progress at that time on one of the event's days, or starting within 30 min
//     after it). A query of only time words returns schedule items only.
//   - Score: field weight × match quality, + a boost for items happening now (largest) or
//     next, − a penalty that puts ended items last. Ties: schedule, location, update, event,
//     then title.
//   - An empty query has no results (the search screen shows suggestions instead).

import Foundation

// MARK: - Targets and results

/// Something in the event the app can show: a jump target for search results, links and notifications.
enum SearchTarget: Hashable, Sendable {
    case scheduleItem(Int)
    case location(Int)
    case notification(Int)
    case event(Int)

    var kind: SearchResultKind {
        switch self {
        case .scheduleItem: return .scheduleItem
        case .location:     return .location
        case .notification: return .notification
        case .event:        return .event
        }
    }

    /// Short stable reference, e.g. "s12" (logs and tie-breaks).
    var reference: String {
        switch self {
        case .scheduleItem(let id): return "s\(id)"
        case .location(let id):     return "l\(id)"
        case .notification(let id): return "n\(id)"
        case .event(let id):        return "e\(id)"
        }
    }
}

/// Result kinds in tie-break order.
enum SearchResultKind: Int, Hashable, Sendable, CaseIterable {
    case scheduleItem, location, notification, event

    var systemImage: String {
        switch self {
        case .scheduleItem: return "calendar"
        case .location:     return "mappin.and.ellipse"
        case .notification: return "bell"
        case .event:        return "ticket"
        }
    }

    var title: String {
        switch self {
        case .scheduleItem: return "Schedule"
        case .location:     return "Location"
        case .notification: return "Update"
        case .event:        return "Event"
        }
    }
}

struct EventSearchResult: Identifiable, Hashable, Sendable {
    enum TimeLabel: String, Hashable, Sendable {
        case now = "Now"
        case next = "Next"
        case ended = "Ended"
    }

    var target: SearchTarget
    var title: String
    /// One line of inline info, e.g. "Sat 7:30 – 8:30 PM · Main Stage".
    var subtitle: String
    /// Schedule items only.
    var timeLabel: TimeLabel?
    /// Matched parts of `title`, as character offsets (sorted, not overlapping).
    var titleHighlights: [Range<Int>]
    var score: Double

    var id: SearchTarget { target }
    var kind: SearchResultKind { target.kind }
}

/// A chip shown for an empty query; tapping it searches for `query`.
struct SearchSuggestion: Identifiable, Hashable, Sendable {
    var title: String
    var systemImage: String
    var query: String
    var id: String { query }
}

// MARK: - Query parsing

/// A time word from the query, evaluated in the event's time zone.
enum SearchTimeFilter: Hashable, Sendable {
    case now
    /// Starting within the next 2 hours (not yet started).
    case next
    case today
    /// Starts at 17:00 or later today.
    case tonight
    case tomorrow
    /// Calendar weekday, 1 = Sunday … 7 = Saturday.
    case weekday(Int)
    /// Minutes after midnight; several when the clock time is ambiguous ("3:30" = 03:30 or 15:30).
    case clock([Int])
}

struct ParsedSearchQuery: Hashable, Sendable {
    /// Normalised text tokens (time words removed).
    var tokens: [String]
    var timeFilters: [SearchTimeFilter]

    var isEmpty: Bool { tokens.isEmpty && timeFilters.isEmpty }
}

enum EventSearch {

    // MARK: Constants

    static let generalLocation = ScheduleGrouping.generalTitle
    /// "next" / "up next" / "soon".
    static let nextWindow: TimeInterval = ScheduleTiming.upNextWindow
    /// A clock time also finds items starting this soon after it.
    static let clockWindow: TimeInterval = 30 * 60
    /// "tonight" starts at this hour (event time zone).
    static let tonightHour = 17
    /// Typo matching only for tokens at least this long.
    static let typoMinimumLength = 5

    // Match quality (multiplied by the field weight).
    static let exactQuality = 4.0
    static let prefixQuality = 3.0
    static let substringQuality = 2.0
    static let typoQuality = 1.0

    // Schedule boosts.
    static let nowBoost = 8.0
    static let nextBoost = 4.0
    static let endedPenalty = 1000.0

    // MARK: Search

    /// Every result for `query`, best first. Empty for an empty query.
    static func search(_ bundle: EventBundle, query: String, now: Date) -> [EventSearchResult] {
        EventSearchIndex(bundle).search(query, now: now)
    }

    /// Suggestions for an empty query: happening now, up next, then the location categories.
    static func suggestions(_ bundle: EventBundle) -> [SearchSuggestion] {
        var result: [SearchSuggestion] = []
        if !bundle.schedule.isEmpty {
            result.append(SearchSuggestion(title: "Happening now", systemImage: "dot.radiowaves.left.and.right", query: "now"))
            result.append(SearchSuggestion(title: "Up next", systemImage: "clock", query: "next"))
        }
        for category in LocationGrouping.categories(bundle.categories, locations: bundle.locations) {
            result.append(SearchSuggestion(title: category, systemImage: "tag", query: category))
        }
        return result
    }

    // MARK: Normalisation

    /// Lower case, diacritics and width folded.
    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil).lowercased()
    }

    /// The normalised words of `text`: folded, split on anything that isn't a letter or digit.
    static func words(_ text: String) -> [String] {
        var words: [String] = []
        var current = ""
        for character in fold(text) {
            if character.isLetter || character.isNumber {
                current.append(character)
            } else if !current.isEmpty {
                words.append(current)
                current = ""
            }
        }
        if !current.isEmpty { words.append(current) }
        return words
    }

    /// "Café Lumière" → "cafe lumiere".
    static func normalise(_ text: String) -> String {
        words(text).joined(separator: " ")
    }

    // MARK: Parsing

    private static let weekdays: [String: Int] = [
        "sunday": 1, "sun": 1,
        "monday": 2, "mon": 2,
        "tuesday": 3, "tue": 3, "tues": 3,
        "wednesday": 4, "wed": 4,
        "thursday": 5, "thu": 5, "thur": 5, "thurs": 5,
        "friday": 6, "fri": 6,
        "saturday": 7, "sat": 7,
    ]

    /// Splits a query into text tokens and time words.
    static func parse(_ query: String) -> ParsedSearchQuery {
        // Time words are recognised on whitespace-separated pieces before punctuation is
        // stripped, so "3:30" stays one clock time. Edge punctuation ("tonight?") is ignored.
        let edge = CharacterSet.punctuationCharacters.union(.symbols).subtracting(CharacterSet(charactersIn: ":"))
        let pieces = fold(query)
            .split(whereSeparator: { $0.isWhitespace })
            .map { $0.trimmingCharacters(in: edge) }
            .filter { !$0.isEmpty }
        var tokens: [String] = []
        var filters: [SearchTimeFilter] = []
        var i = 0
        while i < pieces.count {
            let piece = pieces[i]
            let following = i + 1 < pieces.count ? pieces[i + 1] : nil
            if piece == "happening", following == "now" {
                filters.append(.now); i += 2; continue
            }
            if piece == "up", following == "next" {
                filters.append(.next); i += 2; continue
            }
            switch piece {
            case "now":
                filters.append(.now); i += 1; continue
            case "next", "soon":
                filters.append(.next); i += 1; continue
            case "today":
                filters.append(.today); i += 1; continue
            case "tonight":
                filters.append(.tonight); i += 1; continue
            case "tomorrow":
                filters.append(.tomorrow); i += 1; continue
            case "noon":
                filters.append(.clock([12 * 60])); i += 1; continue
            default:
                break
            }
            if let weekday = weekdays[piece] {
                filters.append(.weekday(weekday)); i += 1; continue
            }
            if let minutes = clockMinutes(piece, suffix: nil) {
                filters.append(.clock(minutes)); i += 1; continue
            }
            if let following, ["am", "pm", "a", "p"].contains(following),
               let minutes = clockMinutes(piece, suffix: following) {
                filters.append(.clock(minutes)); i += 2; continue
            }
            tokens += words(piece)
            i += 1
        }
        return ParsedSearchQuery(tokens: tokens, timeFilters: filters)
    }

    /// "3pm" → [900], "3:30" → [210, 930], "15:00" → [900], "7" → nil (a bare number isn't a time
    /// unless a separate "pm"/"am" follows: `suffix`).
    static func clockMinutes(_ piece: String, suffix: String?) -> [Int]? {
        var text = Substring(piece)
        var meridiem: Character?
        if let suffix {
            meridiem = suffix.first
        } else if text.hasSuffix("am") || text.hasSuffix("pm") {
            meridiem = text.dropLast().last
            text = text.dropLast(2)
        } else if text.hasSuffix("a") || text.hasSuffix("p") {
            meridiem = text.last
            text = text.dropLast()
        }
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count),
              let hourPart = parts.first, (1...2).contains(hourPart.count), hourPart.allSatisfy(\.isASCII),
              let hour = Int(hourPart) else { return nil }
        var minute = 0
        if parts.count == 2 {
            guard parts[1].count == 2, parts[1].allSatisfy(\.isASCII), let m = Int(parts[1]), (0...59).contains(m) else { return nil }
            minute = m
        }
        switch meridiem {
        case "a"?, "p"?:
            guard (1...12).contains(hour) else { return nil }
            let base = hour % 12 + (meridiem == "p" ? 12 : 0)
            return [base * 60 + minute]
        case nil:
            // A bare hour ("7") is not a time; "7:00" and "19:00" are.
            guard parts.count == 2, (0...23).contains(hour) else { return nil }
            if (1...12).contains(hour) {
                // Ambiguous without am/pm: both halves of the day.
                return [hour % 12 * 60 + minute, (hour % 12 + 12) * 60 + minute]
            }
            return [hour * 60 + minute]
        default:
            return nil
        }
    }

    /// The words of a spoken or typed question that are worth searching for
    /// ("When is the mariachi?" → "mariachi"); time words are kept. For the
    /// assistant's fallback; the search field itself uses the query as typed.
    static func keywords(fromQuestion question: String) -> String {
        let stopWords: Set<String> = [
            "a", "an", "the", "is", "are", "was", "be", "what", "whats", "when", "where", "wheres",
            "who", "how", "which", "does", "do", "did", "can", "could", "will", "i", "me", "my", "we",
            "there", "any", "anything", "on", "at", "in", "of", "for", "to", "and", "or", "s",
            "show", "find", "tell", "about", "it", "this", "that", "event", "please", "going",
        ]
        let pieces = fold(question)
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
        let kept = pieces.filter { piece in
            let plain = words(piece).joined()
            return !plain.isEmpty && !stopWords.contains(plain)
        }
        return kept.joined(separator: " ")
    }

    /// Whether a typed query reads like a question for the assistant ("Ask").
    static func looksLikeQuestion(_ query: String) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasSuffix("?") { return true }
        let first = words(trimmed).first ?? ""
        let starters: Set<String> = ["what", "whats", "when", "where", "wheres", "who", "how", "which", "is", "are", "can", "does", "do", "should", "will"]
        return starters.contains(first) && words(trimmed).count >= 3
    }

    // MARK: Matching

    /// Quality of `token` against one normalised word (0 = no match).
    static func quality(token: String, word: String) -> Double {
        if word == token { return exactQuality }
        if word.hasPrefix(token) { return prefixQuality }
        if word.contains(token) { return substringQuality }
        if token.count >= typoMinimumLength, isWithinOneEdit(token, word) { return typoQuality }
        return 0
    }

    /// Levenshtein distance ≤ 1 (one insertion, deletion or substitution).
    static func isWithinOneEdit(_ a: String, _ b: String) -> Bool {
        let x = Array(a), y = Array(b)
        let (short, long) = x.count <= y.count ? (x, y) : (y, x)
        guard long.count - short.count <= 1 else { return false }
        var i = 0, j = 0, edits = 0
        while i < short.count, j < long.count {
            if short[i] == long[j] {
                i += 1; j += 1
                continue
            }
            edits += 1
            if edits > 1 { return false }
            if short.count == long.count { i += 1 }
            j += 1
        }
        edits += (short.count - i) + (long.count - j)
        return edits <= 1
    }

    // MARK: Time filters

    static func matches(
        _ item: ScheduleItem,
        _ filter: SearchTimeFilter,
        now: Date,
        calendar: Calendar,
        eventDays: [Date]
    ) -> Bool {
        switch filter {
        case .now:
            return ScheduleTiming.isHappening(item, at: now)
        case .next:
            guard let start = item.startTime else { return false }
            return start > now && start <= now.addingTimeInterval(nextWindow)
        case .today:
            guard let start = item.startTime else { return false }
            return calendar.isDate(start, inSameDayAs: now)
        case .tonight:
            guard let start = item.startTime else { return false }
            return calendar.isDate(start, inSameDayAs: now) && calendar.component(.hour, from: start) >= tonightHour
        case .tomorrow:
            guard let start = item.startTime,
                  let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) else { return false }
            return calendar.isDate(start, inSameDayAs: tomorrow)
        case .weekday(let weekday):
            guard let start = item.startTime else { return false }
            return calendar.component(.weekday, from: start) == weekday
        case .clock(let minutes):
            guard let start = item.startTime else { return false }
            for day in eventDays {
                for minute in minutes {
                    guard let moment = calendar.date(byAdding: .minute, value: minute, to: day) else { continue }
                    if ScheduleTiming.isHappening(item, at: moment) { return true }
                    if start >= moment, start < moment.addingTimeInterval(clockWindow) { return true }
                }
            }
            return false
        }
    }

    /// Now / Next / Ended for a schedule item.
    static func timeLabel(_ item: ScheduleItem, now: Date) -> EventSearchResult.TimeLabel? {
        if ScheduleTiming.isHappening(item, at: now) { return .now }
        if ScheduleTiming.hasEnded(item, at: now) { return .ended }
        if let start = item.startTime, start > now, start <= now.addingTimeInterval(nextWindow) { return .next }
        return nil
    }

    // MARK: Inline info

    /// "Sat 7:30 – 8:30 PM" in the event's time zone ("Time TBA" without a start).
    static func dayTimeRange(start: Date?, end: Date?, timeZone: TimeZone, locale: Locale = .current) -> String {
        guard let start else { return "Time TBA" }
        if let end, end > start {
            var style = Date.IntervalFormatStyle().weekday(.abbreviated).hour().minute()
            style.timeZone = timeZone
            style.locale = locale
            return style.format(start..<end)
        }
        var style = Date.FormatStyle.dateTime.weekday(.abbreviated).hour().minute()
        style.timeZone = timeZone
        style.locale = locale
        return start.formatted(style)
    }

    /// "Nov 14 – 16" in the event's time zone (nil without a start).
    static func dateRange(start: Date?, end: Date?, timeZone: TimeZone, locale: Locale = .current) -> String? {
        guard let start else { return nil }
        let calendar = EventTimeFormat.calendar(in: timeZone)
        if let end, end > start, !calendar.isDate(start, inSameDayAs: end) {
            var style = Date.IntervalFormatStyle().month(.abbreviated).day()
            style.timeZone = timeZone
            style.locale = locale
            return style.format(start..<end)
        }
        var style = Date.FormatStyle.dateTime.month(.abbreviated).day()
        style.timeZone = timeZone
        style.locale = locale
        return start.formatted(style)
    }

    /// The first `limit` characters of `text` on one line, with an ellipsis when cut.
    static func excerpt(_ text: String, limit: Int = 80) -> String {
        let oneLine = text.split(whereSeparator: \.isNewline).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        guard oneLine.count > limit else { return oneLine }
        return String(oneLine.prefix(limit)).trimmingCharacters(in: .whitespaces) + "…"
    }
}

// MARK: - Index

/// The bundle prepared for searching (normalised once; reuse it while the bundle is unchanged).
struct EventSearchIndex: Sendable {

    struct Field: Sendable {
        var weight: Double
        var words: [String]
    }

    /// A title word with the original character offset of each of its normalised characters.
    struct TitleWord: Sendable {
        var text: String
        var offsets: [Int]
    }

    struct Entry: Sendable {
        var target: SearchTarget
        var title: String
        var titleWords: [TitleWord]
        var titleWeight: Double
        /// Every other field, with its weight.
        var fields: [Field]
        var subtitle: String
        /// Schedule items only (time filters, labels and boosts).
        var item: ScheduleItem?
        var sortTitle: String
    }

    let entries: [Entry]
    let timeZone: TimeZone
    let calendar: Calendar
    /// Start of each day the event or its schedule covers (event time zone), for clock times.
    let eventDays: [Date]

    init(_ bundle: EventBundle) {
        let timeZone = bundle.event.timeZone
        let calendar = EventTimeFormat.calendar(in: timeZone)
        self.timeZone = timeZone
        self.calendar = calendar

        var days = Set<Date>()
        if let start = bundle.event.startTime {
            var day = calendar.startOfDay(for: start)
            let last = calendar.startOfDay(for: max(bundle.event.endTime ?? start, start))
            var count = 0
            while day <= last, count < 31 {
                days.insert(day)
                guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
                day = next
                count += 1
            }
        }
        for item in bundle.schedule {
            if let start = item.startTime { days.insert(calendar.startOfDay(for: start)) }
        }
        eventDays = days.sorted()

        let locationNames = Dictionary(bundle.locations.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        var entries: [Entry] = []

        for item in bundle.schedule {
            let locationName = item.locationName ?? item.locationId.flatMap { locationNames[$0] } ?? EventSearch.generalLocation
            let time = EventSearch.dayTimeRange(start: item.startTime, end: item.endTime, timeZone: timeZone)
            entries.append(Entry(
                target: .scheduleItem(item.id),
                title: item.name,
                titleWords: Self.titleWords(item.name),
                titleWeight: 3,
                fields: [
                    Field(weight: 2, words: item.tags.flatMap(EventSearch.words)),
                    Field(weight: 2, words: EventSearch.words(locationName)),
                    Field(weight: 1, words: EventSearch.words(item.description)),
                    // API-018: performer names and genres weigh like tags, bios and the about text like descriptions.
                    Field(weight: 2, words: ((item.context?.performers.map(\.name) ?? []) + (item.context?.genres ?? [])).flatMap(EventSearch.words)),
                    Field(weight: 1, words: ([item.context?.about ?? ""] + (item.context?.performers.map(\.bio) ?? [])).flatMap(EventSearch.words)),
                ],
                subtitle: "\(time) · \(locationName)",
                item: item,
                sortTitle: EventSearch.normalise(item.name)
            ))
        }

        for location in bundle.locations {
            let info = [location.category ?? "", location.snippet].filter { !$0.isEmpty }
            let subtitle = info.isEmpty ? location.address : info.joined(separator: " · ")
            entries.append(Entry(
                target: .location(location.id),
                title: location.name,
                titleWords: Self.titleWords(location.name),
                titleWeight: 3,
                fields: [
                    // Location tags (API-010) weigh like schedule item tags.
                    Field(weight: 2, words: location.tags.flatMap(EventSearch.words)),
                    Field(weight: 2, words: EventSearch.words(location.category ?? "")),
                    Field(weight: 2, words: EventSearch.words(location.snippet)),
                    Field(weight: 2, words: EventSearch.words(location.address)),
                    Field(weight: 1, words: EventSearch.words(location.description)),
                ],
                subtitle: subtitle,
                item: nil,
                sortTitle: EventSearch.normalise(location.name)
            ))
        }

        for notification in bundle.notifications {
            let sent = notification.sendTime.map { EventTimeFormat.shortDayTime($0, in: timeZone) }
            let subtitle = [sent ?? "", EventSearch.excerpt(notification.body)].filter { !$0.isEmpty }.joined(separator: " · ")
            entries.append(Entry(
                target: .notification(notification.id),
                title: notification.title,
                titleWords: Self.titleWords(notification.title),
                titleWeight: 3,
                fields: [Field(weight: 1, words: EventSearch.words(notification.body))],
                subtitle: subtitle,
                item: nil,
                sortTitle: EventSearch.normalise(notification.title)
            ))
        }

        let event = bundle.event
        let dates = EventSearch.dateRange(start: event.startTime, end: event.endTime, timeZone: timeZone)
        entries.append(Entry(
            target: .event(event.id),
            title: event.name,
            titleWords: Self.titleWords(event.name),
            titleWeight: 3,
            fields: [
                Field(weight: 3, words: EventSearch.words(event.eventCode)),
                Field(weight: 2, words: EventSearch.words(event.address)),
                Field(weight: 1, words: EventSearch.words(event.description)),
            ],
            subtitle: [dates ?? "", event.address].filter { !$0.isEmpty }.joined(separator: " · "),
            item: nil,
            sortTitle: EventSearch.normalise(event.name)
        ))

        self.entries = entries
    }

    /// Normalised words of a title, remembering where each character came from.
    static func titleWords(_ title: String) -> [TitleWord] {
        var words: [TitleWord] = []
        var text = ""
        var offsets: [Int] = []
        func flush() {
            if !text.isEmpty { words.append(TitleWord(text: text, offsets: offsets)) }
            text = ""
            offsets = []
        }
        for (offset, character) in title.enumerated() {
            var added = false
            for folded in EventSearch.fold(String(character)) where folded.isLetter || folded.isNumber {
                text.append(folded)
                offsets.append(offset)
                added = true
            }
            if !added { flush() }
        }
        flush()
        return words
    }

    // MARK: Search

    func search(_ query: String, now: Date) -> [EventSearchResult] {
        let parsed = EventSearch.parse(query)
        guard !parsed.isEmpty else { return [] }
        var results: [(result: EventSearchResult, sortTitle: String)] = []

        for entry in entries {
            if let item = entry.item {
                let passes = parsed.timeFilters.allSatisfy {
                    EventSearch.matches(item, $0, now: now, calendar: calendar, eventDays: eventDays)
                }
                guard passes else { continue }
            } else if parsed.tokens.isEmpty {
                // Only time words: schedule items only.
                continue
            }

            var score = 0.0
            var highlights: [Range<Int>] = []
            var matchedAll = true
            for token in parsed.tokens {
                var titleBest = 0.0
                var titleRange: Range<Int>?
                for word in entry.titleWords {
                    let q = EventSearch.quality(token: token, word: word.text)
                    if q > titleBest {
                        titleBest = q
                        titleRange = Self.highlight(token: token, in: word, quality: q)
                    }
                }
                var best = titleBest * entry.titleWeight
                for field in entry.fields {
                    for word in field.words {
                        best = max(best, EventSearch.quality(token: token, word: word) * field.weight)
                    }
                }
                guard best > 0 else {
                    matchedAll = false
                    break
                }
                score += best
                if let titleRange { highlights.append(titleRange) }
            }
            guard matchedAll else { continue }

            var label: EventSearchResult.TimeLabel?
            if let item = entry.item {
                label = EventSearch.timeLabel(item, now: now)
                switch label {
                case .now?:   score += EventSearch.nowBoost
                case .next?:  score += EventSearch.nextBoost
                case .ended?: score -= EventSearch.endedPenalty
                case nil:     break
                }
            }
            results.append((
                result: EventSearchResult(
                    target: entry.target,
                    title: entry.title,
                    subtitle: entry.subtitle,
                    timeLabel: label,
                    titleHighlights: Self.merged(highlights),
                    score: score
                ),
                sortTitle: entry.sortTitle
            ))
        }

        return results.sorted { a, b in
            if a.result.score != b.result.score { return a.result.score > b.result.score }
            if a.result.kind != b.result.kind { return a.result.kind.rawValue < b.result.kind.rawValue }
            if a.sortTitle != b.sortTitle { return a.sortTitle < b.sortTitle }
            return a.result.target.reference < b.result.target.reference
        }.map(\.result)
    }

    /// A result row for one item without a query (assistant citations).
    func result(for target: SearchTarget, now: Date) -> EventSearchResult? {
        guard let entry = entries.first(where: { $0.target == target }) else { return nil }
        return EventSearchResult(
            target: entry.target,
            title: entry.title,
            subtitle: entry.subtitle,
            timeLabel: entry.item.flatMap { EventSearch.timeLabel($0, now: now) },
            titleHighlights: [],
            score: 0
        )
    }

    /// The original-character range a match covers: the matched prefix or substring, the whole word for a typo.
    static func highlight(token: String, in word: TitleWord, quality: Double) -> Range<Int>? {
        guard quality > 0, let first = word.offsets.first, let last = word.offsets.last else { return nil }
        var lower = 0
        var upper = word.offsets.count
        if quality >= EventSearch.substringQuality, let range = word.text.range(of: token) {
            lower = word.text.distance(from: word.text.startIndex, to: range.lowerBound)
            upper = lower + token.count
        }
        guard lower < upper, upper <= word.offsets.count else { return first..<(last + 1) }
        return word.offsets[lower]..<(word.offsets[upper - 1] + 1)
    }

    static func merged(_ ranges: [Range<Int>]) -> [Range<Int>] {
        var result: [Range<Int>] = []
        for range in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = result.last, range.lowerBound <= last.upperBound {
                result[result.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
            } else {
                result.append(range)
            }
        }
        return result
    }
}
