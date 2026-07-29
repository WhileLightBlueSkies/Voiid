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
