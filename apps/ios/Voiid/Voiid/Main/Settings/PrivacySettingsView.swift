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

    var body: some View {
        List {

            // MARK: Who can see (server-enforced visibility)

            SettingsSection(
                "Who can see my info",
                footer: """
                    Choose who can see your last seen & online, profile photo, and about. \
                    “My Contacts” means people you’ve saved. This is enforced on the server — \
                    other people won’t receive what you hide.
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
    }
}

#Preview {
    NavigationStack {
        PrivacySettingsView()
    }
    .tint(VoiidColor.primary)
}
