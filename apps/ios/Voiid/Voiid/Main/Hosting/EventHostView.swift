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
    var canAssignStaff: Bool = false
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
    /// The attendee whose money is about to go back — drives the reason picker.
    @State private var refundTarget: EventService.Order?
    @State private var notice: String?
    @State private var showCheckIn = false
    @State private var editing = false
    @State private var workspaceTab = "Overview"
    @State private var guestSearch = ""

    init(event: EventService.Event, canAssignStaff: Bool = false, onChange: @escaping () -> Void = {}) {
        self.event = event
        self.canAssignStaff = canAssignStaff
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

                if status == "published" {
                    Button { showCheckIn = true } label: {
                        Label("Open check-in desk", systemImage: "qrcode.viewfinder").font(.headline)
                            .frame(maxWidth: .infinity).padding(14)
                    }.buttonStyle(.borderedProminent)
                }
                if !ordersLoading && !ordersFailed {
                    HStack(spacing: 14) {
                        workspaceMetric("Registered", orders.filter { $0.status == "paid" }.reduce(0) { $0 + ($1.quantity ?? 1) })
                        workspaceMetric("Checked in", orders.reduce(0) { $0 + ($1.checked_in ?? 0) })
                    }
                }
                Text("Counts cover up to 500 bookings.").font(.caption).foregroundStyle(VoiidColor.textSecondary)
                Picker("Workspace", selection: $workspaceTab) {
                    Text("Overview").tag("Overview"); Text("Guests").tag("Guests"); Text("Check-in").tag("Check-in")
                }.pickerStyle(.segmented)
                if workspaceTab == "Overview" {
                    detailsCard
                    if canAssignStaff { NavigationLink("Manage event team") { EventTeamView(eventId: current.id) } }
                    hostControls
                } else if workspaceTab == "Guests" {
                    TextField("Search guest or username", text: $guestSearch).textFieldStyle(.roundedBorder)
                    attendeesCard
                } else {
                    VoiidCardSection("Group entry") {
                        VoiidSettingsRow(icon: "person.2", title: "One scan admits the whole booking", detail: "Ask the whole group to arrive together. Used bookings cannot be admitted again.")
                    }
                    attendeesCard
                }

                if let notice {
                    Text(notice)
                        .font(.footnote)
                        .foregroundStyle(VoiidColor.textSecondary)
                        .padding(.horizontal, 4)
                        .fixedSize(horizontal: false, vertical: true)
                }
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
        .sheet(isPresented: $editing) {
            EventEditView(event: current) { updated in current = updated; onChange() }
        }
        .sheet(isPresented: $showCheckIn) {
            EventCheckInView(eventId: current.id, eventTitle: current.title) {
                Task { await loadOrders() }
            }
        }
        .confirmationDialog("Cancel this event?",
                            isPresented: $confirmCancel,
                            titleVisibility: .visible) {
            if paidCount > 0 {
                Button("Cancel and refund everyone", role: .destructive) {
                    Haptics.rigid()
                    Task { await cancel(refund: true) }
                }
                Button("Cancel without refunds", role: .destructive) {
                    Haptics.rigid()
                    Task { await cancel(refund: false) }
                }
            } else {
                Button("Cancel event", role: .destructive) {
                    Haptics.rigid()
                    Task { await cancel(refund: false) }
                }
            }
            Button("Keep it", role: .cancel) {}
        } message: {
            Text(paidCount > 0
                 ? "Cancelling stops registration and admission. \(paidCount) \(paidCount == 1 ? "person has" : "people have") paid — refunding everyone returns their full amount to how they paid, usually within 5–7 working days. This cannot be reversed."
                 : "Cancelling stops registration and admission. Records are kept. This cannot be reversed.")
        }
        .confirmationDialog(refundTarget.map { "Refund \(VoiidEventDate.price(minor: $0.amount_minor, currency: $0.currency)) to \($0.display)?" } ?? "",
                            isPresented: Binding(get: { refundTarget != nil }, set: { if !$0 { refundTarget = nil } }),
                            titleVisibility: .visible) {
            ForEach(Self.refundReasons, id: \.code) { reason in
                Button(reason.label) {
                    let order = refundTarget
                    refundTarget = nil
                    if let order { Task { await refund(order, reason: reason.code) } }
                }
            }
            Button("Don't refund", role: .cancel) { refundTarget = nil }
        } message: {
            Text("Choose why. They get the full amount back to how they paid, usually within 5–7 working days, and their ticket stops working.")
        }
    }

    private func workspaceMetric(_ title: String, _ count: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.subheadline).foregroundStyle(VoiidColor.textSecondary)
            Text("\(count)").font(.largeTitle.weight(.semibold)).monospacedDigit()
        }.frame(maxWidth: .infinity, alignment: .leading).padding(20)
            .background(VoiidColor.surfaceCard, in: RoundedRectangle(cornerRadius: 24))
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
            if status != "cancelled" {
                Button("Edit event") { editing = true }.disabled(busy)
                VoiidRowDivider()
            }
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
            return "Cancelling stops admission. Refunds are handled separately."
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
                ForEach(Array(orders.filter { guestSearch.isEmpty || $0.display.localizedCaseInsensitiveContains(guestSearch) }.enumerated()), id: \.element.id) { index, order in
                    if index > 0 { VoiidRowDivider() }
                    VoiidSettingsRow(icon: "person",
                                     title: order.display,
                                     detail: orderDetail(order)) {
                        if canRefund(order) {
                            Button(order.refund_error == nil ? "Refund" : "Retry") {
                                Haptics.tap()
                                refundTarget = order
                            }
                            .font(VoiidFont.rounded(14, .semibold))
                            .foregroundStyle(VoiidColor.accentInk)
                            .disabled(busy)
                            .accessibilityLabel("Refund \(order.display)")
                        }
                    }
                }
            }
        }
    }

    private func orderDetail(_ o: EventService.Order) -> String {
        var parts: [String] = []
        if let q = o.quantity, q > 1 { parts.append("\(q) tickets") }
        if let checked = o.checked_in, checked > 0 { parts.append("Checked in") }
        if o.status == "paid", let error = o.refund_error {
            parts.append("Refund failed: \(error)")
            return parts.joined(separator: " \u{00B7} ")
        }
        if o.status == "paid", o.refund_requested_at != nil {
            parts.append("Refund on the way")
            if let r = o.refund_reason { parts.append(r) }
            return parts.joined(separator: " \u{00B7} ")
        }
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

    private func cancel(refund: Bool) async {
        busy = true
        actionError = nil
        defer { busy = false }
        do {
            if refund {
                let r = try await EventService.shared.cancelAndRefund(eventId: current.id)
                if let updated = r.event { current = updated }
                notice = r.failed == 0
                    ? "Cancelled. \(r.requested) refund\(r.requested == 1 ? "" : "s") on the way."
                    : "Cancelled. \(r.requested) refund\(r.requested == 1 ? "" : "s") on the way, \(r.failed) failed — retry them from the attendee list."
                await loadOrders()
            } else if let updated = try await EventService.shared.cancel(eventId: current.id) {
                current = updated
            }
            Haptics.success()
            onChange()
        } catch {
            actionError = error.localizedDescription
        }
    }

    /// Paid orders that took money — the ones a refund applies to.
    private var paidCount: Int {
        orders.filter { $0.status == "paid" && ($0.amount_minor ?? 0) > 0 }.count
    }

    private func canRefund(_ o: EventService.Order) -> Bool {
        o.status == "paid" && (o.amount_minor ?? 0) > 0 && (o.refund_requested_at == nil || o.refund_error != nil)
    }

    private static let refundReasons: [(code: String, label: String)] = [
        ("attendee_request", "Requested by the attendee"),
        ("event_changed", "Event changed"),
        ("duplicate_payment", "Duplicate payment"),
        ("event_cancelled", "Event cancelled"),
    ]

    private func refund(_ order: EventService.Order, reason: String) async {
        busy = true
        actionError = nil
        defer { busy = false }
        do {
            try await EventService.shared.refundOrder(eventId: current.id, orderId: order.id, reason: reason)
            Haptics.success()
            notice = "Refund on the way to \(order.display)."
        } catch {
            Haptics.error()
            actionError = error.localizedDescription
        }
        await loadOrders()
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


private struct EventEditView: View {
    let event: EventService.Event
    let onSaved: (EventService.Event) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var details: String
    @State private var venue: String
    @State private var start: Date
    @State private var end: Date
    @State private var hasEnd: Bool
    @State private var capacity: String
    @State private var busy = false
    @State private var error: String?
    init(event: EventService.Event, onSaved: @escaping (EventService.Event) -> Void) {
        self.event = event; self.onSaved = onSaved
        _title = State(initialValue: event.title); _details = State(initialValue: event.description ?? "")
        _venue = State(initialValue: event.location_text ?? "")
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let begins = event.starts_at.flatMap { formatter.date(from: $0) ?? ISO8601DateFormatter().date(from: $0) } ?? Date()
        _start = State(initialValue: begins)
        _end = State(initialValue: event.ends_at.flatMap { formatter.date(from: $0) ?? ISO8601DateFormatter().date(from: $0) } ?? begins.addingTimeInterval(3600))
        _hasEnd = State(initialValue: event.ends_at != nil)
        _capacity = State(initialValue: event.capacity.map(String.init) ?? "")
    }
    var body: some View {
        NavigationStack {
            Form {
                Section("Event details") {
                    TextField("Title", text: $title)
                    TextField("Description", text: $details, axis: .vertical)
                    TextField("Venue", text: $venue)
                }
                Section("Schedule") {
                    DatePicker("Starts", selection: $start)
                    Toggle("Set end time", isOn: $hasEnd)
                    if hasEnd { DatePicker("Ends", selection: $end, in: start...) }
                }
                Section("Capacity") {
                    TextField("Unlimited when empty", text: $capacity).keyboardType(.numberPad)
                    Text("Reducing capacity does not remove existing registrations.").font(.footnote)
                }
                if let error { Text(error).foregroundStyle(.red) }
            }
            .disabled(busy)
            .navigationTitle("Edit event")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(busy) }
                ToolbarItem(placement: .confirmationAction) { Button(busy ? "Saving…" : "Save") { Task { await save() } }.disabled(busy) }
            }
            .interactiveDismissDisabled(busy)
        }
    }
    @MainActor private func save() async {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTitle.isEmpty, cleanTitle.count <= 120, !hasEnd || end > start,
              capacity.isEmpty || (Int(capacity) ?? 0) > 0 else { error = "Check the title, times and capacity."; return }
        busy = true; error = nil; defer { busy = false }
        do {
            let changes = EventService.EventEdit(title: cleanTitle, description: details, starts_at: ISO8601DateFormatter().string(from: start), ends_at: hasEnd ? ISO8601DateFormatter().string(from: end) : nil, location_text: venue, capacity: Int(capacity))
            guard let updated = try await EventService.shared.edit(eventId: event.id, changes: changes) else { error = "No event returned. Please refresh and try again."; return }
            onSaved(updated); dismiss()
        } catch { self.error = (error as? APIError)?.errorDescription ?? "Unable to save changes." }
    }
}

struct EventTeamView: View {
    let eventId: String
    @State private var members: [EventService.StaffMember] = []
    @State private var username = ""
    @State private var role = "volunteer"
    @State private var error: String?
    @State private var busy = false
    var body: some View {
        Form {
            Section("Invite an active community member") {
                TextField("Username", text: $username).textInputAutocapitalization(.never).autocorrectionDisabled()
                Picker("Event role", selection: $role) { Text("Volunteer").tag("volunteer"); Text("Event manager").tag("manager") }
                Text(role == "volunteer" ? "Can check tickets for this event only." : "Can edit this event, view registrations and check tickets. No bank or community admin access.").font(.footnote)
                Button("Send invitation") { Task { await perform { try await EventService.shared.inviteStaff(eventId: eventId, username: username, role: role); username = "" } } }.disabled(username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if let error { Section { Text(error); Button("Retry") { Task { await load() } } } }
            Section("Event team") {
                if members.isEmpty { Text("No event staff assigned.") }
                ForEach(members) { member in
                    VStack(alignment: .leading) {
                        Text(member.full_name ?? member.username ?? "Member")
                        Text("\(member.role) · \(member.state)").font(.footnote)
                        Text("Access ends: \(member.expires_at)").font(.caption)
                        if member.state != "revoked" { Button("Remove access", role: .destructive) { Task { await perform { try await EventService.shared.removeStaff(eventId: eventId, userId: member.user_id) } } } }
                    }
                }
            }
        }.disabled(busy).navigationTitle("Event team").task { await load() }
    }
    @MainActor private func load() async { await perform {} }
    @MainActor private func perform(_ action: () async throws -> Void) async {
        busy = true; error = nil; defer { busy = false }
        do { try await action(); members = try await EventService.shared.team(eventId: eventId) }
        catch { members = []; self.error = (error as? APIError)?.errorDescription ?? "Unable to update event team." }
    }
}
