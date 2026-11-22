// ContextViews.swift
// Attnd (app + App Clip)
//
// API-018 rich context on the detail screens: the organizer's (AI-imported, reviewed) notes the
// on-device assistant also reads, shown where they help an attendee. Since API-024 each piece is
// one layout section (`ScreenLayout`), drawn where the screen's layout puts it:
//   - schedule item detail (List sections): `PerformersSection`, `ItemFactsSection` (price / age /
//     accessibility), `ContextLinksSection`.
//   - location detail (a stack inside its ScrollView): `PlaceHoursLine`, `PlaceFactsLines`
//     (age / accessibility), `MenuList`, `PlaceLinks`.
//   - `EventInfoView` (List sections): `EventFAQSection`, `EventAmenitiesSection`,
//     `ContextTextSection` (getting there, accessibility, policies, weather plan),
//     `ContextLinksSection`.
// All from the bundle on disk, so offline too. Links open in the browser (`Link`), https only.

import SwiftUI

/// One labelled line ("Price" · "$5").
private struct ContextFact: Hashable {
    var label: String
    var value: String
}

// MARK: - Schedule item

struct PerformersSection: View {
    let performers: [Performer]
    var title: String? = nil

    var body: some View {
        if !performers.isEmpty {
            Section(title ?? (performers.count == 1 ? "Performer" : "Performers")) {
                ForEach(performers, id: \.self) { performer in
                    PerformerRow(performer: performer)
                }
            }
        }
    }
}

/// Price, ages and accessibility of a schedule item ("Good to Know").
struct ItemFactsSection: View {
    let context: ScheduleItemContext
    var title: String? = nil

    var body: some View {
        let facts = factRows
        if !facts.isEmpty {
            Section(title ?? "Good to Know") {
                ForEach(facts, id: \.self) { fact in
                    LabeledContent(fact.label, value: fact.value)
                }
            }
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
            if let url = performer.appleMusicURL {
                ListenOnAppleMusicButton(url: url, artist: performer.name)
                    .padding(.top, 2)
            }
        }
        .padding(.vertical, 2)
        // Not `.combine`: the Apple Music button stays its own control for VoiceOver.
        .accessibilityElement(children: .contain)
    }
}

/// API-030 "Listen on Apple Music" (Apple's wording): opens the artist page (a universal link,
/// so the Music app when installed, else Safari). No MusicKit, no account; nothing without a link.
struct ListenOnAppleMusicButton: View {
    let url: URL
    var artist: String = ""

    var body: some View {
        Link(destination: url) {
            Label("Listen on Apple Music", systemImage: "music.note")
                .font(.subheadline.weight(.semibold))
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .accessibilityLabel(artist.isEmpty ? "Listen on Apple Music" : "Listen to \(artist) on Apple Music")
    }
}

struct ContextLinksSection: View {
    let links: [ContextLink]
    var title: String? = nil

    var body: some View {
        if !links.isEmpty {
            Section(title ?? "Links") {
                ForEach(links, id: \.url) { link in
                    Link(destination: link.url) {
                        Label(link.title, systemImage: "safari")
                    }
                }
            }
        }
    }
}

// MARK: - Location (inside its ScrollView)

struct PlaceHoursLine: View {
    let hours: String

    var body: some View {
        Label(hours, systemImage: "clock")
            .font(.subheadline)
    }
}

/// Age limit and accessibility of a place.
struct PlaceFactsLines: View {
    let context: LocationContext

    var body: some View {
        if !context.ageLimit.isEmpty {
            Label(context.ageLimit, systemImage: "person.crop.circle.badge.checkmark")
                .font(.subheadline)
        }
        if !context.accessibility.isEmpty {
            Label(context.accessibility, systemImage: "figure.roll")
                .font(.subheadline)
        }
    }
}

/// The place's context links, then its own website ("Visit Website").
struct PlaceLinks: View {
    let links: [ContextLink]
    let website: URL?

    var body: some View {
        ForEach(links, id: \.url) { link in
            Link(destination: link.url) {
                Label(link.title, systemImage: "safari")
            }
            .font(.subheadline)
        }
        if let website {
            Link("Visit Website", destination: website)
                .font(.subheadline)
        }
    }
}

struct MenuList: View {
    let menu: [MenuEntry]
    var title: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title ?? "Menu")
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

// MARK: - Event (List sections)

struct EventFAQSection: View {
    let faq: [FAQEntry]
    var title: String? = nil
    var limit: Int? = nil

    var body: some View {
        if !faq.isEmpty {
            Section(title ?? "FAQ") {
                ForEach(Array(faq.prefix(limit ?? faq.count)), id: \.self) { entry in
                    DisclosureGroup(entry.question) {
                        Text(entry.answer)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

struct EventAmenitiesSection: View {
    let amenities: [Amenity]
    var title: String? = nil

    @Environment(AppState.self) private var appState

    var body: some View {
        if !amenities.isEmpty {
            Section(title ?? "Amenities") {
                ForEach(amenities, id: \.self) { amenity in
                    AmenityRow(amenity: amenity, location: appState.location(id: amenity.locationId))
                }
            }
        }
    }
}

/// One of the event's text parts (Details, Getting There, Accessibility, Policies, Weather Plan).
struct ContextTextSection: View {
    let title: String
    let text: String

    var body: some View {
        if !text.isEmpty {
            Section(title) { Text(text) }
        }
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
