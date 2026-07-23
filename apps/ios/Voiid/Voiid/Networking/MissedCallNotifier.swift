//
//  MissedCallNotifier.swift
//  Voiid
//
//  The user-visible "Missed call from X" banner.
//
//  WHY THIS IS A SCHEDULED LOCAL NOTIFICATION AND NOT A POST-HOC ONE:
//  the case that matters most is the one where the app is NOT running when the call
//  goes unanswered. A VoIP push wakes us, we ring CallKit, and then iOS is free to
//  suspend or jetsam us — or the user force-quits from the app switcher while the
//  phone is ringing. In every one of those situations there is no process left to
//  notice that the call ended, so anything posted "when the call finishes" simply
//  never happens and the call is silently lost.
//
//  A pending `UNNotificationRequest` is owned by the system notification daemon, not
//  by us. Once handed over it fires whether or not this process still exists — after
//  suspension, after termination, across a reboot. So we hand one over at the exact
//  moment we START alerting, dated just past the point where the call can no longer
//  still be ringing, and CANCEL it on every path that resolves the call (answer,
//  decline, remote hangup). Cancellation is always reachable: each of those paths
//  necessarily resumes the app first.
//
//  When the app IS alive at teardown we do better than the backstop — `fireNow`
//  replaces the pending request with an immediate one, so the banner lands the second
//  the caller gives up instead of at the end of the ring window.
//
//  The identifier is derived from the call_id, so the VoIP push and the WebSocket
//  offer — which both ring the same call — replace each other instead of stacking
//  two banners.
//
//  RUNTIME CAVEAT: compile-verified only. The push-wake half needs a signed build on
//  real hardware (see VoIPPushManager).
//

import Foundation
import UIKit
import UserNotifications

@MainActor
enum MissedCallNotifier {

    /// Category the notification is filed under; its actions are registered in
    /// `AppDelegate.didFinishLaunchingWithOptions`.
    static let categoryId = "VOIID_MISSED_CALL"
    static let actionCallBack = "VOIID_MISSED_CALL_BACK"
    static let actionMessage = "VOIID_MISSED_CALL_MESSAGE"

    /// Marks our own notifications in `userInfo` so the tap handler can tell a missed
    /// call apart from a message push (both carry `conversation_id`).
    static let typeValue = "missed_call"

    private static func identifier(_ callId: String) -> String { "voiid.missedcall.\(callId)" }

    // MARK: - Schedule / fire

    /// Hand the system a missed-call banner dated `after` seconds from now.
    ///
    /// Call this the moment we start ALERTING (not when the offer parses) — that is
    /// the last instant we can be sure of getting any code run at all. `after` must be
    /// past the longest the call can still legitimately ring, or the banner appears
    /// while the phone is still ringing; callers derive it from the ring cap.
    static func schedule(callId: String, peerUserId: String, displayName: String?,
                         isVideo: Bool, conversationId: String?, after: TimeInterval) {
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(after, 1), repeats: false)
        submit(callId: callId, peerUserId: peerUserId, displayName: displayName,
               isVideo: isVideo, conversationId: conversationId, trigger: trigger)
    }

    /// Post the banner immediately, replacing any pending backstop for the same call.
    /// Used from the teardown path when the app is still alive and we therefore know,
    /// right now, that the call was missed.
    static func fireNow(callId: String, peerUserId: String, displayName: String?,
                        isVideo: Bool, conversationId: String?) {
        // Same identifier ⇒ this REPLACES the pending timed request rather than
        // racing it, so there is no window where both could be delivered.
        submit(callId: callId, peerUserId: peerUserId, displayName: displayName,
               isVideo: isVideo, conversationId: conversationId, trigger: nil)
    }

    private static func submit(callId: String, peerUserId: String, displayName: String?,
                               isVideo: Bool, conversationId: String?,
                               trigger: UNNotificationTrigger?) {
        let content = UNMutableNotificationContent()
        // NEVER the raw user id — the directory is the one place a human-readable
        // name is produced, and it works cold (SQLite) on a push-launched process.
        content.title = UserDirectory.shared.displayName(peerUserId, fallback: displayName)
        content.body = isVideo ? "Missed video call" : "Missed voice call"
        // Match the message-push conventions (see VoiidNSE/NotificationService): the
        // server sends `sound: 'default'`, and threading is by conversation so a
        // missed call groups with that person's messages instead of forming its own
        // stack. With no conversation id we still group per-peer rather than per-call.
        content.sound = .default
        content.threadIdentifier = conversationId ?? "voiid.call.\(peerUserId)"
        content.categoryIdentifier = categoryId
        var info: [String: Any] = [
            "type": typeValue,
            "call_id": callId,
            "caller_id": peerUserId,
            "call_kind": isVideo ? "video" : "voice",
        ]
        // The tap handler in AppDelegate deep-links on `conversation_id`; omitting the
        // key (rather than storing NSNull) keeps that check honest.
        if let conversationId { info["conversation_id"] = conversationId }
        content.userInfo = info

        let request = UNNotificationRequest(identifier: identifier(callId),
                                            content: content, trigger: trigger)
        // Submitted BEFORE (and independently of) the authorization check below: on a
        // push wake we may have only milliseconds before suspension, and an `add` for
        // an unauthorized app fails harmlessly anyway. Checking first would risk
        // never getting to the add at all.
        UNUserNotificationCenter.current().add(request) { error in
            if let error { NSLog("[VOIID] missed-call notification add failed: \(error.localizedDescription)") }
        }
        ensureAuthorization()
    }

    // MARK: - Cancel

    /// Drop the pending backstop for a call that resolved (answered/declined/ended).
    /// Also clears an ALREADY DELIVERED banner: a call answered late — after the ring
    /// window closed but before the caller gave up — would otherwise leave a "missed
    /// call" sitting in Notification Centre for a conversation that happened.
    static func cancel(callId: String) {
        let id = identifier(callId)
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [id])
        center.removeDeliveredNotifications(withIdentifiers: [id])
    }

    /// Drop every scheduled and delivered missed-call banner belonging to this account.
    ///
    /// These live in the system notification daemon and by design OUTLIVE the process — so
    /// on log-out, a pending backstop scheduled for a call that was ringing as the user
    /// signed out would still fire minutes later, naming the previous account's caller on a
    /// device that has since signed into a different account. Only this feature's identifiers
    /// (the `voiid.missedcall.` prefix) are touched, so nothing else's notifications are hit.
    static func cancelAll() {
        let center = UNUserNotificationCenter.current()
        let prefix = "voiid.missedcall."
        center.getPendingNotificationRequests { reqs in
            let ids = reqs.map(\.identifier).filter { $0.hasPrefix(prefix) }
            if !ids.isEmpty { center.removePendingNotificationRequests(withIdentifiers: ids) }
        }
        center.getDeliveredNotifications { notes in
            let ids = notes.map(\.request.identifier).filter { $0.hasPrefix(prefix) }
            if !ids.isEmpty { center.removeDeliveredNotifications(withIdentifiers: ids) }
        }
    }

    // MARK: - Authorization

    /// Notification permission is asked for exactly once, during onboarding
    /// (PermissionsScreen), and never again — so a user who reached the calling code
    /// without it would get this feature as a silent no-op forever. Re-ask, but ONLY
    /// when the status is still undetermined and the app is frontmost: prompting from
    /// a background push wake burns the one-shot system dialog on a moment the user
    /// can't see it.
    static func ensureAuthorization() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .notDetermined:
                Task { @MainActor in
                    guard UIApplication.shared.applicationState == .active else { return }
                    _ = try? await UNUserNotificationCenter.current()
                        .requestAuthorization(options: [.alert, .sound, .badge])
                }
            case .denied:
                NSLog("[VOIID] notifications denied — missed-call alerts will not appear")
            default:
                break
            }
        }
    }
}
