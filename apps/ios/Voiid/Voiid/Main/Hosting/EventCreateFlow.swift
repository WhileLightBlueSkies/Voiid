//
//  EventCreateFlow.swift
//  Voiid
//
//  Creating an event — three steps, in the shape `CommunityCreateFlow` established: ONE sheet
//  whose content swaps per step, a segmented progress bar and a footer that stay put, and
//  Cancel meaning one thing throughout (abandon the draft) rather than sometimes meaning
//  "back one".
//
//  ── FREE ONLY, AND THAT IS THE SERVER'S CURRENT STATE ────────────────────────────
//  `POST /communities/:id/events` REFUSES A PRICED EVENT WITH A 501 while no payment provider
//  is configured, and `POST /events/:id/orders` refuses to sell one for the same reason. So
//  this wizard has no price field at all: offering one whose only outcome is a 501 would be
//  the same mistake as an RSVP button that cannot work. `EventService.EventDraft` pins
//  `price_minor` to 0 to make that a property of the code rather than of this screen.
//
//  ── HOST ONLY ───────────────────────────────────────────────────────────────────
//  The route is gated on `communityAccess(..., needsAdmin: true)`. The caller only presents
//  this sheet to a manager; that is CONVENIENCE, not enforcement — the server refuses anyone
//  else with a 403 whether or not this screen was reachable.
//

import SwiftUI
import Combine

// MARK: - Draft

/// The event being built. `ObservableObject` rather than `@Observable`, matching
/// `CommunityDraftModel` and the other 48 stores in this app.
final class EventDraftModel: ObservableObject {
    enum Step: Int, CaseIterable, Identifiable {
        case what, when, whereAndWho
        var id: Int { rawValue }

        var title: String {
            switch self {
            case .what:         "Details"
            case .when:         "When"
            case .whereAndWho:  "Place"
            }
        }

        var heading: String {
            switch self {
            case .what:        "What's happening?"
            case .when:        "When is it?"
            case .whereAndWho: "Where, and how many?"
            }
        }

        var subheading: String {
            switch self {
            case .what:        "A name and a line about it. You can edit both later."
            case .when:        "A start time is required. An end time is optional."
            case .whereAndWho: "Both optional. Leave capacity empty for no limit."
            }
        }
    }

    @Published var title = ""
    @Published var about = ""
    /// Defaults to the next round hour a week out — a plausible date beats an empty picker,
    /// and the server rejects nothing about a future one.
    @Published var startsAt: Date = EventDraftModel.defaultStart()
    @Published var hasEnd = false
    @Published var endsAt: Date = EventDraftModel.defaultStart().addingTimeInterval(3600)
    @Published var location = ""
    @Published var limitCapacity = false
    @Published var capacity = 50
    /// Publish immediately, or leave it a draft only organisers can see.
    @Published var publishNow = true

    private static func defaultStart() -> Date {
        let cal = Calendar.current
        let week = Date().addingTimeInterval(7 * 24 * 3600)
        return cal.date(bySettingHour: 19, minute: 0, second: 0, of: week) ?? week
    }

    /// The route's own rule: 1–120 characters after trimming.
    var trimmedTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }
    var titleValid: Bool { !trimmedTitle.isEmpty && trimmedTitle.count <= 120 }

    /// The route 400s an end that is not strictly after the start. Checked here so the user
    /// finds out at the picker rather than at the last step.
    var timesValid: Bool { !hasEnd || endsAt > startsAt }

    func canContinue(_ step: Step) -> Bool {
        switch step {
        case .what:        return titleValid
        case .when:        return timesValid
        case .whereAndWho: return true
        }
    }

    /// ISO-8601 with fractional seconds, which is what every other date this client sends
    /// looks like and what `new Date(...)` on the server parses.
    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    func draft() -> EventService.EventDraft {
        let loc = location.trimmingCharacters(in: .whitespacesAndNewlines)
        let desc = about.trimmingCharacters(in: .whitespacesAndNewlines)
        return EventService.EventDraft(
            title: trimmedTitle,
            description: desc.isEmpty ? nil : desc,
            starts_at: Self.iso.string(from: startsAt),
            ends_at: hasEnd ? Self.iso.string(from: endsAt) : nil,
            location_text: loc.isEmpty ? nil : loc,
            capacity: limitCapacity ? capacity : nil,
            publish: publishNow
        )
    }
}

// MARK: - Flow

struct EventCreateFlow: View {
    let communityId: String
    /// Hands back the event the SERVER created, not the draft — only the server knows its id
    /// and its final status.
    var onCreate: (EventService.Event) -> Void = { _ in }

    @Environment(\.dismiss) private var dismiss
    @StateObject private var draft = EventDraftModel()
    @State private var step: EventDraftModel.Step = .what
    @State private var creating = false
    @State private var createError: String?

    private var stepIndex: Int { step.rawValue }
    private var isLast: Bool { step == .whereAndWho }

    var body: some View {
        NavigationStack {
            ZStack {
                VoiidColor.background.ignoresSafeArea()

                VStack(spacing: 0) {
                    progressBar

                    ScrollView {
                        VStack(alignment: .leading, spacing: VoiidSpacing.lg) {
                            heading

                            switch step {
                            case .what:        whatStep
                            case .when:        whenStep
                            case .whereAndWho: placeStep
                            }
                        }
                        .padding(.horizontal, VoiidSpacing.md)
                        .padding(.top, VoiidSpacing.md)
                        .padding(.bottom, VoiidSpacing.xl)
                    }
                    .scrollIndicators(.hidden)

                    if let createError {
                        Text(createError)
                            .font(VoiidFont.footnote)
                            .foregroundColor(VoiidColor.error)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)
                            .padding(.horizontal, VoiidSpacing.md)
                            .padding(.bottom, VoiidSpacing.xs)
                    }

                    footer
                }
            }
            .navigationTitle("New Event")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { Haptics.tap(); dismiss() }
                        .tint(VoiidColor.textSecondary)
                }
            }
        }
    }

    // MARK: Chrome

    private var progressBar: some View {
        VStack(spacing: 6) {
            HStack(spacing: 5) {
                ForEach(EventDraftModel.Step.allCases) { s in
                    Capsule()
                        .fill(s.rawValue <= stepIndex ? VoiidColor.accent : VoiidColor.divider)
                        .frame(height: 3)
                }
            }

            HStack {
                Text("Step \(stepIndex + 1) of \(EventDraftModel.Step.allCases.count)")
                    .font(VoiidFont.rounded(11.5))
                    .foregroundColor(VoiidColor.textSecondary)
                Spacer(minLength: 0)
                Text(step.title)
                    .font(VoiidFont.rounded(11.5, .semibold))
                    .foregroundColor(VoiidColor.accentInk)
            }
        }
        .padding(.horizontal, VoiidSpacing.md)
        .padding(.top, VoiidSpacing.sm)
        .animation(.easeOut(duration: 0.22), value: stepIndex)
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(step.heading)
                .font(VoiidFont.rounded(23, .bold))
                .foregroundColor(VoiidColor.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Text(step.subheading)
                .font(VoiidFont.rounded(14))
                .foregroundColor(VoiidColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var footer: some View {
        HStack(spacing: VoiidSpacing.sm) {
            if stepIndex > 0 {
                Button {
                    Haptics.tap()
                    withAnimation(.easeOut(duration: 0.2)) {
                        step = EventDraftModel.Step(rawValue: stepIndex - 1) ?? .what
                    }
                } label: {
                    Text("Back")
                        .font(VoiidFont.rounded(15, .semibold))
                        .foregroundColor(VoiidColor.textPrimary)
                        .frame(maxWidth: .infinity).frame(height: 46)
                        .background(Capsule().fill(VoiidColor.surfaceCard))
                        .overlay(Capsule().stroke(VoiidColor.divider, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .disabled(creating)
            }

            Button {
                Haptics.tap()
                if isLast {
                    Task { await create() }
                } else {
                    withAnimation(.easeOut(duration: 0.2)) {
                        step = EventDraftModel.Step(rawValue: stepIndex + 1) ?? .whereAndWho
                    }
                }
            } label: {
                HStack(spacing: 7) {
                    if creating {
                        ProgressView().tint(VoiidColor.textOnAccent)
                    }
                    Text(isLast ? (draft.publishNow ? "Publish event" : "Save draft") : "Continue")
                        .font(VoiidFont.rounded(15, .semibold))
                }
                .foregroundColor(VoiidColor.textOnAccent)
                .frame(maxWidth: .infinity).frame(height: 46)
                .background(Capsule().fill(VoiidColor.accent))
            }
            .buttonStyle(.plain)
            .disabled(creating || !draft.canContinue(step))
            .opacity(draft.canContinue(step) ? 1 : 0.5)
        }
        .padding(.horizontal, VoiidSpacing.md)
        .padding(.vertical, VoiidSpacing.sm)
    }

    // MARK: Step 1 — what

    private var whatStep: some View {
        VStack(alignment: .leading, spacing: VoiidSpacing.md) {
            field("Event name") {
                TextField("Friday Design Jam", text: $draft.title)
                    .font(VoiidFont.rounded(15))
                    .foregroundColor(VoiidColor.textPrimary)
                    .tint(VoiidColor.accent)
            }

            // The route's own ceiling, shown only once it is close enough to matter.
            if draft.trimmedTitle.count > 100 {
                Text("\(draft.trimmedTitle.count)/120")
                    .font(VoiidFont.rounded(11.5))
                    .foregroundColor(draft.trimmedTitle.count > 120
                                     ? VoiidColor.error : VoiidColor.textSecondary)
            }

            field("What's it about?") {
                TextField("An evening of critique, coffee and questionable typography.",
                          text: $draft.about, axis: .vertical)
                    .font(VoiidFont.rounded(15))
                    .foregroundColor(VoiidColor.textPrimary)
                    .tint(VoiidColor.accent)
                    .lineLimit(3...6)
            }

            note("Events are free while ticketing is being built. Voiid can't take payments "
               + "yet, so a price would be a promise the app can't keep.")
        }
    }

    // MARK: Step 2 — when

    private var whenStep: some View {
        VStack(alignment: .leading, spacing: VoiidSpacing.md) {
            VoiidCardSection("Starts") {
                DatePicker("Starts", selection: $draft.startsAt)
                    .datePickerStyle(.compact)
                    .labelsHidden()
                    .tint(VoiidColor.accent)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, VoiidSpacing.md)
                    .padding(.vertical, 11)
            }

            VoiidCardSection("Ends",
                             footer: draft.timesValid ? nil
                                   : "The end has to be after the start.") {
                Toggle("Set an end time", isOn: $draft.hasEnd.animation(.easeOut(duration: 0.18)))
                    .font(.body)
                    .foregroundStyle(VoiidColor.textPrimary)
                    .tint(VoiidColor.accent)
                    .padding(.horizontal, VoiidSpacing.md)
                    .padding(.vertical, 11)

                if draft.hasEnd {
                    VoiidRowDivider(inset: VoiidSpacing.md)
                    DatePicker("Ends", selection: $draft.endsAt)
                        .datePickerStyle(.compact)
                        .labelsHidden()
                        .tint(VoiidColor.accent)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, VoiidSpacing.md)
                        .padding(.vertical, 11)
                }
            }
        }
    }

    // MARK: Step 3 — place and capacity

    private var placeStep: some View {
        VStack(alignment: .leading, spacing: VoiidSpacing.md) {
            field("Where") {
                TextField("The studio, 2nd floor", text: $draft.location)
                    .font(VoiidFont.rounded(15))
                    .foregroundColor(VoiidColor.textPrimary)
                    .tint(VoiidColor.accent)
            }

            // NOT A LOCATION SHARE. `community_events.location_text` is free text on a public
            // listing and is deliberately not wired to the E2EE location pipe — writing it
            // here must never start reading like a pin drop.
            note("Free text on a public listing — not a location share, and not encrypted.")

            VoiidCardSection("Capacity",
                             footer: "The server holds the last seat while somebody is "
                                   + "claiming it, so it can't be oversold.") {
                Toggle("Limit the number of people",
                       isOn: $draft.limitCapacity.animation(.easeOut(duration: 0.18)))
                    .font(.body)
                    .foregroundStyle(VoiidColor.textPrimary)
                    .tint(VoiidColor.accent)
                    .padding(.horizontal, VoiidSpacing.md)
                    .padding(.vertical, 11)

                if draft.limitCapacity {
                    VoiidRowDivider(inset: VoiidSpacing.md)
                    Stepper(value: $draft.capacity, in: 1...5000, step: 5) {
                        Text("\(draft.capacity) people")
                            .font(.body)
                            .foregroundStyle(VoiidColor.textPrimary)
                    }
                    .tint(VoiidColor.accent)
                    .padding(.horizontal, VoiidSpacing.md)
                    .padding(.vertical, 11)
                }
            }

            VoiidCardSection("Visibility",
                             footer: draft.publishNow
                                   ? "Everyone in the community sees it and can RSVP straight away."
                                   : "Only you and the other hosts can see a draft. Publish it "
                                   + "when you're ready.") {
                Toggle("Publish now", isOn: $draft.publishNow.animation(.easeOut(duration: 0.18)))
                    .font(.body)
                    .foregroundStyle(VoiidColor.textPrimary)
                    .tint(VoiidColor.accent)
                    .padding(.horizontal, VoiidSpacing.md)
                    .padding(.vertical, 11)
            }
        }
    }

    // MARK: Pieces

    private func field<Content: View>(_ label: String,
                                      @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(label)
                .font(VoiidFont.rounded(12.5, .semibold))
                .foregroundColor(VoiidColor.textSecondary)
            content()
                .padding(.horizontal, VoiidSpacing.md)
                .padding(.vertical, 12)
                .background(VoiidColor.surfaceCard)
                .clipShape(RoundedRectangle(cornerRadius: VoiidRadius.md, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: VoiidRadius.md, style: .continuous)
                    .stroke(VoiidColor.divider, lineWidth: 1))
        }
    }

    private func note(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(VoiidColor.accentInk)
                .padding(.top, 1)
            Text(text)
                .font(VoiidFont.rounded(12.5))
                .foregroundColor(VoiidColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(VoiidSpacing.md)
        .background(VoiidColor.accentTint)
        .clipShape(RoundedRectangle(cornerRadius: VoiidRadius.md, style: .continuous))
    }

    // MARK: Create

    private func create() async {
        creating = true
        createError = nil
        defer { creating = false }
        do {
            if let event = try await EventService.shared.create(communityId: communityId,
                                                               draft: draft.draft()) {
                Haptics.success()
                onCreate(event)
                dismiss()
            } else {
                // 201 with a body this client could not read. Nothing was lost — the event
                // exists — so say so and let the list reload rather than implying a failure.
                onCreate(EventService.Event.placeholder)
                dismiss()
            }
        } catch {
            createError = error.localizedDescription
        }
    }
}

extension EventService.Event {
    /// A stand-in for the one case where the server created the event but this client could
    /// not decode the echo. It carries no invented data — every field is empty — and its only
    /// job is to tell the caller "reload, something exists now".
    static var placeholder: EventService.Event {
        .init(id: "", title: "", description: nil, starts_at: nil, ends_at: nil,
              location_text: nil, capacity: nil, price_minor: nil, currency: nil,
              status: nil, is_free: nil, your_order_status: nil, suspended: nil)
    }
}
