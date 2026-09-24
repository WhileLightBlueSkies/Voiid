//
//  EventTicketsView.swift
//  Voiid
//
//  The attendee's half of events, which had no client at all: `GET /my/event-tickets` and
//  `/event-tickets/:id/code` shipped complete and were never called, so someone could claim a
//  ticket and then have no way to see it — let alone get through a door with it.
//
//  THE CODE IS SHORT-LIVED AND MINTED PER REQUEST. It is never cached to disk and never held
//  past its expiry: a stored code is a permanent bearer token for a door, which is exactly
//  what the server's design avoids by refusing to store one either.
//

import SwiftUI
import PassKit
import Combine
import CoreImage.CIFilterBuiltins

struct EventTicketsView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var tickets: [EventService.Ticket] = []
    @State private var loading = true
    @State private var error: String?
    @State private var showing: EventService.Ticket?

    var body: some View {
        NavigationStack {
            ZStack {
                VoiidColor.background.ignoresSafeArea()

                if loading && tickets.isEmpty {
                    ProgressView().tint(VoiidColor.accent)
                } else if tickets.isEmpty {
                    emptyState
                } else {
                    ScrollView {
                        LazyVStack(spacing: 10) {
                            ForEach(tickets) { ticket in
                                Button {
                                    Haptics.tap()
                                    showing = ticket
                                } label: {
                                    ticketRow(ticket)
                                }
                                .buttonStyle(PressableButtonStyle())
                                .disabled(!ticket.canShowCode)
                            }
                            Color.clear.frame(height: 24)
                        }
                        .padding(.horizontal, VoiidSpacing.md)
                        .padding(.top, VoiidSpacing.sm)
                    }
                }
            }
            .navigationTitle("My tickets")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .foregroundColor(VoiidColor.textSecondary)
                }
            }
            .task { await load() }
            .refreshable { await load() }
            .sheet(item: $showing) { ticket in
                TicketCodeSheet(ticket: ticket)
            }
        }
    }

    @ViewBuilder private var emptyState: some View {
        VStack(spacing: VoiidSpacing.sm) {
            Image(systemName: error == nil ? "ticket" : "exclamationmark.triangle")
                .font(.system(size: 30))
                .foregroundColor(VoiidColor.textSecondary)
            // Error beats empty: "no tickets" for a failed request is a lie the holder cannot
            // act on, and it hides the retry that would fix it.
            Text(error ?? "No tickets yet.")
                .font(VoiidFont.subhead)
                .foregroundColor(VoiidColor.textSecondary)
                .multilineTextAlignment(.center)
            if error != nil {
                Button("Try again") { Task { await load() } }
                    .font(VoiidFont.rounded(15, .semibold))
                    .foregroundColor(VoiidColor.primary)
            }
        }
        .padding(VoiidSpacing.xl)
    }

    private func ticketRow(_ t: EventService.Ticket) -> some View {
        HStack(spacing: VoiidSpacing.md) {
            Image(systemName: "ticket.fill")
                .font(.system(size: 16))
                .foregroundColor(VoiidColor.textOnAccent)
                .frame(width: 38, height: 38)
                .background(RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(t.canShowCode ? VoiidColor.accent : VoiidColor.textSecondary))

            VStack(alignment: .leading, spacing: 2) {
                Text(t.title ?? "Event")
                    .font(VoiidFont.rounded(14.5, .semibold))
                    .foregroundColor(VoiidColor.textPrimary)
                    .lineLimit(1)
                Text("\(t.people ?? 1) \((t.people ?? 1) == 1 ? "person" : "people") · " + subtitle(t))
                    .font(VoiidFont.rounded(12.5))
                    .foregroundColor(VoiidColor.textSecondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            if t.canShowCode {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(VoiidColor.textSecondary)
            }
        }
        .padding(VoiidSpacing.sm + 4)
        .background(VoiidColor.surfaceCard)
        .clipShape(RoundedRectangle(cornerRadius: VoiidRadius.lg, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: VoiidRadius.lg, style: .continuous)
            .stroke(VoiidColor.divider, lineWidth: 1))
        .opacity(t.canShowCode ? 1 : 0.6)
    }

    /// States WHY a ticket cannot be used, rather than leaving a dimmed row unexplained.
    private func subtitle(_ t: EventService.Ticket) -> String {
        if t.isCheckedIn { return "Already checked in" }
        // A refund says what happened to the money, which matters more than why the ticket died.
        if t.order_status == "refunded" { return "Refunded" + (t.refund_reason.map { " · \($0)" } ?? "") }
        if t.refund_requested_at != nil, t.order_status == "paid" {
            return "Refund on the way" + (t.refund_reason.map { " · \($0)" } ?? "")
        }
        if t.event_status == "cancelled" { return "Event cancelled" }
        if t.state != "valid" { return "No longer valid" }
        if t.order_status != "paid" { return "Payment not complete" }
        if let iso = t.starts_at, let when = Self.date(iso) { return when }
        return t.location_text ?? "Ready to scan"
    }

    private static func date(_ iso: String) -> String? {
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let d = parser.date(from: iso) ?? ISO8601DateFormatter().date(from: iso)
        guard let d else { return nil }
        return d.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)
                            .hour().minute())
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            tickets = try await EventService.shared.myTickets()
            error = nil
        } catch {
            self.error = (error as? APIError)?.errorDescription ?? "Couldn’t load your tickets."
        }
    }
}

// MARK: - The code

/// The scannable code, held only in memory and re-minted before it expires.
struct TicketCodeSheet: View {
    let ticket: EventService.Ticket

    @Environment(\.dismiss) private var dismiss
    @State private var code: EventService.TicketCode?
    @State private var error: String?
    @State private var loading = true
    /// Screen brightness is raised while a code is on screen and put back on the way out —
    /// a dim phone at a door is the single most common reason a scan fails.
    @State private var previousBrightness: CGFloat?
    @State private var walletPass: PKPass?
    @ObservedObject private var activity = EventActivityController.shared
    @State private var savingPass = false
    @State private var walletError: String?
    @Environment(\.scenePhase) private var scenePhase
    @State private var refreshAttempt = 0

    @MainActor private func addToWallet() async {
        savingPass = true; walletError = nil
        defer { savingPass = false }
        do {
            struct Payload: Decodable { let pass_base64: String }
            let payload = try await APIClient().request("GET", "event-tickets/\(ticket.id)/apple-wallet", as: Payload.self)
            guard let bytes = Data(base64Encoded: payload.pass_base64) else { throw CocoaError(.fileReadCorruptFile) }
            let pass = try PKPass(data: bytes)
            guard pass.passTypeIdentifier == "pass.in.voiid.events", pass.serialNumber == ticket.id else { throw CocoaError(.fileReadCorruptFile) }
            walletPass = pass
        } catch { walletError = (error as? APIError)?.errorDescription ?? "Unable to prepare your Wallet pass." }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                VoiidColor.background.ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        Label("Event ticket", systemImage: "ticket")
                            .font(.caption.weight(.semibold)).foregroundStyle(VoiidColor.accentInk)
                        Text(ticket.title ?? "Event").font(.largeTitle.weight(.semibold))
                        VStack(alignment: .leading, spacing: 9) {
                            if let start = ticket.starts_at {
                                Label(VoiidEventDate.display(start) ?? start, systemImage: "calendar")
                            }
                            if let location = ticket.location_text { Label(location, systemImage: "mappin.and.ellipse") }
                        }.font(.subheadline).foregroundStyle(VoiidColor.textSecondary)
                        VStack(spacing: 20) {
                            HStack {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text("GROUP ENTRY").font(.caption2.weight(.semibold)).foregroundStyle(VoiidColor.textSecondary)
                                    Text("Admits \(ticket.people ?? 1) \((ticket.people ?? 1) == 1 ? "person" : "people")")
                                        .font(.title2.weight(.semibold))
                                }
                                Spacer()
                                Image(systemName: "person.2.fill").font(.title2).foregroundStyle(VoiidColor.accentInk)
                            }
                            Divider()
                            if let code, code.expires_at > Date().timeIntervalSince1970 * 1000,
                               let image = Self.qr(code.code) {
                                image.interpolation(.none).resizable().scaledToFit()
                                    .frame(maxWidth: 260).padding(22)
                                    .background(Color.white, in: RoundedRectangle(cornerRadius: 20))
                                Text("One QR. Your whole group.").font(.headline)
                                Text("Arrive together. Scan once to check everyone in.")
                                    .font(.footnote).foregroundStyle(VoiidColor.textSecondary)
                                    .multilineTextAlignment(.center)
                            } else if loading { ProgressView("Preparing your QR").frame(height: 260) }
                            else {
                                Image(systemName: "ticket").font(.largeTitle)
                                Text(error ?? "Refresh your ticket to continue.").multilineTextAlignment(.center)
                                Button("Refresh ticket") { refreshAttempt += 1 }
                            }
                        }.padding(22).frame(maxWidth: .infinity)
                            .background(VoiidColor.surfaceCard, in: RoundedRectangle(cornerRadius: 28))
                        Button {
                            Task {
                                if activity.following.contains(ticket.id) { await activity.stop(ticketId: ticket.id) }
                                else { await activity.start(ticketId: ticket.id) }
                            }
                        } label: {
                            Label(activity.following.contains(ticket.id) ? "Stop following event" : "Follow event",
                                  systemImage: "livephoto")
                                .font(.headline).frame(maxWidth: .infinity).padding(16)
                                .background(VoiidColor.surfaceCard, in: RoundedRectangle(cornerRadius: 18))
                        }.buttonStyle(.plain).disabled(activity.busy || !ticket.canShowCode)
                        Text("Show a private countdown on your Lock Screen and Dynamic Island.")
                            .font(.footnote).foregroundStyle(VoiidColor.textSecondary)
                        if let activityError = activity.error { Text(activityError).font(.footnote).foregroundStyle(VoiidColor.error) }
                        if PKAddPassesViewController.canAddPasses() {
                            Button { Task { await addToWallet() } } label: {
                                Label(savingPass ? "Preparing pass…" : "Add to Apple Wallet", systemImage: "wallet.pass.fill")
                                    .font(.headline).frame(maxWidth: .infinity).padding(16)
                                    .background(VoiidColor.surfaceCard, in: RoundedRectangle(cornerRadius: 18))
                            }.buttonStyle(.plain).disabled(savingPass || !ticket.canShowCode)
                            if let walletError { Text(walletError).font(.footnote).foregroundStyle(VoiidColor.error) }
                        }
                    }.padding(20).foregroundStyle(VoiidColor.textPrimary)
                }
            }
            .sheet(isPresented: Binding(get: { walletPass != nil }, set: { if !$0 { walletPass = nil } })) {
                if let walletPass { AddEventPassView(pass: walletPass) }
            }
            .onAppear { activity.restore() }
            .navigationTitle("Your ticket")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .foregroundColor(VoiidColor.textSecondary)
                }
            }
            .task(id: "\(scenePhase)-\(refreshAttempt)") {
                guard scenePhase == .active else { code = nil; return }
                if previousBrightness == nil { previousBrightness = UIScreen.main.brightness }
                UIScreen.main.brightness = 1.0
                while !Task.isCancelled {
                    await mint()
                    guard let fresh = code else { break }
                    let delay = max(1, min(570, fresh.expires_at / 1000 - Date().timeIntervalSince1970 - 30))
                    do { try await Task.sleep(for: .seconds(delay)) } catch { break }
                    code = nil
                }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase != .active {
                    code = nil
                    if let previousBrightness { UIScreen.main.brightness = previousBrightness }
                }
            }
            .onDisappear {
                if let previousBrightness { UIScreen.main.brightness = previousBrightness }
            }
        }
        .presentationDetents([.large])
    }

    private func mint() async {
        loading = true
        code = nil
        defer { loading = false }
        do {
            let fresh = try await EventService.shared.code(ticketId: ticket.id)
            guard !Task.isCancelled, scenePhase == .active else { return }
            code = fresh
            error = nil
        } catch {
            self.error = (error as? APIError)?.errorDescription ?? "Couldn’t get a code."
        }
    }

    private static func qr(_ value: String) -> Image? {
        let context = CIContext()
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(value.utf8)
        // Highest error correction: this is read at an angle, in bad light, off a screen with
        // glare. A code that fails to scan means arguing with someone on a door.
        filter.correctionLevel = "H"
        guard let output = filter.outputImage else { return nil }
        // Nearest-neighbour upscale keeps the modules crisp; a smoothed QR scans worse.
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        guard let cg = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return Image(decorative: cg, scale: 1)
    }
}


private struct AddEventPassView: UIViewControllerRepresentable {
    let pass: PKPass
    func makeUIViewController(context: Context) -> UIViewController {
        PKAddPassesViewController(pass: pass) ?? UIViewController()
    }
    func updateUIViewController(_ controller: UIViewController, context: Context) {}
}

@MainActor final class EventTicketLinkRouter: ObservableObject {
    static let shared = EventTicketLinkRouter()
    struct Destination: Identifiable { let id: String }
    @Published var pending: Destination?
    func handle(_ url: URL?) {
        guard let url, url.scheme == "https", ["voiid.app", "www.voiid.app", "api-dev.voiid.app"].contains(url.host ?? "") else { return }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count == 2, parts[0] == "tickets", UUID(uuidString: parts[1]) != nil else { return }
        pending = Destination(id: parts[1])
    }
}

struct LinkedEventTicketView: View {
    let ticketId: String
    @State private var ticket: EventService.Ticket?
    @State private var error: String?
    var body: some View {
        Group {
            if let ticket { TicketCodeSheet(ticket: ticket) }
            else if let error { VStack { Text(error); Button("Retry") { Task { await load() } } }.padding() }
            else { ProgressView("Loading your ticket") }
        }.task(id: ticketId) { await load() }
    }
    @MainActor private func load() async {
        error = nil; ticket = nil
        do {
            struct Payload: Decodable { let ticket: EventService.Ticket }
            let result = try await APIClient().request("GET", "event-tickets/\(ticketId)", as: Payload.self)
            guard result.ticket.canShowCode, !result.ticket.isCheckedIn else { error = "This ticket is unavailable or already checked in."; return }
            ticket = result.ticket
        } catch { self.error = (error as? APIError)?.errorDescription ?? "Unable to open ticket. Sign in with the account that owns it." }
    }
}
