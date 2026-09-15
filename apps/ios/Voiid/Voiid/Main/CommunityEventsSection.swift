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
    var isOwner: Bool = false
    var managementContext: Bool = false

    @State private var staffInvites: [EventService.StaffInvite] = []
    @State private var staffError: String?
    @State private var checkingIn: EventService.Event?
    @State private var events: [EventService.Event] = []
    @State private var loading = true
    @State private var failed = false
    @State private var creating = false
    @State private var hosting: EventService.Event?
    @State private var showTickets = false
    @State private var booking: EventService.Event?
    @State private var bookingCompleted = false
    /// Owned by the SECTION, not the row — a sheet owned by a row in a lazy stack is torn
    /// down when that row scrolls out, which can happen while the user is mid-report.
    @State private var reporting: EventService.Event?

    var body: some View {
        VStack(alignment: .leading, spacing: VoiidSpacing.sm) {
            HStack(spacing: VoiidSpacing.sm) {
                if !managementContext {
                    Text("Events").font(VoiidFont.rounded(17, .semibold)).foregroundColor(VoiidColor.textPrimary)
                }
                Spacer(minLength: 0)
                // Everyone, not just hosts: the wallet is the ATTENDEE's half, and it was the
                // half with no client at all.
                if !managementContext { ticketsButton }
                if isHost && managementContext { createButton }
            }

                ForEach(staffInvites.filter { $0.state == "pending" }) { invite in
                    VStack(alignment: .leading) {
                        Text("Staff invitation: \(invite.title)").font(.headline)
                        Text(invite.role == "volunteer" ? "Check-in access for this event only." : "Event editing, registrations and check-in access.").font(.footnote)
                        Button("Accept invitation") { Task {
                            do { try await EventService.shared.acceptStaff(eventId: invite.event_id); staffInvites = try await EventService.shared.staffInvites(communityId: communityId); await load() }
                            catch { staffError = "Unable to accept invitation. Check membership and expiry." }
                        } }
                    }
                }
                if let staffError { Text(staffError).font(.footnote) }
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
                ForEach(events) { e in
                    row(e)
                    if !isHost && e.can_manage != true && e.can_checkin == true && e.status == "published" {
                        Button("Check in: \(e.title)") { checkingIn = e }
                    }
                }
            }
        }
        .task(id: communityId) {
            await load()
            do { staffInvites = try await EventService.shared.staffInvites(communityId: communityId) }
            catch { staffError = "Unable to load staff invitations." }
        }
        .sheet(item: $booking, onDismiss: {
            if bookingCompleted { bookingCompleted = false; showTickets = true }
        }) { event in
            EventGroupBookingSheet(event: event) { bookingCompleted = true; booking = nil; Task { await load() } }
        }
        .sheet(item: $checkingIn) { e in EventCheckInView(eventId: e.id, eventTitle: e.title) {} }
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
                EventHostView(event: event, canAssignStaff: isHost) { Task { await load() } }
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
        if isHost || e.can_manage == true {
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
        if isHost || e.can_manage == true {
            Label("Manage event", systemImage: "chevron.right")
                .font(VoiidFont.rounded(12, .semibold))
                .foregroundColor(VoiidColor.primary)
        } else if e.your_order_status == "paid" {
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
        } else {
            Button {
                Haptics.tap()
                booking = e
            } label: {
                Text(e.free ? "RSVP" : "Book tickets")
                    .font(VoiidFont.rounded(13, .semibold))
                    .foregroundColor(VoiidColor.textOnPrimary)
                    .padding(.horizontal, VoiidSpacing.md)
                    .padding(.vertical, 6)
                    .background(VoiidColor.primary)
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
        }
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

struct CommunityEarningsView: View {
    let communityId: String
    @Environment(\.dismiss) private var dismiss
    @State private var earnings: EventService.Earnings?
    @State private var error: String?
    @State private var loading = false
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Text("Your earnings").font(.largeTitle.weight(.semibold))
                    Text("Event sales and your organiser share").font(.subheadline).foregroundStyle(.secondary)
                    if loading { ProgressView("Loading earnings") }
                    if let error { Text(error); Button("Retry") { Task { await load() } }.disabled(loading) }
                    if let earnings {
                        VStack(alignment: .leading, spacing: 16) {
                            Label("Your split", systemImage: "chart.pie").font(.headline)
                            HStack(alignment: .firstTextBaseline) {
                                Text("\(Double(10000 - earnings.commission_bps) / 100, specifier: "%.2f")%")
                                    .font(.largeTitle.weight(.semibold)).monospacedDigit()
                                Spacer()
                                Text("Voiid \(Double(earnings.commission_bps) / 100, specifier: "%.2f")%")
                                    .font(.subheadline).foregroundStyle(.secondary)
                            }
                            ProgressView(value: Double(10000 - earnings.commission_bps), total: 10000).tint(VoiidColor.accentInk)
                            Text("Applies to new orders. Existing orders keep their recorded rate.").font(.footnote).foregroundStyle(.secondary)
                        }.padding(22).background(VoiidColor.surfaceCard, in: RoundedRectangle(cornerRadius: 24))
                        ForEach(Array(earnings.totals.enumerated()), id: \.offset) { _, total in
                            VStack(alignment: .leading, spacing: 16) {
                                HStack { Text(total.status.capitalized).font(.headline); Spacer(); Text("\(total.orders) orders").font(.subheadline).foregroundStyle(.secondary) }
                                Text(amount(total.organiser_minor, total.currency)).font(.largeTitle.weight(.semibold))
                                Text("Your share").font(.subheadline).foregroundStyle(.secondary)
                                Divider()
                                LabeledContent("Gross sales", value: amount(total.gross_minor, total.currency))
                                LabeledContent("Voiid commission", value: amount(total.commission_minor, total.currency))
                                if total.unpriced_orders > 0 { Text("Some older orders have no recorded commission.").font(.footnote).foregroundStyle(.secondary) }
                            }.padding(22).background(VoiidColor.surfaceCard, in: RoundedRectangle(cornerRadius: 24))
                        }
                        if earnings.totals.isEmpty { ContentUnavailableView("No earnings yet", systemImage: "banknote", description: Text("Your event orders will appear here.")) }
                        VStack(alignment: .leading, spacing: 10) {
                            Label("Bank settlements", systemImage: "building.columns").font(.headline)
                            Text("Bank account setup will be available after organiser onboarding is connected.")
                            Text("Order totals are before processing fees and taxes. They are not a withdrawable balance.").font(.footnote).foregroundStyle(.secondary)
                        }.padding(22).background(VoiidColor.surfaceCard, in: RoundedRectangle(cornerRadius: 24))
                    }
                }.padding(20)
            }.background(VoiidColor.background)
                .navigationTitle("Earnings").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
                .task { await load() }.refreshable { await load() }
        }
    }
    private func amount(_ minor: String?, _ currency: String) -> String {
        guard let minor, let number = Decimal(string: minor) else { return "Not recorded" }
        return "\(currency) \(NSDecimalNumber(decimal: number / 100).stringValue)"
    }
    @MainActor private func load() async {
        guard !loading else { return }
        loading = true; error = nil
        defer { loading = false }
        do {
            let updated = try await EventService.shared.earnings(communityId: communityId)
            try Task.checkCancellation()
            earnings = updated
        } catch is CancellationError {
            return
        } catch APIError.transport(let underlying) where (underlying as? URLError)?.code == .cancelled {
            return
        } catch let failure as APIError {
            switch failure {
            case .http(let status, _, _) where status == 401 || status == 403:
                earnings = nil
                self.error = status == 403 ? "Only the community owner can view earnings." : "Please sign in again."
            case .http(let status, _, _) where status == 429:
                self.error = "Please wait a moment before refreshing again."
            default:
                self.error = earnings == nil ? "Unable to load earnings. Please try again." : "Couldn't refresh. Showing the last loaded earnings."
            }
        } catch {
            guard !Task.isCancelled, (error as? URLError)?.code != .cancelled else { return }
            self.error = earnings == nil ? "Unable to load earnings. Please try again." : "Couldn't refresh. Showing the last loaded earnings."
        }
    }
}



private struct EventGroupBookingSheet: View {
    let event: EventService.Event
    let onBooked: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var quantity = 1
    @State private var busy = false
    @State private var error: String?
    @State private var checkout: EventService.Checkout?
    @State private var showingCheckout = false
    @State private var submitted = false
    private var maximum: Int { max(1, min(10, event.capacity ?? 10)) }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Text(event.title).font(.largeTitle.weight(.semibold))
                    if let location = event.location_text { Label(location, systemImage: "mappin.and.ellipse").foregroundStyle(.secondary) }
                    VStack(alignment: .leading, spacing: 20) {
                        Text("How many people?").font(.title2.weight(.semibold))
                        Stepper(value: $quantity, in: 1...maximum) {
                            Text("\(quantity) \(quantity == 1 ? "person" : "people")").font(.title3.weight(.medium))
                        }.disabled(busy)
                        Divider()
                        Label("One QR for your whole booking", systemImage: "qrcode").font(.headline)
                        Text("Arrive together. Scanning once checks in everyone in this booking.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }.padding(22).background(VoiidColor.surfaceCard, in: RoundedRectangle(cornerRadius: 24))
                    HStack { Text("Total"); Spacer(); Text(event.free ? "Free" : String(format: "%@ %.2f", event.currency ?? "INR", Double((event.price_minor ?? 0) * quantity) / 100)).font(.title2.weight(.semibold)) }
                    if let error { Text(error).foregroundStyle(VoiidColor.error).font(.subheadline) }
                    Button { Task { await book() } } label: {
                        Text(busy ? "Please wait…" : event.free ? "Reserve \(quantity) \(quantity == 1 ? "place" : "places")" : "Continue to payment")
                            .font(.headline).frame(maxWidth: .infinity).padding(12)
                    }.buttonStyle(.borderedProminent).disabled(busy)
                }.padding(20)
            }.background(VoiidColor.background)
                .navigationTitle("Book tickets").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() }.disabled(busy) } }
        }.interactiveDismissDisabled(busy || showingCheckout)
        .sheet(isPresented: $showingCheckout, onDismiss: { Task { await confirmPayment() } }) {
            if let checkout {
                EventCheckoutView(checkout: checkout) { success in
                    submitted = success; showingCheckout = false
                }.interactiveDismissDisabled()
            }
        }
    }
    private func confirmPayment() async {
        busy = true
        defer { busy = false }
        for _ in 0..<(submitted ? 12 : 1) {
            do {
                if try await EventService.shared.orderStatus(eventId: event.id) == "paid" {
                    Haptics.success(); onBooked(); return
                }
                if submitted { try await Task.sleep(for: .seconds(1)) }
            } catch { break }
        }
        error = submitted ? "Payment confirmation is pending. Your ticket will appear after verification. Check My tickets before paying again." : "Checkout closed. No payment has been confirmed."
    }
    private func book() async {
        guard !busy else { return }
        busy = true; error = nil
        defer { busy = false }
        do {
            let outcome = try await EventService.shared.placeOrder(eventId: event.id, quantity: quantity)
            switch outcome {
            case .ticketed: Haptics.success(); onBooked()
            case let .needsPayment(_, payload):
                checkout = payload; submitted = false; showingCheckout = true
            }
        } catch { self.error = (error as? APIError)?.errorDescription ?? "Unable to reserve places. Refresh the event and try again." }
    }
}
