//
//  NotificationService.swift
//  VoiidNSE — Notification Service Extension
//
//  Decrypts an incoming message IN THE EXTENSION (separate process from the app)
//  and rewrites the notification to show the real sender + content, Signal/WhatsApp
//  style. The server only ever sends a content-free "New message" placeholder alert
//  with `mutable-content: 1` plus NON-SECRET routing ids (message_id / conversation_id);
//  this extension fetches the ciphertext, decrypts it locally, and replaces the
//  placeholder before it's shown. NO plaintext ever rides in the push (§4.14).
//
//  RATCHET SAFETY: decryption goes through `ChatEngine.notificationDecrypt`, which
//  uses the SAME cross-process-locked, decrypt-once path as the main app (shared
//  keychain session state + app-group message store + an flock single-writer lock).
//  A message decrypted here is marked seen in the shared store, so the app never
//  re-decrypts it (and vice-versa) — the Double Ratchet is advanced exactly once.
//  Group conversations take the MLS branch (GroupEngine) under the same lock, and are
//  strictly inbound-only there: the extension never fetches MLS control events, because
//  that endpoint marks them delivered on read and a watchdog kill would lose them.
//
//  On ANY failure or timeout we fall back to the generic placeholder — never crash,
//  never leak. The extension has a hard ~30s budget; we self-impose a shorter one.
//

import UserNotifications

final class NotificationService: UNNotificationServiceExtension {
    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var bestAttemptContent: UNMutableNotificationContent?
    /// Ensures `contentHandler` is invoked exactly once (didReceive completion vs.
    /// the OS time-expiry callback can otherwise both fire).
    private let deliverLock = NSLock()
    private var delivered = false

    override func didReceive(
        _ request: UNNotificationRequest,
        withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        self.contentHandler = contentHandler
        let best = (request.content.mutableCopy() as? UNMutableNotificationContent)
            ?? UNMutableNotificationContent()
        self.bestAttemptContent = best

        let userInfo = request.content.userInfo
        guard let messageId = userInfo["message_id"] as? String,
              let conversationId = userInfo["conversation_id"] as? String else {
            // No routing ids → nothing to decrypt; show the placeholder as-is.
            deliver(best)
            return
        }
        // Thread the notification by conversation even before we decrypt.
        best.threadIdentifier = conversationId

        // MUTED: DELIVER SILENTLY, DO NOT SUPPRESS.
        //
        // Muting means "stop interrupting me", not "hide this from me" — the message still
        // belongs in Notification Centre and the badge, it simply must not make a sound or
        // raise a banner. Dropping it entirely would lose a message the user has every right
        // to find later.
        //
        // Checked here rather than after decryption: a muted conversation should cost as
        // little work as possible, and the routing id is all this decision needs.
        if Self.isMuted(conversationId) {
            best.sound = nil
            best.interruptionLevel = .passive
        }

        Task { @MainActor in
            let preview = await ChatEngine.shared.notificationDecrypt(
                messageId: messageId, conversationId: conversationId)
            if let preview {
                best.title = preview.title
                best.body = preview.body
                best.threadIdentifier = preview.threadId
            }
            // On decrypt failure `preview` is nil and we deliver the placeholder.
            self.deliver(best)
        }
    }

    // Called just before the extension is terminated for running out of time. Deliver
    // whatever we have (the placeholder if decrypt hasn't finished) — never nothing.
    /// Is this conversation muted?
    ///
    /// Reads the SAME app-group defaults key the main app writes (`MuteStore`). The NSE is a
    /// separate target and cannot import the app's sources; adding a shared framework to
    /// carry nine lines of dictionary lookup would cost a build phase, a module and a
    /// signing identity for no gain.
    ///
    /// READ-ONLY, deliberately. Expiry is cleaned up by the app when IT reads the table —
    /// an extension that writes shared state while the app may also be running is a race
    /// for no benefit, and an expired entry simply reads as not-muted here.
    private static func isMuted(_ conversationId: String) -> Bool {
        guard let store = UserDefaults(suiteName: "group.com.voiid.app"),
              let table = store.dictionary(forKey: "voiid.muted.conversations") as? [String: Double],
              let until = table[conversationId]
        else { return false }
        // 0 means "always".
        return until == 0 || Date().timeIntervalSince1970 < until
    }

    override func serviceExtensionTimeWillExpire() {
        if let best = bestAttemptContent { deliver(best) }
    }

    /// Invoke the content handler at most once.
    private func deliver(_ content: UNNotificationContent) {
        deliverLock.lock()
        let shouldDeliver = !delivered
        delivered = true
        let handler = contentHandler
        deliverLock.unlock()
        guard shouldDeliver, let handler else { return }
        handler(content)
    }
}
