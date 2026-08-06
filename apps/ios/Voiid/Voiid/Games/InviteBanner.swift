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
//  NO INVITER PHOTO HERE, DELIBERATELY. `VoiidAvatar` is still placeholder-only on both platforms —
//  it takes a bundle asset name, not a profile photo URL or initials — so a face on this banner
//  would mean inlining a second image loader into one component. The game art carries the tile
//  until that shared component grows a real remote-photo path.
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
    ///
    /// Seeded in `init` rather than in `.task`, because `.task` runs only AFTER the first render:
    /// starting at zero made every live invite draw one frame as a dead one — grey card, "Missed
    /// invite", an ✕ where Play belongs.
    @State private var remaining: Int64

    init(invite: GamesAPI.PendingInvite,
         onAccept: @escaping () -> Void,
         onDismiss: @escaping () -> Void) {
        self.invite = invite
        self.onAccept = onAccept
        self.onDismiss = onDismiss
        _remaining = State(initialValue: max(0, invite.expires_at - GameInvite.nowMs()))
    }

    private var dead: Bool { invite.missed || remaining <= 0 }

    /// The inviter as THIS device knows them, not as they named themselves.
    ///
    /// `inviter_name` is the sender's own profile name and arrives in the payload; the address
    /// book wins over it, exactly as the push notification for this same invite already resolves.
    /// Without this the backgrounded user saw "Mum" and the foregrounded one saw "Priya Sharma"
    /// for one invite. The directory is @MainActor with a synchronous in-memory mirror, so this is
    /// legal inside a body. Its "Unknown" sentinel is a debugging value, never a thing to render.
    private var inviterName: String {
        let resolved = UserDirectory.shared.displayName(invite.inviter_id ?? "",
                                                        fallback: invite.inviter_name)
        return resolved == "Unknown" ? "Someone" : resolved
    }

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
                Text(dead ? "Missed invite" : "\(inviterName) wants to play")
                    .font(VoiidFont.rounded(14, .semibold))
                    .foregroundStyle(VoiidColor.textPrimary)
                    .lineLimit(1)
                subtitle
                    .font(VoiidFont.rounded(12, .regular))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)

            if dead {
                Button { onDismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(VoiidColor.textSecondary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Dismiss")
            } else {
                // SAYING NO IS AN ANSWER TOO. Until this existed the only way to turn an invite
                // down was to let it expire, which leaves the inviter staring at a lobby for ten
                // minutes. Ghost weight, because declining should be available but not inviting.
                Button { onDismiss() } label: {
                    Text("Decline")
                        .font(VoiidFont.rounded(13, .semibold))
                        .foregroundStyle(VoiidColor.textSecondary)
                        .padding(.horizontal, VoiidSpacing.sm)
                        // Frame after the label so the tap target reaches 44pt without
                        // inflating the text itself.
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Decline invite")

                Button { onAccept() } label: {
                    Text("Play")
                        .font(VoiidFont.rounded(13, .bold))
                        .foregroundStyle(VoiidColor.textOnPrimary)
                        .padding(.horizontal, VoiidSpacing.md)
                        .padding(.vertical, 7)
                        .background(Capsule().fill(VoiidColor.primary))
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Play")
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

    /// Game · settings · time left. A `Text` rather than a `String` so the countdown can carry its
    /// own colour: under a minute it turns `warning`, which reads as urgency without adding
    /// animation to a card that may sit on screen for ten minutes.
    ///
    /// Every run colours itself here — an outer `.foregroundStyle` on the composed `Text` would
    /// repaint the countdown along with the rest and lose the distinction.
    private var subtitle: Text {
        var s = invite.name
        if invite.overs > 0 { s += " · \(invite.overs) \(invite.overs == 1 ? "over" : "overs")" }
        let base = Text(s).foregroundStyle(VoiidColor.textSecondary)
        guard !dead else { return base }

        let total = max(0, remaining / 1000)
        let clock = " · \(total / 60):\(String(format: "%02d", total % 60)) left"
        return base
            + Text(clock).foregroundStyle(total < 60 ? VoiidColor.warning
                                                     : VoiidColor.textSecondary)
    }
}
