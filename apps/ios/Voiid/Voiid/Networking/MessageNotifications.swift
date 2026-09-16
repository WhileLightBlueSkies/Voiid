//
//  MessageNotifications.swift
//  Voiid
//
//  Clearing delivered MESSAGE banners — the iOS half of a behaviour Android does in
//  ChatEngine.clearMessageNotifications, kept deliberately in parity with it.
//
//  WHY
//  ===
//  A message banner tells you about something you have not seen. Once the app is open in
//  front of you, every one of them is answering a question you are now answering for
//  yourself. Nothing used to remove them, so the shade filled with banners for chats that
//  had already been read and the only way to clear them was to swipe each one by hand.
//
//  WHAT IS NOT CLEARED
//  ===================
//  Missed-call banners. A missed call is a RECORD of something that happened, not an alert
//  about unread text, and its banner is how the user gets back to it — removing it on app
//  open would delete that history. They are identified by the "voiid.missedcall." prefix on
//  their request identifier (MissedCallNotifier), NOT by thread: a missed call sets the same
//  `threadIdentifier` as the conversation's messages, so filtering by thread alone would
//  take them with it.
//

import Foundation
import UserNotifications

enum MessageNotifications {

    /// Delivered missed-call banners carry this prefix; see MissedCallNotifier.identifier.
    private static let missedCallPrefix = "voiid.missedcall."

    /// Remove delivered message banners: every one, or just a single conversation's.
    ///
    /// - Parameter conversationId: nil clears all message banners (app came to the
    ///   foreground); a value clears only that thread's (the user opened it).
    static func clear(conversationId: String? = nil) {
        let center = UNUserNotificationCenter.current()
        center.getDeliveredNotifications { delivered in
            let ids = delivered.compactMap { note -> String? in
                let request = note.request
                // Calls are records, not alerts about unread text. Checked FIRST, and by
                // identifier rather than thread, because a missed call shares the
                // conversation's threadIdentifier.
                guard !request.identifier.hasPrefix(missedCallPrefix) else { return nil }
                let thread = request.content.threadIdentifier
                guard !thread.isEmpty else { return nil }
                if let conversationId, thread != conversationId { return nil }
                return request.identifier
            }
            if !ids.isEmpty {
                center.removeDeliveredNotifications(withIdentifiers: ids)
            }
            // OUTSIDE the isEmpty guard, and only on the whole-app clear. A badge left over
            // from banners the user already swiped away would otherwise never reset — the
            // case with nothing to remove is exactly the one where the badge is stale.
            if conversationId == nil {
                Task { @MainActor in try? await center.setBadgeCount(0) }
            }
        }
    }
}
