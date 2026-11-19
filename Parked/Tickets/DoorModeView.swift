// DoorModeView.swift
// Attnd
//
// **App only.** Door mode (API-017): door staff sign in with an email code, pick the event and
// gate, download the ticket list (manifest) and scan, fully offline: VisionKit QR scanning,
// Ed25519 checks and the rules in `DoorRules` (Tickets.swift), a full-screen green / amber /
// red result with haptics and a sound, manual search (name, code, order ref, email), scan out
// for re-entry types, and the upload queue ("Offline · 3 waiting to sync"). `DoorController`
// (TicketsStore.swift) holds the state; its sync loop starts when this screen first opens and
// keeps running while the app is in use (the queue survives restarts on disk either way).

import AudioToolbox
import SwiftUI
import VisionKit

struct DoorModeView: View {
    @Environment(AppState.self) private var appState
    @State private var scanning = false
    @State private var confirmSignOut = false

    private var door: DoorController { appState.door }

    var body: some View {
        Form {
            if door.isSignedIn {
                DoorEventSection(door: door)
                if door.eventId != nil {
                    DoorManifestSection(door: door, startScanning: { scanning = true })
                    DoorSyncSection(door: door)
                }
                Section {
                    LabeledContent("Signed in as", value: door.email ?? "")
                    Button("Sign Out of Door Mode", role: .destructive) { confirmSignOut = true }
                }
            } else {
                TicketSignInForm(
                    intro: "For door staff the organizer added, and the event's team. Use the email the organizer invited.",
                    pendingEmail: door.pendingEmail, isWorking: door.isWorking, errorMessage: door.errorMessage,
                    requestCode: { await door.requestCode(email: $0) },
                    verify: { await door.verify(code: $0) },
                    cancel: { door.cancelSignIn() })
            }
        }
        .navigationTitle("Scan Tickets")
        .task {
            await door.loadStored()
            if door.isSignedIn { door.start() }
        }
        .onChange(of: door.isSignedIn) { _, signedIn in
            if signedIn { door.start() }
        }
        .fullScreenCover(isPresented: $scanning) {
            DoorScannerScreen(door: door)
        }
        .confirmationDialog("Sign out of door mode?", isPresented: $confirmSignOut, titleVisibility: .visible) {
            Button("Sign Out", role: .destructive) { Task { await door.signOut() } }
        } message: {
            Text(door.pendingCount > 0
                 ? "\(door.pendingCount) scans haven't synced yet and will be lost. Connect to the internet first to keep them."
                 : "The ticket lists on this iPhone are deleted.")
        }
    }
}

// MARK: - Sections

private struct DoorEventSection: View {
    let door: DoorController

    var body: some View {
        Section {
            if door.events.isEmpty {
                Text("This email doesn't work the door for any event yet. Ask the organizer to add you to the door team.")
                    .foregroundStyle(.secondary)
                Button("Check Again") { Task { await door.refreshEvents() } }
            } else {
                Picker("Event", selection: Binding(
                    get: { door.eventId ?? 0 },
                    set: { id in Task { await door.select(id) } }
                )) {
                    if door.eventId == nil { Text("Choose…").tag(0) }
                    ForEach(door.events) { event in
                        Text(event.name).tag(event.id)
                    }
                }
            }
        } header: {
            Text("Event")
        }
    }
}

private struct DoorManifestSection: View {
    let door: DoorController
    let startScanning: () -> Void
    @State private var gate = ""

    var body: some View {
        Section {
            if let manifest = door.manifest {
                LabeledContent("Tickets", value: "\(manifest.tickets.count)")
                if let at = door.manifestDownloadedAt {
                    LabeledContent("Downloaded", value: at.formatted(date: .abbreviated, time: .shortened))
                }
            }
            Button {
                Task { await door.downloadManifest() }
            } label: {
                Label(door.isDownloading ? "Downloading…" : (door.manifest == nil ? "Download Tickets" : "Update Ticket List"),
                      systemImage: "arrow.down.circle")
            }
            .disabled(door.isDownloading)
            HStack {
                TextField("Gate (e.g. Gate A)", text: $gate)
                    .onSubmit { door.setGate(gate) }
                if let gates = door.manifest?.gates, !gates.isEmpty {
                    Menu {
                        ForEach(gates, id: \.self) { name in
                            Button(name) { gate = name; door.setGate(name) }
                        }
                    } label: {
                        Label("Gates", systemImage: "list.bullet").labelStyle(.iconOnly)
                    }
                }
            }
            Button(action: {
                door.setGate(gate)
                startScanning()
            }) {
                Label("Start Scanning", systemImage: "qrcode.viewfinder")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .disabled(door.manifest == nil)
        } header: {
            Text("Ticket List")
        } footer: {
            if let error = door.errorMessage {
                Text(error).foregroundStyle(.red)
            } else {
                Text("Download before doors open. Scanning then works with no connection; check-ins sync when you're back online.")
            }
        }
        .onAppear { gate = door.gate }
        .onChange(of: door.eventId) { gate = door.gate }
    }
}

private struct DoorSyncSection: View {
    let door: DoorController

    var body: some View {
        Section {
            Label(DoorText.syncLine(pending: door.pendingCount, online: door.isOnline,
                                    lastSync: door.state?.lastSyncAt, timeZone: door.timeZone),
                  systemImage: door.isOnline ? "arrow.triangle.2.circlepath" : "wifi.slash")
            if let counts = door.state?.counts {
                LabeledContent("Checked in", value: "\(counts.checkedIn) of \(counts.total)")
                LabeledContent("Inside now", value: "\(counts.inside)")
                ForEach(counts.byGate, id: \.gate) { gate in
                    LabeledContent(gate.gate.isEmpty ? "No gate" : gate.gate, value: "\(gate.checkedIn)")
                }
            }
            ForEach(door.state?.localAdmissionsByGate() ?? [], id: \.gate) { row in
                LabeledContent("This iPhone · \(row.gate.isEmpty ? "no gate" : row.gate)", value: "\(row.count)")
            }
            let flagged = door.state?.flagged ?? []
            if !flagged.isEmpty {
                DisclosureGroup("Flagged by the server (\(flagged.count))") {
                    ForEach(flagged) { scan in
                        VStack(alignment: .leading) {
                            Text(DoorText.flagged(scan, timeZone: door.timeZone))
                            Text(scan.at.formatted(date: .omitted, time: .shortened))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        } header: {
            Text("Sync & Counts")
        }
    }
}

// MARK: - Scanner

struct DoorScannerScreen: View {
    let door: DoorController
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var showSearch = false

    private var hasReentry: Bool { door.manifest?.ticketTypes.contains(where: \.reentry) ?? false }

    var body: some View {
        NavigationStack {
            ZStack {
                if DataScannerViewController.isSupported && DataScannerViewController.isAvailable {
                    DoorCameraView(isActive: scenePhase == .active && !showSearch) { raw in
                        _ = door.scan(raw)
                    }
                    .ignoresSafeArea()
                } else {
                    ContentUnavailableView("Camera Unavailable", systemImage: "camera",
                                           description: Text("Use Search to check tickets in by name, code or email."))
                }
                if let verdict = door.lastVerdict {
                    DoorVerdictOverlay(verdict: verdict, timeZone: door.timeZone) { door.dismissVerdict() }
                }
            }
            .safeAreaInset(edge: .bottom) { scannerBar }
            .navigationTitle(door.gate.isEmpty ? (door.event?.name ?? "Scan") : door.gate)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "xmark", role: .close) { dismiss() }
                }
                ToolbarItem(placement: .pinnedTrailing) {
                    Button { showSearch = true } label: {
                        Label("Search", systemImage: "magnifyingglass")
                    }
                }
            }
            .sheet(isPresented: $showSearch) {
                DoorSearchSheet(door: door)
            }
        }
        .sensoryFeedback(trigger: door.lastVerdictAt) { _, _ in
            switch door.lastVerdict?.tone {
            case .green: return .success
            case .amber: return .warning
            case .red:   return .error
            case nil:    return nil
            }
        }
        .onChange(of: door.lastVerdictAt) { DoorSound.play(door.lastVerdict?.tone) }
    }

    private var scannerBar: some View {
        VStack(spacing: 10) {
            if hasReentry {
                Picker("Direction", selection: Binding(get: { door.scanKind }, set: { door.scanKind = $0 })) {
                    Text("Check In").tag(DoorScanKind.in)
                    Text("Check Out").tag(DoorScanKind.out)
                }
                .pickerStyle(.segmented)
            }
            Label(DoorText.syncLine(pending: door.pendingCount, online: door.isOnline,
                                    lastSync: door.state?.lastSyncAt, timeZone: door.timeZone),
                  systemImage: door.isOnline ? "checkmark.icloud" : "wifi.slash")
                .font(.footnote)
        }
        .padding(12)
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
        .padding(.horizontal)
        .padding(.bottom, 8)
    }
}

/// The full-screen result: tap to dismiss; it also goes by itself (green sooner).
private struct DoorVerdictOverlay: View {
    let verdict: DoorVerdict
    let timeZone: TimeZone
    let dismiss: () -> Void

    private var color: Color {
        switch verdict.tone {
        case .green: return .green
        case .amber: return .orange
        case .red:   return .red
        }
    }

    private var icon: String {
        switch verdict.tone {
        case .green: return "checkmark.circle.fill"
        case .amber: return "exclamationmark.triangle.fill"
        case .red:   return "xmark.octagon.fill"
        }
    }

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: icon).font(.system(size: 96))
            Text(DoorText.title(verdict, timeZone: timeZone, now: .now))
                .font(.largeTitle.bold())
                .multilineTextAlignment(.center)
            Text(DoorText.detail(verdict))
                .font(.title3)
                .multilineTextAlignment(.center)
        }
        .foregroundStyle(.white)
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(color.opacity(0.94))
        .contentShape(Rectangle())
        .onTapGesture(perform: dismiss)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .task(id: verdict) {
            try? await Task.sleep(for: .seconds(verdict.tone == .green ? 2 : 4))
            if !Task.isCancelled { dismiss() }
        }
    }
}

private enum DoorSound {
    /// System sounds (positive / beep / negative acknowledgement).
    static func play(_ tone: DoorVerdict.Tone?) {
        switch tone {
        case .green: AudioServicesPlaySystemSound(1054)
        case .amber: AudioServicesPlaySystemSound(1052)
        case .red:   AudioServicesPlaySystemSound(1053)
        case nil:    break
        }
    }
}

// MARK: - Manual search

private struct DoorSearchSheet: View {
    let door: DoorController
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    var body: some View {
        NavigationStack {
            List(door.search(query)) { ticket in
                Button {
                    door.checkIn(ticketId: ticket.id)
                    dismiss()
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(ticket.name.isEmpty ? ticket.code : ticket.name).font(.headline)
                        Text([door.typeName(ticket), ticket.code, ticket.orderRef].filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.subheadline).foregroundStyle(.secondary)
                        if ticket.status != "valid" {
                            Text(ticket.status.capitalized).font(.caption).foregroundStyle(.red)
                        } else if let at = ticket.checkedInAt {
                            Text(DoorText.alreadyIn(at, gate: ticket.checkedInGate, timeZone: door.timeZone, now: .now))
                                .font(.caption).foregroundStyle(.orange)
                        }
                    }
                }
                .tint(.primary)
            }
            .overlay {
                if !query.isEmpty && door.search(query).isEmpty {
                    ContentUnavailableView.search(text: query)
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                        prompt: "Name, code, order or email")
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .navigationTitle("Find a Ticket")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "xmark", role: .close) { dismiss() }
                }
            }
        }
    }
}

// MARK: - Continuous camera

/// `DataScannerViewController` that keeps scanning (unlike the join scanner, which stops at the
/// first code). Each QR that comes into view is passed on (a code held in view counts once);
/// `DoorController.scan` also drops the same code within 3 s.
private struct DoorCameraView: UIViewControllerRepresentable {
    var isActive: Bool
    var onCode: (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .fast,
            recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: false,
            isHighlightingEnabled: true
        )
        scanner.delegate = context.coordinator
        return scanner
    }

    func updateUIViewController(_ scanner: DataScannerViewController, context: Context) {
        context.coordinator.onCode = onCode
        if isActive {
            if !scanner.isScanning { try? scanner.startScanning() }
        } else if scanner.isScanning {
            scanner.stopScanning()
        }
    }

    static func dismantleUIViewController(_ scanner: DataScannerViewController, coordinator: Coordinator) {
        scanner.stopScanning()
    }

    func makeCoordinator() -> Coordinator { Coordinator(onCode: onCode) }

    @MainActor
    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        var onCode: (String) -> Void

        init(onCode: @escaping (String) -> Void) { self.onCode = onCode }

        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            for item in addedItems {
                if case .barcode(let barcode) = item, let raw = barcode.payloadStringValue {
                    onCode(raw)
                    return
                }
            }
        }
    }
}
