//
//  PrivacySettingsView.swift
//  Voiid
//
//  Settings → Privacy. Spec §5.2.
//
//  Three toggles, and that is the whole screen. Each one is backed by
//  `PrivacySettings.shared` (raw UserDefaults, see Models/PrivacySettings.swift) and each
//  one has a consumer that genuinely reads it:
//
//      Send read receipts        ChatStore.syncMessages — both `ChatEngine.markRead`
//                                call sites in Models/Stores.swift
//      Send typing indicators    ChatDetailView — both `WebSocketClient.sendTyping`
//                                call sites
//      Show when contacts are    ChatDetailView.presenceText — the online / last-seen
//      online                    line under the chat title
//
//  What is deliberately absent, and why
//  ------------------------------------
//  No blocking (there is no block/unblock route on the backend and no client code for
//  one), no last-seen visibility, no profile-photo visibility, no disappearing messages,
//  no screenshot blocking, no "who can add me to groups". Every one of those has zero
//  schema, zero route and zero client code, so shipping a control for it would be an
//  advertisement for a feature that does not exist.
//
//  No app lock and no PIN row either. There is no `LocalAuthentication` import anywhere
//  in this app — no biometric or passcode gate exists to switch on. The only PIN Voiid
//  has is the *backup* PIN that wraps the backup master secret, and it already has a
//  home: Settings → Backup & Recovery → Change PIN. Duplicating it here would imply it
//  locks the app, which it does not.
//
//  And there is no footer explaining any of that. A Settings screen states what it does;
//  it does not narrate what it lacks.
//
//  Every footer below is load-bearing. Each of these toggles creates a reasonable and
//  wrong assumption — that turning receipts off also hides other people's receipts from
//  you, that hiding the presence line hides you from others — and the footer's job is to
//  correct it in its first sentence, before the user acts on the wrong belief.
//

import SwiftUI

struct PrivacySettingsView: View {

    @ObservedObject private var settings = PrivacySettings.shared
    // Feature (B) — the Map — mirrors Ghost Mode and the kill switch here (§8). Unlike the
    // three toggles above, these are backed by real state with real consumers: Ghost Mode
    // is a hard local gate on `MapPresenceEngine`'s emission, and the kill switch ends every
    // outbound share. They are not display-only.
    @ObservedObject private var mapVisibility = MapVisibilityState.shared
    @ObservedObject private var mapEngine = MapPresenceEngine.shared
    // Stories view receipts — default OFF, backed by real state with a real consumer:
    // StoryEngine reads it before sending ANY receipt and before reading the viewer list.
    @ObservedObject private var storySettings = StorySettings.shared
    // Contact PIN — how someone who finds you by @username is allowed to message you.
    @State private var pinState: ContactPinService.PinState?
    @State private var pinBusy = false
    @State private var pinError: String?
    @State private var confirmRotate = false

    var body: some View {
        List {

            // MARK: Contact PIN (reachability by @username)

            // ONE short footer, not three paragraphs. The old copy explained the storage
            // model, the mutual-contact exception and the rotation semantics before the user
            // had seen their own PIN — a wall of text where a number belongs. The card below
            // shows the PIN; the sentence says what it's for; everything else moved to the
            // moment it becomes relevant (the rotate confirmation).
            SettingsSection(
                "Contact PIN",
                footer: "Share this with people who find you by @username. They'll need it to "
                    + "message you — and you still choose whether to accept."
            ) {
                ContactPinCard(
                    pin: pinState?.pin,
                    hasPin: pinState?.has_pin == true,
                    storageConfigured: pinState?.storage_configured ?? true,
                    busy: pinBusy,
                    onRegenerate: {
                        Haptics.tap()
                        // Replacing an existing PIN locks out everyone holding the old one, so
                        // it is confirmed. Creating the first one cannot break anything.
                        if pinState?.has_pin == true { confirmRotate = true } else { rotatePin() }
                    }
                )
                if let pinError {
                    Text(pinError)
                        .font(.footnote)
                        .foregroundStyle(VoiidColor.error)
                }
            }

            // MARK: Who can see (server-enforced visibility)

            SettingsSection(
                "Who can see my info",
                footer: """
                    Choose who can see your last seen & online, profile photo, and about. \
                    “My Contacts” means people you’ve saved. This is enforced on the server — \
                    other people won’t receive what you hide.

                    Your messages, calls, and the photos, videos and voice notes you send are \
                    end-to-end encrypted — Voiid can’t read them. Your profile photo is not: \
                    it’s stored on Voiid’s servers so anyone you allow can load it.
                    """
            ) {
                Picker("Last seen & online", selection: $settings.lastSeenVisibility) {
                    ForEach(PrivacySettings.Visibility.allCases) { Text($0.label).tag($0) }
                }
                Picker("Profile photo", selection: $settings.photoVisibility) {
                    ForEach(PrivacySettings.Visibility.allCases) { Text($0.label).tag($0) }
                }
                Picker("About", selection: $settings.aboutVisibility) {
                    ForEach(PrivacySettings.Visibility.allCases) { Text($0.label).tag($0) }
                }
            }

            // MARK: Message receipts

            SettingsSection(
                "Message receipts",
                footer: """
                    When these are off, this device stops sending read receipts and typing \
                    indicators. It doesn’t stop them arriving from other people — Voiid has \
                    no setting for that — so you’ll still see when someone is typing or has \
                    read your message.
                    """
            ) {
                Toggle("Send read receipts", isOn: $settings.sendReadReceipts)
                    .tint(VoiidColor.primary)
                    .accessibilityHint("Lets people see when you have read their message")

                Toggle("Send typing indicators", isOn: $settings.sendTypingIndicators)
                    .tint(VoiidColor.primary)
                    .accessibilityHint("Lets people see when you are typing to them")
            }

            // MARK: Online status

            SettingsSection(
                "Online status",
                footer: """
                    Hides the online and last-seen line at the top of a chat. This changes \
                    only what you see on this device — Voiid has no way to hide your own \
                    online status from other people.
                    """
            ) {
                Toggle("Show when contacts are online", isOn: $settings.showOnlineStatus)
                    .tint(VoiidColor.primary)
                    .accessibilityHint("Shows the online and last-seen line at the top of a chat")
            }

            // MARK: Moments

            // Default OFF and reciprocal: sending a receipt tells the Voiid SERVER you opened
            // someone's moment (it has no other way to learn that, and there is no sealed
            // sender to hide it). So the privacy-preserving default is that the viewer list
            // starts empty until you opt in — and opting out hides your own viewers too.
            SettingsSection(
                "Moments",
                footer: """
                    If you turn this off, people won’t know when you’ve viewed their moment — \
                    and you won’t see who viewed yours.
                    """
            ) {
                Toggle("Moment view receipts", isOn: $storySettings.sendViewReceipts)
                    .tint(VoiidColor.primary)
                    .accessibilityHint("Lets people see that you viewed their moment, and shows you who viewed yours")
            }

            // MARK: Map location

            SettingsSection(
                "Map location",
                footer: """
                    Ghost Mode hides you from everyone on the Map and stops your location \
                    being taken at all — it’s a hard switch, not a filter. You’re hidden by \
                    default and only ever visible to people you pick by name on the Map tab.
                    """
            ) {
                Toggle("Ghost Mode", isOn: Binding(
                    get: { !mapVisibility.isVisible },
                    set: { ghost in
                        Haptics.tap()
                        Task {
                            if ghost { await mapEngine.enterGhost(.untilOff) }
                            else { await mapEngine.leaveGhost() }
                        }
                    }
                ))
                .tint(VoiidColor.primary)
                .accessibilityHint("Hides you from everyone on the Map")

                Button(role: .destructive) {
                    Haptics.rigid()
                    Task { await mapEngine.killSwitch() }
                } label: {
                    Text("Stop all location sharing")
                        .foregroundStyle(VoiidColor.error)
                }
                .accessibilityHint("Ends every share and turns Ghost Mode on")
            }
        }
        // Row titles are `.body` in `VoiidColor.textPrimary`; `.fontDesign(.rounded)`
        // arrives from `voiidSettingsList()` and turns that into SF Pro Rounded while
        // keeping full Dynamic Type. Section header/footer typography is owned by
        // `SettingsSection` and is not restated here.
        .font(.body)
        .foregroundStyle(VoiidColor.textPrimary)
        .voiidSettingsList()
        .background(VoiidColor.background.ignoresSafeArea())
        .navigationTitle("Privacy")
        .task {
            // Includes the PIN itself since migration 026 — owner-only, keyed on the auth
            // token server-side.
            pinState = try? await ContactPinService.shared.state()
        }
        .confirmationDialog("Generate a new PIN?", isPresented: $confirmRotate,
                            titleVisibility: .visible) {
            Button("Generate", role: .destructive) { rotatePin() }
            Button("Cancel", role: .cancel) {}
        } message: {
            // The rotation caveat lives HERE, at the moment it applies, rather than in a
            // footer the user reads before they have any reason to care.
            Text("Anyone who has your current PIN will no longer be able to reach you with it.")
        }
    }

    private func rotatePin() {
        pinBusy = true
        pinError = nil
        Task {
            do {
                _ = try await ContactPinService.shared.rotate()
                // Re-read rather than trusting the rotate response: `state()` is the one
                // place that knows whether the new PIN is actually viewable, so the card
                // never claims a PIN is stored readably when the server couldn't do it.
                pinState = try? await ContactPinService.shared.state()
                Haptics.success()
            } catch {
                // Say what failed. A silent no-op on a security control is worse than an error.
                pinError = "Couldn't generate a PIN. Check your connection and try again."
            }
            pinBusy = false
        }
    }
}

// MARK: - Contact PIN card

/// The PIN, shown as a number rather than described in a paragraph.
///
/// Since migration 026 the PIN is stored encrypted rather than hashed, so it can be read
/// back — which is what lets this be a display surface instead of a one-shot reveal. The
/// digits are the largest thing on the screen because reading them aloud or copying them is
/// the entire task; every other affordance is deliberately quieter.
private struct ContactPinCard: View {
    let pin: String?
    let hasPin: Bool
    /// False when the SERVER cannot store a PIN readably (no secretbox key).
    let storageConfigured: Bool
    let busy: Bool
    let onRegenerate: () -> Void

    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: VoiidSpacing.md) {
            if let pin {
                digits(pin)
                actions(pin)
            } else if hasPin && !storageConfigured {
                // The SERVER cannot store PINs readably. Rotating would not help — it would
                // mint another unviewable one — so this deliberately does not offer it as the
                // fix, and names the missing setting so whoever runs the deployment can act.
                Text("Your PIN is set and works, but this server can't display it. "
                     + "VOIID_SECRETBOX_KEY isn't configured.")
                    .font(.footnote)
                    .foregroundStyle(VoiidColor.warning)
                    .fixedSize(horizontal: false, vertical: true)
                regenerateButton(title: "Generate a new PIN")
            } else if hasPin {
                // Set before 026, so it exists only as a hash and genuinely cannot be shown.
                // Say that plainly instead of rendering an empty card that looks broken.
                Text("Your PIN is set but can't be shown — it was created before PINs became "
                     + "viewable. Generate a new one to see it here.")
                    .font(.footnote)
                    .foregroundStyle(VoiidColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                regenerateButton(title: "Generate a viewable PIN")
            } else {
                Text("You don't have a PIN yet, so nobody can reach you by @username.")
                    .font(.footnote)
                    .foregroundStyle(VoiidColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                regenerateButton(title: "Create a PIN")
            }
        }
        .padding(.vertical, VoiidSpacing.sm)
        .animation(.easeInOut(duration: 0.2), value: copied)
    }

    /// Grouped 3 + 3. Six undifferentiated digits are meaningfully harder to read aloud and
    /// to check against what you just typed, which is most of what this card is for.
    private func digits(_ pin: String) -> some View {
        let mid = pin.index(pin.startIndex, offsetBy: min(3, pin.count))
        return HStack(spacing: VoiidSpacing.sm) {
            Text(String(pin[pin.startIndex..<mid]))
            Text(String(pin[mid...]))
        }
        .font(.system(size: 34, weight: .semibold, design: .rounded))
        .monospacedDigit()
        .kerning(4)
        .foregroundStyle(VoiidColor.textPrimary)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .center)
        .accessibilityElement()
        // Read as separate digits, not as "four hundred eighteen thousand".
        .accessibilityLabel("Your contact PIN is " + pin.map(String.init).joined(separator: " "))
    }

    private func actions(_ pin: String) -> some View {
        HStack(spacing: 0) {
            Button {
                UIPasteboard.general.string = pin
                Haptics.success()
                copied = true
                // Revert on its own. A permanently "Copied" button stops being a control.
                Task {
                    try? await Task.sleep(nanoseconds: 1_600_000_000)
                    copied = false
                }
            } label: {
                Label(copied ? "Copied" : "Copy",
                      systemImage: copied ? "checkmark" : "doc.on.doc")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(copied ? VoiidColor.success : VoiidColor.primary)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)

            Divider().frame(height: 20)

            Button(action: onRegenerate) {
                // "New PIN", not "Regenerate": this REPLACES the PIN and cuts off everyone
                // holding the old one, and the label should not sound like a refresh.
                Label("New PIN", systemImage: "arrow.triangle.2.circlepath")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(busy ? VoiidColor.textSecondary : VoiidColor.primary)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)
            .disabled(busy)
        }
        .overlay(alignment: .trailing) {
            if busy { ProgressView().controlSize(.small) }
        }
    }

    private func regenerateButton(title: String) -> some View {
        Button(action: onRegenerate) {
            HStack {
                Label(title, systemImage: "arrow.triangle.2.circlepath")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(busy ? VoiidColor.textSecondary : VoiidColor.primary)
                if busy {
                    Spacer()
                    ProgressView().controlSize(.small)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(busy)
    }
}

#Preview {
    NavigationStack {
        PrivacySettingsView()
    }
    .tint(VoiidColor.primary)
}
