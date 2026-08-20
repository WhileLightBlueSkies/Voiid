//
//  OnboardingKit.swift
//  Voiid
//
//  The onboarding design kit, ported VERBATIM from the design source
//  (`Voiid Ui/DesignSystem/OnboardingKit.swift`). Sizes, paddings, radii and weights are the
//  reference's numbers — not approximations, and not substitutions from the app's other
//  components. That exactness is the point of this file.
//
//  ── WHY THIS SITS BESIDE OnboardingBrandChrome RATHER THAN REPLACING IT ─────────
//  `OnboardingBrandChrome` carries the GLOWING MARK composition — the V on a horizon arc, with
//  bloom. That is a different design: the reference's screens lead with the WORDMARK as type at
//  34pt and no glow. Both exist because different screens use each, and collapsing them would
//  mean one screen silently changing when the other is edited.
//
//  Screens ported to the reference use the types in this file. Screens still on the older
//  composition use OnboardingBrandChrome. A screen must not mix the two headers.
//

import SwiftUI

// MARK: - Brand surfaces

/// The brand surfaces, named once.
///
/// NOT a second palette. `VoiidColor` (Theme.swift) is the app's real token set and stays the
/// source of truth for anything theme-aware. What lives here is the small group of values that
/// are FIXED regardless of theme, because the screens that use them are committed to dark: the
/// near-black ground, the surfaces stacked on it, and the accent.
///
/// Keeping them separate makes the distinction legible at the call site. `VoiidColor.background`
/// resolves per theme and is right for the app proper; `VoiidBrand.ground` is always Voiid Black
/// and is right for onboarding, where the glow only exists on black.
enum VoiidBrand {
    /// Voiid Black — the ground for every committed-dark screen.
    static let ground = Color(hex: 0x0B0B0B)
    /// A card sitting on the ground.
    static let card = Color(hex: 0x121212)
    /// A row inside a card, one step up so it separates from what it sits on.
    static let row = Color(hex: 0x181818)
    /// Hairlines. White at low alpha rather than a fixed grey, so they stay correct if the
    /// surfaces beneath them are ever re-tuned.
    static let hairline = Color.white.opacity(0.07)

    /// Tide — the brand teal. The token names below still read `lime*` because they are the
    /// SLOTS (fill / lit edge / lower stop / label), not the hue, and renaming them would
    /// churn 60-odd onboarding call sites for no visual change. The values are the single
    /// source of truth; `VoiidBrand` in the reference calls the same slots `cyan*`.
    static let lime = Color(hex: 0x13828C)
    /// The mark's lit top edge, and a pill's upper stop.
    static let limeBright = Color(hex: 0x68B8BD)
    /// A pill's lower stop.
    static let limeDeep = Color(hex: 0x0E6E77)

    /// Text on a Tide fill. WHITE, and this INVERTS what lime required: lime was a light
    /// fill needing a near-black label, Tide is a mid-tone where white wins (4.57:1 vs
    /// 4.30:1). Every filled button, badge and pill label flips with it.
    static let onLime = Color(hex: 0xFFFFFF)
}

// MARK: - Splash handoff

/// The shared-element contract between the splash and the first onboarding screen.
///
/// One constant, because a `matchedGeometryEffect` id is a STRING MATCHED AT RUNTIME: a typo on
/// either side does not fail to compile, it just silently stops animating and cross-fades
/// instead. That is a bug you have to notice by eye, which is the worst kind.
enum OnboardingHandoff {
    static let wordmarkID = "voiid.wordmark"
}

// MARK: - Header

/// Wordmark, title, blurb — the top of every ported onboarding screen.
struct OnboardingHeader: View {

    /// THE onboarding wordmark size. One constant, because it was previously a `34` literal in
    /// several files — identical by luck, and one edit away from the wordmark being a different
    /// size on one screen than the others. Every onboarding screen renders the mark through this
    /// type, so they cannot disagree.
    static let wordmarkSize: CGFloat = 34

    /// How the title is set.
    enum Title {
        /// One line: white part, then the lime part immediately after — "Allow Permissions".
        case inline(String, accent: String)
        /// Two lines, the second in lime. The break is DELIBERATE, not a wrap: free wrapping
        /// breaks at a different word on every width, and these titles are composed so the
        /// accent half lands on its own line.
        case stacked(String, accent: String)
    }

    let title: Title
    /// The explanatory line under the title.
    let blurb: String

    /// Whether the wordmark is drawn above the title.
    ///
    /// FALSE WHEN THE TITLE ITSELF SAYS "VOIID". The restore pages read "Welcome back to
    /// **Voiid**" and "Restoring your **Voiid**", so drawing the wordmark above them put the
    /// brand on screen twice, a few points apart, at two different sizes — which reads as a
    /// layout bug rather than branding. In that case the title IS the wordmark's placement and
    /// the mark above is redundant.
    var showsWordmark: Bool = true

    /// The splash's namespace, when this header is the landing point of the splash handoff.
    ///
    /// THE EFFECT BELONGS TO THE WORDMARK, NOT THE HEADER. Pairing it with the whole header —
    /// wordmark plus a 26pt title plus a three-line blurb — asks SwiftUI to interpolate a
    /// compact lockup into a tall text block, and it does exactly that: the mark stretches and
    /// smears on its way in. Only the wordmark exists on both sides, so only the wordmark can
    /// travel. Nil on every screen that is not the handoff target.
    var logoNS: Namespace.ID? = nil

    /// Convenience for the common one-line case, so existing call sites read unchanged.
    init(title: String, accent: String, blurb: String,
         showsWordmark: Bool = true, logoNS: Namespace.ID? = nil) {
        self.title = .inline(title, accent: accent)
        self.blurb = blurb
        self.showsWordmark = showsWordmark
        self.logoNS = logoNS
    }

    init(title: Title, blurb: String,
         showsWordmark: Bool = true, logoNS: Namespace.ID? = nil) {
        self.title = title
        self.blurb = blurb
        self.showsWordmark = showsWordmark
        self.logoNS = logoNS
    }

    var body: some View {
        VStack(spacing: VoiidSpacing.sm) {
            // WHITE LETTERS, LIME DOTS — the brand lockup, and both halves are explicit here
            // rather than left to the defaults.
            //
            // `BrandWordmark`'s default colour is `VoiidColor.primary`, which is THEME-RESOLVING:
            // lime on dark, near-black on light. Onboarding is committed to dark, so the default
            // happened to give lime letters — the wordmark is not lime, it is white with two lime
            // tittles, and a lime word loses that contrast entirely.
            if showsWordmark { wordmark }

            titleText
                .font(VoiidFont.rounded(26, .bold))
                .multilineTextAlignment(.center)

            Text(blurb)
                .font(VoiidFont.subhead)
                .foregroundColor(VoiidColor.textSecondary)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
        }
        .frame(maxWidth: .infinity)
    }

    /// The wordmark, optionally carrying the shared-element id.
    ///
    /// Branch rather than an optional modifier: `matchedGeometryEffect` has no "inactive" form,
    /// and applying it with a namespace nobody else uses still opts the view into the geometry
    /// system for no reason.
    @ViewBuilder
    private var wordmark: some View {
        if let logoNS {
            BrandWordmark(size: Self.wordmarkSize, color: .white, dotColor: VoiidBrand.lime)
                .matchedGeometryEffect(id: OnboardingHandoff.wordmarkID, in: logoNS)
        } else {
            BrandWordmark(size: Self.wordmarkSize, color: .white, dotColor: VoiidBrand.lime)
        }
    }

    @ViewBuilder
    private var titleText: some View {
        switch title {
        case let .inline(lead, accent):
            Text(lead).foregroundColor(VoiidColor.textPrimary)
                + Text(accent).foregroundColor(VoiidBrand.lime)

        case let .stacked(lead, accent):
            VStack(spacing: 0) {
                Text(lead).foregroundColor(VoiidColor.textPrimary)
                Text(accent).foregroundColor(VoiidBrand.lime)
            }
        }
    }
}

// MARK: - Card

/// A group of rows on the ground.
struct OnboardingKitCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            content
        }
        .background(VoiidBrand.card)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(VoiidBrand.hairline, lineWidth: 1)
        )
    }
}

/// The divider between two rows in an `OnboardingKitCard`.
///
/// Inset to the text rather than full-bleed: a line running under the icon column cuts the
/// row's own left margin and makes the list look like a table.
struct OnboardingRowDivider: View {
    var body: some View {
        Rectangle()
            .fill(VoiidBrand.hairline)
            .frame(height: 1)
            .padding(.leading, 68)
    }
}

// MARK: - Row

/// One tappable row: lime-tinted icon tile, title, subtitle, chevron.
struct OnboardingRow: View {
    let icon: String
    let title: String
    let subtitle: String
    var subtitleWraps: Bool = false
    /// Whether the row shows a trailing chevron. True for rows that navigate; false for rows
    /// that are purely informational — see the note at the chevron itself.
    var showsChevron: Bool = true
    /// Nil for an informational row. A row with nothing to do is rendered as PLAIN CONTENT, not
    /// as a Button with an empty closure: a button still takes the tap, still highlights under
    /// RowButtonStyle, and still announces itself to VoiceOver as a button, all to do nothing.
    var action: (() -> Void)? = nil

    var body: some View {
        if let action {
            Button(action: action) { rowContent }
                .buttonStyle(RowButtonStyle())
                .accessibilityElement(children: .combine)
                .accessibilityHint("Opens \(title)")
        } else {
            rowContent
                .accessibilityElement(children: .combine)
        }
    }

    private var rowContent: some View {
        HStack(spacing: VoiidSpacing.md) {
                RoundedRectangle(cornerRadius: VoiidRadius.md, style: .continuous)
                    .fill(VoiidBrand.lime.opacity(0.10))
                    .overlay(
                        RoundedRectangle(cornerRadius: VoiidRadius.md, style: .continuous)
                            .stroke(VoiidBrand.lime.opacity(0.22), lineWidth: 1)
                    )
                    .frame(width: 40, height: 40)
                    .overlay {
                        Image(systemName: icon)
                            .font(.system(size: 17, weight: .medium))
                            .foregroundColor(VoiidBrand.lime)
                    }

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(VoiidFont.rounded(15, .semibold))
                        .foregroundColor(VoiidColor.textPrimary)

                    subtitleText
                }

                Spacer(minLength: 0)

                // A chevron PROMISES NAVIGATION. Terms' rows keep it because they open a
                // document; Permissions' rows do not, because nothing opens — the whole
                // sequence belongs to Allow All, and a chevron there is an affordance that
                // lies about what a tap does.
                if showsChevron {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(VoiidColor.textSecondary.opacity(0.7))
                }
            }
            .padding(.horizontal, VoiidSpacing.md)
            // Less vertical padding when the subtitle wraps: a two-line row already carries its
            // own height, so Terms' 11pt — tuned for single-line rows — made these rows tall
            // enough that the sixth fell under the footer. Single-line rows keep 11.
        .padding(.vertical, subtitleWraps ? 9 : 11)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var subtitleText: some View {
        let base = Text(subtitle)
            .font(VoiidFont.rounded(12.5))
            .foregroundColor(VoiidColor.textSecondary)

        if subtitleWraps {
            // Tighter leading than the default. A wrapping subtitle is two lines on most rows,
            // and the default gap between them is tuned for prose, not for a two-line label
            // inside a row — it cost enough height to push the last row off screen.
            base
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.leading)
                .lineSpacing(0)
        } else {
            // 0.75 so the longest label still SETS rather than truncating to an ellipsis.
            base
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
    }
}

// MARK: - Footer

/// The pinned footer: an opaque backing under the controls, with the scroll fading into it.
///
/// THE FADE CANNOT DOUBLE AS THE BACKING, which the first version tried. A single top-to-bottom
/// gradient behind the whole footer left the controls on a partly transparent ground, so the
/// last row scrolled through the consent text and both became unreadable. The backing is solid
/// where content sits; the fade lives entirely above it.
struct OnboardingFooter<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: VoiidSpacing.md) {
            content
        }
        .padding(.horizontal, VoiidSpacing.lg)
        .padding(.top, VoiidSpacing.md)
        .padding(.bottom, VoiidSpacing.lg)
        .background(alignment: .top) {
            VoiidBrand.ground
                .ignoresSafeArea()
                .overlay(alignment: .top) {
                    LinearGradient(
                        colors: [VoiidBrand.ground.opacity(0), VoiidBrand.ground],
                        startPoint: .top, endPoint: .bottom
                    )
                    .frame(height: 28)
                    .offset(y: -28)
                }
        }
    }
}

// MARK: - Primary button

/// The primary action: a lime capsule with a trailing arrow.
///
/// `enabled` dims AND disables. Opacity alone would still take the tap; `.disabled` alone would
/// look live. Both, or the control misrepresents what it will do.
struct OnboardingKitButton: View {
    let title: String
    var enabled: Bool = true
    let action: () -> Void

    var body: some View {
        Button {
            Haptics.success()
            action()
        } label: {
            HStack {
                Spacer(minLength: 0)
                Text(title)
                    .font(VoiidFont.rounded(17, .semibold))
                Spacer(minLength: 0)
                Image(systemName: "arrow.right")
                    .font(.system(size: 17, weight: .semibold))
            }
            .foregroundColor(VoiidBrand.onLime)
            .padding(.horizontal, VoiidSpacing.lg)
            .frame(height: 56)
            .frame(maxWidth: .infinity)
            .background(
                Capsule().fill(
                    LinearGradient(
                        colors: [VoiidBrand.limeBright, VoiidBrand.lime],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    )
                )
            )
        }
        .buttonStyle(PressableButtonStyle())
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
        .animation(.easeOut(duration: 0.2), value: enabled)
    }
}

// MARK: - Button styles

/// Scales down on press. 0.97 — enough to feel, short of looking like it shrank.
struct PressableButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.16), value: configuration.isPressed)
    }
}

/// A row highlights rather than scales. Scaling a full-width row inside a card lifts its corners
/// off the card's own edge, which reads as the row detaching.
struct RowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? VoiidBrand.row : .clear)
            .animation(.easeOut(duration: 0.16), value: configuration.isPressed)
    }
}

// MARK: - Form field

/// A form field: icon in a lime disc, a label above the input, and an optional trailing state.
///
/// The label sits ABOVE the value rather than acting as a placeholder that vanishes on focus.
/// A placeholder-as-label is the classic form defect: the moment the user starts typing, the
/// only thing telling them what the field is disappears — and it is exactly when they are most
/// likely to need it.
struct OnboardingField<Trailing: View>: View {
    let icon: String
    let label: String
    let prompt: String
    @Binding var text: String

    var keyboard: UIKeyboardType = .default
    var contentType: UITextContentType?
    var autocapitalization: TextInputAutocapitalization = .sentences
    /// Draws as a multi-line box with a counter when set.
    var characterLimit: Int?
    @ViewBuilder var trailing: Trailing

    @FocusState private var focused: Bool

    var body: some View {
        HStack(alignment: characterLimit == nil ? .center : .top, spacing: VoiidSpacing.md) {
            Circle()
                .fill(VoiidBrand.lime.opacity(0.10))
                .frame(width: 38, height: 38)
                .overlay {
                    Image(systemName: icon)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(VoiidBrand.lime)
                }

            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(VoiidFont.rounded(12.5))
                    .foregroundColor(VoiidColor.textSecondary)

                if let characterLimit {
                    // `axis: .vertical` rather than a TextEditor: a TextEditor brings its own
                    // background, insets and scroll behaviour that all have to be fought back
                    // to match a TextField, and it cannot show a prompt.
                    TextField("", text: $text, prompt: promptText, axis: .vertical)
                        .lineLimit(2...3)
                        .focused($focused)
                        .font(VoiidFont.rounded(16))
                        .foregroundColor(VoiidColor.textPrimary)
                        .onChange(of: text) { _, new in
                            if new.count > characterLimit {
                                text = String(new.prefix(characterLimit))
                            }
                        }
                } else {
                    TextField("", text: $text, prompt: promptText)
                        .focused($focused)
                        .font(VoiidFont.rounded(16))
                        .foregroundColor(VoiidColor.textPrimary)
                        .keyboardType(keyboard)
                        .textContentType(contentType)
                        .textInputAutocapitalization(autocapitalization)
                        .autocorrectionDisabled(contentType == .username || keyboard == .emailAddress)
                }
            }

            Spacer(minLength: 0)

            trailing
        }
        .padding(.horizontal, VoiidSpacing.md)
        // ~58pt tall: comfortably past the 44pt minimum tap target, and uniform with the
        // phone-number and OTP fields, which are the same height elsewhere in onboarding.
        .padding(.vertical, 11)
        .overlay(alignment: .bottomTrailing) {
            if let characterLimit {
                Text("\(text.count)/\(characterLimit)")
                    .font(VoiidFont.rounded(12))
                    .foregroundColor(VoiidColor.textSecondary)
                    .padding(.trailing, VoiidSpacing.md)
                    .padding(.bottom, 10)
                    .monospacedDigit()
            }
        }
        .background(VoiidBrand.card)
        .clipShape(RoundedRectangle(cornerRadius: VoiidRadius.lg, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: VoiidRadius.lg, style: .continuous)
                .stroke(focused ? VoiidBrand.lime.opacity(0.7) : VoiidBrand.hairline,
                        lineWidth: focused ? 1.5 : 1)
        )
        .animation(.easeOut(duration: 0.18), value: focused)
    }

    private var promptText: Text {
        Text(prompt).foregroundColor(VoiidColor.placeholder)
    }
}

extension OnboardingField where Trailing == EmptyView {
    init(icon: String,
         label: String,
         prompt: String,
         text: Binding<String>,
         keyboard: UIKeyboardType = .default,
         contentType: UITextContentType? = nil,
         autocapitalization: TextInputAutocapitalization = .sentences,
         characterLimit: Int? = nil) {
        self.init(icon: icon, label: label, prompt: prompt, text: text,
                  keyboard: keyboard, contentType: contentType,
                  autocapitalization: autocapitalization,
                  characterLimit: characterLimit) { EmptyView() }
    }
}

// MARK: - Step indicator

/// Progress through a multi-page step, as dots.
///
/// Dots rather than "Step 1 of 2" text: at two pages the count is small enough that the shape
/// reads faster than the sentence, and it does not need translating. The current dot is a
/// lengthened capsule rather than merely a brighter circle, so the position is legible without
/// relying on colour alone — the same reason state is never carried by hue anywhere else in
/// this app.
struct StepDots: View {
    /// Zero-based.
    let current: Int
    let total: Int

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<total, id: \.self) { index in
                Capsule()
                    .fill(index == current ? VoiidBrand.lime : VoiidColor.fieldBorder)
                    .frame(width: index == current ? 20 : 6, height: 6)
            }
        }
        .frame(maxWidth: .infinity)
        .animation(.easeOut(duration: 0.25), value: current)
        .accessibilityElement()
        .accessibilityLabel("Step \(current + 1) of \(total)")
    }
}

// MARK: - Image downscaling

extension UIImage {
    /// Scales the longest edge down to `maxDimension`, preserving aspect. Returns self when it
    /// is already small enough, so a modest image is never re-encoded for nothing.
    ///
    /// A modern phone photo is several thousand pixels wide; an avatar is never displayed above
    /// ~350pt. Keeping the original wastes memory here and bandwidth at upload.
    func resized(maxDimension: CGFloat) -> UIImage {
        let longest = max(size.width, size.height)
        guard longest > maxDimension else { return self }

        let scale = maxDimension / longest
        let target = CGSize(width: size.width * scale, height: size.height * scale)

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1        // target is already in pixels; the screen scale would triple it
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            draw(in: CGRect(origin: .zero, size: target))
        }
    }
}
