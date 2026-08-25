//
//  EventCheckInView.swift
//  Voiid
//
//  The door. A host reads a guest's ticket code and `POST /events/:id/check-in` decides
//  whether they get in.
//
//  ── WHY THIS IS TYPED, NOT SCANNED ──────────────────────────────────────────────
//  There is no QR scanner anywhere in this app, and `NSCameraUsageDescription` currently says
//  the camera is for a profile photo. Shipping a scanner means a new capability, a new
//  purpose string and a camera-permission flow — none of which is the thing that was missing.
//  What WAS missing is the ability to check anyone in at all, and the endpoint takes a code
//  either way. So the door reads the code the guest's phone is showing. Adding a scanner
//  later changes how the string arrives here and nothing else on this screen.
//
//  ── EVERY DECISION IS THE SERVER'S ──────────────────────────────────────────────
//  This screen validates nothing. It does not parse the code, does not check the signature,
//  does not decide whether a ticket is spent. A valid signature says "the server minted
//  this"; it does not say "let this person in", and every door system that has collapsed the
//  two has honoured a revoked ticket. So the string goes up whole and the answer comes back
//  whole — including "already used at 19:42", which is the useful answer at a door.
//

import SwiftUI

struct EventCheckInView: View {
    let eventId: String
    let eventTitle: String
    /// Fired after a successful admission so the attendee list behind this can refresh.
    var onAdmitted: () -> Void = {}

    @Environment(\.dismiss) private var dismiss

    @State private var code = ""
    @State private var checking = false
    /// The last verdict, kept apart from `admitted` so a refusal never renders in the shape
    /// of a success.
    @State private var admitted: EventService.CheckIn?
    @State private var refusal: String?
    /// A running tally for this session at the door — how many this device let in.
    @State private var admittedCount = 0

    @FocusState private var codeFocused: Bool

    private var trimmed: String { code.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: VoiidSpacing.md) {
                    VoiidSettingsHeader("Check in",
                                        subtitle: eventTitle.isEmpty
                                                ? "Read the code on the guest's ticket."
                                                : eventTitle)

                    entryCard
                    verdictCard

                    if admittedCount > 0 {
                        Text("\(admittedCount) checked in on this device.")
                            .font(.footnote)
                            .foregroundStyle(VoiidColor.textSecondary)
                            .padding(.horizontal, 4)
                    }
                }
                .padding(.horizontal, VoiidSpacing.md)
                .padding(.top, VoiidSpacing.sm)
                .padding(.bottom, VoiidSpacing.xl)
            }
            .voiidSettingsPage()
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { Haptics.tap(); dismiss() }
                        .tint(VoiidColor.accentInk)
                }
            }
            .onAppear { codeFocused = true }
        }
    }

    private var entryCard: some View {
        VoiidCardSection("Ticket code",
                         footer: "The guest's ticket shows a code that changes every few "
                               + "minutes. If theirs has expired, ask them to refresh it.") {
            HStack(spacing: VoiidSpacing.md) {
                VoiidRowIcon(systemName: "ticket")
                TextField("Paste or type the code", text: $code)
                    .font(.body.monospaced())
                    .foregroundStyle(VoiidColor.textPrimary)
                    .tint(VoiidColor.accent)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($codeFocused)
                    .submitLabel(.go)
                    .onSubmit { Task { await submit() } }
                if checking { ProgressView().tint(VoiidColor.accent) }
            }
            .padding(.horizontal, VoiidSpacing.md)
            .padding(.vertical, 11)

            VoiidRowDivider(inset: VoiidSpacing.md)

            Button {
                Haptics.tap()
                Task { await submit() }
            } label: {
                Text("Check in")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(VoiidColor.accentInk)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(checking || trimmed.isEmpty)
            .opacity(trimmed.isEmpty ? 0.5 : 1)
        }
    }

    @ViewBuilder private var verdictCard: some View {
        if let admitted {
            VoiidCardSection("Admitted") {
                VoiidSettingsRow(icon: "checkmark.circle",
                                 title: admitted.holder_name ?? "Ticket accepted",
                                 detail: admitted.checked_in_at
                                    .flatMap(VoiidEventDate.display)
                                    .map { "Checked in at \($0)" })
            }
        } else if let refusal {
            // Destructive tint, not the accent: a refusal at a door has to be unmistakable
            // across a crowded room.
            VoiidCardSection("Refused") {
                VoiidSettingsRow(icon: "xmark.circle",
                                 title: refusal,
                                 destructive: true)
            }
        }
    }

    private func submit() async {
        let value = trimmed
        guard !value.isEmpty, !checking else { return }
        checking = true
        admitted = nil
        refusal = nil
        defer { checking = false }
        do {
            let result = try await EventService.shared.checkIn(eventId: eventId, code: value)
            if result.ok == true {
                admitted = result
                admittedCount += 1
                code = ""
                codeFocused = true
                Haptics.success()
                onAdmitted()
            } else {
                // A refusal is an ANSWER, not an exception — the service turns the router's
                // `reason` into the sentence the volunteer needs. Anything it could not map
                // still refuses rather than admitting: a door that treats an ambiguous answer
                // as admission is the exact failure this screen exists to avoid.
                refusal = result.message ?? "This ticket wasn't accepted."
                Haptics.error()
            }
        } catch {
            // The server's reason is written FOR the person holding the scanner — "expired,
            // ask them to refresh" and "this is not one of ours" are different conversations
            // at a door — so it is shown rather than replaced with a generic failure.
            refusal = error.localizedDescription
            Haptics.error()
        }
    }
}
