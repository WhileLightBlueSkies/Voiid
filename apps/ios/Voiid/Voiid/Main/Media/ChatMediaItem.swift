//
//  ChatMediaItem.swift
//  Voiid
//
//  One photo or video in a conversation, as the media viewer consumes it.
//
//  Read from the `chat_media` index (VoiidDatabase v4), never by scanning `messages`:
//  finding "every photo in this chat" that way means decoding `media_json` on every row of
//  a long thread to discover most of them are text.
//

import Foundation
import GRDB

struct ChatMediaItem: Identifiable, Equatable {
    /// The message this media belongs to. THE identity everywhere — selection binds to it
    /// rather than to an array index, so a deletion cannot silently shift what is on screen.
    let id: String
    let chatId: String
    let type: Kind
    /// The encrypted reference. Bytes are fetched and decrypted through the same path the
    /// chat bubbles use, so a photo already seen opens from cache with no spinner.
    let ref: MediaRef
    let sentAt: Date
    let senderId: String
    let senderName: String?
    let isOutgoing: Bool
    let caption: String?
    let durationMs: Int?

    enum Kind: String { case image, video }

    /// "You" for your own media — the viewer's top bar names the sender, and a name there
    /// should read the way the user thinks of it.
    var displayName: String {
        isOutgoing ? "You" : (senderName?.isEmpty == false ? senderName! : "Unknown")
    }

    var durationLabel: String? {
        guard type == .video, let ms = durationMs, ms > 0 else { return nil }
        let s = ms / 1000
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

// MARK: - Store

enum ChatMediaStore {

    /// Every image and video in one chat, oldest first.
    ///
    /// ONE MERGED CHRONOLOGICAL STREAM. Sent and received are interleaved by `sent_at` and
    /// never grouped by sender — the viewer is a record of what passed through the
    /// conversation, and splitting it by who sent what would make "the next photo" mean
    /// something different from what the thread shows.
    /// ── WHY THIS READS THE LIVE STORE, NOT THE `chat_media` TABLE ───────────────
    ///
    /// The index exists and is maintained (VoiidDatabase v4, LocalStore.indexMedia), but it
    /// is fed by `LocalStore.saveMessages` — and NOTHING CALLS THAT. Messages are persisted
    /// by `ChatEngine.persist()` into `voiid_messages.json`; the GRDB `messages` table is a
    /// mirror that no live code path writes. So the index was always empty and the viewer
    /// opened blank.
    ///
    /// Reading from `ChatStore` is therefore not a shortcut around the index — it is
    /// reading the only place the data actually is. The table and its write path stay: the
    /// moment message persistence moves to GRDB this becomes a one-line switch, and until
    /// then a table that is empty is harmless while a viewer that is blank is not.
    ///
    /// The transcript is already in memory (ChatStore holds it for the open conversation),
    /// so this is a filter over an array rather than a query.
    @MainActor
    static func items(chatId: String, from chat: ChatStore) -> [ChatMediaItem] {
        chat.messages(for: chatId).compactMap { m -> ChatMediaItem? in
            guard let ref = m.mediaRef else { return nil }
            let kind: ChatMediaItem.Kind
            if ref.mime.hasPrefix("image/") { kind = .image }
            else if ref.mime.hasPrefix("video/") { kind = .video }
            // Voice notes and documents share the media pipeline but belong to a different
            // screen — admitting them would put an unplayable item in the pager.
            else { return nil }

            let caption = m.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return ChatMediaItem(
                id: m.id,
                chatId: chatId,
                type: kind,
                ref: ref,
                sentAt: m.createdAt,
                senderId: m.senderId,
                senderName: m.senderName.isEmpty ? nil : m.senderName,
                isOutgoing: m.isMine,
                caption: caption.isEmpty ? nil : caption,
                durationMs: nil
            )
        }
    }

    /// Drop a row when its message is deleted. The bytes are the media cache's business.
    static func remove(messageId: String) {
        VoiidDatabase.shared.write { db in
            try db.execute(sql: "DELETE FROM chat_media WHERE message_id = ?",
                           arguments: [messageId])
        }
    }

    private static func decode(_ row: Row) -> ChatMediaItem? {
        guard let id: String = row["message_id"],
              let chatId: String = row["chat_id"],
              let rawType: String = row["type"],
              let kind = ChatMediaItem.Kind(rawValue: rawType),
              let json: String = row["media_json"],
              let data = json.data(using: .utf8),
              let ref = try? JSONDecoder().decode(MediaRef.self, from: data)
        else { return nil }

        let sent: Int64 = row["sent_at"] ?? 0
        return ChatMediaItem(
            id: id,
            chatId: chatId,
            type: kind,
            ref: ref,
            sentAt: Date(timeIntervalSince1970: TimeInterval(sent)),
            senderId: row["sender_id"] ?? "",
            senderName: row["sender_name"],
            isOutgoing: row["is_outgoing"] ?? false,
            caption: row["caption"],
            durationMs: row["duration_ms"]
        )
    }
}
