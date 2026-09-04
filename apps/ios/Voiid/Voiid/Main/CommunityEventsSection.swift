//
//  CommunityEventsSection.swift
//  Voiid
//
//  Events inside a community (plan item 3.23).
//
//  The member's view of an event: when, where, and a way to claim a ticket. Creating,
//  publishing and checking people in are ADMIN flows with their own screens; this section
//  now REACHES those screens for a manager, and is otherwise unchanged.
//
//  ── THE HOST HALF IS ADDITIVE, AND IT IS NOT THE AUTHORISATION ───────────────────
//  `isHost` adds a Create button and turns each row into a door to `EventHostView`. It is
//  presentation only: every hosting endpoint is gated on the server by
//  `communityAccess(..., needsAdmin: true)`, so a member who reached those screens would see
//  403s rather than an unlocked control panel. The member's row is byte-for-byte what it was.
//
//  ── PAID EVENTS SAY SO INSTEAD OF PRETENDING ─────────────────────────────────────
//  `POST /events/:id/orders` answers 501 for a paid event because no payment provider is
//  wired up. So a paid event shows its price and states that ticketing is not open, rather
//  than offering an RSVP button whose only possible outcome is an error. The moment the
//  server can take money, this branch is what changes.
//

import SwiftUI

struct CommunityEventsSection: View {
    let communityId: String
    /// Whether to draw the host affordances. Defaults to false so every existing caller
    /// renders exactly the member's view it rendered before.
    var isHost: Bool = false

    @State private var events: [EventService.Event] = []
    @State private var loading = true
    @State private var failed = false
    @State private var busyId: String?
    @State private var creating = false
    @State private var hosting: EventService.Event?
    @State private var showTickets = false
    /// Owned by the SECTION, not the row — a sheet owned by a row in a lazy stack is torn
    /// down when that row scrolls out, which can happen while the user is mid-report.
    @State private var reporting: EventService.Event?

    var body: some View {
        VStack(alignment: .leading, spacing: VoiidSpacing.sm) {
            HStack(spacing: VoiidSpacing.sm) {
                Text("Events")
                    .font(VoiidFont.rounded(17, .semibold))
                    .foregroundColor(VoiidColor.textPrimary)
                Spacer(minLength: 0)
                // Everyone, not just hosts: the wallet is the ATTENDEE's half, and it was the
                // half with no client at all.
                ticketsButton
                if isHost { createButton }
            }

            if loading {
                ProgressView().tint(VoiidColor.primary)
            } else if failed {
                // A FAILED FETCH IS NOT AN EMPTY LIST. "No events yet" would be a claim about
                // this community that the app has no evidence for.
                retry("Couldn't load events.")
            } else if events.isEmpty {
                Text(isHost ? "No events yet. Create the first one."
                            : "No events yet.")
                    .font(VoiidFont.footnote)
                    .foregroundColor(VoiidColor.textSecondary)
            } else {
                ForEach(events) { e in row(e) }
            }
        }
        .task(id: communityId) { await load() }
        .sheet(isPresented: $creating) {
            EventCreateFlow(communityId: communityId) { _ in
                Task { await load() }
            }
        }
        // A SHEET, not a push. This section is rendered inside the community detail scroll
        // view and does not own a navigation stack, so a push would either do nothing or
        // escape into whichever stack happened to be above it.
        .sheet(isPresented: $showTickets) {
            EventTicketsView()
        }
        .sheet(item: $reporting) { event in
            ReportSheet(target: .event(eventId: event.id)) { reporting = nil }
        }
        .sheet(item: $hosting) { event in
            NavigationStack {
                EventHostView(event: event) { Task { await load() } }
            }
        }
    }

    private var ticketsButton: some View {
        Button {
            Haptics.tap()
            showTickets = true
        } label: {
            Image(systemName: "ticket")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(VoiidColor.accentInk)
                // Draws small, taps at 44 — the same treatment the settings controls needed.
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityLabel("My tickets")
    }

    /// Host only. The server gates the create route on adminship; this button is convenience.
    private var createButton: some View {
        Button {
            Haptics.tap()
            creating = true
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "plus").font(.system(size: 11, weight: .bold))
                Text("Create").font(VoiidFont.rounded(13, .semibold))
            }
            .foregroundColor(VoiidColor.textOnAccent)
            .padding(.horizontal, VoiidSpacing.md)
            .padding(.vertical, 6)
            .background(Capsule().fill(VoiidColor.accent))
        }
        .buttonStyle(.plain)
    }

    private func retry(_ message: String) -> some View {
        Button {
            Haptics.tap()
            Task { await load() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.clockwise").font(.system(size: 11, weight: .semibold))
                Text(message).font(VoiidFont.footnote)
                Text("Tap to retry.").font(VoiidFont.footnote).foregroundColor(VoiidColor.accentInk)
            }
            .foregroundColor(VoiidColor.textSecondary)
        }
        .buttonStyle(.plain)
    }

    /// The row itself is UNCHANGED for a member. For a host it gains a tap target and a
    /// chevron; nothing about the member's rendering moved.
    @ViewBuilder private func row(_ e: EventService.Event) -> some View {
        if isHost {
            Button {
                Haptics.tap()
                hosting = e
            } label: {
                rowBody(e)
            }
            .buttonStyle(.plain)
        } else {
            // A member cannot open an event (there is no detail screen yet), so the report
            // affordance is a context menu on the row itself rather than an action inside a
            // screen that does not exist. A host is not offered it: reporting your own
            // listing is refused server-side, and offering an action that always no-ops is
            // worse than not offering it.
            rowBody(e)
                .contextMenu {
                    Button(role: .destructive) {
                        Haptics.tap()
                        reporting = e
                    } label: {
                        Label("Report event", systemImage: "flag")
                    }
                }
        }
    }

    private func rowBody(_ e: EventService.Event) -> some View {
        HStack(alignment: .top, spacing: VoiidSpacing.md) {
            VStack(alignment: .leading, spacing: 3) {
                Text(e.title)
                    .font(VoiidFont.rounded(15, .semibold))
                    .foregroundColor(VoiidColor.textPrimary)
                    .lineLimit(2)
                Text(subtitle(e))
                    .font(VoiidFont.rounded(11, .regular))
                    .foregroundColor(VoiidColor.textSecondary)
                if let loc = e.location_text, !loc.isEmpty {
                    Text(loc)
                        .font(VoiidFont.rounded(11, .regular))
                        .foregroundColor(VoiidColor.textSecondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            action(e)
        }
        .padding(VoiidSpacing.md)
        .background(VoiidColor.surfaceCard)
        .clipShape(RoundedRectangle(cornerRadius: VoiidRadius.md, style: .continuous))
    }

    private func subtitle(_ e: EventService.Event) -> String {
        var parts: [String] = []
        if let when = e.starts_at.flatMap(Self.displayDate) { parts.append(when) }
        parts.append(e.free ? "Free" : price(e))
        return parts.joined(separator: " · ")
    }

    /// Minor units are an integer count of the currency's smallest unit, so the conversion is
    /// a divide by 100 — NOT a locale-formatted currency string, which would need the
    /// currency's real exponent (not every currency has two decimal places).
    private func price(_ e: EventService.Event) -> String {
        let minor = e.price_minor ?? 0
        let code = e.currency ?? "INR"
        return String(format: "%@ %.2f", code, Double(minor) / 100)
    }

    private static func displayDate(_ iso: String) -> String? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let d = f.date(from: iso) ?? ISO8601DateFormatter().date(from: iso) else { return nil }
        let out = DateFormatter()
        out.dateFormat = "d MMM, h:mm a"
        return out.string(from: d)
    }

    @ViewBuilder private func action(_ e: EventService.Event) -> some View {
        if e.your_order_status == "paid" {
            Text("Going")
                .font(VoiidFont.rounded(12, .semibold))
                .foregroundColor(VoiidColor.primary)
        } else if e.suspended == true {
            // Checked BEFORE status, because a suspended event is still 'published' and would
            // otherwise fall through to an RSVP button the server refuses with a 409.
            //
            // "Unavailable", not "reported": the reason a listing is off sale is a moderation
            // fact, and telling attendees a complaint was made invites them to guess who made
            // it. What they can act on is that it cannot be booked.
            Text("Unavailable")
                .font(VoiidFont.rounded(12, .regular))
                .foregroundColor(VoiidColor.textSecondary)
        } else if e.status != "published" {
            // Draft and cancelled events take no orders; the server 409s. Say which.
            Text(e.status == "cancelled" ? "Cancelled" : "Not open")
                .font(VoiidFont.rounded(12, .regular))
                .foregroundColor(VoiidColor.textSecondary)
        } else if !e.free {
            // The one honest thing to render: the server answers 501 here.
            Text("Ticketing soon")
                .font(VoiidFont.rounded(12, .regular))
                .foregroundColor(VoiidColor.textSecondary)
        } else {
            Button {
                Haptics.tap()
                Task { await rsvp(e) }
            } label: {
                Text("RSVP")
                    .font(VoiidFont.rounded(13, .semibold))
                    .foregroundColor(VoiidColor.textOnPrimary)
                    .padding(.horizontal, VoiidSpacing.md)
                    .padding(.vertical, 6)
                    .background(VoiidColor.primary)
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(busyId == e.id)
        }
    }

    private func rsvp(_ e: EventService.Event) async {
        busyId = e.id
        defer { busyId = nil }
        // Capacity is the server's to enforce and people may be racing for the last seat, so
        // the list is re-read rather than optimistically marked "Going".
        _ = try? await EventService.shared.rsvp(eventId: e.id)
        await load()
    }

    private func load() async {
        loading = events.isEmpty
        failed = false
        defer { loading = false }
        do {
            events = try await EventService.shared.list(communityId: communityId)
        } catch {
            // Keep the last good list if there is one; only claim failure when there is
            // nothing to show, so a background refresh does not blank a working screen.
            failed = events.isEmpty
        }
    }
}
