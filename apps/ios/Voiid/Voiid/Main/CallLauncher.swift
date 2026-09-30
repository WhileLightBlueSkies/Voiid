//
//  CallLauncher.swift
//  Voiid
//
//  Builds the `CallRequest` for a call started OUTSIDE a chat — the Calls tab and the Chats
//  list. `ChatDetailView.startCall` is the reference; this mirrors it so the three entry
//  points cannot drift. Two rules carried over, both of which were easy to lose:
//
//   * A 1:1 call ALWAYS carries its conversation. `POST /calls/ring` needs it, or the
//     callee's wake push is never sent and the call only rings a phone that is already open.
//   * A group call carries its conversation only when the MLS group exists — the media key is
//     derived from it, and joining without one would hand plaintext to the SFU.
//
//  Without `peerUserId` (1:1) or `conversationId` (group), CallScreen falls back to the
//  SIMULATED path, so a request missing them silently places no real call.
//

import Foundation

@MainActor
enum CallLauncher {

    /// `nil` when another call already owns the audio route — 1:1 and group calls are
    /// mutually exclusive, as two WebRTC audio managers cannot share one AVAudioSession.
    static func request(for conversation: VConversation, kind: CallKind) async -> CallRequest? {
        guard GroupCallService.canStart() else { return nil }
        let isGroup = conversation.type == .group
        let conversationId: String? = isGroup
            ? (GroupEngine.shared.hasGroup(conversationId: conversation.id) ? conversation.id : nil)
            : conversation.id

        // Real members for the group-call tiles (never DummyData).
        var members: [VMember] = []
        if isGroup, let cm = try? await ChatService.shared.members(conversationId: conversation.id) {
            let myId = TokenStore.shared.userId
            members = cm.map { m in
                VMember(id: m.userId, name: m.name ?? "VOIID user", phone: "", photoName: nil,
                        role: m.role, statusText: nil, isYou: m.userId == myId)
            }
        }

        return CallRequest(
            title: conversation.title,
            isGroup: isGroup,
            members: members,
            photoName: conversation.photoName,
            kind: kind,
            peerUserId: isGroup ? nil : conversation.peerUserId,
            conversationId: conversationId)
    }
}
