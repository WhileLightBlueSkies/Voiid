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
//  No disappearing messages, no screenshot blocking, no "who can add me to groups". Each
//  has zero schema, zero route and zero client code, so shipping a control for it would be
//  an advertisement for a feature that does not exist.
//
//  Blocking IS here now (043_user_blocks + /blocks, enforced server-side). It gets a row
//  rather than a toggle, because blocking is per-person: the switch lives on each person's
//  profile, and this screen is where you see the list and undo it.
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
//  "Who can reach you" is PROSE, not toggles, and that is not an omission
//  ---------------------------------------------------------------------
//  reachability.ts enforces exactly three routes into your inbox and offers no choice
//  between them: no column turns requests off, none closes username search, none makes a
//  mutual contact go through a request first. The rules were real and enforced but stated
//  nowhere, so a user had no way to know who could message them or how. That is what the
//  section fixes — by explaining, not by adding switches. A toggle here would promise a
//  decision the server does not honour, which is worse than no toggle: a privacy control
//  that silently does nothing. The Contact PIN sits under the explanation because it is the
//  one genuine control among them, governing the third path.
//
//  "My status" is here rather than in Edit Profile
//  -----------------------------------------------
//  The server gates `status_text` on `last_seen_privacy` — a status says where you are and
//  whether you are attending your phone, so it is presence information and rides the presence
//  gate. That makes this the screen where the control and the switch deciding who sees it can
//  be read together. Edit Profile is also a dirty-tracked form behind a Save button, and a
//  status that took a Save to change would be the wrong shape for a thing you flip.
//
//  Every footer below is load-bearing. Each of these toggles creates a reasonable and
//  wrong assumption — that turning receipts off also hides other people's receipts from
//  you, that hiding the presence line hides you from others — and the footer's job is to
//  correct it in its first sentence, before the user acts on the wrong belief.
//

import SwiftUI

struct PrivacySettingsView: View {

    /// Your own availability status. Lives on this screen rather than in Edit Profile because
    /// it is governed by the last-seen scope two cards below it — the server gates the status
    /// on `last_seen_privacy`, so the control and the switch that decides who sees it belong
    /// on one screen. Edit Profile is also a dirty-tracked form with a Save button, and a
    /// status that took two taps and a Save to change would be the wrong shape entirely.
    @EnvironmentObject private var session: AppSession

    @ObservedObject private var settings = PrivacySettings.shared
    /// Blocking (043). Drives the count beside the Blocked contacts row.
    @ObservedObject private var blocks = BlockService.shared
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
    /// Availability status write in flight. The picker is disabled while it runs — a status
    /// is about what other people see, so letting a second tap race the first would leave the
    /// screen showing one value and the server holding another.
    @State private var statusBusy = false
    @State private var statusError: String?
    /// Pending inbound requests. `nil` means UNKNOWN — either not asked yet or the ask
    /// failed — and is rendered as no number at all, never as a zero. A "0" beside the row
    /// would state that nobody is waiting, which is a claim a failed fetch cannot make.
    @State private var requestCount: Int?
    @State private var requestsLoading = true
    @State private var showRequests = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: VoiidSpacing.md) {

            VoiidSettingsHeader(
                "Privacy",
                subtitle: "Who can reach you, what this device sends, and who you've blocked."
            )

            // MARK: My status

            statusSection

            // MARK: Who can reach you

            reachabilitySection

            // MARK: Contact PIN (reachability by @username)

            // ONE short footer, not three paragraphs. The old copy explained the storage
            // model, the mutual-contact exception and the rotation semantics before the user
            // had seen their own PIN — a wall of text where a number belongs. The card below
            // shows the PIN; the sentence says what it's for; everything else moved to the
            // moment it becomes relevant (the rotate confirmation).
            //
            // It now sits DIRECTLY UNDER the explanation of the three paths, because the PIN
            // is only meaningful as the mechanism for the third of them. On its own it was a
            // six-digit number with no stated purpose beyond one footer sentence; read after
            // "Someone who searches your @username", it is the answer to a question the user
            // has just been given.
            VoiidCardSection(
                "Contact PIN",
                footer: "Share this with people who find you by @username. They'll need it to "
                    + "message you — and you still choose whether to accept."
            ) {
                VStack(alignment: .leading, spacing: 0) {
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
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                }
                .padding(.horizontal, VoiidSpacing.md)
                .padding(.vertical, VoiidSpacing.sm)
            }

            // MARK: Who can see (server-enforced visibility)

            VoiidCardSection(
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
                // The Pickers keep their bindings and their case list exactly; only the
                // chrome around them changed. `.menu` style is what a card row can host —
                // an inset-grouped List drew the same control as a pushed picker page.
                VoiidSettingsRow(icon: "eye.trianglebadge.exclamationmark",
                                 title: "Last seen & online") {
                    Picker("Last seen & online", selection: $settings.lastSeenVisibility) {
                        ForEach(PrivacySettings.Visibility.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .tint(VoiidColor.textSecondary)
                }
                VoiidRowDivider()
                VoiidSettingsRow(icon: "person.crop.circle", title: "Profile photo") {
                    Picker("Profile photo", selection: $settings.photoVisibility) {
                        ForEach(PrivacySettings.Visibility.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .tint(VoiidColor.textSecondary)
                }
                VoiidRowDivider()
                VoiidSettingsRow(icon: "text.quote", title: "About") {
                    Picker("About", selection: $settings.aboutVisibility) {
                        ForEach(PrivacySettings.Visibility.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .tint(VoiidColor.textSecondary)
                }
            }

            // MARK: Message receipts

            VoiidCardSection(
                "Message receipts",
                footer: """
                    When these are off, this device stops sending read receipts and typing \
                    indicators. It doesn’t stop them arriving from other people — Voiid has \
                    no setting for that — so you’ll still see when someone is typing or has \
                    read your message.
                    """
            ) {
                VoiidSettingsRow(icon: "checkmark.message", title: "Send read receipts") {
                    Toggle("", isOn: $settings.sendReadReceipts)
                        .labelsHidden()
                        .tint(VoiidColor.primary)
                }
                .accessibilityHint("Lets people see when you have read their message")

                VoiidRowDivider()

                VoiidSettingsRow(icon: "ellipsis.bubble", title: "Send typing indicators") {
                    Toggle("", isOn: $settings.sendTypingIndicators)
                        .labelsHidden()
                        .tint(VoiidColor.primary)
                }
                .accessibilityHint("Lets people see when you are typing to them")
            }

            // MARK: Online status

            VoiidCardSection(
                "Online status",
                footer: """
                    Hides the online and last-seen line at the top of a chat. This changes \
                    only what you see on this device — Voiid has no way to hide your own \
                    online status from other people.
                    """
            ) {
                VoiidSettingsRow(icon: "circle.fill", title: "Show when contacts are online") {
                    Toggle("", isOn: $settings.showOnlineStatus)
                        .labelsHidden()
                        .tint(VoiidColor.primary)
                }
                .accessibilityHint("Shows the online and last-seen line at the top of a chat")
            }

            // MARK: Moments

            // Default OFF and reciprocal: sending a receipt tells the Voiid SERVER you opened
            // someone's moment (it has no other way to learn that, and there is no sealed
            // sender to hide it). So the privacy-preserving default is that the viewer list
            // starts empty until you opt in — and opting out hides your own viewers too.
            VoiidCardSection(
                "Moments",
                footer: """
                    If you turn this off, people won’t know when you’ve viewed their moment — \
                    and you won’t see who viewed yours.
                    """
            ) {
                VoiidSettingsRow(icon: "eye.circle", title: "Moment view receipts") {
                    Toggle("", isOn: $storySettings.sendViewReceipts)
                        .labelsHidden()
                        .tint(VoiidColor.primary)
                }
                .accessibilityHint("Lets people see that you viewed their moment, and shows you who viewed yours")
            }

            // MARK: Map location

            // MARK: Blocked contacts

            // A row, not a toggle: blocking is per-person and starts on that person's
            // profile. This is the way back — you should not have to find someone you have
            // been avoiding in order to stop avoiding them.
            VoiidCardSection(
                "Blocked",
                footer: "Blocked people can't message or call you, and you can't message or "
                    + "call them. They're never told."
            ) {
                NavigationLink {
                    BlockedContactsView()
                } label: {
                    HStack(spacing: VoiidSpacing.md) {
                        VoiidRowIcon(systemName: "hand.raised.slash")
                        Text("Blocked contacts")
                            .font(.body)
                            .foregroundStyle(VoiidColor.textPrimary)
                        Spacer(minLength: VoiidSpacing.sm)
                        // Only once loaded, and only when non-zero: a "0" beside a settings
                        // row invites the question of what it counts.
                        if blocks.didLoad, !blocks.blocked.isEmpty {
                            Text("\(blocks.blocked.count)")
                                .font(.subheadline)
                                .foregroundStyle(VoiidColor.textSecondary)
                        }
                        VoiidChevron()
                    }
                    .padding(.horizontal, VoiidSpacing.md)
                    .padding(.vertical, 11)
                    .contentShape(Rectangle())
                }
                .buttonStyle(RowButtonStyle())
            }

            VoiidCardSection(
                "Map location",
                footer: """
                    Ghost Mode hides you from everyone on the Map and stops your location \
                    being taken at all — it’s a hard switch, not a filter. You’re hidden by \
                    default and only ever visible to people you pick by name on the Map tab.
                    """
            ) {
                VoiidSettingsRow(icon: "moon.zzz", title: "Ghost Mode") {
                    Toggle("", isOn: Binding(
                        get: { !mapVisibility.isVisible },
                        set: { ghost in
                            Haptics.tap()
                            Task {
                                if ghost { await mapEngine.enterGhost(.untilOff) }
                                else { await mapEngine.leaveGhost() }
                            }
                        }
                    ))
                    .labelsHidden()
                    .tint(VoiidColor.primary)
                }
                .accessibilityHint("Hides you from everyone on the Map")

                VoiidRowDivider()

                // Destructive, and haptically distinct: `rigid` alone, not `tap`.
                // `VoiidSettingsRow` deliberately plays NO haptic of its own precisely so a
                // control like this one keeps the single heavier confirmation it needs
                // instead of stuttering through two.
                VoiidSettingsRow(icon: "location.slash",
                                 title: "Stop all location sharing",
                                 destructive: true,
                                 action: {
                                     Haptics.rigid()
                                     Task { await mapEngine.killSwitch() }
                                 })
                .accessibilityHint("Ends every share and turns Ghost Mode on")
            }
            }
            .padding(VoiidSpacing.md)
        }
        // Row titles are `.body` in `VoiidColor.textPrimary`; `.fontDesign(.rounded)` turns
        // that into SF Pro Rounded while keeping full Dynamic Type. Section header/footer
        // typography is owned by `VoiidCardSection` and is not restated here.
        .font(.body)
        .foregroundStyle(VoiidColor.textPrimary)
        .fontDesign(.rounded)
        .voiidSettingsPage()
        .task {
            // Includes the PIN itself since migration 026 — owner-only, keyed on the auth
            // token server-side.
            pinState = try? await ContactPinService.shared.state()
        }
        .task { await loadRequestCount() }
        .sheet(isPresented: $showRequests) {
            // The SAME screen the Chats banner opens, not a second copy of the list. Accepting
            // from here re-reads the count so the row stops advertising a request the user has
            // just dealt with; there is no conversation to open from Settings, so the callback
            // does only that.
            MessageRequestsView { _ in
                Task { await loadRequestCount() }
            }
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

    // MARK: - My status

    /// The availability status, as four choices and a Clear.
    ///
    /// A MENU PICKER, matching the three visibility pickers below it rather than inventing a
    /// segmented control or a row of chips. The chosen value is the thing worth showing, and
    /// this screen already has a vocabulary for "a setting with a small closed set of values"
    /// — using it means the status reads as one more setting rather than as a feature bolted
    /// on beside them.
    ///
    /// The footer is `AvailabilityStatus.honestFooter` and is NOT paraphrased here. It is the
    /// sentence that stops "Do not disturb" from implying a mute it does not perform, and it
    /// lives beside the enum so that any future surface offering this picker inherits it.
    @ViewBuilder
    private var statusSection: some View {
        let current = AvailabilityStatus.from(session.profile.statusText)

        VoiidCardSection("My status", footer: AvailabilityStatus.honestFooter) {
            VStack(alignment: .leading, spacing: 0) {
                VoiidSettingsRow(
                    // The row's own icon reflects the CURRENT status, so the setting is
                    // legible from the icon column at a glance without opening the menu.
                    icon: current?.systemImage ?? "circle.dashed",
                    title: "Status"
                ) {
                    if statusBusy {
                        ProgressView().controlSize(.small)
                    } else {
                        Picker("Status", selection: Binding(
                            get: { current },
                            set: { setStatus($0) }
                        )) {
                            // "None" is a real choice, not the absence of one. Without it
                            // there would be no way back to having no status at all.
                            Text("None").tag(AvailabilityStatus?.none)
                            ForEach(AvailabilityStatus.allCases) { s in
                                // Label rather than Text: the swatch is what makes the four
                                // distinguishable in a closed menu, and it is the same glyph
                                // the row and the profile use, so one status looks like
                                // itself everywhere it appears.
                                Label {
                                    Text(s.label)
                                } icon: {
                                    Image(systemName: s.systemImage).foregroundStyle(s.tint)
                                }
                                .tag(AvailabilityStatus?.some(s))
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .tint(VoiidColor.textSecondary)
                    }
                }
                .accessibilityHint("The label people see on your profile. It does not change how messages, calls or notifications reach you.")

                // FAILED IS NOT SILENT. `session.setStatus` writes local state only after the
                // server confirms, so a failure leaves the picker showing the value that is
                // genuinely stored — but that alone would look like the tap simply did
                // nothing, which is the worst reading of a privacy-adjacent control.
                if let statusError {
                    Text(statusError)
                        .font(.footnote)
                        .foregroundStyle(VoiidColor.error)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, VoiidSpacing.md)
                        .padding(.bottom, VoiidSpacing.sm)
                }
            }
        }
    }

    private func setStatus(_ status: AvailabilityStatus?) {
        // Client gate only: the picker offers exactly the four values the server accepts, but
        // it is `STATUS_VALUES` in backend/api/src/routes/users.ts that ENFORCES that — this
        // is convenience, not authorisation. Same for the visibility scopes below.
        guard !statusBusy else { return }
        Haptics.tap()
        statusBusy = true
        statusError = nil
        Task {
            do {
                try await session.setStatus(status)
                Haptics.success()
            } catch {
                statusError = "Couldn't save your status. Check your connection and try again."
            }
            statusBusy = false
        }
    }

    // MARK: - Who can reach you

    /// The three paths `backend/api/src/routes/reachability.ts` actually enforces, stated in
    /// the user's terms.
    ///
    /// WHY THIS IS PROSE AND NOT TOGGLES. The server enforces exactly three routes into your
    /// inbox and offers no choice between them: there is no column that turns off requests,
    /// no setting that closes username search, nothing that makes a mutual contact go through
    /// a request first. A switch here would promise a decision the server does not honour,
    /// which is worse than no switch — it would be a privacy control that quietly does
    /// nothing. So this section explains, and the one real control (the PIN, which genuinely
    /// governs the third path) sits directly beneath it.
    ///
    /// Ordered by how open the path is, most-trusted first, so the list reads as a widening
    /// circle rather than an arbitrary set of rules.
    private var reachabilitySection: some View {
        VoiidCardSection(
            "Who can reach you",
            footer: "These are the only ways into your chats, and they're enforced on Voiid's "
                + "servers — not by this app. Blocked people can't use any of them."
        ) {
            reachPath(
                icon: "person.2.fill",
                title: "People you've both saved",
                detail: "If you have each other in your contacts, their message opens as a "
                    + "normal chat straight away."
            )
            VoiidRowDivider()
            reachPath(
                icon: "person.crop.circle.badge.questionmark",
                title: "Someone who has you saved",
                detail: "If they've saved you but you haven't saved them, their message waits "
                    + "as a request. Nothing reaches your chat list until you accept it."
            )
            VoiidRowDivider()
            reachPath(
                icon: "at",
                title: "Someone who searched your @username",
                detail: "A stranger who finds you by username has to enter your Contact PIN "
                    + "first. Even then it still arrives as a request for you to accept."
            )
            VoiidRowDivider()
            requestsRow
        }
    }

    /// One path. Not a `VoiidSettingsRow`, because these are statements rather than controls
    /// and a row shape that elsewhere means "tappable" would invite taps that go nowhere.
    /// The icon column and spacing match exactly so it still reads as part of the card.
    private func reachPath(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: VoiidSpacing.md) {
            VoiidRowIcon(systemName: icon)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.body)
                    .foregroundStyle(VoiidColor.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(VoiidColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, VoiidSpacing.md)
        .padding(.vertical, 11)
        .accessibilityElement(children: .combine)
    }

    /// A door to the requests inbox that is ALWAYS here.
    ///
    /// `MessageRequestsView` already exists and already has an entry point — the banner at the
    /// top of Chats — so this deliberately presents that same screen rather than duplicating
    /// the list. What it adds is permanence: the banner renders only when the count is above
    /// zero, which is right for a chat list but means a user who has just read the three
    /// paths above and wants to check has nowhere to go. Two doors, one room.
    ///
    /// Three distinct states, and a failed count is not an empty one: unknown shows nothing
    /// beside the chevron rather than a "0" that would claim there are no requests when we
    /// simply could not ask.
    private var requestsRow: some View {
        VoiidSettingsRow(icon: "tray", title: "Message requests", action: {
            Haptics.tap()
            showRequests = true
        }) {
            if requestsLoading {
                ProgressView().controlSize(.small)
            } else if let requestCount, requestCount > 0 {
                Text("\(requestCount)")
                    .font(.subheadline)
                    .foregroundStyle(VoiidColor.textSecondary)
            }
            VoiidChevron()
        }
        .accessibilityHint("People waiting for you to accept or decline")
    }

    /// Count only — the list itself is `MessageRequestsView`'s job, and fetching it here would
    /// be a second full read of the same endpoint for a number.
    ///
    /// A THROW LEAVES `requestCount` NIL rather than setting it to zero. The distinction is the
    /// whole point: "no requests" and "we couldn't find out" look different on the row.
    private func loadRequestCount() async {
        requestsLoading = true
        requestCount = try? await ContactPinService.shared.pending().count
        requestsLoading = false
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
    // The status card reads its value from the session, so the preview needs one — without
    // it SwiftUI traps at runtime rather than rendering.
    .environmentObject(AppSession())
}
