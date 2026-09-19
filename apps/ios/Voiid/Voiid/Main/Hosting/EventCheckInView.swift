import SwiftUI
import AVFoundation

struct EventCheckInView: View {
    let eventId: String
    let eventTitle: String
    /// Fired after a successful admission so the attendee list behind this can refresh.
    var onAdmitted: () -> Void = {}

    @Environment(\.dismiss) private var dismiss

    @State private var code = ""
    @State private var cameraAllowed = false
    @State private var cameraUnavailable = false
    @State private var latched = false
    @Environment(\.scenePhase) private var scenePhase
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

                    if cameraAllowed && !cameraUnavailable {
                        VoiidQRScannerPreview(isScanning: !checking && !latched && scenePhase == .active, torchOn: false,
                            onCode: { value in
                                guard !latched, !checking else { return }
                                latched = true; code = value
                                Task { await submit() }
                            }, onUnavailable: { cameraUnavailable = true }, onTorchStatus: { _, _ in })
                            .frame(height: 280).clipShape(RoundedRectangle(cornerRadius: 24))
                    }
                    if latched {
                        Button("Scan next booking") { code = ""; admitted = nil; refusal = nil; latched = false }
                            .buttonStyle(.borderedProminent).frame(maxWidth: .infinity)
                    }
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
            .task {
                cameraAllowed = AVCaptureDevice.authorizationStatus(for: .video) == .authorized
                if AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined {
                    cameraAllowed = await AVCaptureDevice.requestAccess(for: .video)
                }
            }
        }
    }

    private var entryCard: some View {
        VoiidCardSection("Ticket code",
                         footer: "The guest's ticket shows a code that changes every few "
                               + "minutes. If theirs has expired, ask them to refresh it.") {
            HStack(spacing: VoiidSpacing.md) {
                VoiidRowIcon(systemName: "ticket")
                TextField("Paste or type the code", text: $code)
                    .font(.body.monospacedDigit())
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
                                 title: "\(admitted.people ?? 1) \((admitted.people ?? 1) == 1 ? "person" : "people") admitted",
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
        latched = true
        checking = true
        admitted = nil
        refusal = nil
        defer { checking = false }
        do {
            let result = try await EventService.shared.checkIn(eventId: eventId, code: value)
            if result.ok == true {
                admitted = result
                admittedCount += result.people ?? 1
                code = ""
                codeFocused = false
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
