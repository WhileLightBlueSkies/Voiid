//
//  InviteBanner.swift
//  Voiid
//
//  Incoming-invite banner for the games home screen.
//
//  TWO KINDS, AND THE DIFFERENCE MATTERS. A LIVE invite is actionable and carries a countdown — the
//  point is to make you decide now. A MISSED one is information: it tells you someone wanted to play
//  and you weren't there, which is worth knowing once and never again. So a missed banner is
//  dismissed as soon as it has been seen, while a live one stays until it is answered or expires.
//  Treating both the same would either nag about dead invites or hide live ones.
//
//  The chat message is still the durable record; these banners are a shortcut, not the source of
//  truth. That is why dismissing one declines/acknowledges the invite rather than deleting anything.
//
//  Mirrors Android `InviteBanners.kt`.
//

import SwiftUI

struct InviteBanner: View {
    let invite: GamesAPI.PendingInvite
    let onAccept: () -> Void
    let onDismiss: () -> Void

    /// Recomputed from the SERVER's expires_at rather than a local duration — a device with a
    /// skewed clock still agrees with the backend about what has expired.
    @State private var remaining: Int64 = 0

    private var dead: Bool { invite.missed || remaining <= 0 }

    var body: some View {
        HStack(spacing: VoiidSpacing.sm) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(VoiidColor.primary.opacity(0.10))
                if UIImage(named: "game_\(invite.slug)") != nil {
                    Image("game_\(invite.slug)")
                        .resizable()
                        .scaledToFill()
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                } else {
                    Image(systemName: "gamecontroller")
                        .font(.system(size: 22))
                        .foregroundStyle(VoiidColor.primary)
                }
            }
            .frame(width: 48, height: 48)

            VStack(alignment: .leading, spacing: 2) {
                Text(dead ? "Missed invite"
                          : "\(invite.inviter_name ?? "A friend") wants to play")
                    .font(VoiidFont.rounded(14, .semibold))
                    .foregroundStyle(VoiidColor.textPrimary)
                    .lineLimit(1)
                Text(subtitle)
                    .font(VoiidFont.rounded(12, .regular))
                    .foregroundStyle(VoiidColor.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)

            if dead {
                Button { onDismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(VoiidColor.textSecondary)
                        .padding(8)
                }
                .accessibilityLabel("Dismiss")
            } else {
                Button { onAccept() } label: {
                    Text("Play")
                        .font(VoiidFont.rounded(13, .bold))
                        .foregroundStyle(VoiidColor.textOnPrimary)
                        .padding(.horizontal, VoiidSpacing.md)
                        .padding(.vertical, 7)
                        .background(Capsule().fill(VoiidColor.primary))
                }
            }
        }
        .padding(VoiidSpacing.sm)
        .background(
            RoundedRectangle(cornerRadius: VoiidRadius.lg)
                .fill(dead ? VoiidColor.surfaceCard : VoiidColor.primary.opacity(0.12)))
        .contentShape(Rectangle())
        .onTapGesture { if !dead { onAccept() } }
        .task {
            remaining = max(0, invite.expires_at - GameInvite.nowMs())
            while !Task.isCancelled, remaining > 0 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                remaining = max(0, invite.expires_at - GameInvite.nowMs())
            }
        }
    }

    private var subtitle: String {
        var s = invite.name
        if invite.overs > 0 { s += " · \(invite.overs) \(invite.overs == 1 ? "over" : "overs")" }
        if !dead {
            let total = max(0, remaining / 1000)
            s += " · \(total / 60):\(String(format: "%02d", total % 60)) left"
        }
        return s
    }
}
