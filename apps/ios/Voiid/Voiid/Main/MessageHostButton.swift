//
//  MessageHostButton.swift
//  Voiid
//
//  "Message host" — the member's end of the ONE scoped exception to 020_reachability.sql.
//  Port of Android `main/MessageHostButton.kt`; the two must behave identically, because the
//  same community has members on both platforms.
//
//  A self-contained control so the community info card adopts it in one line and inherits
//  every rule below rather than re-deriving them:
//
//      MessageHostButton(communityId: card.id) { conversationId in
//          dismiss(); openConversation(conversationId)
//      }
//
//  ── IT RENDERS NOTHING UNLESS THE SERVER SAYS THE CALLER MAY USE IT ──────────────
//
//  The probe is `GET /communities/:id/host-thread`, which refuses for anyone who is not an
//  ACTIVE member and reports the host's user id for anyone who is. The button's visibility is
//  therefore a SERVER decision, not a guess made from a membership field the client happens to
//  be holding. On any refusal — not a member, still pending, left, banned, community suspended,
//  endpoint not deployed yet — this view draws nothing at all. It never says WHY: the server
//  deliberately returns one message for all of those states rather than acting as an oracle for
//  moderation status, and a client that invented the distinction would undo that.
//
//  ── WHO THE PEER IS, IS NOT A PARAMETER ─────────────────────────────────────────
//
//  There is no target user in this API and there must never be one. The peer is
//  `communities.owner_id`, resolved server-side. This control can open a line to a community's
//  HOST and to nobody else; it cannot be pointed at another member, because there is no
//  argument to point. Joining a space is consent to be asked questions by its members — it is
//  not consent to be messaged by every other member, and any code that reads community
//  membership to authorise a message between two ordinary members is a bug (the same rule the
//  creator follow graph carries).
//
//  The conversation it opens is an ordinary Double-Ratchet 1:1: end-to-end encrypted, zero new
//  cryptography, the server holding opaque ciphertext exactly as it does for every other chat.
//

import SwiftUI

struct MessageHostButton: View {
    let communityId: String
    /// Handed the conversation id once there is one. The caller navigates; this control does
    /// not, because it does not know whether it sits inside a sheet that has to dismiss first.
    var onOpenConversation: (String) -> Void

    /// nil = still probing, or the server said no. Either way: draw nothing.
    @State private var probe: CommunityHostThreadService.HostThread?
    @State private var opening = false
    @State private var error: String?

    private var hostUserId: String? { probe?.host_user_id }
    /// The host does not message themselves. The server refuses this with a 400 anyway;
    /// catching it here keeps a pointless button off the owner's own card.
    private var isSelf: Bool { hostUserId != nil && hostUserId == TokenStore.shared.userId }
    private var hasThread: Bool { !(probe?.conversation_id ?? "").isEmpty }

    var body: some View {
        Group {
            if hostUserId != nil && !isSelf {
                VStack(spacing: 8) {
                    Button {
                        Haptics.tap()
                        Task { await open() }
                    } label: {
                        ZStack {
                            if opening {
                                ProgressView().tint(VoiidColor.textPrimary)
                            } else {
                                // Two different promises, so they get two different labels: one
                                // opens a chat that already exists, the other starts one.
                                Text(hasThread ? "Open chat with host" : "Message host")
                                    .font(VoiidFont.rounded(16, .semibold))
                                    .foregroundStyle(VoiidColor.textPrimary)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(VoiidColor.fieldFill, in: Capsule())
                    }
                    .disabled(opening)

                    Text("A private chat with the host only. Other members can’t message you.")
                        .font(VoiidFont.rounded(12))
                        .foregroundStyle(VoiidColor.textSecondary)
                        .multilineTextAlignment(.center)

                    if let error {
                        Text(error)
                            .font(VoiidFont.rounded(13))
                            .foregroundStyle(VoiidColor.error)
                            .multilineTextAlignment(.center)
                    }
                }
            }
        }
        // A GET, deliberately: a card that minted a conversation just by being LOOKED AT would
        // make every impression an act of contact and would fill a popular host's chat list with
        // people who only ever browsed. Nothing is created until the button is pressed.
        .task(id: communityId) {
            probe = try? await CommunityHostThreadService.shared.existing(communityId: communityId)
        }
    }

    private func open() async {
        guard !opening else { return }
        opening = true
        error = nil
        do {
            let thread = try await CommunityHostThreadService.shared.open(communityId: communityId)
            Haptics.success()
            // Refresh the probe so a re-entry says "Open chat with host" even if the caller does
            // not navigate away. Only the two fields this view reads are carried over; the
            // response's own `opened_via` is not re-asserted here, because whether the server
            // CREATED a community thread or handed back a pre-existing personal chat is its
            // answer to record, not this view's to restate.
            probe = CommunityHostThreadService.HostThread(
                conversation_id: thread.conversationId,
                host_user_id: thread.hostUserId,
                existed: thread.existed,
                opened_via: probe?.opened_via
            )
            onOpenConversation(thread.conversationId)
        } catch let e as APIError {
            error = e.errorDescription ?? "Couldn’t open a chat with the host."
        } catch {
            self.error = "Couldn’t reach Voiid. Check your connection and try again."
        }
        opening = false
    }
}
