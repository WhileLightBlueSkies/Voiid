//
//  OnboardingBrandChrome.swift
//  Voiid
//
//  The shared skeleton behind the branded onboarding screens (welcome/terms, permissions).
//
//  WHY THIS IS ONE FILE AND NOT COPY-PASTED TWICE
//  ---------------------------------------------
//  Both screens are the same composition: glowing mark over a horizon, a card of rows, a
//  privacy footnote, a lime pill. Building that twice on iOS and twice again on Android is
//  four places for the glow radius or the card radius to drift, and drift is exactly what
//  makes a "designed" app look assembled. The two screens supply their content; the identity
//  lives here.
//
//  ALL FOUR SCREENS ARE COMMITTED TO DARK, and that is deliberate rather than an oversight.
//  The glow and the horizon are light bleeding onto near-black; on a white ground there is
//  nothing for them to bleed into and the composition collapses. First-run is also the one
//  place a fixed look is safe — the user has not chosen a theme yet.
//

import SwiftUI

// MARK: - Ground

/// The brand ground for onboarding: Voiid Black, fixed in both themes.
enum OnboardingBrand {
    static let ground = Color(hex: 0x0B0B0B)
    /// The card behind a group of rows.
    static let card = Color(hex: 0x121212)
    /// A row inside that card, one step up so it separates from the card it sits on.
    static let row = Color(hex: 0x181818)
    /// Hairlines. White at low alpha rather than a grey token — it stays correct if the
    /// surfaces beneath it are ever re-tuned.
    static let hairline = Color.white.opacity(0.07)
}

// MARK: - Mark, glow, horizon

/// The "V" mark with its bloom, sitting on a horizon arc.
///
/// PLACEHOLDER geometry — two strokes meeting at a point, which is the reference mark at its
/// simplest. When the real art lands, swap the `VMarkShape` stroke for the asset and keep the
/// glow layers: they are what make it read as lit rather than pasted.
struct OnboardingBrandHeader: View {
    /// Mark height in points.
    var markSize: CGFloat = 132
    /// Drives the settle-in on appear.
    var appeared: Bool = true

    var body: some View {
        ZStack {
            // HORIZON. A circle far wider than the screen, pushed down so only its top edge
            // crosses the layout — that is what reads as a planet curve rather than an arc
            // someone drew. The stroke fades to nothing at both ends, because a hairline that
            // stops mid-air looks like a clipping bug.
            Circle()
                .strokeBorder(
                    LinearGradient(
                        colors: [.clear, VoiidColor.accent.opacity(0.5), .clear],
                        startPoint: .leading, endPoint: .trailing
                    ),
                    lineWidth: 1.5
                )
                .frame(width: 920, height: 920)
                .offset(y: 476)
                // The pool of light where the mark meets the ground.
                .shadow(color: VoiidColor.accent.opacity(0.32), radius: 28, y: -8)

            VMark(size: markSize)
                .offset(y: -30)
                .opacity(appeared ? 1 : 0)
                .scaleEffect(appeared ? 1 : 0.94)
        }
        .frame(height: 205)
        .clipped()
    }
}

/// The mark itself: a gradient stroke plus three widening bloom passes.
struct VMark: View {
    var size: CGFloat = 132

    var body: some View {
        ZStack {
            // Three passes at widening radii. ONE pass reads as a drop shadow; three read as
            // light, because real bloom falls off gradually rather than in a single step.
            ForEach([(0.55, 18.0), (0.34, 42.0), (0.20, 72.0)], id: \.1) { opacity, radius in
                VMarkShape()
                    .stroke(VoiidColor.accent,
                            style: .init(lineWidth: size * 0.185, lineCap: .round, lineJoin: .round))
                    .frame(width: size * 0.60, height: size * 0.72)
                    .blur(radius: radius * 0.32)
                    .opacity(opacity)
                    .shadow(color: VoiidColor.accent.opacity(opacity), radius: radius)
            }

            VMarkShape()
                .stroke(
                    // Brighter at the top so the mark looks lit from above, matching where the
                    // bloom sits. A flat fill at this scale looks like a swatch.
                    LinearGradient(colors: [Color(hex: 0xE4FF6B), VoiidColor.accent],
                                   startPoint: .top, endPoint: .bottom),
                    style: .init(lineWidth: size * 0.185, lineCap: .round, lineJoin: .round)
                )
                .frame(width: size * 0.60, height: size * 0.72)
        }
    }
}

struct VMarkShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        return p
    }
}

// MARK: - Title

/// A headline with exactly one lime run — the brand word.
///
/// Colouring the whole line would spend the accent on a sentence and leave the brand no
/// louder than the greeting around it. Takes the parts explicitly so either order works
/// ("Welcome to **Voiid**" and "**Voiid** needs a few permissions" are both in the design).
struct OnboardingTitle: View {
    var leading: String = ""
    var accented: String
    var trailing: String = ""

    var body: some View {
        (
            Text(leading).foregroundColor(VoiidColor.textPrimary)
            + Text(accented).foregroundColor(VoiidColor.accent)
            + Text(trailing).foregroundColor(VoiidColor.textPrimary)
        )
        .font(VoiidFont.rounded(30, .bold))
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 20)
    }
}

// MARK: - Card

/// The rounded container a group of rows sits in.
struct OnboardingCard<Content: View>: View {
    /// Rows drawn edge to edge with dividers (permissions) rather than as separate tiles
    /// (terms). The design uses both, and the difference is the padding.
    var flush: Bool = false
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) { content }
            .padding(flush ? 0 : 18)
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(OnboardingBrand.card)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.06), lineWidth: 1)
            )
    }
}

// MARK: - Glyph tile

/// A lime glyph in a rounded well — the permissions rows' leading element.
///
/// Outlined glyph on a dark tile, never a filled lime square: at six repetitions a filled
/// accent would out-shout the button, and the accent's power on these screens is entirely in
/// its rarity.
struct OnboardingGlyphTile: View {
    let system: String
    var size: CGFloat = 44

    var body: some View {
        Image(systemName: system)
            .font(.system(size: size * 0.48, weight: .regular))
            .foregroundColor(VoiidColor.accent)
            .frame(width: size, height: size)
            .background(
                RoundedRectangle(cornerRadius: size * 0.29, style: .continuous)
                    .fill(Color.white.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: size * 0.29, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.06), lineWidth: 1)
            )
    }
}

// MARK: - Privacy footnote

/// The reassurance line above the button, with one lime run.
struct OnboardingPrivacyNote: View {
    let system: String
    let lines: [String]
    /// The phrase rendered in lime, if it appears in the last line.
    var accentPhrase: String?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: system)
                .font(.system(size: 21, weight: .medium))
                .foregroundColor(VoiidColor.accent)
                .frame(width: 26)

            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                    if index == lines.count - 1, let phrase = accentPhrase,
                       let range = line.range(of: phrase) {
                        (
                            Text(String(line[line.startIndex..<range.lowerBound]))
                                .foregroundColor(VoiidColor.textSecondary)
                            + Text(phrase).foregroundColor(VoiidColor.accent)
                            + Text(String(line[range.upperBound...]))
                                .foregroundColor(VoiidColor.textSecondary)
                        )
                        .font(VoiidFont.rounded(14, .regular))
                    } else {
                        Text(line)
                            .font(VoiidFont.rounded(14, .regular))
                            .foregroundColor(VoiidColor.textSecondary)
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }
}

// MARK: - The lime pill

/// The primary action. The brightest thing on the screen, and the only thing that glows this
/// hard — which is what makes it unmissable without an arrow pointing at it.
struct OnboardingPrimaryButton: View {
    let title: String
    var busy: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Spacer()
                if busy {
                    ProgressView().tint(VoiidColor.textOnAccent)
                } else {
                    Text(title).font(VoiidFont.rounded(18, .semibold))
                }
                Spacer()
                if !busy {
                    Image(systemName: "arrow.right")
                        .font(.system(size: 17, weight: .semibold))
                }
            }
            // Black on lime — 16.59:1, and the only correct label colour on this fill.
            .foregroundColor(VoiidColor.textOnAccent)
            .padding(.horizontal, 26)
            .frame(height: 62)
            .background(
                Capsule().fill(
                    LinearGradient(colors: [Color(hex: 0xD8FF45), Color(hex: 0xB4EC00)],
                                   startPoint: .top, endPoint: .bottom)
                )
            )
            .shadow(color: VoiidColor.accent.opacity(0.42), radius: 22)
            .shadow(color: VoiidColor.accent.opacity(0.22), radius: 44, y: 8)
        }
        .buttonStyle(.plain)
        .disabled(busy)
    }
}
