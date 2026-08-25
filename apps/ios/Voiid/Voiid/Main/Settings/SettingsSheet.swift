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
//  Clips settings, a "Chats" screen and Help have no rows here — not disabled, not
//  greyed, not "coming soon". None of them exist in this app (Clips is DummyData
//  end-to-end and the server reports feature_flags.clips = false; no support URL exists
//  anywhere in the repo). A top-level row for a feature that does not exist has no peers,
//  no precondition and no path to resolution; it is an unactionable control that also
//  advertises the feature as if it shipped. Absent features get no pixels.
//
//  Privacy & Legal used to be on that list for the same reason — there was no privacy
//  policy anywhere in the repo to link to. There is now: the notice and the terms are
//  bundled in the app (Legal/LegalDocuments.swift), so the row is no longer a door to
//  nowhere. It sits beside About rather than under Privacy because it is also where
//  consent is withdrawn, and DPDP s.6(4) requires that to be as easy as giving it was —
//  which means at the depth of a root row, not buried under a settings screen.
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
//  "Delete My Account" is not at root either. It lives at the bottom of Edit Profile (and
//  as of the DPDP wiring it actually EXISTS there — this comment described it for a long
//  time before the control was built): it
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

    /// The disc drawn behind the initials when there is no photo.
    ///
    /// DEFAULTS TO `fieldFill`, which is right on a plain ground — but wrong ON A CARD. In
    /// dark mode `fieldFill` (#1A1A1A) is a step darker than `surfaceCard` (#121212)… so an
    /// avatar placed on a card punched a visibly darker circle into it: a second tone where
    /// there should be one surface, which is the "dual tone" on the settings profile row.
    /// Callers sitting on a card pass that card's colour and the avatar reads as part of it.
    var placeholderFill: Color = VoiidColor.fieldFill

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
            Circle().fill(placeholderFill)
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
    // ── WIRED: real screens, real backends ──────────────────────────────────────────
    case editProfile
    case linkedDevices
    case backup
    case privacy
    case storage
    case about
    case legal
    // NO `.games` CASE, DELIBERATELY. Game settings — sound, haptics and per-game
    // visibility — live in the GAMES TAB, behind the `slider.horizontal.3` button in its
    // header (`Games/GameSettingsView.swift`). They briefly had a row here; that was
    // reversed, because settings about the arcade belong where the player is standing when
    // they want them, and because ONE screen must have ONE door. Re-adding a row here would
    // recreate exactly the two-entry-point confusion this removal exists to fix.

    // ── PREVIEW ONLY: reference rows Voiid has no backend for ───────────────────────
    // Kept as real cases rather than dead rows so the compiler forces every one of them to
    // have a destination. Each destination wears an UnwiredNotice saying what is missing —
    // see PreviewSettingsScreens.swift.
    case qrCode
    case shareProfile
    case accountCenter
    case encryption
    case account
    case chatSettings
    case voiidOne
    case payments
    case help

    /// Whether this route leads to a screen that actually does something. Drives the amber
    /// dot on the row, so the state is visible BEFORE the tap rather than after it.
    var isWired: Bool {
        switch self {
        case .editProfile, .linkedDevices, .backup, .privacy, .storage, .about, .legal:
            return true
        case .qrCode, .shareProfile, .accountCenter, .encryption, .account,
             .chatSettings, .voiidOne, .payments, .help:
            return false
        }
    }
}

// MARK: - Root

/// Settings, reached by tapping your own avatar at the top-left of the Chats screen.
///
/// ── THE UNION OF TWO DESIGNS, NOT A REPLACEMENT ─────────────────────────────────
/// This screen carries the reference's LAYOUT (identity block, quick-actions strip,
/// encryption banner, labelled card groups, the isolated red log-out card) and BOTH
/// products' rows. Where the reference has a row Voiid lacks a backend for, the row is here
/// and its destination says so. Where Voiid has a row the reference never drew — Backup &
/// Recovery, Privacy & Legal, the Appearance and Chat-list pickers — the row stays, folded
/// into whichever group it belongs to.
///
/// Nothing that worked before was removed. The `List` became cards; the routes, the log-out
/// teardown, the backup probe and every destination screen are unchanged.
struct SettingsSheet: View {
    @EnvironmentObject var session: AppSession
    /// Light / Dark / System, applied app-wide at ContentView.
    @ObservedObject private var theme = ThemePreference.shared
    @ObservedObject private var chatLayout = ChatLayoutPreference.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    @State private var confirmLogOut = false
    @State private var loggingOut = false
    @State private var path: [SettingsRoute] = []

    /// Whether a backup blob actually EXISTS on the server.
    ///
    /// `BackupManager.hasLocalSecret` only says a master secret sits in this keychain — it
    /// says nothing about whether a backup was ever uploaded. Keying the log-out warning on
    /// it told users "you can restore them with your recovery phrase" when there was nothing
    /// to restore from, which is precisely the class of lie this screen exists to remove.
    /// nil = not checked yet or the check failed; we then promise nothing.
    @State private var backupExists: Bool?

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(spacing: VoiidSpacing.md) {
                    identity
                    quickActions
                    encryptionBanner

                    group("Account", rows: [
                        .init(.account, "person", "Account", "Phone, email, username"),
                        .init(.privacy, "lock", "Privacy & security",
                              "Visibility, blocked contacts, app lock"),
                    ])

                    group("Chats & notifications", rows: [
                        .init(.chatSettings, "bubble.left", "Chats",
                              "Theme, wallpaper, chat settings"),
                        // Notifications is NOT a route: iOS owns Voiid's notification
                        // behaviour entirely, so the row leaves the app. It is rendered
                        // separately below the group for exactly that reason.
                        .init(.storage, "internaldrive", "Storage & data",
                              "Manage storage, data usage"),
                    ], trailing: { notificationsRow })

                    group("Voiid ecosystem", rows: [
                        // VOIID'S OWN, not the reference's: this is the real encrypted
                        // backup screen, and it is the thing "Voiid One" describes.
                        .init(.backup, "checkmark.shield", "Backup & Recovery",
                              backupDetail),
                        .init(.voiidOne, "cloud", "Voiid One", "Encrypted backup & restore"),
                        .init(.payments, "creditcard", "Payments",
                              "UPI, cards, transactions"),
                        .init(.linkedDevices, "laptopcomputer.and.iphone", "Devices",
                              "Linked devices, sessions"),
                        // NO "Games" ROW. See `SettingsRoute` — game settings are reached
                        // from the Games tab's own header and from nowhere else.
                    ])

                    displayGroup

                    group("Support & more", rows: [
                        .init(.help, "questionmark.circle", "Help & support", "FAQ, contact us"),
                        // VOIID'S OWN: the notice and terms are bundled in the app, and DPDP
                        // s.6(4) requires withdrawing consent to be as easy as giving it —
                        // which means at the depth of a root row.
                        .init(.legal, "hand.raised", "Privacy & Legal",
                              "Notice, terms, withdraw consent"),
                        .init(.about, "info.circle", "About Voiid",
                              "Version, terms, privacy policy"),
                    ])

                    logOutButton
                        .padding(.top, VoiidSpacing.sm)
                }
                .padding(.horizontal, VoiidSpacing.md)
                .padding(.top, VoiidSpacing.sm)
                .padding(.bottom, VoiidSpacing.xl)
            }
            .scrollIndicators(.hidden)
            .background(VoiidColor.background.ignoresSafeArea())
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: SettingsRoute.self) { route in
                switch route {
                // Wired.
                case .editProfile:   EditProfileView()
                case .linkedDevices: LinkedDevicesView()
                case .backup:        BackupRecoveryView()
                case .privacy:       PrivacySettingsView()
                case .storage:       StorageSettingsView()
                case .about:         AboutView()
                case .legal:         LegalView()
                // Preview only — each says so on the screen.
                case .qrCode:        MyQRCodeScreen()
                case .shareProfile:  ShareProfileScreen()
                case .accountCenter: AccountCenterScreen()
                case .encryption:    EncryptionStatusScreen()
                case .account:       AccountScreen()
                case .chatSettings:  ChatSettingsScreen()
                case .voiidOne:      VoiidOneScreen()
                case .payments:      PaymentsScreen()
                case .help:          HelpAndSupportScreen()
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
        // Sheets do not reliably inherit the root tint.
        .tint(VoiidColor.primary)
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

    /// Same three states as the log-out warning: a key without a backup is not "On".
    private var backupDetail: String {
        switch backupExists {
        case .some(true):  return "On · encrypted backup & restore"
        case .some(false): return "Not set up"
        case nil:          return "Encrypted backup & restore"
        }
    }

    // MARK: Identity

    /// YOU, at the top of your own settings. "Am I in the right account?" is the first
    /// question any settings screen has to answer, so it is never buried.
    private var identity: some View {
        HStack(alignment: .top, spacing: VoiidSpacing.md) {
            // ONE TONE, NOT TWO. The default `fieldFill` disc is darker than the ground in
            // dark mode, which punched a visibly darker circle where the photo would be.
            ProfileAvatarButton(photoURL: session.profile.photoURL,
                                name: session.profile.fullName,
                                size: 84,
                                placeholderFill: VoiidColor.surfaceCard)

            VStack(alignment: .leading, spacing: 4) {
                Text(session.profile.fullName.isEmpty ? "Add your name"
                                                      : session.profile.fullName)
                    .font(VoiidFont.rounded(22, .bold))
                    .foregroundColor(session.profile.fullName.isEmpty
                                     ? VoiidColor.placeholder : VoiidColor.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)

                // The handle leads because it is the identifier you share; the number is
                // quieter beneath. Both truncate rather than wrap — at 84pt the avatar
                // leaves too little width for a dot-separated row to survive real data.
                if let handle = session.profile.username, !handle.isEmpty {
                    Text("@\(handle)")
                        .font(VoiidFont.rounded(14))
                        .foregroundColor(VoiidColor.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                if !session.profile.phoneNumber.isEmpty {
                    Text(session.profile.phoneNumber)
                        .font(VoiidFont.rounded(13))
                        .foregroundColor(VoiidColor.textSecondary)
                        .lineLimit(1)
                }

                // Your own availability status, where you already look to answer "am I in the
                // right account?".
                //
                // ONLY WHEN SET. An "Available" that appears by default would be a status the
                // user never chose, shown to everyone who can see their profile — and the
                // absence of a line is the honest rendering of having no status. The row does
                // not tap through: Privacy owns the control, and a second door into it from a
                // block that is otherwise pure identity would be a third way to reach one
                // setting. Unrecognised values fall out at `from` and render nothing, so a
                // legacy row's unvetted text never reaches the screen.
                if let status = AvailabilityStatus.from(session.profile.statusText) {
                    HStack(spacing: 5) {
                        Image(systemName: status.systemImage)
                            .font(.system(size: 10))
                            .foregroundColor(status.tint)
                        Text(status.label)
                            .font(VoiidFont.rounded(13))
                            .foregroundColor(VoiidColor.textSecondary)
                            .lineLimit(1)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Your status is \(status.label)")
                }

                HStack(spacing: VoiidSpacing.sm) {
                    Button {
                        Haptics.tap()
                        path.append(.editProfile)
                    } label: {
                        Text("Edit profile")
                            .font(VoiidFont.rounded(14, .semibold))
                            .foregroundColor(VoiidColor.accentInk)
                            .padding(.horizontal, VoiidSpacing.md)
                            .frame(height: 36)
                            .background(Capsule().stroke(VoiidColor.accent, lineWidth: 1.5))
                    }
                    .buttonStyle(PressableButtonStyle())

                    Button {
                        Haptics.tap()
                        path.append(.qrCode)
                    } label: {
                        Image(systemName: "qrcode")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundColor(VoiidColor.accentInk)
                            .frame(width: 36, height: 36)
                            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(VoiidColor.accent, lineWidth: 1.5))
                    }
                    .buttonStyle(PressableButtonStyle())
                    .accessibilityLabel("My QR code")
                }
                .padding(.top, 6)
            }

            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .contain)
    }

    // MARK: Quick actions

    private var quickActions: some View {
        HStack(spacing: 0) {
            quickAction(.editProfile, "person.crop.circle", "Edit profile")
            quickDivider
            quickAction(.qrCode, "qrcode", "My QR code")
            quickDivider
            quickAction(.shareProfile, "square.and.arrow.up", "Share profile")
            quickDivider
            quickAction(.accountCenter, "gearshape", "Account center")
        }
        .padding(.vertical, VoiidSpacing.md)
        .background(VoiidColor.surfaceCard)
        .clipShape(RoundedRectangle(cornerRadius: VoiidRadius.lg, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: VoiidRadius.lg, style: .continuous)
            .stroke(VoiidColor.divider, lineWidth: 1))
    }

    private func quickAction(_ route: SettingsRoute, _ icon: String,
                             _ label: String) -> some View {
        Button {
            Haptics.tap()
            path.append(route)
        } label: {
            VStack(spacing: 6) {
                Circle()
                    .stroke(VoiidColor.accent, lineWidth: 1.5)
                    .frame(width: 40, height: 40)
                    .overlay {
                        Image(systemName: icon)
                            .font(.system(size: 17, weight: .medium))
                            .foregroundColor(VoiidColor.accentInk)
                    }
                    .overlay(alignment: .topTrailing) {
                        if !route.isWired { UnwiredDot().offset(x: 1, y: -1) }
                    }

                Text(label)
                    .font(VoiidFont.rounded(11))
                    .foregroundColor(VoiidColor.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle())
    }

    private var quickDivider: some View {
        Rectangle()
            .fill(VoiidColor.divider)
            .frame(width: 1, height: 44)
    }

    // MARK: Encryption banner

    private var encryptionBanner: some View {
        Button {
            Haptics.tap()
            path.append(.encryption)
        } label: {
            HStack(spacing: VoiidSpacing.md) {
                Circle()
                    .fill(VoiidColor.accent.opacity(0.12))
                    .frame(width: 44, height: 44)
                    .overlay {
                        Image(systemName: "checkmark.shield.fill")
                            .font(.system(size: 19))
                            .foregroundColor(VoiidColor.accentInk)
                    }

                VStack(alignment: .leading, spacing: 2) {
                    Text("You're protected with end-to-end encryption")
                        .font(VoiidFont.rounded(14, .semibold))
                        .foregroundColor(VoiidColor.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)

                    Text("Your chats, calls and data are always private.")
                        .font(VoiidFont.rounded(12.5))
                        .foregroundColor(VoiidColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }

                Spacer(minLength: 0)

                chevron
            }
            .padding(VoiidSpacing.md)
            .contentShape(Rectangle())
        }
        .buttonStyle(RowButtonStyle())
        .background(VoiidColor.accent.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: VoiidRadius.lg, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: VoiidRadius.lg, style: .continuous)
            .stroke(VoiidColor.accent.opacity(0.3), lineWidth: 1))
        .accessibilityElement(children: .combine)
    }

    // MARK: Groups

    /// One row's worth of content, so a group can be declared as data rather than nested views.
    private struct Row {
        let route: SettingsRoute
        let icon: String
        let title: String
        let detail: String

        init(_ route: SettingsRoute, _ icon: String, _ title: String, _ detail: String) {
            self.route = route
            self.icon = icon
            self.title = title
            self.detail = detail
        }
    }

    private func group(_ title: String, rows: [Row]) -> some View {
        group(title, rows: rows, trailing: { EmptyView() })
    }

    /// `trailing` is for the rows that are not routes — Notifications leaves the app, so it
    /// cannot be a `Row`, but it belongs inside the same card.
    private func group<T: View>(_ title: String, rows: [Row],
                                @ViewBuilder trailing: () -> T) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(VoiidFont.rounded(13))
                .foregroundColor(VoiidColor.textSecondary)
                .padding(.leading, 4)

            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.element.route) { index, row in
                    settingsRow(row)

                    if index < rows.count - 1 {
                        rowDivider
                    }
                }
                trailing()
            }
            .background(VoiidColor.surfaceCard)
            .clipShape(RoundedRectangle(cornerRadius: VoiidRadius.lg, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: VoiidRadius.lg, style: .continuous)
                .stroke(VoiidColor.divider, lineWidth: 1))
        }
    }

    private var rowDivider: some View {
        Rectangle()
            .fill(VoiidColor.divider)
            .frame(height: 1)
            .padding(.leading, 60)
    }

    private func settingsRow(_ row: Row) -> some View {
        Button {
            Haptics.tap()
            path.append(row.route)
        } label: {
            HStack(spacing: VoiidSpacing.md) {
                Circle()
                    .stroke(VoiidColor.accent.opacity(0.5), lineWidth: 1)
                    .frame(width: 34, height: 34)
                    .overlay {
                        Image(systemName: row.icon)
                            .font(.system(size: 15, weight: .medium))
                            .foregroundColor(VoiidColor.accentInk)
                    }

                VStack(alignment: .leading, spacing: 1) {
                    Text(row.title)
                        .font(VoiidFont.rounded(15, .semibold))
                        .foregroundColor(VoiidColor.textPrimary)

                    Text(row.detail)
                        .font(VoiidFont.rounded(12))
                        .foregroundColor(VoiidColor.textSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }

                Spacer(minLength: 0)

                // The state BEFORE the tap, not after it.
                if !row.route.isWired { UnwiredDot() }

                chevron
            }
            .padding(.horizontal, VoiidSpacing.md)
            .padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(RowButtonStyle())
        .accessibilityElement(children: .combine)
    }

    /// Not a route. iOS owns Voiid's notification behaviour entirely, so this jumps straight
    /// to Voiid's pane in Settings.app. The external-link glyph rather than a chevron tells
    /// the user they are leaving the app; that distinction is the contract, not decoration.
    private var notificationsRow: some View {
        VStack(spacing: 0) {
            rowDivider

            Button {
                Haptics.tap()
                if let url = URL(string: UIApplication.openNotificationSettingsURLString) {
                    openURL(url)
                }
            } label: {
                HStack(spacing: VoiidSpacing.md) {
                    Circle()
                        .stroke(VoiidColor.accent.opacity(0.5), lineWidth: 1)
                        .frame(width: 34, height: 34)
                        .overlay {
                            Image(systemName: "bell")
                                .font(.system(size: 15, weight: .medium))
                                .foregroundColor(VoiidColor.accentInk)
                        }

                    VStack(alignment: .leading, spacing: 1) {
                        Text("Notifications")
                            .font(VoiidFont.rounded(15, .semibold))
                            .foregroundColor(VoiidColor.textPrimary)
                        Text("Message, group & call tones")
                            .font(VoiidFont.rounded(12))
                            .foregroundColor(VoiidColor.textSecondary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 0)

                    Image(systemName: "arrow.up.forward.app")
                        .font(.footnote)
                        .foregroundStyle(VoiidColor.placeholder)
                }
                .padding(.horizontal, VoiidSpacing.md)
                .padding(.vertical, 11)
                .contentShape(Rectangle())
            }
            .buttonStyle(RowButtonStyle())
            .accessibilityHint("Opens Voiid's notification settings in the Settings app")
        }
    }

    // MARK: Display

    /// VOIID'S OWN GROUP — the reference never drew it.
    ///
    /// Navigation and inline choice are different interactions and belong in different
    /// groups: every other card here is a list of doors, and dropping two segmented controls
    /// among them breaks that rhythm twice. Apple's own Settings does the same — Display &
    /// Brightness is its own section, not a picker buried among links.
    private var displayGroup: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Display")
                .font(VoiidFont.rounded(13))
                .foregroundColor(VoiidColor.textSecondary)
                .padding(.leading, 4)

            VStack(spacing: 0) {
                settingsPicker("Chat list", icon: "rectangle.grid.2x2") {
                    Picker("Chat list", selection: Binding(
                        get: { chatLayout.layout },
                        set: { Haptics.selection(); chatLayout.layout = $0 }
                    )) {
                        ForEach(ChatLayoutPreference.Layout.allCases) { l in
                            Text(l.label).tag(l)
                        }
                    }
                }

                rowDivider

                // INLINE, not a pushed screen: the result is visible the instant you tap, so
                // navigating away to choose and back to see the effect would be worse.
                settingsPicker("Appearance", icon: "circle.lefthalf.filled") {
                    Picker("Appearance", selection: Binding(
                        get: { theme.mode },
                        set: { Haptics.selection(); theme.mode = $0 }
                    )) {
                        ForEach(ThemePreference.Mode.allCases) { m in
                            Text(m.label).tag(m)
                        }
                    }
                }
            }
            .background(VoiidColor.surfaceCard)
            .clipShape(RoundedRectangle(cornerRadius: VoiidRadius.lg, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: VoiidRadius.lg, style: .continuous)
                .stroke(VoiidColor.divider, lineWidth: 1))
        }
    }

    /// Label above, control beneath, so the icon column still reads as a column instead of
    /// the control colliding with it.
    private func settingsPicker<P: View>(_ title: String, icon: String,
                                         @ViewBuilder _ picker: () -> P) -> some View {
        VStack(alignment: .leading, spacing: VoiidSpacing.sm) {
            HStack(spacing: VoiidSpacing.md) {
                Circle()
                    .stroke(VoiidColor.accent.opacity(0.5), lineWidth: 1)
                    .frame(width: 34, height: 34)
                    .overlay {
                        Image(systemName: icon)
                            .font(.system(size: 15, weight: .medium))
                            .foregroundColor(VoiidColor.accentInk)
                    }

                Text(title)
                    .font(VoiidFont.rounded(15, .semibold))
                    .foregroundColor(VoiidColor.textPrimary)

                Spacer(minLength: 0)
            }

            picker()
                .pickerStyle(.segmented)
                .labelsHidden()
        }
        .padding(.horizontal, VoiidSpacing.md)
        .padding(.vertical, 11)
    }

    private var chevron: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 14, weight: .semibold))
            .foregroundColor(VoiidColor.textSecondary.opacity(0.7))
    }

    // MARK: Log out

    /// Alone, at the bottom, in `VoiidColor.error`. The isolation *is* the affordance: a
    /// destructive row sharing a card with navigation rows is a mis-tap generator.
    private var logOutButton: some View {
        Button {
            Haptics.rigid()
            confirmLogOut = true
        } label: {
            HStack(spacing: VoiidSpacing.sm) {
                Image(systemName: "rectangle.portrait.and.arrow.right")
                    .font(.system(size: 17, weight: .medium))
                Text("Log out")
                    .font(VoiidFont.rounded(16, .semibold))
            }
            .foregroundColor(VoiidColor.error)
            .frame(maxWidth: .infinity)
            .frame(height: 54)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle())
        .disabled(loggingOut)
        .background(VoiidColor.error.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: VoiidRadius.lg, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: VoiidRadius.lg, style: .continuous)
            .stroke(VoiidColor.error.opacity(0.35), lineWidth: 1))
    }

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
