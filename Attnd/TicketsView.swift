// TicketsView.swift
// Attnd
//
// **App only.** My tickets (API-017): email-code sign-in, the tickets held by that email
// (from the stored copy first, so it works offline), a ticket's big QR code (screen at full
// brightness while shown), Add to Apple Wallet (the downloaded `.pkpass` in
// `PKAddPassesViewController`; no entitlement needed) and Manage (the ticket page in Safari:
// transfer, refund, resend). Nothing is sold in the app.

import PassKit
import SwiftUI
import UIKit

// MARK: - Email code sign-in (My tickets and door mode)

struct TicketSignInForm: View {
    let intro: String
    let pendingEmail: String?
    let isWorking: Bool
    let errorMessage: String?
    let requestCode: (String) async -> Void
    let verify: (String) async -> Void
    let cancel: () -> Void

    @State private var email = ""
    @State private var code = ""
    @FocusState private var codeFocused: Bool

    var body: some View {
        Section {
            if let pendingEmail {
                Text("We sent a 6-digit code to \(pendingEmail). It's valid for 10 minutes.")
                    .font(.subheadline)
                TextField("Code", text: $code)
                    .textContentType(.oneTimeCode)
                    .keyboardType(.numberPad)
                    .focused($codeFocused)
                    .onAppear { codeFocused = true }
                Button("Sign In") { Task { await verify(code) } }
                    .disabled(code.filter(\.isNumber).count < 6 || isWorking)
                Button("Use Another Email", role: .cancel) {
                    code = ""
                    cancel()
                }
            } else {
                TextField("Email", text: $email)
                    .textContentType(.emailAddress)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onSubmit { Task { await requestCode(email) } }
                Button("Send Code") { Task { await requestCode(email) } }
                    .disabled(!email.contains("@") || isWorking)
            }
            if isWorking { ProgressView() }
        } header: {
            Text("Sign In")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
                Text(intro)
            }
        }
    }
}

// MARK: - My tickets

struct MyTicketsView: View {
    @Environment(AppState.self) private var appState
    @State private var confirmSignOut = false

    private var store: TicketsStore { appState.tickets }

    var body: some View {
        List {
            if store.isSignedIn {
                signedInContent
            } else {
                TicketSignInForm(
                    intro: "Sign in with the email you bought tickets with. Your tickets stay on this iPhone, so they show even without a connection.",
                    pendingEmail: store.pendingEmail, isWorking: store.isWorking, errorMessage: store.errorMessage,
                    requestCode: { await store.requestCode(email: $0) },
                    verify: { await store.verify(code: $0) },
                    cancel: { store.cancelSignIn() })
            }
        }
        .navigationTitle("My Tickets")
        .refreshable { await store.refresh() }
        .task { await store.refresh() }
        .toolbar {
            if store.isSignedIn {
                ToolbarItem(placement: .pinnedTrailing) {
                    Button { confirmSignOut = true } label: {
                        Label("Sign Out", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                }
            }
        }
        .confirmationDialog("Sign out of My Tickets?", isPresented: $confirmSignOut, titleVisibility: .visible) {
            Button("Sign Out", role: .destructive) { Task { await store.signOut() } }
        } message: {
            Text("The tickets saved on this iPhone are removed. Your tickets themselves aren't affected.")
        }
    }

    @ViewBuilder
    private var signedInContent: some View {
        let sections = MyTicketsGrouping.sections(store.payload?.tickets ?? [], now: .now)
        if sections.isEmpty {
            Section {
                if store.payload == nil && store.isRefreshing {
                    ProgressView()
                } else {
                    ContentUnavailableView("No Tickets", systemImage: "ticket",
                                           description: Text("Tickets bought with \(store.email ?? "this email") show here."))
                }
            }
        }
        ForEach(sections) { section in
            Section {
                ForEach(section.tickets) { ticket in
                    NavigationLink {
                        TicketDetailView(ticket: ticket)
                    } label: {
                        MyTicketRow(ticket: ticket)
                    }
                }
            } header: {
                Text(section.event.name)
            } footer: {
                if let date = MyTicketsText.eventDate(section.event) { Text(date) }
            }
        }
        Section {
            LabeledContent("Signed in as", value: store.email ?? "")
        } footer: {
            MyTicketsFreshness(fetchedAt: store.fetchedAt, isOffline: store.isOffline, error: store.errorMessage)
        }
    }
}

private struct MyTicketsFreshness: View {
    let fetchedAt: Date?
    let isOffline: Bool
    let error: String?

    var body: some View {
        if let error {
            Text(error)
        } else if let fetchedAt {
            Text("\(isOffline ? "Offline · " : "")Updated \(fetchedAt.formatted(date: .omitted, time: .shortened))")
        }
    }
}

private struct MyTicketRow: View {
    let ticket: MyTicket

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(ticket.typeName.isEmpty ? "Ticket" : ticket.typeName).font(.headline)
            Text([ticket.holderName, ticket.code].filter { !$0.isEmpty }.joined(separator: " · "))
                .font(.subheadline).foregroundStyle(.secondary)
            Text(MyTicketsText.status(ticket))
                .font(.caption)
                .foregroundStyle(ticket.isValid && !ticket.event.cancelled ? Color.green : Color.red)
        }
    }
}

// MARK: - One ticket

struct TicketDetailView: View {
    let ticket: MyTicket
    @Environment(AppState.self) private var appState
    @State private var qr: UIImage?
    @State private var addingPass = false
    @State private var walletError: String?

    var body: some View {
        List {
            Section {
                TicketQRCode(image: qr, isValid: ticket.qr != nil)
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.white)
            } footer: {
                Text(ticket.qr == nil ? MyTicketsText.status(ticket) : "Show this code at the door. It works without a connection.")
            }
            Section {
                LabeledContent("Event", value: ticket.event.name)
                if let date = MyTicketsText.eventDate(ticket.event) { LabeledContent("When", value: date) }
                if !ticket.event.address.isEmpty { LabeledContent("Where", value: ticket.event.address) }
                LabeledContent("Ticket", value: ticket.typeName)
                LabeledContent("Holder", value: ticket.holderName)
                LabeledContent("Code") { Text(ticket.code).font(.body.monospaced()) }
                LabeledContent("Order", value: ticket.orderRef)
                LabeledContent("Status", value: MyTicketsText.status(ticket))
            }
            actions
        }
        .navigationTitle(ticket.typeName.isEmpty ? "Ticket" : ticket.typeName)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: ticket.qr) {
            qr = ticket.qr.flatMap { QRCode.image(for: $0, scale: 14) }
            AppLog.debug(.tickets, "tickets.qr.shown", "Ticket QR shown", [
                "event_id": .int(ticket.event.id), "offline": .bool(appState.tickets.isOffline),
            ])
        }
        .onAppear { if ticket.qr != nil { ScreenBrightness.boost() } }
        .onDisappear { ScreenBrightness.restore() }
    }

    @ViewBuilder
    private var actions: some View {
        Section {
            if let wallet = ticket.appleWalletURL, PKAddPassesViewController.canAddPasses() {
                Button {
                    Task { await addToWallet(wallet) }
                } label: {
                    Label(addingPass ? "Adding…" : "Add to Apple Wallet", systemImage: "wallet.pass")
                }
                .disabled(addingPass)
            }
            if let manage = ticket.ticketURL {
                Link(destination: manage) {
                    Label(ticket.transferable ? "Manage, Transfer or Resend" : "Manage Ticket", systemImage: "safari")
                }
            }
        } footer: {
            if let walletError { Text(walletError).foregroundStyle(.red) }
        }
    }

    private func addToWallet(_ url: URL) async {
        addingPass = true
        walletError = nil
        defer { addingPass = false }
        do {
            let pass = try await WalletPass.download(url)
            guard let controller = PKAddPassesViewController(pass: pass) else { throw WalletPass.Failure.cannotAdd }
            WalletPass.present(controller)
            AppLog.info(.tickets, "tickets.wallet.add", "Wallet pass presented", ["platform": "apple", "ok": true])
        } catch {
            walletError = "Couldn't get the Wallet pass. Try again with a connection."
            AppLog.notice(.tickets, "tickets.wallet.add", "Wallet pass failed", [
                "platform": "apple", "ok": false, "error": .string((error as? WalletPass.Failure)?.rawValue ?? "download"),
            ])
        }
    }
}

private struct TicketQRCode: View {
    let image: UIImage?
    let isValid: Bool

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .accessibilityLabel("Ticket QR code")
            } else {
                Image(systemName: isValid ? "qrcode" : "xmark.octagon")
                    .font(.system(size: 80))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: 320, maxHeight: 320)
        .padding(.vertical, 12)
    }
}

// MARK: - Wallet

enum WalletPass {
    enum Failure: String, Error { case download, notAPass = "not_a_pass", cannotAdd = "cannot_add" }

    /// Downloads the `.pkpass` (a plain web URL with the ticket's key; no app credentials).
    @MainActor
    static func download(_ url: URL) async throws -> PKPass {
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw Failure.download }
        do {
            return try PKPass(data: data)
        } catch {
            throw Failure.notAPass
        }
    }

    @MainActor
    static func present(_ controller: UIViewController) {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        guard var top = scene?.keyWindow?.rootViewController else { return }
        while let presented = top.presentedViewController { top = presented }
        top.present(controller, animated: true)
    }
}

// MARK: - Brightness

/// Full brightness while a ticket's QR is shown (door scanners read it better), restored after.
@MainActor
enum ScreenBrightness {
    private static var saved: CGFloat?

    private static var screen: UIScreen? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }?.screen
    }

    static func boost() {
        guard let screen else { return }
        if saved == nil { saved = screen.brightness }
        screen.brightness = 1
    }

    static func restore() {
        guard let saved, let screen else { return }
        screen.brightness = saved
        self.saved = nil
    }
}
