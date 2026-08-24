//
//  SettingsChrome.swift
//  Voiid
//
//  The ONLY shared vocabulary for the Settings tree. Every Settings screen — the
//  root sheet and all five pushed screens — is built from exactly these two symbols.
//
//  Why this file exists
//  --------------------
//  Five private copies of a hand-rolled "card" helper already exist in this codebase.
//  The Settings rebuild does not add a sixth. If you are writing a Settings screen and
//  find yourself declaring a private `card`, a private `divider`, a private row builder
//  or a second toast, stop: use `SettingsSection` + `voiidSettingsList()`.
//
//  The design decision underneath it
//  ---------------------------------
//  The native `.insetGrouped` List *is* the Voiid card idiom — it brings correct separators,
//  Dynamic Type restacking, swipe actions and VoiceOver grouping for free. Brand cues are
//  layered on top: the background gutter (supplied by the caller, see below) and Voiid
//  separators.
//
//  HISTORICAL NOTE: this used to lean on the app being pinned to light mode, where iOS drew
//  row backgrounds with `systemBackground` = #FFFFFF, which happened to equal the old
//  `surfaceCard` byte for byte. The app now supports both themes (Peacock), so that
//  coincidence is gone and `voiidSettingsList()` pins `listRowBackground` to the token
//  explicitly — otherwise Settings would be the one screen drifting off-palette in dark.
//
//  Typography note (deliberate, documented deviation from Theme.swift)
//  ------------------------------------------------------------------
//  `VoiidFont.*` are fixed-point `.system(size:)` fonts and do NOT scale with Dynamic
//  Type. Settings is a text-dense reading surface and must scale. `voiidSettingsList()`
//  therefore applies `.fontDesign(.rounded)` once, which propagates through the
//  environment to every descendant `Text`; screens then use semantic styles only:
//
//      .body                       row titles
//      .subheadline                trailing detail
//      .footnote                   section footers, status lines
//      .title3.weight(.semibold)   the profile name on the root row
//
//  That yields SF Pro Rounded *and* full Dynamic Type. Do not reach for `VoiidFont.*`
//  in Settings; the one sanctioned exception is the initials inside `ProfileAvatarButton`,
//  which sizes itself relative to its own frame.
//
//  Also: no fixed row heights, anywhere. Native rows size themselves and `LabeledContent`
//  restacks vertically at accessibility sizes on its own. A hardcoded height reintroduces
//  clipping.
//

import SwiftUI

// MARK: - SettingsSection

/// A `Section` with Voiid's settings chrome already applied.
///
/// Applies, to the section it wraps:
///  * `.listRowBackground(VoiidColor.surfaceCard)` on every row (states the white
///    explicitly rather than inheriting it from the system);
///  * `.listRowSeparatorTint(VoiidColor.divider.opacity(0.6))` — separators on brand
///    the Voiid `divider` token instead of system grey;
///  * header typography: `.footnote.weight(.semibold)`, `VoiidColor.textSecondary`,
///    `.textCase(nil)` so headers read as sentence case, not shouty uppercase;
///  * footer typography: `.footnote`, `VoiidColor.textSecondary`.
///
/// Header and footer are both optional. **Use footers.** They are how Apple explains a
/// setting, and on these screens they are load-bearing: several of them exist purely to
/// correct an assumption the toggle above would otherwise create.
///
/// Individual rows may still override anything — an inner modifier wins over the one
/// this applies. `.listRowBackground(Color.clear)` on a single row (the centred avatar
/// on Edit Profile, say) works exactly as you would expect.
///
/// ```swift
/// SettingsSection("Message receipts",
///                 footer: "When these are off, this device stops sending them.") {
///     Toggle("Send read receipts", isOn: $settings.sendReadReceipts)
///         .tint(VoiidColor.primary)
/// }
/// ```
struct SettingsSection<Content: View>: View {
    private let header: String?
    private let footer: String?
    private let content: Content

    /// - Parameters:
    ///   - header: Sentence-case section header, or `nil` for an unheaded group.
    ///   - footer: Explanatory footer, or `nil`.
    ///   - content: The section's rows.
    init(_ header: String? = nil,
         footer: String? = nil,
         @ViewBuilder content: () -> Content) {
        self.header = header
        self.footer = footer
        self.content = content()
    }

    var body: some View {
        Section {
            // `Group` propagates list-row modifiers to each child row rather than
            // treating the whole block as one row.
            Group {
                content
            }
            .listRowBackground(VoiidColor.surfaceCard)
            .listRowSeparatorTint(VoiidColor.divider.opacity(0.6))
        } header: {
            if let header {
                Text(header)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(VoiidColor.textSecondary)
                    .textCase(nil)
            }
        } footer: {
            if let footer {
                Text(footer)
                    .font(.footnote)
                    .foregroundStyle(VoiidColor.textSecondary)
            }
        }
    }
}

// MARK: - List chrome

extension View {
    /// Applies the Settings list chrome. Put this on the `List` of every Settings screen.
    ///
    /// It sets: `.insetGrouped` style, a hidden scroll background (which strips only the
    /// systemGroupedBackground grey — row fills survive), `.fontDesign(.rounded)`, and an
    /// inline navigation title.
    ///
    /// Two things it deliberately does **not** do, because they belong to the caller:
    ///
    /// ```swift
    /// List { … }
    ///     .voiidSettingsList()
    ///     .background(VoiidColor.background.ignoresSafeArea())   // the ground gutter
    ///     .navigationTitle("Privacy")
    /// ```
    ///
    /// The gutter colour is what makes these screens read as Voiid rather than stock iOS;
    /// it is one line and it is not optional.
    ///
    /// Note: accept iOS's 10pt group corner radius. Do **not** force `VoiidRadius.lg`.
    /// Matching the platform is the more native call, and it is the only visible delta
    /// from the hand-rolled cards this replaces.
    func voiidSettingsList() -> some View {
        self
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            // Rows are pinned to the Voiid card token rather than left to the platform's
            // `systemBackground`. That default was only ever correct because the app was
            // pinned to light, where systemBackground happened to equal the card colour
            // exactly. Now that both themes exist, the platform's dark grey would not match
            // Peacock's `surfaceCard`, so Settings alone would drift off-palette.
            .listRowBackground(VoiidColor.surfaceCard)
            .fontDesign(.rounded)
            .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - The reference chrome
//
// ── WHY A SECOND VOCABULARY, AND NOT A REPLACEMENT ──────────────────────────────
// Everything above builds a native `.insetGrouped` List. That was the right call when
// Settings was the only design in the app, and the doc comment's reasoning still holds:
// native rows bring Dynamic Type restacking, swipe actions and VoiceOver grouping for free.
//
// The Voiid UI reference draws settings differently — a large scrolling title rather than a
// nav bar, hand-built cards at `VoiidRadius.lg` rather than the platform's 10pt group corner,
// circle-outline accent icons rather than plain SF Symbols in Label's leading slot, and an
// accent-tinted card for whatever the screen is really about. The root sheet already moved to
// that design; a pushed screen still wearing inset-grouped rows reads as a different app the
// moment you tap into it.
//
// So this section adds the reference's card idiom as SHARED symbols, and every pushed screen
// is rebuilt on them. The List vocabulary above stays for anything that genuinely wants a
// platform list (a long roster with swipe-to-delete, say) — but Settings no longer uses it.
//
// The Dynamic Type concern from above is answered rather than abandoned: `VoiidCardSection`
// and `VoiidSettingsRow` use semantic font styles (.body, .subheadline, .footnote), so they
// scale exactly as the List rows did. Only the CHROME changed, not the typography rule.

/// The large scrolling header every pushed Settings screen opens with.
///
/// Replaces the inline navigation title: the reference puts the screen's name in the content
/// at 32pt so it scrolls away, which is what makes these read as pages rather than as rows
/// that happen to have pushed.
struct VoiidSettingsHeader: View {
    let title: String
    let subtitle: String?
    /// An optional capsule under the subtitle — "End-to-end encrypted" and friends. The one
    /// place a Settings screen gets to state its guarantee.
    var badge: (icon: String, text: String)?

    init(_ title: String, subtitle: String? = nil,
         badge: (icon: String, text: String)? = nil) {
        self.title = title
        self.subtitle = subtitle
        self.badge = badge
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.largeTitle.weight(.bold))
                .foregroundStyle(VoiidColor.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            if let subtitle {
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(VoiidColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let badge {
                HStack(spacing: 6) {
                    Image(systemName: badge.icon)
                        .font(.system(size: 11))
                    Text(badge.text)
                        .font(.footnote.weight(.medium))
                }
                .foregroundStyle(VoiidColor.accentInk)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Capsule().fill(VoiidColor.accent.opacity(0.10)))
                .overlay(Capsule().stroke(VoiidColor.accent.opacity(0.4), lineWidth: 1))
                .padding(.top, 4)
                .accessibilityElement(children: .combine)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A labelled card group — the reference's replacement for `SettingsSection`.
///
/// The label sits OUTSIDE the card in `textSecondary`, and the rows sit inside a
/// `surfaceCard` rectangle at `VoiidRadius.lg` with a hairline border. Dividers between rows
/// are the caller's job via `VoiidRowDivider`, because only the caller knows which rows are
/// adjacent once conditionals are involved.
struct VoiidCardSection<Content: View>: View {
    private let header: String?
    private let footer: String?
    private let content: Content

    init(_ header: String? = nil, footer: String? = nil,
         @ViewBuilder content: () -> Content) {
        self.header = header
        self.footer = footer
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let header {
                Text(header)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(VoiidColor.textSecondary)
                    .padding(.leading, 4)
            }

            VStack(spacing: 0) { content }
                .background(VoiidColor.surfaceCard)
                .clipShape(RoundedRectangle(cornerRadius: VoiidRadius.lg, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: VoiidRadius.lg, style: .continuous)
                    .stroke(VoiidColor.divider, lineWidth: 1))

            // FOOTERS ARE LOAD-BEARING on these screens — several exist purely to correct an
            // assumption the control above would otherwise create. Keeping them was a
            // requirement of the conversion, not a nicety.
            if let footer {
                Text(footer)
                    .font(.footnote)
                    .foregroundStyle(VoiidColor.textSecondary)
                    .padding(.horizontal, 4)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// The hairline between two rows inside a `VoiidCardSection`. Inset to clear the icon column
/// so it separates the text rather than cutting the whole card in half.
struct VoiidRowDivider: View {
    var inset: CGFloat = 60

    var body: some View {
        Rectangle()
            .fill(VoiidColor.divider)
            .frame(height: 1)
            .padding(.leading, inset)
    }
}

/// The circle-outline accent icon every reference row leads with.
struct VoiidRowIcon: View {
    let systemName: String
    var size: CGFloat = 34
    /// Destructive rows tint the whole thing with `error` instead of the accent.
    var destructive: Bool = false

    var body: some View {
        Circle()
            .stroke((destructive ? VoiidColor.error : VoiidColor.accent).opacity(0.5),
                    lineWidth: 1)
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: systemName)
                    .font(.system(size: size * 0.44, weight: .medium))
                    .foregroundStyle(destructive ? VoiidColor.error : VoiidColor.accentInk)
            }
    }
}

/// One row inside a `VoiidCardSection`: icon, title, optional detail, and whatever the caller
/// puts on the trailing edge (a chevron, a value, a toggle, a spinner).
///
/// `action` nil means the row is not tappable — a value row rather than a door. That is a
/// real distinction on these screens and it is drawn from the presence of the closure rather
/// than from a separate type.
struct VoiidSettingsRow<Trailing: View>: View {
    let icon: String
    let title: String
    var detail: String?
    var destructive: Bool = false
    var action: (() -> Void)?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        if let action {
            // NO `Haptics.tap()` HERE, deliberately.
            //
            // An earlier version fired one before calling `action`. That silently changed the
            // feel of every row whose action plays its OWN haptic: the Map kill switch went
            // from a single `rigid` to `tap` then `rigid`, which reads as a stutter rather
            // than as the heavier confirmation `rigid` exists to give. A shared row cannot
            // know which haptic its action wants, so it plays none and the caller decides.
            Button {
                action()
            } label: { rowBody }
                .buttonStyle(RowButtonStyle())
                .accessibilityElement(children: .combine)
        } else {
            rowBody.accessibilityElement(children: .combine)
        }
    }

    private var rowBody: some View {
        HStack(spacing: VoiidSpacing.md) {
            VoiidRowIcon(systemName: icon, destructive: destructive)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.body)
                    .foregroundStyle(destructive ? VoiidColor.error : VoiidColor.textPrimary)
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
        .contentShape(Rectangle())
    }
}

extension VoiidSettingsRow where Trailing == EmptyView {
    init(icon: String, title: String, detail: String? = nil,
         destructive: Bool = false, action: (() -> Void)? = nil) {
        self.init(icon: icon, title: title, detail: detail,
                  destructive: destructive, action: action) { EmptyView() }
    }
}

/// The chevron a navigating row ends with. A shared symbol so every screen's is identical.
struct VoiidChevron: View {
    var body: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(VoiidColor.textSecondary.opacity(0.7))
    }
}

extension View {
    /// The page chrome for a pushed Settings screen built on cards.
    ///
    /// Hides the navigation title (the content's own 32pt header replaces it) but KEEPS the
    /// navigation bar, so the system back button, its swipe-back gesture and its hit target
    /// all survive. The reference draws its own floating back button; that is not worth
    /// reimplementing when the platform's works and is already correct.
    func voiidSettingsPage() -> some View {
        self
            .scrollIndicators(.hidden)
            .background(VoiidColor.background.ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
    }
}
