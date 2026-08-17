//
//  BrandMark.swift
//  Voiid
//
//  PLACEHOLDER brand mark, drawn in code. The real logo is coming.
//
//  WHY THIS EXISTS RATHER THAN AN EMPTY IMAGESET
//  --------------------------------------------
//  The old art was removed for the rebrand, and `Image("VoiidWordmark")` against an empty
//  imageset renders NOTHING — five screens would have shown a blank gap where a mark belongs,
//  which reads as a broken build rather than a pending asset. This draws something deliberate
//  instead: the wordmark as type, and the logomark as a lime tile.
//
//  WHEN THE REAL LOGO ARRIVES
//  --------------------------
//  Drop the files into the imagesets that are already wired and named:
//
//      Assets.xcassets/VoiidWordmark.imageset/   <- wordmark (SVG, preserves-vector is set)
//      Assets.xcassets/VoiidLogoMark.imageset/   <- logomark (PNG or SVG)
//
//  then replace the two bodies below with `Image("VoiidWordmark")` / `Image("VoiidLogoMark")`.
//  Every call site already goes through [BrandWordmark] and [BrandLogoMark], so nothing else
//  changes. That indirection is the point — the old code called `Image(...)` directly from
//  five files, which is why a logo swap touched five files.
//
//  ONE CONSTRAINT THE NEW ART MUST MEET
//  -----------------------------------
//  The old wordmark was filled #E8E0E0 — near-white, drawn for dark grounds only. On the new
//  light theme (white ground) that is invisible. Supply either a two-appearance asset or a
//  monochrome one that can be tinted at the call site, which is what this placeholder does.
//

import SwiftUI

/// The "voiid" wordmark.
///
/// Type, not art, until the real mark lands: the app's logo face (Urbanist Bold via
/// `VoiidFont.logo`) with tracking pulled in. Tinted by the caller and theme-aware by default,
/// so it reads on both the white and Voiid Black grounds.
struct BrandWordmark: View {
    /// Cap height in points. The old call sites passed a frame width; this takes the size
    /// directly, which is what a type-drawn mark actually needs.
    var size: CGFloat = 28
    /// Defaults to the theme-resolving primary — ink on light, lime on dark.
    var color: Color = VoiidColor.primary
    var opacity: Double = 1

    var body: some View {
        Text("voiid")
            .font(VoiidFont.logo(size))
            // Tightened tracking is most of what makes a wordmark read as a mark rather than
            // a word. Proportional to size so it holds at 14pt and at 96pt.
            .tracking(-size * 0.035)
            .foregroundColor(color.opacity(opacity))
            .accessibilityLabel("Voiid")
    }
}

/// The logomark — the square, icon-shaped mark.
///
/// A rounded lime tile carrying the initial. Deliberately plain: a placeholder that tries to
/// look like a real logo invites someone to ship it.
struct BrandLogoMark: View {
    var size: CGFloat = 64

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(VoiidColor.accent)
            .frame(width: size, height: size)
            .overlay(
                Text("v")
                    .font(VoiidFont.logo(size * 0.56))
                    // On the lime fill, always the dark label — 16.59:1. Never the
                    // theme-resolving text colour, which would go near-white in light mode
                    // and measure 1.2:1 here.
                    .foregroundColor(VoiidColor.textOnAccent)
            )
            // Lime vs white is 1.19:1, so on the light ground this tile has no visible edge
            // without a border. See the caveat on VoiidColor.accent.
            .overlay(
                RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                    .strokeBorder(VoiidColor.fieldBorder, lineWidth: 1)
            )
            .accessibilityLabel("Voiid")
    }
}
