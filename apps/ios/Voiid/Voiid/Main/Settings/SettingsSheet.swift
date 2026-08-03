//
//  SettingsSheet.swift
//  Voiid
//
//  Settings, reached by tapping your own avatar at the top-left of the Chats screen.
//  This is the ONLY entry point: the duplicate hamburger menu in ChatsHomeView (a second
//  "Backup & Recovery" plus an unconfirmed "Log out") was deleted in the same change.
//
//  The root list has no section headers and no section footers. Grouping alone carries
//  the structure, exactly as Settings.app, Signal and WhatsApp do at their roots. Footers
//  are explanatory apparatus and belong on the screen where the setting lives, not on a
//  list of doors.
//
//  Order follows Apple's gradient: who you are → what protects your account → how the app
//  behaves → what it is → how you leave.
//
//  What is deliberately absent, and why
//  ------------------------------------
//  Clips settings, a "Chats" screen, Privacy Policy and Help have no rows here — not
//  disabled, not greyed, not "coming soon". None of them exist in this app (Clips is
//  DummyData end-to-end and the server reports feature_flags.clips = false; no
//  privacy-policy or support URL exists anywhere in the repo). A top-level row for a
//  feature that does not exist has no peers, no precondition and no path to resolution;
//  it is an unactionable control that also advertises the feature as if it shipped.
//  Absent features get no pixels.
//
//  Stories now EXISTS, so its earlier absence here no longer applies — but it still gets
//  no root row: its one setting is a privacy concern (whether you send story view
//  receipts) and lives under Privacy, beside the other reciprocal visibility toggles. A
//  root "Stories" row would advertise a screen that is really a single switch.
//
//  The Map (Feature B) now EXISTS, so its earlier absence here no longer applies — but it
//  still gets no root row: Map controls are not an account concern. Ghost Mode and the
//  "Stop all location sharing" kill switch live under Privacy (where they sit beside the
//  other visibility toggles), and the Map's own tab hosts the primary audience UI. A root
//  row would duplicate a control that already has a home on its own surface.
//
//  "Delete My Account" is not at root either. It lives at the bottom of Edit Profile: it
//  is an identity operation, not a session operation, and one tap from root inside the
//  screen that owns your name and email satisfies App Review 5.1.1(v) while keeping two
//  irreversible actions off the same screen.
//

import SwiftUI
import UIKit

// MARK: - Profile avatar
//
// Lives here rather than in DesignSystem because it is the Settings entry point's own
// affordance; ChatsHomeView's header reuses it, so it must stay public to this module.

/// Round avatar used in the Chats header and at the top of Settings. Falls back to the
/// initials of the name, and only then to a glyph — an avatar that renders as an empty
/// grey circle reads as a loading bug rather than "no photo set".
struct ProfileAvatarButton: View {
    var photoURL: String?
    var name: String?
    var size: CGFloat = 38

    /// FILL A RECTANGULAR FRAME instead of clipping to a circle.
    ///
    /// The avatar is a circle almost everywhere — chat rows, toolbars, the settings header —
    /// so that stays the default and all 18 existing call sites are untouched. The contact
    /// profile's full-bleed portrait is the exception: it needs the photo to fill a 360pt
    /// banner, and the hard-coded `.frame(width:height:)` + `.clipShape(Circle())` was
    /// squeezing it into a circle in the top-left of that space.
    ///
    /// When true the view takes the frame its PARENT gives it and crops the image to fill,
    /// which is what a banner needs.
    var fillsFrame: Bool = false

    private var initials: String {
        let parts = (name ?? "").split(separator: " ").prefix(2)
        let letters = parts.compactMap { $0.first }.map(String.init).joined()
        return letters.isEmpty ? "" : letters.uppercased()
    }

    /// Resolved bytes for an R2 object key. Avatars are stored as opaque keys, not
    /// absolute URLs, so they need a presigned GET before they can be drawn.
    @State private var resolved: UIImage?

    var body: some View {
        ZStack {
            Circle().fill(VoiidColor.fieldFill)
            if let resolved {
                Image(uiImage: resolved).resizable().scaledToFill()
            } else if let photoURL, photoURL.hasPrefix("http"),
                      let url = URL(string: photoURL) {
                AsyncImage(url: url) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Text(initials)
                        .font(VoiidFont.rounded(size * 0.38, .semibold))
                        .foregroundColor(VoiidColor.textSecondary)
                }
            } else if !initials.isEmpty {
                Text(initials)
                    .font(VoiidFont.rounded(size * 0.38, .semibold))
                    .foregroundColor(VoiidColor.textSecondary)
            } else {
                Image(systemName: "person.fill")
                    .font(.system(size: size * 0.44))
                    .foregroundColor(VoiidColor.textSecondary)
            }
        }
        .modifier(AvatarShape(size: size, fillsFrame: fillsFrame))
        .task(id: photoURL) { await resolveIfNeeded() }
    }

    /// Square-and-circular by default; frame-filling when the caller asks for it.
    private struct AvatarShape: ViewModifier {
        let size: CGFloat
        let fillsFrame: Bool

        func body(content: Content) -> some View {
            if fillsFrame {
                // No fixed frame: the parent decides. `.clipped()` crops the overflow that
                // scaledToFill produces, so the photo fills the banner without letterboxing.
                content.frame(maxWidth: .infinity, maxHeight: .infinity).clipped()
            } else {
                content.frame(width: size, height: size).clipShape(Circle())
            }
        }
    }

    /// Resolve through the SHARED cache so a face fetched once shows instantly everywhere
    /// (and your own profile photo stops taking a few seconds each time). A synchronous
    /// cache hit paints immediately; a miss fetches once and caches. Failure is silent —
    /// the initials fallback is a fine avatar.
    private func resolveIfNeeded() async {
        guard let ref = photoURL, !ref.isEmpty else { resolved = nil; return }
        if let hit = AvatarCache.cached(ref) { resolved = hit; return }
        resolved = await AvatarCache.resolve(ref)
    }
}

// MARK: - Routes

/// Every destination in the Settings tree.
///
/// There is exactly ONE `.navigationDestination(for: SettingsRoute.self)` in the whole
/// tree and it lives on the root `List` in `SettingsSheet`. Do not add a second one on a
/// pushed screen — the root's handler already covers the entire stack.
///
/// Consequence for screen authors: **every destination view must be constructible with no
/// arguments.** `EditProfileView()`, `LinkedDevicesView()`, `BackupRecoveryView()`,
/// `PrivacySettingsView()`, `StorageSettingsView()`, `AboutView()`. Read what you need
/// from `@EnvironmentObject var session: AppSession` or from the relevant singleton. No
/// initialiser parameters, no bindings threaded down from here.
///
/// To push from anywhere inside the tree:
/// ```swift
/// NavigationLink(value: SettingsRoute.backup) { Text("Backup & Recovery") }
/// ```
enum SettingsRoute: Hashable {
    case editProfile
    case linkedDevices
    case backup
    case privacy
    case storage
    case about
}

// MARK: - Root

struct SettingsSheet: View {
    @EnvironmentObject var session: AppSession
    /// Light / Dark / System, applied app-wide at ContentView.
    @ObservedObject private var theme = ThemePreference.shared
    @ObservedObject private var chatLayout = ChatLayoutPreference.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    @State private var confirmLogOut = false
    @State private var loggingOut = false

    /// Whether a backup blob actually EXISTS on the server.
    ///
    /// `BackupManager.hasLocalSecret` only says a master secret sits in this keychain — it
    /// says nothing about whether a backup was ever uploaded. Keying the log-out warning on
    /// it told users "you can restore them with your recovery phrase" when there was nothing
    /// to restore from, which is precisely the class of lie this screen exists to remove.
    /// nil = not checked yet or the check failed; we then promise nothing.
    @State private var backupExists: Bool?

    var body: some View {
        NavigationStack {
            List {
                identity
                accountAndSecurity
                appBehaviour
                about
                signOut
            }
            .voiidSettingsList()
            .background(VoiidColor.background.ignoresSafeArea())
            .navigationTitle("Settings")
            .navigationDestination(for: SettingsRoute.self) { route in
                switch route {
                case .editProfile:   EditProfileView()
                case .linkedDevices: LinkedDevicesView()
                case .backup:        BackupRecoveryView()
                case .privacy:       PrivacySettingsView()
                case .storage:       StorageSettingsView()
                case .about:         AboutView()
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { Haptics.tap(); dismiss() }
                        .fontWeight(.semibold)
                        .foregroundStyle(VoiidColor.primary)
                }
            }
            .confirmationDialog("Log out of Voiid?",
                                isPresented: $confirmLogOut,
                                titleVisibility: .visible) {
                Button("Log Out", role: .destructive) { Task { await performLogOut() } }
                Button("Cancel", role: .cancel) {}
            } message: {
                // Two real variants. Telling someone their keys are recoverable when no
                // backup exists is the exact kind of lie this rebuild is here to remove.
                // Three states, because there are genuinely three. Promising recovery
                // requires knowing a backup EXISTS, not merely that a key does.
                Text({
                    switch backupExists {
                    case .some(true):
                        return "Your messages and encryption keys will be removed from this iPhone. You can restore them with your recovery phrase."
                    case .some(false):
                        return "Your messages and encryption keys will be removed from this iPhone. You haven't backed them up, so they can't be recovered."
                    case nil:
                        return "Your messages and encryption keys will be removed from this iPhone. They can only be restored if you have a backup and your recovery phrase."
                    }
                }())
            }
        }
        // Sheets do not reliably inherit the root tint, and the app is a fixed light
        // design — "correct in dark mode" here means "identical in dark mode".
        .tint(VoiidColor.primary)
        // No colour-scheme pin: Peacock tokens resolve per theme, and a sheet that
        // forced light would be the one bright rectangle in a dark app.
        // Ask the server whether a backup actually exists, so the log-out warning and the
        // Backup row state describe reality rather than the presence of a keychain item.
        // Failure leaves it nil, which makes both surfaces promise nothing.
        .task {
            // No master secret means backup was never set up — local and certain.
            guard BackupManager.shared.hasLocalSecret else { backupExists = false; return }
            do {
                // A nil meta is a definite "no backup on the server".
                backupExists = try await BackupManager.shared.status() != nil
            } catch {
                // Offline or the server errored: we genuinely do not know, so stay nil and
                // let both surfaces fall back to the copy that claims nothing.
                backupExists = nil
            }
        }
    }

    // MARK: G1 — identity

    /// The Apple ID card. "Am I in the right account?" is the first question any settings
    /// screen has to answer, so it is never buried.
    ///
    /// The avatar here is NOT a PhotosPicker: two competing tap targets in one row is a
    /// mis-tap generator. Photo editing lives on the Edit Profile screen this row opens.
    /// YOU, at the top of your own settings.
    ///
    /// It was a 60pt avatar in an ordinary row — the same weight as "Storage" or
    /// "Appearance" — so the one thing on this screen that is ABOUT you carried no more
    /// presence than a preference toggle. It now gets a card of its own: a larger avatar, the
    /// name at title size, and the handle and number on one line beneath, which is the same
    /// identity treatment the contact profile uses. The two screens finally rhyme.
    private var identity: some View {
        NavigationLink(value: SettingsRoute.editProfile) {
            HStack(spacing: VoiidSpacing.md) {
                ProfileAvatarButton(photoURL: session.profile.photoURL,
                                    name: session.profile.fullName,
                                    size: 72)
                    .overlay(Circle().strokeBorder(VoiidColor.textPrimary.opacity(0.08), lineWidth: 1))

                VStack(alignment: .leading, spacing: 3) {
                    Text(session.profile.fullName.isEmpty ? "Add your name" : session.profile.fullName)
                        .font(VoiidFont.rounded(22, .bold))
                        .kerning(-0.3)
                        .foregroundStyle(session.profile.fullName.isEmpty
                                         ? VoiidColor.placeholder : VoiidColor.textPrimary)
                        .lineLimit(1)

                    // Handle and number on ONE line, separated by a dot — the same pattern as
                    // the contact profile, rather than two stacked lines at equal weight.
                    let handle = (session.profile.username ?? "").isEmpty
                        ? nil : session.profile.username
                    HStack(spacing: 6) {
                        if let handle {
                            Text("@\(handle)")
                                .font(VoiidFont.rounded(14, .medium))
                                .foregroundStyle(VoiidColor.primary)
                        }
                        if handle != nil && !session.profile.phoneNumber.isEmpty {
                            Circle()
                                .fill(VoiidColor.textSecondary.opacity(0.4))
                                .frame(width: 3, height: 3)
                        }
                        // Never render an empty line where a phone number would go.
                        if !session.profile.phoneNumber.isEmpty {
                            Text(session.profile.phoneNumber)
                                .font(VoiidFont.rounded(14, .regular))
                                .foregroundStyle(VoiidColor.textSecondary)
                        }
                    }

                    Text("View and edit profile")
                        .font(VoiidFont.rounded(12, .medium))
                        .foregroundStyle(VoiidColor.primary)
                        .padding(.top, 1)
                }

                Spacer(minLength: 0)
            }
            .padding(VoiidSpacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(VoiidColor.surfaceCard)
            .clipShape(RoundedRectangle(cornerRadius: VoiidRadius.lg, style: .continuous))
            .accessibilityElement(children: .combine)
            .accessibilityLabel(profileAccessibilityLabel)
            .accessibilityHint("Opens your profile")
        }
        .buttonStyle(.plain)
    }

    private var profileAccessibilityLabel: String {
        let name = session.profile.fullName.isEmpty ? "no name set" : session.profile.fullName
        let phone = session.profile.phoneNumber
        return phone.isEmpty ? "Profile, \(name)" : "Profile, \(name), \(phone)"
    }

    // MARK: G2 — account & security

    /// Both rows are account-scoped custody concerns rather than app preferences: who can
    /// read your messages, and whether you can get them back. Devices precedes Backup
    /// because "who is signed in" is a security question and outranks a recovery question.
    private var accountAndSecurity: some View {
        SettingsSection {
            NavigationLink(value: SettingsRoute.linkedDevices) {
                rowLabel("Linked Devices", systemImage: "laptopcomputer.and.iphone")
            }
            // No device count here: it would need a network fetch to draw the root list,
            // and a row showing "—" while loading is noise. Backup state is a local,
            // synchronous Bool and is free.
            NavigationLink(value: SettingsRoute.backup) {
                LabeledContent {
                    // Same three states as the log-out warning: a key without a backup is
                    // not "On". Blank while the check is in flight beats a wrong answer.
                    Text(backupExists == true ? "On" : (backupExists == false ? "Not set up" : ""))
                        .font(.subheadline)
                        .foregroundStyle(VoiidColor.textSecondary)
                } label: {
                    rowLabel("Backup & Recovery", systemImage: "checkmark.shield")
                }
            }
        }
    }

    // MARK: G3 — app behaviour

    /// Ordered by frequency of use, not alphabet. Notifications is the most-visited
    /// setting in any messenger; Privacy is second; Storage is a once-a-quarter forensic
    /// screen and sits last.
    ///
    /// The row is "Storage", not "Data & Storage" — there is not one data control in this
    /// app (no auto-download preference, no low-data mode, and `CallSDPTuning` deliberately
    /// exposes no bitrate knob). The longer name would promise half a screen that does not
    /// exist.
    private var appBehaviour: some View {
        SettingsSection {
            // Not a NavigationLink. iOS owns Voiid's notification behaviour entirely, so
            // this jumps straight to Voiid's pane in Settings.app. The external-link glyph
            // rather than a chevron tells the user they are leaving the app; that
            // distinction is the contract, not decoration.
            Button {
                Haptics.tap()
                if let url = URL(string: UIApplication.openNotificationSettingsURLString) {
                    openURL(url)
                }
            } label: {
                LabeledContent {
                    Image(systemName: "arrow.up.forward.app")
                        .font(.footnote)
                        .foregroundStyle(VoiidColor.placeholder)
                } label: {
                    rowLabel("Notifications", systemImage: "bell")
                }
            }
            .accessibilityHint("Opens Voiid's notification settings in the Settings app")

            NavigationLink(value: SettingsRoute.privacy) {
                rowLabel("Privacy", systemImage: "lock")
            }
            NavigationLink(value: SettingsRoute.storage) {
                rowLabel("Storage", systemImage: "internaldrive")
            }

            // Chat list layout — same reasoning as Appearance below: two options, and the
            // result is on the screen you just came from, so a pushed screen would mean
            // choosing blind and navigating back to check.
            VStack(alignment: .leading, spacing: VoiidSpacing.sm) {
                rowLabel("Chat list", systemImage: "rectangle.grid.2x2")
                Picker("Chat list", selection: Binding(
                    get: { chatLayout.layout },
                    set: { Haptics.selection(); chatLayout.layout = $0 }
                )) {
                    ForEach(ChatLayoutPreference.Layout.allCases) { l in
                        Label(l.label, systemImage: l.icon).tag(l)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            .padding(.vertical, 2)

            // Appearance is INLINE, not a pushed screen: there are exactly three options and
            // the result is visible the instant you tap, so navigating away to choose and
            // then back to see the effect would be worse.
            VStack(alignment: .leading, spacing: VoiidSpacing.sm) {
                rowLabel("Appearance", systemImage: "circle.lefthalf.filled")
                Picker("Appearance", selection: Binding(
                    get: { theme.mode },
                    set: { Haptics.selection(); theme.mode = $0 }
                )) {
                    ForEach(ThemePreference.Mode.allCases) { m in
                        Text(m.label).tag(m)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            .padding(.vertical, 2)
        }
    }

    // MARK: G4 — about

    private var about: some View {
        SettingsSection {
            NavigationLink(value: SettingsRoute.about) {
                rowLabel("About", systemImage: "info.circle")
            }
        }
    }

    // MARK: G5 — destructive

    /// Alone, at the bottom, in `VoiidColor.error`. The isolation *is* the affordance: a
    /// destructive row sharing a card with navigation rows is a mis-tap generator.
    private var signOut: some View {
        SettingsSection {
            Button(role: .destructive) {
                Haptics.rigid()
                confirmLogOut = true
            } label: {
                Label("Log Out", systemImage: "rectangle.portrait.and.arrow.right")
                    .font(.body)
                    .foregroundStyle(VoiidColor.error)
            }
            .disabled(loggingOut)
        }
    }

    // MARK: - Row label
    //
    // Plain SF Symbol in Label's leading slot, no fixed icon frame (Label aligns the icon
    // column itself), and no coloured rounded-rect tiles — that idiom is specific to
    // Settings.app and cloning it would make Voiid look like a knock-off. Icon and title
    // share one colour because VoiidColor.primary and .textPrimary are the same hex.

    private func rowLabel(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.body)
            .foregroundStyle(VoiidColor.textPrimary)
    }

    // MARK: - Log out

    /// Log-out and local teardown ship together or neither ships. `AppSession.signOut()`
    /// alone clears the JWT and the profile key and nothing else — the app-group SQLite
    /// store, the plaintext message blob, the E2E keychain and the registered VoIP token
    /// all survive, so the next account to sign in on this device renders the previous
    /// user's chats and the handset keeps ringing for the account that left.
    ///
    /// Order matters: the token is cleared LAST (inside `session.signOut()`), so the
    /// best-effort VoIP unregister inside the teardown can still authenticate.
    private func performLogOut() async {
        loggingOut = true
        await SessionTeardown.wipeLocalAccountState()
        session.signOut()
        Haptics.success()
        dismiss()
    }
}
