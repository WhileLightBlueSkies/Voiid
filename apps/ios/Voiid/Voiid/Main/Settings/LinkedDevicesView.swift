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
//     its own section, built by its own row, with no `.swipeActions` modifier anywhere in
//     its ancestry. There is no `if device.isCurrent { }` guarding a shared row builder,
//     because that guard is one careless refactor away from letting a user sign their own
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
        List {
            switch phase {
            case .loading:
                loadingSection
            case .failed(let message):
                failureSection(message)
            case .loaded:
                loadedSections
            }
        }
        .voiidSettingsList()
        .background(VoiidColor.background.ignoresSafeArea())
        .navigationTitle("Linked Devices")
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
        SettingsSection {
            HStack {
                Spacer()
                ProgressView()
                    .tint(VoiidColor.primary)
                Spacer()
            }
            .padding(.vertical, VoiidSpacing.sm)
            .accessibilityElement()
            .accessibilityLabel("Loading devices")
        }
    }

    private func failureSection(_ message: String) -> some View {
        SettingsSection {
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
                // Keeps the tap target on the button rather than letting the List
                // promote the whole row to one control.
                .buttonStyle(.borderless)
            }
            .padding(.vertical, VoiidSpacing.xs)
        }
    }

    @ViewBuilder
    private var loadedSections: some View {
        // Section 1 — this device. Rendered only when the backend list actually contains
        // it. If our device id is absent from an authoritative list of ACTIVE devices,
        // this device has been revoked server-side; drawing "This device — Signed in"
        // anyway would assert something the server just denied.
        if let thisDevice {
            SettingsSection(
                "This device",
                footer: "Signing in to Voiid on another iPhone signs this one out — Voiid keeps one iPhone per account."
            ) {
                DeviceRow(
                    symbol: "iphone",
                    name: thisDevice.name,
                    detail: "Signed in",
                    label: "\(thisDevice.name), this device, signed in"
                )
            }
        }

        if currentDeviceID == nil {
            // We cannot tell which row is the phone in the user's hand, so nothing is
            // removable: a wrong guess here signs the user out of their own account.
            SettingsSection(
                "Devices",
                footer: "Voiid can't tell which of these is the iPhone you're using right now, so devices can't be removed here — removing the wrong one would sign you out. Pull down to refresh."
            ) {
                if devices.isEmpty {
                    emptyRow("No devices are signed in.")
                } else {
                    ForEach(devices) { device in
                        DeviceRow(
                            symbol: device.symbol,
                            name: device.name,
                            detail: lastActive(device),
                            label: label(for: device)
                        )
                    }
                }
                inlineError
            }
        } else {
            SettingsSection(
                "Other devices",
                footer: "Removing a device stops it receiving new messages straight away. Anything already downloaded to that device stays on it. Devices are added when you sign in to Voiid on a new device."
            ) {
                if otherDevices.isEmpty {
                    emptyRow("No other devices are signed in.")
                } else {
                    ForEach(otherDevices) { device in
                        DeviceRow(
                            symbol: device.symbol,
                            name: device.name,
                            detail: lastActive(device),
                            label: label(for: device)
                        )
                        .swipeActions(edge: .trailing) {
                            Button("Remove", role: .destructive) {
                                Haptics.rigid()
                                removalError = nil
                                deviceToRemove = device
                            }
                        }
                    }
                }
                inlineError
            }
        }
    }

    @ViewBuilder
    private var inlineError: some View {
        if let removalError {
            Text(removalError)
                .font(.footnote)
                .foregroundStyle(VoiidColor.error)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// A non-interactive placeholder row. Not a button, not a link — there is nothing to
    /// tap, and dressing it up as tappable would be its own small lie.
    private func emptyRow(_ text: String) -> some View {
        Text(text)
            .font(.body)
            .foregroundStyle(VoiidColor.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
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
/// callers that permit removal attach `.swipeActions` themselves, which is what keeps
/// "this device" unrevocable by construction rather than by condition.
private struct DeviceRow: View {
    let symbol: String
    let name: String
    let detail: String?
    let label: String

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.body)
                    .foregroundStyle(VoiidColor.textPrimary)
                if let detail {
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(VoiidColor.textSecondary)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol)
                .foregroundStyle(VoiidColor.primary)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label)
    }
}
