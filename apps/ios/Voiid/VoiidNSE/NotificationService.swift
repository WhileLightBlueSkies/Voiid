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
