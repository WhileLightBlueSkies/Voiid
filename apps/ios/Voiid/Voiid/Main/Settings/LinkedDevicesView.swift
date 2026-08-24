//
//  LinkedDevicesView.swift
//  Voiid
//
//  Spec §5.3. Answers one question — "what is signed in to my account, and can I stop
//  it?" — and refuses to answer any question the backend cannot actually answer.
//
//  THREE DECISIONS WORTH READING BEFORE EDITING THIS FILE
//  -----------------------------------------------------
//  1. The current device is unrevocable *structurally*, not conditionally. It lives in
//     its own hand-built card, with no removal affordance anywhere in its ancestry — the
//     card is deliberately NOT a shared row type that could grow one. There is no
//     `if device.isCurrent { }` guarding a shared row builder, because that guard is one careless refactor away from letting a user sign their own
//     handset out of an account they are actively using.
//
//  2. No device id ever reaches the screen. `DELETE /v1/devices/:device_id` is not
//     ownership-scoped on the backend (routes/devices.ts:104), so a rendered — worse, a
//     selectable — device id is a live handle for revoking someone else's device. The id
//     exists in this file solely as `ForEach` identity and as the argument to
//     `DeviceDirectoryService.revoke`.
//
//  3. There is no "Link a Device" button, and this is not an oversight. The backend's
//     linking routes (routes/linking.ts) pair a *web companion*: the web client posts its
//     own keys for a `link_token`, shows it as a QR, and an existing device scans and
//     approves it. iOS can only ever be the approver, and approving means scanning a QR —
//     camera capture, a permission string, a scanner surface, an approval screen. Until
//     that exists, a button here would open nothing. See the long note in
//     `DeviceDirectoryService.swift`.
//
//  What the screen does NOT claim: nothing here reports whether a device is currently
//  online, because the server exposes no such field. "Last active" is `last_seen_at` and
//  is labelled as exactly that.
//

import SwiftUI

struct LinkedDevicesView: View {

    // MARK: Load state

    private enum Phase {
        case loading
        case loaded
        case failed(String)
    }

    @State private var phase: Phase = .loading
    @State private var devices: [LinkedDevice] = []

    /// Set when a swipe asks to remove a device; drives the confirmation dialog.
    @State private var deviceToRemove: LinkedDevice?

    /// A revoke (or a pull-to-refresh over a good list) that failed. Shown inline under
    /// the list instead of replacing it — losing the whole screen because one request
    /// timed out is a worse answer than the list plus an explanation.
    @State private var removalError: String?

    /// The device this app is running on, as registered with the backend. `nil` before
    /// E2E bootstrap has ever completed, or if the E2E keychain was cleared.
    private var currentDeviceID: String? { E2EManager.shared.deviceId }

    private var thisDevice: LinkedDevice? {
        guard let currentDeviceID else { return nil }
        return devices.first { $0.id == currentDeviceID }
    }

    private var otherDevices: [LinkedDevice] {
        devices.filter { $0.id != currentDeviceID }
    }

    // MARK: Body

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: VoiidSpacing.md) {
                // The badge states the guarantee above the phase switch rather than inside it,
                // so it holds while the list is still loading or has failed — those are exactly
                // the moments a user wonders what is happening to their account, and the answer
                // does not depend on the request succeeding.
                VoiidSettingsHeader(
                    "Linked Devices",
                    subtitle: "Manage devices connected to your Voiid account.",
                    badge: (icon: "lock.fill", text: "End-to-end encrypted")
                )

                switch phase {
                case .loading:
                    loadingSection
                case .failed(let message):
                    failureSection(message)
                case .loaded:
                    loadedSections
                }
            }
            .padding(VoiidSpacing.md)
        }
        .voiidSettingsPage()
        .task { await load(showingSpinner: true) }
        .refreshable { await load(showingSpinner: false) }
        .confirmationDialog(
            "Remove this device?",
            isPresented: removalDialogIsPresented,
            titleVisibility: .visible,
            presenting: deviceToRemove
        ) { device in
            Button("Remove", role: .destructive) {
                Task { await remove(device) }
            }
            Button("Cancel", role: .cancel) { }
        } message: { _ in
            Text("It will stop receiving new messages.")
        }
    }

    // MARK: - Sections

    private var loadingSection: some View {
        VoiidCardSection {
            HStack {
                Spacer()
                ProgressView()
                    .tint(VoiidColor.primary)
                Spacer()
            }
            .padding(.vertical, VoiidSpacing.md)
            .accessibilityElement()
            .accessibilityLabel("Loading devices")
        }
    }

    private func failureSection(_ message: String) -> some View {
        VoiidCardSection {
            VStack(alignment: .leading, spacing: VoiidSpacing.sm) {
                Text(message)
                    .font(.body)
                    .foregroundStyle(VoiidColor.error)
                    .fixedSize(horizontal: false, vertical: true)

                Button("Try Again") {
                    Task { await load(showingSpinner: true) }
                }
                .font(.body.weight(.semibold))
                .foregroundStyle(VoiidColor.primary)
                // Keeps the tap target on the button rather than letting the row
                // promote the whole block to one control.
                .buttonStyle(.borderless)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(VoiidSpacing.md)
        }
    }

    @ViewBuilder
    private var loadedSections: some View {
        // Section 1 — this device. Rendered only when the backend list actually contains
        // it. If our device id is absent from an authoritative list of ACTIVE devices,
        // this device has been revoked server-side; drawing "This device — Signed in"
        // anyway would assert something the server just denied.
        if let thisDevice {
            VStack(alignment: .leading, spacing: 6) {
                Text("This device")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(VoiidColor.textSecondary)
                    .padding(.leading, 4)

                currentCard(thisDevice)

                Text("Signing in to Voiid on another iPhone signs this one out — Voiid keeps one iPhone per account.")
                    .font(.footnote)
                    .foregroundStyle(VoiidColor.textSecondary)
                    .padding(.horizontal, 4)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }

        if currentDeviceID == nil {
            // We cannot tell which row is the phone in the user's hand, so nothing is
            // removable: a wrong guess here signs the user out of their own account.
            VoiidCardSection(
                "Devices",
                footer: "Voiid can't tell which of these is the iPhone you're using right now, so devices can't be removed here — removing the wrong one would sign you out. Pull down to refresh."
            ) {
                if devices.isEmpty {
                    emptyRow("No devices are signed in.")
                } else {
                    ForEach(Array(devices.enumerated()), id: \.element.id) { index, device in
                        DeviceRow(
                            symbol: device.symbol,
                            name: device.name,
                            detail: lastActive(device),
                            label: label(for: device)
                        )
                        if index < devices.count - 1 { VoiidRowDivider() }
                    }
                }
                inlineError
            }
        } else {
            VoiidCardSection(
                "Other devices",
                footer: "Removing a device stops it receiving new messages straight away. Anything already downloaded to that device stays on it. Devices are added when you sign in to Voiid on a new device."
            ) {
                if otherDevices.isEmpty {
                    emptyRow("No other devices are signed in.")
                } else {
                    ForEach(Array(otherDevices.enumerated()), id: \.element.id) { index, device in
                        DeviceRow(
                            symbol: device.symbol,
                            name: device.name,
                            detail: lastActive(device),
                            label: label(for: device)
                        ) {
                            // The remove affordance is attached by the CALLER, never built into
                            // DeviceRow — which is what keeps "this device" unrevocable by
                            // construction rather than by condition. The card design has no
                            // swipe gesture, so the same intent is expressed as a menu.
                            Menu {
                                Button(role: .destructive) {
                                    Haptics.rigid()
                                    removalError = nil
                                    deviceToRemove = device
                                } label: {
                                    Label("Remove", systemImage: "trash")
                                }
                            } label: {
                                Image(systemName: "ellipsis")
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundStyle(VoiidColor.textSecondary)
                                    .frame(width: 30, height: 40)
                                    .contentShape(Rectangle())
                            }
                            .accessibilityLabel("Options for \(device.name)")
                        }
                        if index < otherDevices.count - 1 { VoiidRowDivider() }
                    }
                }
                inlineError
            }
        }
    }

    /// The device you are holding. Accent-bordered and labelled, because the one mistake this
    /// screen must prevent is someone signing themselves out. Hand-built rather than a
    /// `VoiidCardSection` precisely so no removal affordance can ever be attached to it.
    private func currentCard(_ device: LinkedDevice) -> some View {
        HStack(spacing: VoiidSpacing.md) {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(VoiidColor.accent.opacity(0.12))
                .frame(width: 52, height: 52)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(VoiidColor.accent.opacity(0.4), lineWidth: 1)
                )
                .overlay {
                    Image(systemName: device.symbol)
                        .font(.system(size: 22, weight: .regular))
                        .foregroundStyle(VoiidColor.accentInk)
                }

            VStack(alignment: .leading, spacing: 2) {
                Text(device.name)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(VoiidColor.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 5) {
                    Circle()
                        .fill(VoiidColor.accent)
                        .frame(width: 6, height: 6)
                    Text("Signed in")
                        .font(.footnote)
                        .foregroundStyle(VoiidColor.accentInk)
                }
                .padding(.top, 1)
            }

            Spacer(minLength: VoiidSpacing.sm)

            HStack(spacing: 4) {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .bold))
                Text("Current device")
                    .font(.caption.weight(.semibold))
            }
            .foregroundStyle(VoiidColor.textOnAccent)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Capsule().fill(VoiidColor.accent))
            .fixedSize()
        }
        .padding(VoiidSpacing.md)
        .background(VoiidColor.accent.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(VoiidColor.accent, lineWidth: 1.5)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(device.name), this device, signed in")
    }

    @ViewBuilder
    private var inlineError: some View {
        if let removalError {
            Text(removalError)
                .font(.footnote)
                .foregroundStyle(VoiidColor.error)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, VoiidSpacing.md)
                .padding(.vertical, 11)
        }
    }

    /// A non-interactive placeholder row. Not a button, not a link — there is nothing to
    /// tap, and dressing it up as tappable would be its own small lie.
    private func emptyRow(_ text: String) -> some View {
        Text(text)
            .font(.body)
            .foregroundStyle(VoiidColor.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, VoiidSpacing.md)
            .padding(.vertical, 11)
    }


    // MARK: - Copy helpers

    /// `nil` when the server has never recorded a check-in for the device, so the row
    /// shows no second line instead of guessing at one.
    private func lastActive(_ device: LinkedDevice) -> String? {
        guard let seen = device.lastSeen else { return nil }
        return "Last active \(seen.formatted(.relative(presentation: .named)))"
    }

    private func label(for device: LinkedDevice) -> String {
        if let detail = lastActive(device) { return "\(device.name), \(detail)" }
        return device.name
    }

    // MARK: - Dialog plumbing

    private var removalDialogIsPresented: Binding<Bool> {
        Binding(
            get: { deviceToRemove != nil },
            set: { presented in if !presented { deviceToRemove = nil } }
        )
    }

    // MARK: - Actions

    private func load(showingSpinner: Bool) async {
        if showingSpinner { phase = .loading }
        do {
            devices = try await DeviceDirectoryService.shared.devices()
            removalError = nil
            phase = .loaded
        } catch {
            // A cold load has nothing to keep, so the failure takes the screen. A refresh
            // over an already-good list keeps the list and reports the failure inline.
            if showingSpinner || devices.isEmpty {
                phase = .failed(describe(error))
            } else {
                removalError = describe(error)
            }
        }
    }

    private func remove(_ device: LinkedDevice) async {
        do {
            try await DeviceDirectoryService.shared.revoke(deviceID: device.id)
            Haptics.success()
            await load(showingSpinner: false)
        } catch {
            Haptics.error()
            removalError = describe(error)
        }
    }

    private func describe(_ error: Error) -> String {
        (error as? APIError)?.errorDescription ?? error.localizedDescription
    }
}

// MARK: - Row

/// One device. Used by both sections; the *remove* affordance is never part of it —
/// callers that permit removal attach their own trailing affordance, which is what keeps
/// "this device" unrevocable by construction rather than by condition.
private struct DeviceRow<Trailing: View>: View {
    let symbol: String
    let name: String
    let detail: String?
    let label: String
    /// Whatever the caller puts on the trailing edge — a removal menu, or nothing at all.
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: VoiidSpacing.md) {
            VoiidRowIcon(systemName: symbol)

            VStack(alignment: .leading, spacing: 1) {
                Text(name)
                    .font(.body)
                    .foregroundStyle(VoiidColor.textPrimary)
                    .multilineTextAlignment(.leading)
                if let detail {
                    Text(detail)
                        .font(.footnote)
                        .foregroundStyle(VoiidColor.textSecondary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: VoiidSpacing.sm)

            trailing
        }
        .padding(.horizontal, VoiidSpacing.md)
        .padding(.vertical, 11)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label)
    }
}

extension DeviceRow where Trailing == EmptyView {
    init(symbol: String, name: String, detail: String?, label: String) {
        self.init(symbol: symbol, name: name, detail: detail, label: label) { EmptyView() }
    }
}
