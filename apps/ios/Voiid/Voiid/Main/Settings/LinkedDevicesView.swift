//
//  LinkedDevicesView.swift
//  Voiid
//
//  Spec §5.3. Answers one question — "what is signed in to my account, and can I stop
//  it?" — and refuses to answer any question the backend cannot actually answer.
//
//  Design reference: Voiid Ui/Chat/LinkedDevicesScreen.swift — a native inset-grouped List
//  under the system large title, so swipe-to-remove, long-press menus, push-to-detail,
//  Dynamic Type and VoiceOver come from the platform.
//
//  THREE DECISIONS WORTH READING BEFORE EDITING THIS FILE
//  -----------------------------------------------------
//  1. The current device is unrevocable *structurally*, not conditionally. Its section
//     renders `DeviceRow` bare; the swipe action, context menu and detail link are attached
//     only inside the OTHER-devices ForEach. There is no `if device.isCurrent { }` guarding a
//     shared row builder, because that guard is one careless refactor away from letting a
//     user sign their own handset out of an account they are actively using.
//
//  2. Browser linking has its own scanner and explicit approval sheet. The general
//     profile scanner cannot grant account access. The current phone authenticates
//     locally, then the server validates its active device and the previewed key.
//
//  3. When this phone's device id is unknown, NOTHING is removable — a wrong guess signs
//     the user out of their own account.
//
//  What the screen does NOT claim: nothing here reports whether another device is online,
//  where it is, or its IP, because the server exposes none of that. "Last active" is
//  `last_seen_at` and is labelled as exactly that.
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
    @State private var showingLinkBrowser = false
    @State private var showingHelp = false
    @State private var confirmingRemoveAll = false
    @State private var working = false

    /// Set when a swipe, menu or detail asks to remove a device; drives the dialog.
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

    /// "Linked browsers" when that is all they are — Voiid keeps one phone per account, so
    /// that is the normal case — otherwise the honest general term.
    private var othersTitle: String {
        otherDevices.allSatisfy { $0.platform.lowercased() == "web" } ? "Linked browsers" : "Other devices"
    }

    // MARK: Body

    var body: some View {
        List {
            linkSection

            switch phase {
            case .loading:
                Section {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .accessibilityLabel("Loading devices")
                }
            case .failed(let message):
                Section {
                    Text(message).foregroundStyle(VoiidColor.error)
                    Button("Try Again") { Task { await load(showingSpinner: true) } }
                }
            case .loaded:
                loadedSections
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .softScrollEdge()
        .background(VoiidColor.background.ignoresSafeArea())
        .font(.system(.body, design: .rounded))
        .tint(VoiidColor.accentInk)
        .navigationTitle("Linked Devices")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("How linking works", systemImage: "questionmark.circle") { showingHelp = true }
            }
        }
        .animation(.default, value: devices)
        .sheet(isPresented: $showingLinkBrowser, onDismiss: {
            Task { await load(showingSpinner: false) }
        }) { LinkBrowserView() }
        .sheet(isPresented: $showingHelp) { LinkedDevicesHelpSheet() }
        .task { await load(showingSpinner: true) }
        .refreshable { await load(showingSpinner: false) }
        .confirmationDialog(
            "Remove this device?",
            isPresented: removalDialogIsPresented,
            titleVisibility: .visible,
            presenting: deviceToRemove
        ) { device in
            Button("Remove", role: .destructive) { Task { await remove([device]) } }
            Button("Cancel", role: .cancel) { }
        } message: { device in
            // What actually happens, not "are you sure".
            Text("\(device.name) will be signed out and stop receiving new messages. Linking it again takes a new QR scan from this phone.")
        }
        .confirmationDialog("Log out all other devices?",
                            isPresented: $confirmingRemoveAll,
                            titleVisibility: .visible) {
            Button("Log Out \(otherDevices.count) Devices", role: .destructive) {
                Task { await remove(otherDevices) }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This phone stays signed in. Every other device is signed out immediately.")
        }
    }

    // MARK: - Sections

    /// The one thing people come here to DO, so it leads — above the list, not after it.
    private var linkSection: some View {
        Section {
            VStack(spacing: VoiidSpacing.md) {
                Image(systemName: "laptopcomputer.and.iphone")
                    .font(.system(size: 40))
                    .foregroundStyle(VoiidColor.accentInk)
                    .symbolRenderingMode(.hierarchical)
                    .padding(.top, VoiidSpacing.sm)
                    .accessibilityHidden(true)

                Text("Use Voiid on your computer. Messages stay end-to-end encrypted on every device you link.")
                    .font(.system(.subheadline, design: .rounded))
                    .foregroundStyle(VoiidColor.textSecondary)
                    .multilineTextAlignment(.center)

                Button {
                    Haptics.tap()
                    showingLinkBrowser = true
                } label: {
                    Label("Link a Browser", systemImage: "qrcode.viewfinder")
                        .font(.system(.body, design: .rounded, weight: .semibold))
                        .frame(maxWidth: .infinity)
                }
                .prominentAction()
                // Approval needs to know which device is doing the approving.
                .disabled(currentDeviceID == nil)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, VoiidSpacing.xs)
        }
    }

    @ViewBuilder
    private var loadedSections: some View {
        // This device. Rendered only when the backend list actually contains it: if our id
        // is absent from an authoritative list of ACTIVE devices, this device has been
        // revoked server-side, and drawing "This device" anyway would assert something the
        // server just denied.
        if let thisDevice {
            Section {
                DeviceRow(device: thisDevice, isCurrent: true)
            } header: {
                Text("This device")
            } footer: {
                Text("Signing in to Voiid on another phone signs this one out. Voiid keeps one phone per account.")
            }
        }

        if currentDeviceID == nil {
            Section {
                if devices.isEmpty {
                    emptyRow("No devices are signed in.")
                } else {
                    ForEach(devices) { DeviceRow(device: $0, isCurrent: false) }
                }
                inlineError
            } header: {
                Text("Devices")
            } footer: {
                Text("Voiid can't tell which of these is the phone you're using right now, so devices can't be removed here — removing the wrong one would sign you out. Pull down to refresh.")
            }
        } else {
            Section {
                if otherDevices.isEmpty {
                    emptyRow("No browsers are linked.")
                } else {
                    ForEach(otherDevices) { device in
                        // Removal is attached HERE, never inside DeviceRow — see decision 1.
                        NavigationLink {
                            LinkedDeviceDetail(device: device) { deviceToRemove = device }
                        } label: {
                            DeviceRow(device: device, isCurrent: false)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button("Remove", systemImage: "trash", role: .destructive) {
                                askToRemove(device)
                            }
                        }
                        .contextMenu {
                            Button("Remove", systemImage: "trash", role: .destructive) {
                                askToRemove(device)
                            }
                        }
                    }
                }
                inlineError
            } header: {
                Text(othersTitle)
            } footer: {
                Text("Removing a device stops it receiving new messages straight away. Anything it already downloaded stays on it.")
            }

            if otherDevices.count > 1 {
                Section {
                    Button(role: .destructive) {
                        Haptics.rigid()
                        removalError = nil
                        confirmingRemoveAll = true
                    } label: {
                        HStack {
                            Spacer()
                            if working { ProgressView() } else { Text("Log Out All Other Devices") }
                            Spacer()
                        }
                    }
                    .disabled(working)
                }
            }
        }
    }

    @ViewBuilder
    private var inlineError: some View {
        if let removalError {
            Text(removalError)
                .font(.footnote)
                .foregroundStyle(VoiidColor.error)
        }
    }

    /// A non-interactive placeholder row. Not a button, not a link — there is nothing to tap.
    private func emptyRow(_ text: String) -> some View {
        Text(text)
            .font(.system(.subheadline, design: .rounded))
            .foregroundStyle(VoiidColor.textSecondary)
    }

    // MARK: - Dialog plumbing

    private func askToRemove(_ device: LinkedDevice) {
        Haptics.rigid()
        removalError = nil
        deviceToRemove = device
    }

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

    /// Revokes each device in turn and reloads. Never receives the current device: every
    /// caller draws from `otherDevices` or a row inside it.
    private func remove(_ targets: [LinkedDevice]) async {
        working = true; defer { working = false }
        var failure: Error?
        for device in targets where device.id != currentDeviceID {
            do { try await DeviceDirectoryService.shared.revoke(deviceID: device.id) }
            catch { failure = error }
        }
        if let failure {
            Haptics.error()
            removalError = describe(failure)
        } else {
            Haptics.success()
        }
        await load(showingSpinner: false)
    }

    private func describe(_ error: Error) -> String {
        (error as? APIError)?.errorDescription ?? error.localizedDescription
    }
}

// MARK: - Row

/// One device. Deliberately carries NO removal affordance — see decision 1.
private struct DeviceRow: View {
    let device: LinkedDevice
    let isCurrent: Bool

    private var detail: String? {
        if isCurrent { return "Active now" }
        return device.lastSeen.map { "Last active \($0.formatted(.relative(presentation: .named)))" }
    }

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: device.symbol)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(isCurrent ? VoiidColor.textOnAccent : VoiidColor.accentInk)
                .frame(width: 38, height: 38)
                .background(isCurrent ? VoiidColor.accent : VoiidColor.accentTint,
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(device.name)
                    .font(.system(.body, design: .rounded, weight: .semibold))
                    .foregroundStyle(VoiidColor.textPrimary)

                if let detail {
                    HStack(spacing: 5) {
                        if isCurrent {
                            Circle().fill(VoiidColor.success).frame(width: 7, height: 7)
                        }
                        Text(detail)
                            .foregroundStyle(isCurrent ? VoiidColor.onlineText : VoiidColor.textSecondary)
                    }
                    .font(.system(.subheadline, design: .rounded))
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel([device.name, isCurrent ? "this device" : nil, detail]
            .compactMap { $0 }.joined(separator: ", "))
    }
}

// MARK: - Detail

private struct LinkedDeviceDetail: View {
    let device: LinkedDevice
    var onRemove: () -> Void

    @Environment(\.dismiss) private var dismiss

    private var platform: String {
        switch device.platform.lowercased() {
        case "web": return "Voiid Web"
        case "ios": return "iPhone"
        case "android": return "Android"
        default: return device.platform.isEmpty ? "Unknown" : device.platform
        }
    }

    var body: some View {
        List {
            Section {
                VStack(spacing: 10) {
                    Image(systemName: device.symbol)
                        .font(.system(size: 34))
                        .foregroundStyle(VoiidColor.accentInk)
                        .frame(width: 72, height: 72)
                        .background(VoiidColor.accentTint,
                                    in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    Text(device.name)
                        .font(.system(.title2, design: .rounded, weight: .bold))
                        .foregroundStyle(VoiidColor.textPrimary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .listRowBackground(Color.clear)
            }

            Section {
                LabeledContent("App", value: platform)
                LabeledContent("Last active",
                               value: device.lastSeen?.formatted(date: .abbreviated, time: .shortened) ?? "Not yet")
            } footer: {
                Text("Don't recognise this device? Remove it. Whoever is using it loses access to new messages immediately.")
            }

            Section {
                Button(role: .destructive) {
                    Haptics.tap()
                    dismiss()
                    // Let the pop finish before the dialog, or it anchors to a view that's leaving.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { onRemove() }
                } label: {
                    Text("Remove Device").frame(maxWidth: .infinity)
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .softScrollEdge()
        .background(VoiidColor.background.ignoresSafeArea())
        .font(.system(.body, design: .rounded))
        .navigationTitle("Device")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Help

private struct LinkedDevicesHelpSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                item("qrcode.viewfinder", "Linking",
                     "Open Voiid Web on a computer and scan its QR code with this phone. Nothing is linked until you check the code matches and confirm with Face ID or your passcode.")
                item("lock.fill", "Encryption",
                     "Each browser has its own keys. Messages are end-to-end encrypted to every linked device.")
                item("iphone", "One phone per account",
                     "Signing in on another phone signs this one out.")
                item("hand.raised.fill", "Something you don't recognise",
                     "Remove it. It stops receiving new messages at once.")
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .softScrollEdge()
            .background(VoiidColor.background.ignoresSafeArea())
            .navigationTitle("How Linking Works")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .tint(VoiidColor.accentInk)
        .presentationDetents([.medium, .large])
    }

    private func item(_ icon: String, _ title: String, _ body: String) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(.body, design: .rounded, weight: .semibold))
                    .foregroundStyle(VoiidColor.textPrimary)
                Text(body)
                    .font(.system(.subheadline, design: .rounded))
                    .foregroundStyle(VoiidColor.textSecondary)
            }
        } icon: {
            Image(systemName: icon).foregroundStyle(VoiidColor.accentInk)
        }
        .padding(.vertical, 4)
    }
}
