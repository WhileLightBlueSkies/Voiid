//
//  EventHostView.swift
//  Voiid
//
//  The host's view of one event: what it is, who is coming, and the two state changes a host
//  can make — publish and cancel.
//
//  ── THIS SCREEN IS NOT THE AUTHORISATION ────────────────────────────────────────
//  Every call it makes is gated on the server by `communityAccess(..., needsAdmin: true)`.
//  The caller only offers this screen to a manager, and that is CONVENIENCE — a member who
//  reached it anyway would see 403s, not an unlocked control panel. Never move an
//  authorisation decision into this file.
//
//  ── THE LIFECYCLE, EXACTLY AS THE ROUTER DEFINES IT ─────────────────────────────
//      draft ──publish──▶ published ──cancel──▶ cancelled
//        └───────────────cancel───────────────────┘
//  There is no un-publish and no un-cancel; the router's UPDATEs are one-way and 409 anything
//  else. A draft is invisible to members — the list endpoint filters it in SQL — so publishing
//  is the moment the event becomes real to anyone but a host.
//
//  ── CANCEL DOES NOT REFUND, AND SAYS SO ─────────────────────────────────────────
//  The route leaves orders and tickets untouched: a refund moves money, money moves through a
//  provider, and a cancel button that silently moved other people's money would be the wrong
//  button. The confirmation says that in words rather than letting a host discover it.
//

import SwiftUI

struct EventHostView: View {
    let event: EventService.Event
    /// Called whenever this screen changed something the list behind it renders.
    var onChange: () -> Void = {}

    @Environment(\.dismiss) private var dismiss

    /// The event as this screen currently understands it — seeded from the row that was
    /// tapped, replaced by whatever the server hands back from publish or cancel.
    @State private var current: EventService.Event

    @State private var orders: [EventService.Order] = []
    @State private var ordersLoading = true
    @State private var ordersFailed = false

    @State private var busy = false
    @State private var actionError: String?
    @State private var confirmCancel = false
    @State private var showCheckIn = false

    init(event: EventService.Event, onChange: @escaping () -> Void = {}) {
        self.event = event
        self.onChange = onChange
        _current = State(initialValue: event)
    }

    private var status: String { current.status ?? "draft" }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: VoiidSpacing.md) {
                VoiidSettingsHeader(current.title.isEmpty ? "Event" : current.title,
                                    subtitle: headerSubtitle,
                                    badge: statusBadge)

                detailsCard
                hostControls
                attendeesCard

                if let actionError {
                    Text(actionError)
                        .font(.footnote)
                        .foregroundStyle(VoiidColor.error)
                        .padding(.horizontal, 4)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, VoiidSpacing.md)
            .padding(.top, VoiidSpacing.sm)
            .padding(.bottom, VoiidSpacing.xl)
        }
        .voiidSettingsPage()
        .task(id: current.id) { await loadOrders() }
        .sheet(isPresented: $showCheckIn) {
            EventCheckInView(eventId: current.id, eventTitle: current.title) {
                Task { await loadOrders() }
            }
        }
        .confirmationDialog("Cancel this event?",
                            isPresented: $confirmCancel,
                            titleVisibility: .visible) {
            Button("Cancel event", role: .destructive) {
                Haptics.rigid()
                Task { await cancel() }
            }
            Button("Keep it", role: .cancel) {}
        } message: {
            Text("Everyone who RSVP'd keeps their ticket and nothing is refunded — cancelling "
               + "marks the event off, it doesn't undo it. This can't be reversed.")
        }
    }

    // MARK: Header

    private var headerSubtitle: String {
        var parts: [String] = []
        if let when = current.starts_at.flatMap(VoiidEventDate.display) { parts.append(when) }
        parts.append(current.free ? "Free" : VoiidEventDate.price(minor: current.price_minor,
                                                                 currency: current.currency))
        return parts.joined(separator: " \u{00B7} ")
    }

    private var statusBadge: (icon: String, text: String)? {
        switch status {
        case "draft":     return ("eye.slash", "Draft \u{2014} only hosts can see this")
        case "published": return ("checkmark.seal", "Published")
        case "cancelled": return ("xmark.circle", "Cancelled")
        default:          return nil
        }
    }

    // MARK: Details

    private var detailsCard: some View {
        VoiidCardSection("Event") {
            if let d = current.description, !d.isEmpty {
                VoiidSettingsRow(icon: "text.alignleft", title: "About", detail: d)
                VoiidRowDivider()
            }
            if let loc = current.location_text, !loc.isEmpty {
                // Free text on a listing, NOT a location share and not encrypted. The wording
                // stays neutral so it never reads like a pin drop.
                VoiidSettingsRow(icon: "mappin.and.ellipse", title: "Where", detail: loc)
                VoiidRowDivider()
            }
            VoiidSettingsRow(icon: "calendar", title: "Starts") {
                value(current.starts_at.flatMap(VoiidEventDate.display) ?? "\u{2014}")
            }
            if let ends = current.ends_at.flatMap(VoiidEventDate.display) {
                VoiidRowDivider()
                VoiidSettingsRow(icon: "calendar.badge.clock", title: "Ends") { value(ends) }
            }
            VoiidRowDivider()
            VoiidSettingsRow(icon: "person.2", title: "Capacity") {
                value(current.capacity.map { "\($0)" } ?? "No limit")
            }
        }
    }

    // MARK: Host controls

    @ViewBuilder private var hostControls: some View {
        VoiidCardSection("Hosting", footer: controlsFooter) {
            if status == "draft" {
                VoiidSettingsRow(icon: "paperplane",
                                 title: "Publish",
                                 detail: "Make it visible to the community.") {
                    Haptics.tap()
                    Task { await publish() }
                } trailing: {
                    if busy { ProgressView().tint(VoiidColor.accent) } else { VoiidChevron() }
                }
                VoiidRowDivider()
            }

            if status == "published" {
                VoiidSettingsRow(icon: "qrcode.viewfinder",
                                 title: "Check people in",
                                 detail: "Read a ticket code at the door.") {
                    Haptics.tap()
                    showCheckIn = true
                } trailing: { VoiidChevron() }
                VoiidRowDivider()
            }

            if status == "draft" || status == "published" {
                VoiidSettingsRow(icon: "xmark.circle",
                                 title: "Cancel event",
                                 destructive: true) {
                    Haptics.tap()
                    confirmCancel = true
                }
            } else {
                VoiidSettingsRow(icon: "xmark.circle",
                                 title: "This event was cancelled",
                                 detail: "Existing tickets were left untouched.")
            }
        }
        .disabled(busy)
    }

    private var controlsFooter: String {
        switch status {
        case "draft":
            return "A draft is invisible to members. Publishing is what makes it real, and "
                 + "it can't be undone \u{2014} an event you no longer want is cancelled."
        case "published":
            return "Cancelling leaves every ticket valid and refunds nothing."
        default:
            return "A cancelled event can't be reopened. Create a new one instead."
        }
    }

    // MARK: Attendees

    @ViewBuilder private var attendeesCard: some View {
        // Three states, kept apart on purpose: a failed fetch must never read as "nobody
        // came", which is a different and much more alarming statement.
        if ordersLoading {
            VoiidCardSection("Attendees") {
                HStack(spacing: VoiidSpacing.md) {
                    ProgressView().tint(VoiidColor.accent)
                    Text("Loading\u{2026}")
                        .font(.body)
                        .foregroundStyle(VoiidColor.textSecondary)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, VoiidSpacing.md)
                .padding(.vertical, 11)
            }
        } else if ordersFailed {
            VoiidCardSection("Attendees") {
                VoiidSettingsRow(icon: "arrow.clockwise",
                                 title: "Couldn't load the list",
                                 detail: "Tap to try again.") {
                    Haptics.tap()
                    Task { await loadOrders() }
                }
            }
        } else if orders.isEmpty {
            VoiidCardSection("Attendees",
                             footer: status == "draft"
                                   ? "Nobody can RSVP until this is published."
                                   : nil) {
                VoiidSettingsRow(icon: "person.badge.clock", title: "No RSVPs yet")
            }
        } else {
            VoiidCardSection("Attendees \u{00B7} \(orders.count)") {
                ForEach(Array(orders.enumerated()), id: \.element.id) { index, order in
                    if index > 0 { VoiidRowDivider() }
                    VoiidSettingsRow(icon: "person",
                                     title: order.display,
                                     detail: orderDetail(order))
                }
            }
        }
    }

    private func orderDetail(_ o: EventService.Order) -> String {
        var parts: [String] = []
        if let q = o.quantity, q > 1 { parts.append("\(q) tickets") }
        if let checked = o.checked_in, checked > 0 { parts.append("Checked in") }
        if let s = o.status {
            switch s {
            case "paid":      parts.append("Confirmed")
            case "pending":   parts.append("Holding a seat")
            case "cancelled": parts.append("Cancelled")
            case "refunded":  parts.append("Refunded")
            case "failed":    parts.append("Payment failed")
            default:          parts.append(s)
            }
        }
        return parts.joined(separator: " \u{00B7} ")
    }

    private func value(_ text: String) -> some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(VoiidColor.textSecondary)
            .multilineTextAlignment(.trailing)
    }

    // MARK: Actions

    private func publish() async {
        busy = true
        actionError = nil
        defer { busy = false }
        do {
            // The server's echo replaces the local copy rather than a locally-flipped string:
            // it is the only thing that knows whether the transition actually happened.
            if let updated = try await EventService.shared.publish(eventId: current.id) {
                current = updated
            }
            Haptics.success()
            onChange()
        } catch {
            actionError = error.localizedDescription
        }
    }

    private func cancel() async {
        busy = true
        actionError = nil
        defer { busy = false }
        do {
            if let updated = try await EventService.shared.cancel(eventId: current.id) {
                current = updated
            }
            Haptics.success()
            onChange()
        } catch {
            actionError = error.localizedDescription
        }
    }

    private func loadOrders() async {
        guard !current.id.isEmpty else { ordersLoading = false; return }
        ordersLoading = orders.isEmpty
        ordersFailed = false
        defer { ordersLoading = false }
        do {
            orders = try await EventService.shared.orders(eventId: current.id)
        } catch {
            ordersFailed = true
        }
    }
}

// MARK: - Shared formatting

/// The one place event dates and prices are turned into strings, so the member's row and the
/// host's screen can never disagree about how the same event reads.
enum VoiidEventDate {
    static func display(_ iso: String) -> String? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let d = f.date(from: iso) ?? ISO8601DateFormatter().date(from: iso) else { return nil }
        let out = DateFormatter()
        out.dateFormat = "d MMM, h:mm a"
        return out.string(from: d)
    }

    /// Minor units are an integer count of the currency's smallest unit, so this divides by
    /// 100 rather than locale-formatting — not every currency has two decimal places, and a
    /// locale formatter would quietly invent an exponent this client does not know.
    static func price(minor: Int?, currency: String?) -> String {
        String(format: "%@ %.2f", currency ?? "INR", Double(minor ?? 0) / 100)
    }
}
