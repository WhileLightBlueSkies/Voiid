//
//  UnwiredNotice.swift
//  Voiid
//
//  The banner every screen wears while it is still a design and not a feature.
//
//  ── WHY A COMPONENT AND NOT A COMMENT ───────────────────────────────────────────
//  A screen that looks finished and does nothing is the single most expensive kind of bug to
//  find: it passes review, it demos well, and it is discovered by a user. A source comment
//  saying "TODO: wire this" is invisible to everyone who is not reading the file.
//
//  So the admission is ON THE SCREEN, in the build, where anyone tapping through the app sees
//  it. When the screen is wired, deleting the one `UnwiredNotice(...)` line is the last step —
//  and if someone forgets, the banner is still there saying so.
//
//  ── IT IS NOT AN ERROR ──────────────────────────────────────────────────────────
//  Amber, not red, and phrased as a statement of state rather than a failure. Nothing has gone
//  wrong: the screen genuinely is a preview. Red would train people to ignore red.
//

import SwiftUI

struct UnwiredNotice: View {
    /// What is missing, in the author's own words. Specific beats generic: "no highlights
    /// table yet" tells the next person what to build, "not implemented" does not.
    let detail: String

    init(_ detail: String) { self.detail = detail }

    var body: some View {
        HStack(alignment: .top, spacing: VoiidSpacing.sm) {
            Image(systemName: "wrench.and.screwdriver.fill")
                .font(.system(size: 12))
                .foregroundColor(VoiidColor.warning)

            VStack(alignment: .leading, spacing: 2) {
                Text("Preview only")
                    .font(VoiidFont.rounded(12.5, .semibold))
                    .foregroundColor(VoiidColor.textPrimary)

                Text(detail)
                    .font(VoiidFont.rounded(11.5))
                    .foregroundColor(VoiidColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(VoiidSpacing.sm + 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(VoiidColor.warning.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: VoiidRadius.md, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: VoiidRadius.md, style: .continuous)
            .stroke(VoiidColor.warning.opacity(0.35), lineWidth: 1))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Preview only. \(detail)")
    }
}

/// The same admission, sized for a settings ROW rather than a screen. Used on rows in the
/// profile sheet whose destination is still a preview, so the state is visible BEFORE the tap
/// rather than after it.
struct UnwiredDot: View {
    var body: some View {
        Circle()
            .fill(VoiidColor.warning)
            .frame(width: 6, height: 6)
            .accessibilityLabel("Preview only")
    }
}
