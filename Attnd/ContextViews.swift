// ContextViews.swift
// Attnd (app + App Clip)
//
// API-018 rich context on the detail screens: the organizer's (AI-imported, reviewed) notes the
// on-device assistant also reads, shown where they help an attendee:
//   - `ScheduleItemContextSections` (schedule item detail, List sections): About, performers with
//     genres and bios, price / age / accessibility, links.
//   - `LocationContextView` (location detail, a stack inside its ScrollView): About, hours,
//     menu, accessibility / age, links.
//   - `EventContextSections` (`EventInfoView`, Options' event section): FAQ, amenities (with the
//     place they're at), getting there, accessibility, policies, weather plan, links.
// All from the bundle on disk, so offline too. Links open in the browser (`Link`), https only.

import SwiftUI

/// One labelled line ("Price" · "$5").
private struct ContextFact: Hashable {
    var label: String
    var value: String
}

struct ScheduleItemContextSections: View {
    let context: ScheduleItemContext

    var body: some View {
        if !context.about.isEmpty {
            Section("About") {
                Text(context.about)
            }
        }
        if !context.performers.isEmpty {
            Section(context.performers.count == 1 ? "Performer" : "Performers") {
                ForEach(context.performers, id: \.self) { performer in
                    PerformerRow(performer: performer)
                }
            }
        }
        let facts = factRows
        if !facts.isEmpty {
            Section("Good to Know") {
                ForEach(facts, id: \.self) { fact in
                    LabeledContent(fact.label, value: fact.value)
                }
            }
        }
        if !context.links.isEmpty {
            ContextLinksSection(links: context.links)
        }
    }

    private var factRows: [ContextFact] {
        var rows: [ContextFact] = []
        if !context.price.isEmpty { rows.append(ContextFact(label: "Price", value: context.price)) }
        if !context.ageLimit.isEmpty { rows.append(ContextFact(label: "Ages", value: context.ageLimit)) }
        if !context.accessibility.isEmpty { rows.append(ContextFact(label: "Accessibility", value: context.accessibility)) }
        return rows
    }
}

private struct PerformerRow: View {
    let performer: Performer

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(performer.name)
                .font(.headline)
            if !performer.genres.isEmpty {
                Text(TagText.line(performer.genres))
                    .font(.subheadline)
                    .foregroundStyle(.tint)
            }
            if !performer.bio.isEmpty {
                Text(performer.bio)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

private struct ContextLinksSection: View {
    let links: [ContextLink]

    var body: some View {
        Section("Links") {
            ForEach(links, id: \.url) { link in
                Link(destination: link.url) {
                    Label(link.title, systemImage: "safari")
                }
            }
        }
    }
}

/// The location detail's context (inside its ScrollView, between dividers).
struct LocationContextView: View {
    let context: LocationContext

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !context.about.isEmpty {
                Text(context.about)
            }
            if !context.hours.isEmpty {
                Label(context.hours, systemImage: "clock")
                    .font(.subheadline)
            }
            if !context.ageLimit.isEmpty {
                Label(context.ageLimit, systemImage: "person.crop.circle.badge.checkmark")
                    .font(.subheadline)
            }
            if !context.accessibility.isEmpty {
                Label(context.accessibility, systemImage: "figure.roll")
                    .font(.subheadline)
            }
            if !context.menu.isEmpty {
                MenuList(menu: context.menu)
            }
            ForEach(context.links, id: \.url) { link in
                Link(destination: link.url) {
                    Label(link.title, systemImage: "safari")
                }
                .font(.subheadline)
            }
        }
    }
}

private struct MenuList: View {
    let menu: [MenuEntry]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Menu")
                .font(.title3.bold())
            ForEach(menu, id: \.self) { entry in
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(entry.name)
                        if !entry.note.isEmpty {
                            Text(entry.note)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 8)
                    if !entry.price.isEmpty {
                        Text(entry.price)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
    }
}

/// The event's own context (List sections).
struct EventContextSections: View {
    let context: EventContext

    @Environment(AppState.self) private var appState

    var body: some View {
        if !context.about.isEmpty {
            Section("Details") { Text(context.about) }
        }
        if !context.faq.isEmpty {
            Section("FAQ") {
                ForEach(context.faq, id: \.self) { entry in
                    DisclosureGroup(entry.question) {
                        Text(entry.answer)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        if !context.amenities.isEmpty {
            Section("Amenities") {
                ForEach(context.amenities, id: \.self) { amenity in
                    AmenityRow(amenity: amenity, location: appState.location(id: amenity.locationId))
                }
            }
        }
        ForEach(textRows, id: \.self) { row in
            Section(row.label) { Text(row.value) }
        }
        if !context.links.isEmpty {
            ContextLinksSection(links: context.links)
        }
    }

    private var textRows: [ContextFact] {
        [
            ContextFact(label: "Getting There", value: context.gettingThere),
            ContextFact(label: "Accessibility", value: context.accessibility),
            ContextFact(label: "Policies", value: context.policies),
            ContextFact(label: "Weather Plan", value: context.weatherPlan),
        ].filter { !$0.value.isEmpty }
    }
}

private struct AmenityRow: View {
    let amenity: Amenity
    let location: Location?

    @Environment(AppState.self) private var appState

    var body: some View {
        Button {
            if let location { appState.open(.location(location.id)) }
        } label: {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(amenity.name)
                    let detail = [location?.name, amenity.note.isEmpty ? nil : amenity.note].compactMap { $0 }
                    if !detail.isEmpty {
                        Text(detail.joined(separator: " · "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } icon: {
                Image(systemName: amenity.kind.systemImage)
            }
        }
        .buttonStyle(.plain)
        .disabled(location == nil)
    }
}
