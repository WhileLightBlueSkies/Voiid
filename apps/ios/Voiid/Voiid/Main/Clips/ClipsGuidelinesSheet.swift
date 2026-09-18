//
//  ClipsGuidelinesSheet.swift
//  Voiid
//
//  The Community Guidelines a Clips creator agrees to before their profile is created.
//
//  ── THE RULES ARE HERE, NOT BEHIND A LINK ───────────────────────────────────────
//  Apple Guideline 1.2 requires a EULA prohibiting objectionable content that users actually
//  agree to. A checkbox pointing at a webpage puts the one thing being agreed to behind a
//  network request that can fail, and behind a tap most people never make.
//
//  So the rules are written out in full, in the sheet, in plain words. They are short enough
//  to read — which is the property that makes an agreement real rather than ceremonial. The
//  canonical long-form document still lives on the web for the cases that need it.
//
//  ── AGREEING FROM IN HERE ───────────────────────────────────────────────────────
//  The primary button agrees and dismisses, so someone who reads to the bottom does not have
//  to hunt back to a checkbox they have scrolled past. Closing without agreeing leaves the
//  checkbox exactly as it was — reading is not consent.
//

import SwiftUI

struct ClipsGuidelinesSheet: View {

    let accepted: Bool
    var onAgree: () -> Void = {}
    var onClose: () -> Void = {}

    var body: some View {
        NavigationStack {
            ZStack {
                VoiidColor.background.ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: VoiidSpacing.lg) {
                        intro

                        ForEach(ClipsGuideline.all) { rule in
                            ruleBlock(rule)
                        }

                        enforcement
                        reporting
                    }
                    .padding(VoiidSpacing.md)
                    .padding(.bottom, 120)
                }
                .scrollIndicators(.hidden)

                footer
            }
            .navigationTitle("Community Guidelines")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", action: onClose)
                }
            }
        }
        .preferredColorScheme(.dark)
        .tint(VoiidColor.primary)
    }

    // MARK: Intro

    private var intro: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("What you can and can’t post")
                .font(VoiidFont.rounded(22, .bold))
                .foregroundColor(VoiidColor.textPrimary)

            Text("These apply to every Clip, comment, handle, bio and profile photo on Voiid. They apply the same way to everyone.")
                .font(VoiidFont.subhead)
                .foregroundColor(VoiidColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Rule block

    private func ruleBlock(_ rule: ClipsGuideline) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: rule.icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(rule.tint)
                    .frame(width: 22)

                Text(rule.title)
                    .font(VoiidFont.rounded(16, .semibold))
                    .foregroundColor(VoiidColor.textPrimary)
            }

            ForEach(rule.points, id: \.self) { point in
                HStack(alignment: .top, spacing: 8) {
                    Text("•")
                        .font(VoiidFont.rounded(13))
                        .foregroundColor(VoiidColor.textSecondary)
                    Text(point)
                        .font(VoiidFont.rounded(13))
                        .foregroundColor(VoiidColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(.leading, 32)
            }
        }
        .padding(VoiidSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(VoiidColor.surfaceCard)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(VoiidColor.fieldBorder, lineWidth: 1)
        )
    }

    // MARK: Enforcement

    /// Said plainly, because a rule with no stated consequence is advice. It also sets the
    /// expectation that removal can happen without warning for the severe categories.
    private var enforcement: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("What happens if you break them")
                .font(VoiidFont.rounded(16, .semibold))
                .foregroundColor(VoiidColor.textPrimary)

            Text("We remove content that breaks these rules. Depending on what it is, we may also limit who can see your Clips, suspend your ability to post, or remove your account. Sexual content involving minors and credible threats of violence are removed immediately and reported to the authorities.")
                .font(VoiidFont.rounded(13))
                .foregroundColor(VoiidColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(VoiidSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(VoiidColor.error.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(VoiidColor.error.opacity(0.3), lineWidth: 1)
        )
    }

    // MARK: Reporting

    private var reporting: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("If you see something")
                .font(VoiidFont.rounded(16, .semibold))
                .foregroundColor(VoiidColor.textPrimary)

            Text("Every Clip and every profile has a Report option, and you can block anyone from your own profile at any time. Reports are reviewed, and we act on the serious ones within 24 hours.")
                .font(VoiidFont.rounded(13))
                .foregroundColor(VoiidColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(VoiidSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(VoiidColor.primary.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(VoiidColor.primary.opacity(0.25), lineWidth: 1)
        )
    }

    // MARK: Footer

    private var footer: some View {
        VStack {
            Spacer()

            Button {
                onAgree()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: accepted ? "checkmark.circle.fill" : "checkmark")
                        .font(.system(size: 14, weight: .bold))
                    Text(accepted ? "Agreed" : "I agree to these guidelines")
                        .font(VoiidFont.rounded(16, .bold))
                }
                .foregroundColor(Color.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 15)
                .background(VoiidColor.primary)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, VoiidSpacing.md)
            .padding(.top, 12)
            .padding(.bottom, 12)
            .background(
                LinearGradient(
                    colors: [VoiidColor.background.opacity(0),
                             VoiidColor.background.opacity(0.85),
                             VoiidColor.background],
                    startPoint: .top, endPoint: .bottom
                )
                .ignoresSafeArea(edges: .bottom)
            )
        }
    }
}

// MARK: - The rules

struct ClipsGuideline: Identifiable {
    let id: String
    let title: String
    let icon: String
    let tint: Color
    let points: [String]

    /// Written as specific behaviours rather than categories. "Be respectful" is unenforceable
    /// and tells a person nothing about where the line is; "don't post someone's address"
    /// does.
    static let all: [ClipsGuideline] = [
        .init(id: "people", title: "Treat people decently", icon: "person.2.fill",
              tint: Color(hex: 0x4ADE80),
              points: [
                "No harassment, bullying, or pile-ons — including in comments.",
                "No hate speech or slurs targeting anyone’s race, religion, caste, gender, sexuality, disability or nationality.",
                "No posting someone’s private information: address, phone number, ID documents.",
                "No impersonating another person, creator or organisation.",
              ]),
        .init(id: "safety", title: "Keep people safe", icon: "shield.lefthalf.filled",
              tint: Color(hex: 0xF59E0B),
              points: [
                "No threats of violence, and nothing encouraging or organising it.",
                "No content promoting self-harm, suicide or eating disorders.",
                "No dangerous challenges or stunts people could copy and get hurt by.",
                "No sale of weapons, drugs or other illegal goods.",
              ]),
        .init(id: "minors", title: "Protect minors", icon: "figure.and.child.holdinghands",
              tint: Color(hex: 0xF87171),
              points: [
                "Absolutely no sexual content involving anyone under 18. This is removed immediately and reported.",
                "No sexualising minors, in any form, including animation or AI-generated material.",
                "You must be 13 or older to have a Clips profile.",
              ]),
        .init(id: "adult", title: "Keep it appropriate", icon: "eye.slash.fill",
              tint: Color(hex: 0xA78BFA),
              points: [
                "No pornography or sexually explicit content.",
                "No graphic violence or gore posted for shock value.",
                "Mark sensitive content as sensitive when you post it.",
              ]),
        .init(id: "authentic", title: "Be real", icon: "checkmark.seal.fill",
              tint: Color(hex: 0x38BDF8),
              points: [
                "No spam, engagement farming, or bulk-posting the same Clip.",
                "No scams, fake giveaways or misleading financial claims.",
                "Don’t post other people’s work as your own — credit the original creator.",
                "Label AI-generated content that could be mistaken for real footage.",
              ]),
    ]
}

// MARK: - Previews

#Preview("Guidelines") {
    ClipsGuidelinesSheet(accepted: false)
}
