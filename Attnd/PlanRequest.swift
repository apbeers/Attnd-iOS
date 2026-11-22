// PlanRequest.swift
// Attnd (app + App Clip; unit tested in PlanRequestTests)
//
// Turning an attendee's request ("Plan my Saturday around live music and BBQ") into
// `PlanPreferences` (shared spec §6; a port of Android's `domain/PlanRequest.kt`):
//
//   - looksLikePlan: whether Ask should make a plan rather than answer a question.
//   - prompt: the event's vocabulary (days, tags, categories, hearted items, upcoming items) and
//     the request, for the on-device model (EventAssistant.planPreferences).
//   - validate / parse: the model's reply (Foundation Models' structured output, or JSON text)
//     checked against the bundle: unknown tags, categories, ids and days are dropped.
//   - heuristic: the same request read with plain rules; `merge` lets it fill whatever the
//     model left empty, and it replaces the model when the model is unavailable or fails.
//   - examples: the suggestion chips for onboarding and the empty plan card.

import Foundation

/// A suggestion chip for onboarding / the plan card; `isPlan` chips make a plan, others are questions.
struct PlanExample: Hashable, Sendable, Identifiable {
    var text: String
    var isPlan: Bool

    var id: String { text }
}

/// The model's preferences before validation: what Foundation Models' `@Generable` reply (or a
/// JSON object) said, as plain values. `PlanRequest.validate` turns it into `PlanPreferences`.
struct PlanModelReply: Hashable, Sendable {
    var likedTags: [String] = []
    var dislikedTags: [String] = []
    var likedCategories: [String] = []
    var dislikedCategories: [String] = []
    /// Item ids as given: "101", "S103", "[s12]".
    var similarTo: [String] = []
    /// "YYYY-MM-DD".
    var days: [String] = []
    /// "HH:MM" (24-hour).
    var earliest: String? = nil
    var latest: String? = nil
    var hours: Double? = nil
    var pace: String? = nil
    var includeMeals = false
    var kidFriendly = false
}

enum PlanRequest {

    /// Whether an Ask request should make a plan rather than answer a question.
    static func looksLikePlan(_ request: String) -> Bool {
        let pattern = #"\b(plan|planner|planning|itinerary|highlights|schedule me|build me|my (day|morning|afternoon|evening|night|weekend|monday|tuesday|wednesday|thursday|friday|saturday|sunday))\b|(?<!\bin )\b\d+(\.\d)? ?(hours?|hrs?)\b|(?<!\bin )\b(an|one|two|three|four|five|six|a few|a couple of) hours?\b|\b(kid|kids|family) friendly (morning|afternoon|evening|day)\b"#
        return firstMatch(pattern, in: PlanText.normalize(request)) != nil
    }

    // MARK: Model prompt

    static let maxItemsInPrompt = 60
    static let maxTagsInPrompt = 40

    /// The request with the event's vocabulary, for the on-device model (Android's prompt, line
    /// for line; the reply's shape comes from `@Generable` on iOS, the JSON form stays as a hint).
    static func prompt(_ bundle: EventBundle, request: String, heartedItems: Set<Int>, now: Date) -> String {
        let calendar = PlanCalendar.calendar(bundle.event.timeZone)
        let today = PlanDate(now, in: calendar)
        let clock = calendar.dateComponents([.hour, .minute], from: now)
        let days = PlanCalendar.eventDays(bundle, now: now).filter { $0 >= today }
        let items = bundle.schedule
            .filter { item in item.startTime != nil && (ScheduleTiming.effectiveEnd(of: item).map { $0 > now } ?? false) }
            .sorted(by: Planner.itemOrder)
            .prefix(maxItemsInPrompt)
        let hearted = bundle.schedule.filter { heartedItems.contains($0.id) }.sorted(by: Planner.itemOrder)
        var lines: [String] = []
        lines.append("You help plan a visit to the event \"\(bundle.event.name)\".")
        lines.append("Read the request and reply with only one JSON object and no other text, in this form:")
        lines.append(#"{"liked_tags":[],"disliked_tags":[],"liked_categories":[],"disliked_categories":[],"similar_to":[],"days":[],"earliest":null,"latest":null,"hours":null,"pace":"balanced","include_meals":false,"kid_friendly":false}"#)
        lines.append("Rules:")
        lines.append("- liked_tags and disliked_tags: only words from TAGS. liked_categories and disliked_categories: only from CATEGORIES.")
        lines.append("- similar_to: the numbers of ITEMS the request names or wants more of.")
        lines.append("- days: dates from DAYS the request asks for, as YYYY-MM-DD; [] when it names none.")
        lines.append("- earliest and latest: \"HH:MM\" (24-hour) when the request gives times. hours: how many hours it has, as a number.")
        lines.append("- pace: \"relaxed\", \"balanced\" or \"packed\".")
        lines.append("- include_meals: true when it mentions lunch, dinner or food breaks. kid_friendly: true for kids or family.")
        lines.append("NOW: \(today.weekdayName) \(today) \(String(format: "%02d:%02d", clock.hour ?? 0, clock.minute ?? 0))")
        lines.append("DAYS: " + days.map { "\($0) \($0.weekdayName)" }.joined(separator: ", "))
        lines.append("TAGS: " + tagVocabulary(bundle).prefix(maxTagsInPrompt).joined(separator: ", "))
        lines.append("CATEGORIES: " + categories(bundle).joined(separator: ", "))
        if !hearted.isEmpty {
            lines.append("HEARTED: " + hearted.map { "\($0.id) \($0.name)" }.joined(separator: "; "))
        }
        lines.append("ITEMS: " + items.map { item in
            "\(item.id) \(item.name)" + (item.tags.isEmpty ? "" : " (\(item.tags.joined(separator: ", ")))")
        }.joined(separator: "; "))
        lines.append("REQUEST: \(request.trimmingCharacters(in: .whitespacesAndNewlines))")
        return lines.joined(separator: "\n") + "\nJSON:"
    }

    /// Tags of schedule items and locations, lower case, by how many use them (ties alphabetical).
    static func tagVocabulary(_ bundle: EventBundle) -> [String] {
        var counts: [String: Int] = [:]
        for tag in bundle.schedule.flatMap(\.tags) + bundle.locations.flatMap(\.tags) {
            let key = tag.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if !key.isEmpty { counts[key, default: 0] += 1 }
        }
        return counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.map(\.key)
    }

    /// The bundle's categories plus any location category it doesn't list, in that order, without
    /// duplicates (case-insensitive; the first spelling wins).
    static func categories(_ bundle: EventBundle) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for category in bundle.categories + bundle.locations.compactMap(\.category)
        where !category.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if seen.insert(category.lowercased()).inserted { result.append(category) }
        }
        return result
    }

    // MARK: Reading the model's reply

    /// The model's reply validated against `bundle`: tags lower case and in the event, categories
    /// in the event's spelling, ids of schedule items ("S103" too), event days, "HH:MM" times,
    /// 0 < hours ≤ 24, the pace.
    static func validate(_ reply: PlanModelReply, bundle: EventBundle, now: Date) -> PlanPreferences {
        let tagSet = Set(tagVocabulary(bundle))
        var categoryByLower: [String: String] = [:]
        for category in categories(bundle) where categoryByLower[category.lowercased()] == nil {
            categoryByLower[category.lowercased()] = category
        }
        let ids = Set(bundle.schedule.map(\.id))
        let eventDays = Set(PlanCalendar.eventDays(bundle, now: now))

        func tags(_ values: [String]) -> Set<String> {
            Set(values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }.filter { tagSet.contains($0) })
        }
        func cats(_ values: [String]) -> Set<String> {
            Set(values.compactMap { categoryByLower[$0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()] })
        }

        let similar = reply.similarTo.compactMap { value -> Int? in
            if let id = Int(value) { return id }
            var text = Substring(value.trimmingCharacters(in: .whitespacesAndNewlines))
            while let first = text.first, first == "S" || first == "s" || first == "[" { text = text.dropFirst() }
            while text.last == "]" { text = text.dropLast() }
            return Int(text)
        }
        .filter { ids.contains($0) }

        var minutes: Int?
        if let hours = reply.hours, hours > 0, hours <= 24 {
            minutes = Int((hours * 60).rounded(.toNearestOrAwayFromZero))
        }

        return PlanPreferences(
            likedTags: tags(reply.likedTags),
            dislikedTags: tags(reply.dislikedTags),
            likedCategories: cats(reply.likedCategories),
            dislikedCategories: cats(reply.dislikedCategories),
            similarTo: Set(similar),
            days: Set(reply.days.compactMap { PlanDate.parse($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
                .filter { eventDays.contains($0) }).sorted(),
            earliest: clock(reply.earliest),
            latest: clock(reply.latest),
            durationMinutes: minutes,
            pace: PlanPace.of(reply.pace),
            includeMeals: reply.includeMeals,
            kidFriendly: reply.kidFriendly
        )
    }

    /// A JSON reply (the first `{` to the last `}`), validated; nil when it can't be read.
    static func parse(_ raw: String, bundle: EventBundle, now: Date) -> PlanPreferences? {
        guard let start = raw.firstIndex(of: "{"), let end = raw.lastIndex(of: "}"), start < end,
              let data = String(raw[start...end]).data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }

        func strings(_ key: String) -> [String] {
            (object[key] as? [Any] ?? []).compactMap(primitiveText)
        }
        var reply = PlanModelReply()
        reply.likedTags = strings("liked_tags")
        reply.dislikedTags = strings("disliked_tags")
        reply.likedCategories = strings("liked_categories")
        reply.dislikedCategories = strings("disliked_categories")
        // A JSON number is an id as it is; "true" never is.
        reply.similarTo = (object["similar_to"] as? [Any] ?? []).compactMap { element in
            if isBool(element) { return nil }
            if let number = element as? NSNumber {
                let value = number.doubleValue
                return value == value.rounded() ? String(Int(value)) : nil
            }
            return element as? String
        }
        reply.days = strings("days")
        reply.earliest = object["earliest"].flatMap(primitiveText)
        reply.latest = object["latest"].flatMap(primitiveText)
        reply.hours = object["hours"].flatMap { value -> Double? in
            if isBool(value) { return nil }
            if let number = value as? NSNumber { return number.doubleValue }
            return (value as? String).flatMap { Double($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        }
        reply.pace = object["pace"].flatMap(primitiveText)
        reply.includeMeals = boolValue(object["include_meals"])
        reply.kidFriendly = boolValue(object["kid_friendly"])
        return validate(reply, bundle: bundle, now: now)
    }

    private static func isBool(_ value: Any) -> Bool {
        guard let number = value as? NSNumber else { return false }
        return CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    /// A JSON primitive's text (null and containers → nil): strings as they are, numbers and booleans as written.
    private static func primitiveText(_ value: Any) -> String? {
        if let text = value as? String { return text }
        if isBool(value), let number = value as? NSNumber { return number.boolValue ? "true" : "false" }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    private static func boolValue(_ value: Any?) -> Bool {
        guard let value else { return false }
        if isBool(value), let number = value as? NSNumber { return number.boolValue }
        if let text = value as? String { return text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "true" }
        return false
    }

    /// "15:00" → 15:00 (a prefix "H:MM" / "HH:MM", hour 0–23, minute 0–59); nil otherwise.
    private static func clock(_ value: String?) -> PlanClock? {
        guard let text = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              let match = firstMatch(#"^(\d{1,2}):(\d{2})"#, in: text),
              let hour = match[1].flatMap({ Int($0) }), let minute = match[2].flatMap({ Int($0) }),
              (0...23).contains(hour), (0...59).contains(minute) else { return nil }
        return PlanClock(hour: hour, minute: minute)
    }

    // MARK: Plain-rule reading

    private static let negations: Set<String> = ["no", "not", "without", "avoid", "skip", "except", "hate", "dislike"]
    private static let relaxedWords = ["relaxed", "relax", "relaxing", "chill", "easy", "slow", "laid back", "lazy"]
    private static let packedWords = ["packed", "busy", "everything", "as much as", "lots", "full day", "nonstop", "non stop"]
    private static let mealWords = ["lunch", "dinner", "eat", "eating", "meal", "meals", "food break", "food breaks", "snack", "brunch"]
    private static let kidWords = ["kid", "kids", "child", "children", "family", "toddler", "toddlers"]
    /// In this order (Android's `mapOf` keeps insertion order).
    private static let wordHours: [(String, Int)] = [
        ("an", 60), ("one", 60), ("a couple of", 120), ("two", 120), ("a few", 180),
        ("three", 180), ("four", 240), ("five", 300), ("six", 360),
    ]
    private static let noon = PlanClock(hour: 12, minute: 0)
    private static let evening = PlanClock(hour: 17, minute: 0)

    /// The request read with plain rules (normalised text, whole-phrase matches): event tags and
    /// categories it mentions (after "no"/"not"/"without"/"avoid"/"skip"/"except"/"hate"/"dislike"
    /// → disliked), schedule item names of 4+ characters (→ similarTo), weekdays/"today"/
    /// "tomorrow" that are event days, "after/from 3pm" (earliest) and "before/until/by 9pm"
    /// (latest; an hour 1–7 without am/pm is pm), else "morning" (latest 12:00), "afternoon"
    /// (12:00–17:00), "evening"/"tonight"/"night" (earliest 17:00); "3 hours"/"a couple of
    /// hours", pace words, meal words, kid words.
    static func heuristic(_ request: String, bundle: EventBundle, now: Date) -> PlanPreferences {
        let text = " " + PlanText.normalize(request).trimmingCharacters(in: .whitespaces) + " "
        var liked = Set<String>(), disliked = Set<String>()
        for tag in tagVocabulary(bundle) {
            let phrase = PlanText.normalize(tag).trimmingCharacters(in: .whitespaces)
            if phrase.isEmpty { continue }
            switch mention(text, phrase) {
            case .liked?:    liked.insert(tag)
            case .disliked?: disliked.insert(tag)
            case nil:        break
            }
        }
        var likedCats = Set<String>(), dislikedCats = Set<String>()
        for category in categories(bundle) {
            switch mention(text, PlanText.normalize(category).trimmingCharacters(in: .whitespaces)) {
            case .liked?:    likedCats.insert(category)
            case .disliked?: dislikedCats.insert(category)
            case nil:        break
            }
        }
        let similar = Set(bundle.schedule.filter { item in
            let name = PlanText.normalize(item.name).trimmingCharacters(in: .whitespaces)
            return name.count >= 4 && text.contains(" \(name) ")
        }.map(\.id))

        let calendar = PlanCalendar.calendar(bundle.event.timeZone)
        let today = PlanDate(now, in: calendar)
        let eventDays = PlanCalendar.eventDays(bundle, now: now)
        var days: [PlanDate] = []
        func addDay(_ day: PlanDate) { if !days.contains(day) { days.append(day) } }
        if text.contains(" today ") || text.contains(" tonight ") { addDay(today) }
        if text.contains(" tomorrow ") { addDay(today.adding(days: 1)) }
        // Monday … Sunday, as Android's DayOfWeek.entries.
        for weekday in [2, 3, 4, 5, 6, 7, 1] {
            let name = PlanDate.weekdayNames[weekday - 1].lowercased()
            if text.contains(" \(name) "), let day = eventDays.first(where: { $0.weekday == weekday && $0 >= today }) {
                addDay(day)
            }
        }

        var earliest: PlanClock?
        var latest: PlanClock?
        for match in allMatches(#"\b(after|from|before|until|till|til|by) (\d{1,2})(?: (\d{2}))? ?(am|pm|a m|p m)?\b"#, in: text) {
            guard var hour = match[2].flatMap({ Int($0) }) else { continue }
            let minute = match[3].flatMap { Int($0) } ?? 0
            let suffix = (match[4] ?? "").replacingOccurrences(of: " ", with: "")
            if hour > 23 || minute > 59 { continue }
            if suffix == "pm", hour < 12 {
                hour += 12
            } else if suffix == "am", hour == 12 {
                hour = 0
            } else if suffix.isEmpty, (1...7).contains(hour) {
                hour += 12
            }
            let time = PlanClock(hour: hour % 24, minute: minute)
            switch match[1] {
            case "after"?, "from"?: earliest = time
            default:                latest = time
            }
        }

        // Parts of the day, only where no explicit time was given.
        if text.contains(" morning ") {
            if latest == nil { latest = noon }
        } else if text.contains(" afternoon ") {
            if earliest == nil { earliest = noon }
            if latest == nil { latest = evening }
        } else if text.contains(" evening ") || text.contains(" tonight ") || text.contains(" night ") {
            if earliest == nil { earliest = evening }
        }

        var duration: Int?
        if let hours = firstMatch(#"\b(\d+(?:\.\d+)?) ?(?:hours?|hrs?)\b"#, in: text)?[1].flatMap({ Double($0) }),
           hours > 0, hours <= 24 {
            duration = Int((hours * 60).rounded(.toNearestOrAwayFromZero))
        } else {
            duration = wordHours.first { text.contains(" \($0.0) hour") }?.1
        }

        let pace: PlanPace
        if relaxedWords.contains(where: { text.contains(" \($0) ") }) {
            pace = .relaxed
        } else if packedWords.contains(where: { text.contains(" \($0) ") }) {
            pace = .packed
        } else {
            pace = .balanced
        }
        let eventDaySet = Set(eventDays)
        return PlanPreferences(
            likedTags: liked,
            dislikedTags: disliked,
            likedCategories: likedCats,
            dislikedCategories: dislikedCats,
            similarTo: similar,
            days: days.filter { eventDaySet.contains($0) }.sorted(),
            earliest: earliest,
            latest: latest,
            durationMinutes: duration,
            pace: pace,
            includeMeals: mealWords.contains { text.contains(" \($0) ") },
            kidFriendly: kidWords.contains { text.contains(" \($0) ") }
        )
    }

    private enum Mention { case liked, disliked }

    /// Whether `phrase` (or its plural) appears as whole words, and whether a negation word is
    /// among the two words right before it.
    private static func mention(_ text: String, _ phrase: String) -> Mention? {
        if phrase.isEmpty { return nil }
        for form in [phrase, phrase + "s"] {
            guard let range = text.range(of: " \(form) ") else { continue }
            let before = text[..<range.lowerBound].trimmingCharacters(in: .whitespaces)
                .split(separator: " ", omittingEmptySubsequences: false)
                .suffix(2)
            return before.contains { negations.contains(String($0)) } ? .disliked : .liked
        }
        return nil
    }

    /// The model's preferences completed by the plain-rule reading: tag/category/similar sets are
    /// unions (a tag both liked and disliked stays disliked only), days/times/duration come from
    /// the model when it gave them, the pace is the model's unless it said balanced, and the
    /// yes/no preferences are true when either says so.
    static func merge(_ model: PlanPreferences?, _ rules: PlanPreferences) -> PlanPreferences {
        guard let model else { return rules }
        let disliked = model.dislikedTags.union(rules.dislikedTags)
        let dislikedCats = model.dislikedCategories.union(rules.dislikedCategories)
        return PlanPreferences(
            likedTags: model.likedTags.union(rules.likedTags).subtracting(disliked),
            dislikedTags: disliked,
            likedCategories: model.likedCategories.union(rules.likedCategories).subtracting(dislikedCats),
            dislikedCategories: dislikedCats,
            similarTo: model.similarTo.union(rules.similarTo),
            days: model.days.isEmpty ? rules.days : model.days,
            earliest: model.earliest ?? rules.earliest,
            latest: model.latest ?? rules.latest,
            durationMinutes: model.durationMinutes ?? rules.durationMinutes,
            pace: model.pace != .balanced ? model.pace : rules.pace,
            includeMeals: model.includeMeals || rules.includeMeals,
            kidFriendly: model.kidFriendly || rules.kidFriendly
        )
    }

    // MARK: Examples

    /// Tags that say little about taste and never appear in the example chips.
    private static let genericTags: Set<String> = Set(["general", "free", "music", "demo"]).union(Planner.familyTags)

    /// Example requests made from this event's data (onboarding and the empty plan card), in
    /// order: "Plan my <weekday> around <tag 1> and <tag 2>" (the two most used schedule tags,
    /// generic ones skipped; "around <tag>" with one, "Plan my <weekday>" with none; the weekday
    /// is the first event day on or after today), "I've got 3 hours, show me the highlights",
    /// "Kid-friendly afternoon" (only when an item has a family tag) and the question "What's on
    /// near me right now?".
    static func examples(_ bundle: EventBundle, now: Date) -> [PlanExample] {
        let calendar = PlanCalendar.calendar(bundle.event.timeZone)
        let today = PlanDate(now, in: calendar)
        let day = PlanCalendar.eventDays(bundle, now: now).first { $0 >= today } ?? today
        var counts: [String: Int] = [:]
        for item in bundle.schedule {
            var seen = Set<String>()
            for tag in item.tags {
                let key = tag.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                guard !key.isEmpty, !genericTags.contains(key), seen.insert(key).inserted else { continue }
                counts[key, default: 0] += 1
            }
        }
        let top = counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(2).map(\.key)
        let first: String
        switch top.count {
        case 0:  first = "Plan my \(day.weekdayName)"
        case 1:  first = "Plan my \(day.weekdayName) around \(top[0])"
        default: first = "Plan my \(day.weekdayName) around \(top[0]) and \(top[1])"
        }
        let hasFamily = bundle.schedule.contains { item in item.tags.contains { Planner.familyTags.contains($0.lowercased()) } }
        var examples = [
            PlanExample(text: first, isPlan: true),
            PlanExample(text: "I've got 3 hours, show me the highlights", isPlan: true),
        ]
        if hasFamily { examples.append(PlanExample(text: "Kid-friendly afternoon", isPlan: true)) }
        examples.append(PlanExample(text: "What's on near me right now?", isPlan: false))
        return examples
    }

    // MARK: Regular expressions

    /// The first match's groups (index 0 = the whole match; nil for a group that didn't take part).
    private static func firstMatch(_ pattern: String, in text: String) -> [String?]? {
        allMatches(pattern, in: text).first
    }

    private static func allMatches(_ pattern: String, in text: String) -> [[String?]] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).map { match in
            (0..<match.numberOfRanges).map { index in
                Range(match.range(at: index), in: text).map { String(text[$0]) }
            }
        }
    }
}
