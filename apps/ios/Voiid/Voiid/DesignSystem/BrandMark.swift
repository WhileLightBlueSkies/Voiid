//
//  BrandMark.swift
//  Voiid
//
//  The brand mark. ONE component, used everywhere.
//
//  WHY A COMPONENT AND NOT `Image("VoiidLogoMark")` AT EACH CALL SITE
//  -----------------------------------------------------------------
//  The mark was previously called as a bare `Image(...)` from five different files, each with
//  its own `.resizable().scaledToFit().frame(...)` and its own opacity. Swapping the art
//  therefore meant editing five files, and the sizes had already drifted apart. Everything goes
//  through here instead: new art is one asset swap, and a size change is one place.
//
//  THE ART
//  -------
//  Three rounded bars forming a V. The back stroke carries a gradient — dark at the ends,
//  bright mid-bar — which is what makes it read as passing BEHIND the other two.
//
//  The supplied original did this with a 1600x1600 raster embedded in the SVG: 7.3 MB, could
//  not tint, and its shading desaturated in the middle. `VoiidLogoMark.imageset` holds the
//  rebuilt vector — same shading sampled from the original, ~1 KB, tintable and resolution-free.
//
//  NOTE ON THE PLACEHOLDER THAT USED TO LIVE HERE
//  ----------------------------------------------
//  [BrandLogoMark] drew a lime tile with a "v" in it, because the real art had not landed and
//  an empty imageset renders NOTHING. The art has landed. The tile is gone, but the TYPE is
//  kept as a thin alias over [VoiidMark] so the existing call sites keep compiling.
//

import SwiftUI

// MARK: - The mark

/// The V mark on its own — app icon, tab bar, avatar placeholder, anywhere square.
///
/// Not tinted by default: the mark is a two-tone gradient and flattening it to one colour throws
/// away the depth that makes it a mark rather than a letter. Pass `tint` only where a single
/// colour is genuinely required (a template context, a monochrome toolbar).
struct VoiidMark: View {
    /// Rendered width and height in points.
    var size: CGFloat = 64
    /// Flattens the mark to one colour. Use sparingly — see the note above.
    var tint: Color?

    var body: some View {
        // `renderingMode` belongs on the Image itself, before the layout modifiers erase it to
        // `some View`. Applying it after is a compile error, and the tempting fix — wrapping in
        // AnyView — costs the type information for no benefit.
        Group {
            if let tint {
                Image("VoiidLogoMark")
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .foregroundColor(tint)
            } else {
                Image("VoiidLogoMark")
                    .resizable()
                    .scaledToFit()
            }
        }
        // WIDTH ONLY — the height follows the art.
        //
        // This used to be `.frame(width: size, height: size)`, a SQUARE box around artwork whose
        // viewBox is 88x80. `scaledToFit` then letterboxed the mark inside it, leaving ~9% dead
        // space above and below that reads as a faint panel behind the logo — especially in a
        // lockup, where the wordmark below makes the extra padding measurable by eye.
        //
        // Constraining one axis and letting the aspect ratio supply the other means the frame
        // IS the art: no letterboxing, and no box.
        .frame(width: size)
        .aspectRatio(Self.aspect, contentMode: .fit)
        .accessibilityElement()
        .accessibilityLabel("Voiid")
    }

    /// The mark's true aspect, from the SVG viewBox (88 x 80). Named rather than inlined so a
    /// change to the artwork has one place to land.
    static let aspect: CGFloat = 88.0 / 80.0
}

// MARK: - Note on the glow
//
// There WAS a `VoiidMarkGlow` in the design source — the mark under three widening blur passes.
// It is deliberately not carried over.
//
// Seen at 120pt it washed out the mark's own gradient: the bloom lifted the dark end of the back
// stroke until the depth that distinguishes the three bars disappeared, so the effect destroyed
// the thing it was decorating. A mark that already carries light in its gradient does not need
// light thrown at it.
//
// If a hero placement ever needs more presence, scale the mark up rather than glowing it.
// (Onboarding's horizon bloom in OnboardingBrandChrome is a different effect on a different
// ground, and is unaffected by this note.)

// MARK: - The wordmark

/// "Voiid" as type — capital V, with the two i-dots in the accent.
///
/// WHY THE DOTS ARE DRAWN RATHER THAN COLOURED
/// -------------------------------------------
/// You cannot recolour part of a glyph. `Text("voiid")` is one run, and a tittle is baked into
/// the `i` outline — there is no way to reach it. So the two `i`s are set with the DOTLESS
/// form (U+0131, "ı") and the dots are drawn as circles on top. Same trick the web wordmark
/// uses, for the same reason.
///
/// The dot size and offset are derived from `size`, not fixed points, so the mark holds together
/// at 14pt in a toolbar and at 48pt in a lockup. A fixed 4pt dot looks like a full stop at one
/// end of that range and a bullet at the other.
///
/// The wordmark is TYPE, not art: it has to set at any size, follow the user's text-size
/// setting, and stay crisp — none of which a bitmap of a word can do. Tracking is negative and
/// proportional, because letters read progressively further apart as they grow, so one fixed
/// letter-spacing is wrong at either end.
struct BrandWordmark: View {
    /// Cap height in points.
    var size: CGFloat = 28
    /// The letters. Defaults to the theme-resolving primary — ink on light, lime on dark.
    var color: Color = VoiidColor.primary
    /// Colour of the two i-dots. The dots are always the accent — that IS the wordmark.
    var dotColor: Color = VoiidColor.accent
    /// Retained because existing call sites pass it (watermarks at 0.25–0.3).
    var opacity: Double = 1

    /// Diameter of each dot, as a fraction of cap height. Tuned against the rounded face's own
    /// tittle so the drawn dots read as belonging to the letters rather than floating above them.
    private var dotSize: CGFloat { size * 0.165 }

    /// How far the dots sit above the stem.
    ///
    /// Measured from the overlay's TOP edge, so a SMALLER number lifts the dot. At 0.30 the dots
    /// rested ON the stems and read as part of the letter; a tittle needs visible air under it to
    /// read as its own mark. Proportional to size so the gap scales rather than becoming a
    /// hairline at 13pt and a chasm at 48pt.
    ///
    /// NOTE this is measured against the stem's own box, which is why capitalising the V did not
    /// move it: each dot is positioned relative to ITS letter, not to the line.
    private var dotRise: CGFloat { size * 0.10 }

    var body: some View {
        // Capital V, lowercase rest. The dots are the only accent — that IS the wordmark.
        HStack(spacing: 0) {
            glyphs("Vo")
            stemWithDot()
            stemWithDot()
            glyphs("d")
        }
        // OPTICAL CENTRING, not geometric. Measured, the ink box centres within 1px of the
        // screen — and it still reads as sitting right of centre.
        //
        // The cause is the letterforms: `V` is a diagonal that leaves open space at its
        // lower-left, while `d` ends in a hard vertical stem. So the visual MASS sits right of
        // the box's midpoint even when the box is perfectly centred. Centring by bounding box is
        // the wrong measurement for asymmetric letterforms; typographers correct this by eye and
        // so does this.
        //
        // Proportional to size so the correction scales with the type instead of becoming
        // invisible at 13pt and a visible shove at 58pt.
        .offset(x: -size * 0.022)
        .opacity(opacity)
        .accessibilityElement()
        .accessibilityLabel("Voiid")
    }

    private func glyphs(_ text: String) -> some View {
        Text(text)
            .font(face)
            .tracking(-size * 0.02)
            .foregroundColor(color)
    }

    /// A dotless stem with its dot drawn above.
    ///
    /// `alignment: .top` with a negative offset places the dot relative to the STEM, so the pair
    /// stays locked to the letter when the type scales rather than drifting apart.
    private func stemWithDot() -> some View {
        Text("\u{0131}")
            .font(face)
            .tracking(-size * 0.02)
            .foregroundColor(color)
            .overlay(alignment: .top) {
                Circle()
                    .fill(dotColor)
                    .frame(width: dotSize, height: dotSize)
                    .offset(y: dotRise)
            }
    }

    private var face: Font {
        .system(size: size, weight: .bold, design: .rounded)
    }
}

// MARK: - Compatibility

/// The logomark, by its former name.
///
/// Kept as an alias rather than renamed at the call sites: `BrandLogoMark` was the placeholder
/// tile, and every caller that asked for it wants the real mark now that one exists. One type,
/// so there is no second implementation to drift.
struct BrandLogoMark: View {
    var size: CGFloat = 64
    var tint: Color?

    var body: some View { VoiidMark(size: size, tint: tint) }
}

/// Mark + wordmark, the full lockup.
///
/// The gap and the wordmark's size are DERIVED from the mark's, so the two never drift out of
/// proportion when a call site changes one number.
struct VoiidLockup: View {
    var markSize: CGFloat = 64
    /// The wordmark's letters. WHITE by default, and deliberately not the theme-resolving
    /// `VoiidColor.primary` that `BrandWordmark` falls back to on its own.
    ///
    /// `primary` is lime on dark and near-black on light, so a lockup taking the default rendered
    /// the whole word LIME wherever it appeared on the brand ground. The wordmark is white
    /// letters with two lime tittles — the dots are the only accent, and a lime word throws that
    /// contrast away. Every lockup placement in the app sits on the near-black ground, so white
    /// is the right default; a call site on a light ground passes ink explicitly.
    var wordColor: Color = .white

    var body: some View {
        VStack(spacing: markSize * 0.12) {
            VoiidMark(size: markSize)
            BrandWordmark(size: markSize * 0.42, color: wordColor)
        }
    }
}

// MARK: - Previews

#Preview("Mark sizes") {
    ZStack {
        Color(hex: 0x0B0B0B).ignoresSafeArea()
        VStack(spacing: 28) {
            ForEach([132.0, 64.0, 40.0, 24.0], id: \.self) { s in
                HStack(spacing: 18) {
                    VoiidMark(size: s)
                    Text("\(Int(s))")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(VoiidColor.textSecondary)
                    Spacer()
                }
            }
        }
        .padding(28)
    }
    .preferredColorScheme(.dark)
}

#Preview("Lockup") {
    ZStack {
        Color(hex: 0x0B0B0B).ignoresSafeArea()
        VoiidLockup(markSize: 88)
    }
    .preferredColorScheme(.dark)
}
