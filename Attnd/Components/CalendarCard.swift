// CalendarCard.swift
// Attnd (app target only — not the App Clip)
//
// "Add to Calendar" (assistant spec §7, the `calendar` block and `add_to_calendar`), with EventKit:
//   - One item: the system's event editor (`EKEventEditViewController`). Since iOS 17 it runs
//     out of process and needs no calendar permission at all; the person picks the calendar
//     and taps Add.
//   - Several (a plan): write-only access (`requestWriteOnlyAccessToEvents`, Info.plist
//     `NSCalendarsWriteOnlyAccessUsageDescription`), then each item is saved to the default
//     calendar in one commit. The app can't read any calendar (not even what it added), so
//     adding twice adds twice; the card says "Added" afterwards.
// Events carry the EVENT's time zone, the location's name (+ address and coordinates) and the
// item's description.

import CoreLocation
import EventKit
import EventKitUI
import SwiftUI

// MARK: - Drafts

/// One calendar event to add, from a schedule item.
struct CalendarEventDraft: Identifiable, Hashable, Sendable {
    var id: Int
    var title: String
    var start: Date
    var end: Date
    var timeZone: TimeZone
    /// "Main Stage" (+ ", address").
    var locationText: String?
    var coordinate: Coordinate?
    var notes: String?
    var url: URL?

    /// Items without a start time can't go into a calendar (nil). No end = start + 1 h.
    @MainActor
    static func make(_ item: ScheduleItem, appState: AppState) -> CalendarEventDraft? {
        guard let start = item.startTime, let end = ScheduleTiming.effectiveEnd(of: item) else { return nil }
        let location = appState.location(id: item.locationId)
        let placeName = location?.name ?? item.locationName
        var locationText = placeName
        if let address = location?.address, !address.isEmpty {
            locationText = [placeName, address].compactMap { $0 }.joined(separator: ", ")
        }
        var notes = item.description.isEmpty ? nil : item.description
        if let eventName = appState.currentEvent?.name {
            notes = [eventName, notes].compactMap { $0 }.joined(separator: "\n\n")
        }
        return CalendarEventDraft(
            id: item.id,
            title: item.name,
            start: start,
            end: end,
            timeZone: appState.timeZone,
            locationText: locationText,
            coordinate: location?.coordinate,
            notes: notes,
            url: appState.currentEvent?.joinUrl
        )
    }

    /// Fills an EKEvent (any store).
    func apply(to event: EKEvent) {
        event.title = title
        event.startDate = start
        event.endDate = end
        event.timeZone = timeZone
        event.location = locationText
        if let locationText, let coordinate {
            let structured = EKStructuredLocation(title: locationText)
            structured.geoLocation = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
            event.structuredLocation = structured
        }
        event.notes = notes
        event.url = url
    }
}

// MARK: - Writing

@MainActor
enum CalendarWriter {
    enum Outcome: Hashable, Sendable {
        case added(Int)
        case denied
        case failed
    }

    /// Adds every draft to the default calendar (write-only access, asked for once).
    static func add(_ drafts: [CalendarEventDraft]) async -> Outcome {
        guard !drafts.isEmpty else { return .added(0) }
        switch EKEventStore.authorizationStatus(for: .event) {
        case .writeOnly, .fullAccess:
            break
        case .notDetermined:
            guard await requestWriteOnlyAccess() else { return .denied }
        default:
            return .denied
        }
        // A store made after access was granted sees it.
        let store = EKEventStore()
        guard let calendar = store.defaultCalendarForNewEvents else { return .failed }
        do {
            for draft in drafts {
                let event = EKEvent(eventStore: store)
                draft.apply(to: event)
                event.calendar = calendar
                try store.save(event, span: .thisEvent, commit: false)
            }
            try store.commit()
        } catch {
            AppLog.caught(error, .ui, "calendar.add")
            store.reset()
            return .failed
        }
        AppLog.debug(.ui, "ui.action", "Added to the calendar", ["name": "calendar", "count": .int(drafts.count)])
        return .added(drafts.count)
    }

    /// The permission prompt, off the main actor with its own store (EKEventStore isn't Sendable).
    nonisolated private static func requestWriteOnlyAccess() async -> Bool {
        let store = EKEventStore()
        do {
            return try await store.requestWriteOnlyAccessToEvents()
        } catch {
            return false
        }
    }
}

// MARK: - Card

/// The `calendar` block: "Add to Calendar" for one item (the system editor) or several (a plan,
/// written directly with write-only access).
struct CalendarCard: View {
    let items: [ScheduleItem]
    var title: String? = nil

    @Environment(AppState.self) private var appState
    @State private var editing: CalendarEventDraft?
    @State private var working = false
    @State private var outcome: CalendarWriter.Outcome?

    var body: some View {
        let drafts = items.compactMap { CalendarEventDraft.make($0, appState: appState) }
        VStack(alignment: .leading, spacing: 8) {
            Label(title ?? (drafts.count == 1 ? drafts[0].title : "\(drafts.count) items"), systemImage: "calendar.badge.plus")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            switch outcome {
            case .added(let count)?:
                Label(count == 1 ? "Added to your calendar." : "Added \(count) items to your calendar.", systemImage: "checkmark.circle.fill")
                    .font(.subheadline)
                    .foregroundStyle(.green)
            case .denied?:
                Text("Attnd can't add to your calendar. Allow it in Settings → Attnd → Calendars.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            case .failed?:
                Text("Couldn't add to your calendar. Try again.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            case nil:
                Text("Times in the event's time zone, with the place.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            if !drafts.isEmpty, outcome != .added(drafts.count) {
                Button {
                    add(drafts)
                } label: {
                    Label("Add to Calendar", systemImage: "calendar.badge.plus")
                }
                .buttonStyle(.bordered)
                .disabled(working)
            }
        }
        .blockCardBackground()
        .sheet(item: $editing) { draft in
            EventEditSheet(draft: draft) { added in
                editing = nil
                if added { outcome = .added(1) }
            }
            .ignoresSafeArea()
        }
    }

    private func add(_ drafts: [CalendarEventDraft]) {
        if drafts.count == 1 {
            editing = drafts[0]
            return
        }
        working = true
        Task {
            outcome = await CalendarWriter.add(drafts)
            working = false
        }
    }
}

/// "Add to Calendar" as a plain button (schedule item detail): the system editor, no permission.
struct AddToCalendarButton: View {
    let item: ScheduleItem

    @Environment(AppState.self) private var appState
    @State private var editing: CalendarEventDraft?

    var body: some View {
        if let draft = CalendarEventDraft.make(item, appState: appState) {
            Button {
                editing = draft
            } label: {
                Label("Add to Calendar", systemImage: "calendar.badge.plus")
            }
            .sheet(item: $editing) { draft in
                EventEditSheet(draft: draft) { _ in editing = nil }
                    .ignoresSafeArea()
            }
        }
    }
}

// MARK: - System editor

/// EKEventEditViewController with the draft filled in. Calls `onDone(true)` when the person
/// added it, `onDone(false)` when they cancelled.
struct EventEditSheet: UIViewControllerRepresentable {
    let draft: CalendarEventDraft
    let onDone: (Bool) -> Void

    func makeUIViewController(context: Context) -> EKEventEditViewController {
        let store = context.coordinator.store
        let event = EKEvent(eventStore: store)
        draft.apply(to: event)
        let controller = EKEventEditViewController()
        controller.eventStore = store
        controller.event = event
        controller.editViewDelegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: EKEventEditViewController, context: Context) {
        context.coordinator.onDone = onDone
    }

    func makeCoordinator() -> EventEditDelegate { EventEditDelegate(onDone: onDone) }
}

/// The editor's delegate: only reports the outcome (SwiftUI dismisses the sheet).
final class EventEditDelegate: NSObject, EKEventEditViewDelegate {
    let store = EKEventStore()
    var onDone: (Bool) -> Void

    init(onDone: @escaping (Bool) -> Void) {
        self.onDone = onDone
    }

    func eventEditViewController(_ controller: EKEventEditViewController, didCompleteWith action: EKEventEditViewAction) {
        onDone(action == .saved)
    }
}
