//
//  CallIntentRouter.swift
//  Voiid
//
//  The inbound half of contact/dialer linking.
//
//  `CallManager` donates an INStartCallIntent for every call, which is what puts a
//  Voiid entry in the phone app's Recents and a "Voiid" row inside the contact card.
//  When the user taps one of those, iOS relaunches or resumes US with that intent —
//  and this is what turns it back into a real call.
//
//  Without this file the donations still appear, but tapping them does nothing, which
//  is worse than not offering the affordance at all.
//

import Foundation
import Intents

@MainActor
enum CallIntentRouter {

    /// Resume a call from a system-provided activity (Recents, contact card, Siri).
    ///
    /// The person is identified by PHONE NUMBER, not by our user id — the system has
    /// no idea what a Voiid user id is. We map the number back to a user through the
    /// local directory, which is exactly the reverse of the lookup that produced the
    /// handle in the first place.
    static func startCall(from activity: NSUserActivity, forceVideo: Bool = false) {
        guard let interaction = activity.interaction else { return }

        var handles: [String] = []
        var wantsVideo = forceVideo

        if let intent = interaction.intent as? INStartCallIntent {
            handles = intent.contacts?.compactMap { $0.personHandle?.value } ?? []
            if intent.callCapability == .videoCall { wantsVideo = true }
        } else if let intent = interaction.intent as? INStartAudioCallIntent {
            handles = intent.contacts?.compactMap { $0.personHandle?.value } ?? []
        } else if let intent = interaction.intent as? INStartVideoCallIntent {
            handles = intent.contacts?.compactMap { $0.personHandle?.value } ?? []
            wantsVideo = true
        }

        guard let userId = handles.lazy.compactMap({ userId(forPhone: $0) }).first else {
            NSLog("[VOIID] call intent for an unknown number — ignoring")
            return
        }

        let name = UserDirectory.shared.displayName(userId)
        // The system knows nothing about conversations, so resolve one locally —
        // `POST /calls/ring` needs it or the callee never gets a wake push.
        CallService.shared.startCall(peerUserId: userId, title: name, isVideo: wantsVideo,
                                     conversationId: LocalStore.conversationId(forPeer: userId))
    }

    /// Reverse lookup: E.164 -> our user id.
    ///
    /// Compares NORMALIZED numbers on both sides. The system hands back whatever string
    /// it stored, which may not be formatted the way we wrote it, so a raw string
    /// comparison would silently fail to find a user we plainly know.
    private static func userId(forPhone raw: String) -> String? {
        guard let target = CallManager.normalizedE164(raw) else { return nil }
        return UserDirectory.shared.byId.first { _, user in
            CallManager.normalizedE164(user.phoneE164) == target
        }?.key
    }
}
