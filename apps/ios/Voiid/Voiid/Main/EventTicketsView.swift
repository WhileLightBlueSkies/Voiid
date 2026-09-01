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
                Text(subtitle(t))
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
private struct TicketCodeSheet: View {
    let ticket: EventService.Ticket

    @Environment(\.dismiss) private var dismiss
    @State private var code: EventService.TicketCode?
    @State private var error: String?
    @State private var loading = true
    /// Screen brightness is raised while a code is on screen and put back on the way out —
    /// a dim phone at a door is the single most common reason a scan fails.
    @State private var previousBrightness: CGFloat?

    var body: some View {
        NavigationStack {
            ZStack {
                VoiidColor.background.ignoresSafeArea()

                VStack(spacing: VoiidSpacing.lg) {
                    Text(ticket.title ?? "Event")
                        .font(VoiidFont.rounded(17, .semibold))
                        .foregroundColor(VoiidColor.textPrimary)
                        .multilineTextAlignment(.center)

                    if let code, let image = Self.qr(code.code) {
                        image
                            .interpolation(.none)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: 260)
                            .padding(VoiidSpacing.md)
                            // WHITE ground regardless of theme. A scanner reads contrast, and
                            // a dark-mode QR on a dark card is the classic failure.
                            .background(Color.white)
                            .clipShape(RoundedRectangle(cornerRadius: VoiidRadius.lg,
                                                        style: .continuous))

                        Text("Show this at the door")
                            .font(VoiidFont.rounded(13))
                            .foregroundColor(VoiidColor.textSecondary)
                    } else if loading {
                        ProgressView().tint(VoiidColor.accent).frame(height: 260)
                    } else {
                        VStack(spacing: VoiidSpacing.sm) {
                            Image(systemName: "exclamationmark.triangle")
                                .font(.system(size: 28))
                                .foregroundColor(VoiidColor.textSecondary)
                            Text(error ?? "Couldn’t get a code.")
                                .font(VoiidFont.subhead)
                                .foregroundColor(VoiidColor.textSecondary)
                                .multilineTextAlignment(.center)
                            Button("Try again") { Task { await mint() } }
                                .font(VoiidFont.rounded(15, .semibold))
                                .foregroundColor(VoiidColor.primary)
                        }
                        .frame(height: 260)
                    }

                    Spacer(minLength: 0)
                }
                .padding(VoiidSpacing.lg)
            }
            .navigationTitle("Ticket")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .foregroundColor(VoiidColor.textSecondary)
                }
            }
            .task {
                previousBrightness = UIScreen.main.brightness
                UIScreen.main.brightness = 1.0
                await mint()
            }
            .onDisappear {
                if let previousBrightness { UIScreen.main.brightness = previousBrightness }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func mint() async {
        loading = true
        defer { loading = false }
        do {
            code = try await EventService.shared.code(ticketId: ticket.id)
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
