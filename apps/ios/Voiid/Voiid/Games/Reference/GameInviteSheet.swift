//
//  GameInviteSheet.swift
//  Voiid
//
//  Games flow, step 2 — a friend invites you to play.
//
//  ── A SHEET, NOT A SCREEN ───────────────────────────────────────────────────────
//  An invite is an interruption: it arrives while you are doing something else, and the two
//  honest answers are yes and not-now. A pushed screen would imply you had navigated somewhere,
//  and would put a back button where a decline belongs. The sheet keeps Games visible behind
//  it, so declining returns you to exactly where you were.
//
//  ── "MAYBE LATER", NOT "DECLINE" ────────────────────────────────────────────────
//  Same action, different social contract. These are friends, and the wording of a refusal is
//  part of the product.
//

import SwiftUI

struct GameInviteSheet: View {

    let invite: RefGameInvite
    var onJoin: () -> Void = {}
    var onMessage: () -> Void = {}

    @Environment(\.dismiss) private var dismiss

    /// Drives the entrance. The avatar and confetti settle rather than snapping in.
    @State private var appeared = false

    var body: some View {
        ZStack {
            VoiidColor.background.ignoresSafeArea()

            VStack(spacing: 0) {
                HStack {
                    Spacer(minLength: 0)
                    Button {
                        Haptics.tap()
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(VoiidColor.textSecondary)
                            .frame(width: 32, height: 32)
                            .background(Circle().fill(VoiidColor.surfaceCard))
                    }
                    .buttonStyle(PressableButtonStyle())
                    .accessibilityLabel("Dismiss invite")
                }
                .padding(.horizontal, VoiidSpacing.md)
                .padding(.top, VoiidSpacing.md)

                inviter
                    .padding(.top, VoiidSpacing.sm)

                gameCard
                    .padding(.horizontal, VoiidSpacing.md)
                    .padding(.top, VoiidSpacing.lg)

                Spacer(minLength: VoiidSpacing.lg)

                actions
                    .padding(.horizontal, VoiidSpacing.md)
                    .padding(.bottom, VoiidSpacing.lg)
            }
        }
        .presentationDetents([.height(560)])
        .presentationDragIndicator(.hidden)
        .presentationCornerRadius(28)
        .onAppear {
            Haptics.success()
            withAnimation(.spring(duration: 0.45, bounce: 0.24)) { appeared = true }
        }
    }

    // MARK: Who is asking

    private var inviter: some View {
        VStack(spacing: VoiidSpacing.sm) {
            ZStack {
                // Confetti. Drawn rather than animated as particles: this is a moment, not a
                // celebration screen, and a full particle system would upstage the decision.
                ForEach(0..<10, id: \.self) { i in
                    confettiPiece(index: i)
                }

                ProfilePhoto(name: invite.from, size: 88, allowFallbackPhoto: true)
                    .overlay(Circle().stroke(VoiidColor.accent, lineWidth: 2.5).padding(-4))
                    .overlay(alignment: .bottomTrailing) {
                        Circle()
                            .fill(VoiidColor.success)
                            .frame(width: 20, height: 20)
                            .overlay(Circle().stroke(VoiidColor.background, lineWidth: 3))
                    }
                    .scaleEffect(appeared ? 1 : 0.88)
            }
            .frame(height: 130)

            Text(invite.from)
                .font(VoiidFont.rounded(23, .bold))
                .foregroundColor(VoiidColor.textPrimary)

            Text("invited you to play")
                .font(VoiidFont.rounded(14.5))
                .foregroundColor(VoiidColor.textSecondary)
        }
        .opacity(appeared ? 1 : 0)
    }

    private func confettiPiece(index: Int) -> some View {
        // Positions are derived from the index rather than random, so the sheet looks the same
        // every time it opens — a layout that reshuffles reads as a glitch.
        let angle = Double(index) / 10 * 2 * .pi
        let radius: CGFloat = index.isMultiple(of: 2) ? 74 : 58
        let colors: [Color] = [VoiidColor.accent, VoiidColor.accentSoft,
                               VoiidColor.warning, VoiidColor.info]

        return RoundedRectangle(cornerRadius: 1.5, style: .continuous)
            .fill(colors[index % colors.count])
            .frame(width: 6, height: 9)
            .rotationEffect(.degrees(Double(index) * 42))
            .offset(x: cos(angle) * radius, y: sin(angle) * radius * 0.72)
            .opacity(appeared ? 0.85 : 0)
            .scaleEffect(appeared ? 1 : 0.4)
            .animation(.spring(duration: 0.55, bounce: 0.3)
                .delay(Double(index) * 0.02), value: appeared)
    }

    // MARK: What the game is

    private var gameCard: some View {
        HStack(spacing: VoiidSpacing.md) {
            LinearGradient(
                colors: [AvatarPalette.color(for: invite.gameTitle),
                         AvatarPalette.color(for: invite.format).opacity(0.65)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            .frame(width: 74, height: 74)
            .overlay {
                Image(systemName: "gamecontroller.fill")
                    .font(.system(size: 26))
                    .foregroundColor(.white.opacity(0.35))
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(invite.gameTitle)
                    .font(VoiidFont.rounded(17, .bold))
                    .foregroundColor(VoiidColor.textPrimary)

                Text(invite.format)
                    .font(VoiidFont.rounded(13))
                    .foregroundColor(VoiidColor.textSecondary)
            }

            Spacer(minLength: 0)
        }
        .padding(VoiidSpacing.sm + 4)
        .background(VoiidColor.surfaceCard)
        .clipShape(RoundedRectangle(cornerRadius: VoiidRadius.lg, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: VoiidRadius.lg, style: .continuous)
                .stroke(VoiidColor.divider, lineWidth: 1)
        )
        .overlay(alignment: .bottom) {
            HStack(spacing: VoiidSpacing.lg) {
                metaChip("person.2.fill", invite.mode)
                metaChip("checkmark.circle.fill", invite.slots)
            }
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity)
            .background(VoiidColor.surfaceRaised)
            .clipShape(UnevenRoundedRectangle(
                topLeadingRadius: 0, bottomLeadingRadius: VoiidRadius.lg,
                bottomTrailingRadius: VoiidRadius.lg, topTrailingRadius: 0,
                style: .continuous))
            .offset(y: 38)
        }
        .padding(.bottom, 38)
    }

    private func metaChip(_ icon: String, _ text: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundColor(VoiidColor.accentInk)
            Text(text)
                .font(VoiidFont.rounded(12.5, .medium))
                .foregroundColor(VoiidColor.textPrimary)
        }
    }

    // MARK: Answering

    private var actions: some View {
        VStack(spacing: VoiidSpacing.sm) {
            Button {
                Haptics.success()
                onJoin()
            } label: {
                Text("Join")
                    .font(VoiidFont.rounded(17, .semibold))
                    .foregroundColor(VoiidColor.textOnAccent)
                    .frame(maxWidth: .infinity)
                    .frame(height: 54)
                    .background(
                        RoundedRectangle(cornerRadius: VoiidRadius.lg, style: .continuous)
                            .fill(VoiidColor.accent)
                    )
            }
            .buttonStyle(PressableButtonStyle())

            Button {
                Haptics.tap()
                dismiss()
            } label: {
                Text("Maybe later")
                    .font(VoiidFont.rounded(16, .semibold))
                    .foregroundColor(VoiidColor.textPrimary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .background(
                        RoundedRectangle(cornerRadius: VoiidRadius.lg, style: .continuous)
                            .fill(VoiidColor.surfaceCard)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: VoiidRadius.lg, style: .continuous)
                            .stroke(VoiidColor.divider, lineWidth: 1)
                    )
            }
            .buttonStyle(PressableButtonStyle())

            // A third way out: not everyone declining wants to say nothing. Text, not a
            // button — it is the quietest of the three answers.
            Button {
                Haptics.tap()
                onMessage()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "message")
                        .font(.system(size: 12))
                    Text("Message \(invite.from)")
                        .font(VoiidFont.rounded(14, .medium))
                }
                .foregroundColor(VoiidColor.textSecondary)
            }
            .padding(.top, 2)
        }
    }
}
