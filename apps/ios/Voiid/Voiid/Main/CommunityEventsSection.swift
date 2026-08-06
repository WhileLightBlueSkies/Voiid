//
//  CommunityEventsSection.swift
//  Voiid
//
//  Events inside a community (plan item 3.23).
//
//  The member's view of an event: when, where, and a way to claim a ticket. Creating,
//  publishing and checking people in are ADMIN flows with their own screens; this is not
//  those.
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

    @State private var events: [EventService.Event] = []
    @State private var loading = true
    @State private var busyId: String?

    var body: some View {
        VStack(alignment: .leading, spacing: VoiidSpacing.sm) {
            Text("Events")
                .font(VoiidFont.rounded(17, .semibold))
                .foregroundColor(VoiidColor.textPrimary)

            if loading {
                ProgressView().tint(VoiidColor.primary)
            } else if events.isEmpty {
                Text("No events yet.")
                    .font(VoiidFont.footnote)
                    .foregroundColor(VoiidColor.textSecondary)
            } else {
                ForEach(events) { e in row(e) }
            }
        }
        .task(id: communityId) { await load() }
    }

    private func row(_ e: EventService.Event) -> some View {
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
        defer { loading = false }
        events = (try? await EventService.shared.list(communityId: communityId)) ?? events
    }
}
