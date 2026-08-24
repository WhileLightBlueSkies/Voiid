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
    /// The band the mark and horizon occupy. Fixed so the three screens' headers line up.
    static let height: CGFloat = 190
    /// How far below the frame's bottom edge the horizon's apex sits. Small positive values
    /// bring the curve UP into the frame; this is tuned so it passes just under the mark.
    static let horizonInset: CGFloat = -34

    /// Mark height in points.
    var markSize: CGFloat = 132
    /// Drives the settle-in on appear.
    var appeared: Bool = true

    var body: some View {
        // GeometryReader, and the width claim below, are load-bearing.
        //
        // The first version drew the horizon as `Circle().frame(width: 920)` inside a
        // height-only frame. `.clipped()` clips the DRAWING but not the LAYOUT, so the ZStack
        // still reported itself 920pt wide, the enclosing VStack grew to match, and every
        // sibling — title, card, button — got centred against 920pt instead of the screen.
        // The result was a screen that looked zoomed in with its left edge cut off.
        //
        // So: read the real width, size the horizon FROM it, and pin the container to it.
        GeometryReader { geo in
            let w = geo.size.width
            // Diameter as a multiple of the screen width. A wide circle is what makes the top
            // edge read as a planet curve rather than an arc someone drew; 2.6x is shallow
            // enough to look like a horizon and steep enough to still be visibly curved.
            let diameter = w * 2.6

            ZStack {
                Circle()
                    .strokeBorder(
                        LinearGradient(
                            colors: [.clear, VoiidColor.accent.opacity(0.5), .clear],
                            startPoint: .leading, endPoint: .trailing
                        ),
                        lineWidth: 1.5
                    )
                    .frame(width: diameter, height: diameter)
                    // Push it down so only the top of the curve crosses the frame.
                    .offset(y: diameter / 2 + Self.horizonInset)
                    // The pool of light where the mark meets the ground.
                    .shadow(color: VoiidColor.accent.opacity(0.32), radius: 28, y: -8)

                VMark(size: markSize)
                    .offset(y: -26)
                    .opacity(appeared ? 1 : 0)
                    .scaleEffect(appeared ? 1 : 0.94)
            }
            // Centre the ZStack in the reader, then let the circle overflow it visually.
            .frame(width: w, height: Self.height, alignment: .center)
            .clipped()
        }
        // The container claims ONLY the screen width and a fixed height, so nothing inside can
        // push its siblings around.
        .frame(height: Self.height)
    }
}

/// The mark, with its bloom.
///
/// The ART IS NOW REAL (Assets.xcassets/VoiidLogoMark) — three rounded bars forming the V. The
/// bloom passes stay, because the asset is a flat fill and the glow is what makes it read as lit
/// rather than pasted on. `.blur` on a duplicate of the image is how you bloom an asset you
/// cannot re-stroke.
struct VMark: View {
    var size: CGFloat = 132

    var body: some View {
        ZStack {
            // Three passes at widening radii. ONE pass reads as a drop shadow; three read as
            // light, because real bloom falls off gradually rather than in a single step.
            ForEach([(0.55, 14.0), (0.34, 30.0), (0.20, 54.0)], id: \.1) { opacity, radius in
                Image("VoiidLogoMark")
                    .resizable()
                    .scaledToFit()
                    .frame(width: size * 0.62)
                    .blur(radius: radius * 0.4)
                    .opacity(opacity)
            }

            Image("VoiidLogoMark")
                .resizable()
                .scaledToFit()
                .frame(width: size * 0.62)
        }
    }
}

// MARK: - Top bar

/// The circled back / help pair the design puts above the mark.
///
/// Circled outlines rather than bare chevrons: on a near-black ground with a glow behind it, a
/// bare glyph at the screen edge reads as debris. The ring gives it a hit target you can see.
struct OnboardingTopBar: View {
    var onBack: (() -> Void)?
    var onHelp: (() -> Void)?

    var body: some View {
        HStack {
            if let onBack {
                circleButton("arrow.left", label: "Back", action: onBack)
            } else {
                // Holds the row's height so the mark below does not shift between the screens
                // that have a back button and the ones that do not.
                Circle().fill(.clear).frame(width: 44, height: 44)
            }
            Spacer()
            if let onHelp {
                circleButton("questionmark", label: "Help", action: onHelp)
            }
        }
        .padding(.horizontal, 20)
    }

    private func circleButton(_ system: String, label: String,
                              action: @escaping () -> Void) -> some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            Image(systemName: system)
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(VoiidColor.textPrimary)
                .frame(width: 44, height: 44)
                .overlay(Circle().strokeBorder(Color.white.opacity(0.18), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

// MARK: - Trust strip

/// The four-up reassurance row: a lime glyph over two lines, divided by hairlines.
///
/// Four columns of two words each. The copy is deliberately short — this is scanned, not read,
/// and a third line would turn it into a paragraph nobody finishes.
struct OnboardingTrustStrip: View {
    struct Item: Identifiable {
        let id: String
        let system: String
        let line1: String
        let line2: String
    }

    let items: [Item]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                if index > 0 {
                    Rectangle()
                        .fill(OnboardingBrand.hairline)
                        .frame(width: 1, height: 52)
                }
                VStack(spacing: 8) {
                    Image(systemName: item.system)
                        .font(.system(size: 22, weight: .regular))
                        .foregroundColor(VoiidColor.accent)
                    VStack(spacing: 1) {
                        Text(item.line1)
                        Text(item.line2)
                    }
                    .font(VoiidFont.rounded(13, .regular))
                    .foregroundColor(VoiidColor.textSecondary)
                    .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(OnboardingBrand.card)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Color.white.opacity(0.06), lineWidth: 1)
        )
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
        // NEGATIVE tracking, because this is display type. Letters read progressively further
        // apart as they grow, so a value that is right for body copy leaves a 30pt heading
        // looking spaced out. Proportional to size rather than a fixed -0.6pt, so the same
        // token holds if the heading ever changes scale.
        .tracking(-30 * 0.018)
        .lineSpacing(-1)
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
    /// Gates the button on a precondition the screen owns (Terms' consent tick).
    ///
    /// It LOOKS disabled as well as being disabled — the glow drops and the fill dims. A button
    /// that appears live and then refuses the tap teaches the user that the interface lies; one
    /// that is visibly inert tells them what to do next.
    var enabled: Bool = true
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
            // The glow is what makes this the brightest thing on the screen, so a disabled
            // button drops it entirely rather than dimming it — a dim glow still reads as lit.
            .shadow(color: VoiidColor.accent.opacity(enabled ? 0.42 : 0), radius: 22)
            .shadow(color: VoiidColor.accent.opacity(enabled ? 0.22 : 0), radius: 44, y: 8)
            .opacity(enabled ? 1 : 0.38)
        }
        .buttonStyle(.plain)
        .disabled(busy || !enabled)
        .animation(.easeOut(duration: 0.2), value: enabled)
    }
}
