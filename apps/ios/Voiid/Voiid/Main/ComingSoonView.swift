//
//  ComingSoonView.swift
//  Voiid
//
//  The placeholder for a tab that exists in the bar but has no feature behind it yet
//  (Communities, Games).
//
//  DELIBERATELY NOT a bare "Coming soon" centred on an empty screen. A tab a user can reach
//  and tap is a promise; the screen has to say what the thing WILL be, or tapping it feels
//  like a bug. So: the tab's own icon, its name, one honest sentence about the feature, and a
//  quiet status chip. Nothing that pretends to be interactive — no fake buttons, no waitlist
//  field that goes nowhere.
//
//  Mirrors Android `ComingSoonView.kt`.
//

import SwiftUI

struct ComingSoonView: View {
    let icon: String
    let title: String
    let blurb: String

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            // The tab's own glyph, held in a soft brand-tinted disc so the screen reads as
            // designed-but-empty rather than unfinished.
            ZStack {
                Circle()
                    .fill(VoiidColor.primary.opacity(0.10))
                    .frame(width: 84, height: 84)
                Image(systemName: icon)
                    .font(.system(size: 34, weight: .regular))
                    .foregroundStyle(VoiidColor.primary)
            }

            Text(title)
                .font(VoiidFont.rounded(26, .bold))
                .foregroundStyle(VoiidColor.textPrimary)
                .padding(.top, VoiidSpacing.lg)

            Text(blurb)
                .font(VoiidFont.rounded(14, .regular))
                .foregroundStyle(VoiidColor.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.top, VoiidSpacing.sm)
                .padding(.horizontal, VoiidSpacing.xl)

            // Status, stated plainly. "In development" rather than a date — a date we might
            // miss is worse than no date at all.
            Text("In development")
                .font(VoiidFont.rounded(12, .semibold))
                .foregroundStyle(VoiidColor.textSecondary)
                .padding(.horizontal, VoiidSpacing.md)
                .padding(.vertical, VoiidSpacing.sm)
                .background(Capsule().fill(VoiidColor.fieldFill))
                .padding(.top, VoiidSpacing.lg)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(VoiidColor.background.ignoresSafeArea())
    }
}
