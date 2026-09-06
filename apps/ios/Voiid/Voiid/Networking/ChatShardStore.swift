//
//  ChatShardStore.swift
//  Voiid
//
//  The serial owner of message-shard IO (I01).
//
//  ─────────────────────────────────────────────────────────────────────────────
//  WHY THIS EXISTS — MEASURED, NOT ASSUMED
//  ─────────────────────────────────────────────────────────────────────────────
//
//  `ChatEngine` is `@MainActor`, and `persist()` JSON-encoded the WHOLE conversation
//  and wrote it, synchronously, on that actor — once per sent message, per received
//  message, per receipt, per delete. Encoding a conversation is O(history), so the
//  cost of sending one message grew with everything ever said in the thread.
//
//  Measured with the real record shape (apps/ios/checks/ChatHistoryCostCheck.swift),
//  on a development Mac — a phone is slower:
//
//      1,000 messages    5.1 ms    0.3 frames
//     10,000 messages   33.7 ms    2.0 frames      3.4 MB
//     50,000 messages  147.3 ms    8.8 frames     17.2 MB
//
//  147ms on the main actor to send one message into a long thread — roughly nine
//  dropped frames, every time, while the keyboard is up. Cold launch decoded every
//  shard the same way: 130ms for one 50k conversation, before anything rendered.
//
//  WHAT THIS CHANGES, AND WHAT IT DELIBERATELY DOES NOT. Encoding and file IO move
//  here, off the main actor. The in-memory `store` stays where it is and remains the
//  UI's source of truth, so this is not the GRDB migration I01 ultimately asks for —
//  see the completion record for what is left.
//
//  SERIAL BY CONSTRUCTION. It is an actor, so two writes to one conversation cannot
//  interleave, and a write cannot race the read that reloads a shard after the NSE
//  has touched it. The previous code got that property from `@MainActor` for free;
//  moving IO off the main actor would have lost it if this were a plain queue.
//
//  THE DURABILITY CONTRACT IS UNCHANGED. M02/I03 acknowledge to the server only what
//  reached this disk, so `write` still reports per-conversation success and the
//  caller still keeps anything that failed marked dirty. Nothing here may turn a
//  failed write into a silent success.
//

import Foundation

actor ChatShardStore {
    static let shared = ChatShardStore()

    /// `<app-group>/messages/` — one JSON shard per conversation.
    private let dir: URL = {
        let base = AppGroup.containerURL
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let d = base.appendingPathComponent("messages", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    /// A conversation id is a UUID (filesystem-safe), so it is a fine file name directly.
    private func url(_ convId: String) -> URL { dir.appendingPathComponent("\(convId).json") }

    // MARK: - Writing

    /// Encode and atomically write one conversation's shard.
    ///
    /// Returns true ONLY if the bytes reached the disk — the caller acknowledges messages
    /// to the server on the strength of this, so an optimistic true here would lose
    /// messages permanently.
    func write(_ messages: [DecryptedMessage], conversationId: String) -> Bool {
        let data: Data
        do {
            data = try JSONEncoder().encode(messages)
        } catch {
            NSLog("[VOIID] ❌ shard ENCODE FAILED conv=\(conversationId): \(error)")
            return false
        }
        do {
            // `.atomic` writes to a temporary and replaces — there is no in-place fallback,
            // so a failure leaves the previous shard exactly as it was.
            try data.write(to: url(conversationId),
                           options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            return true
        } catch {
            NSLog("[VOIID] ❌ shard WRITE FAILED conv=\(conversationId): \(error)")
            return false
        }
    }

    /// Write several shards, reporting exactly which ones committed.
    ///
    /// One hop off the main actor for the whole dirty set rather than one per shard: the
    /// caller is awaiting this before it may acknowledge anything.
    func write(_ batch: [String: [DecryptedMessage]]) -> Set<String> {
        var committed: Set<String> = []
        for (conv, msgs) in batch where write(msgs, conversationId: conv) {
            committed.insert(conv)
        }
        return committed
    }

    // MARK: - Reading

    /// Decode one shard, or nil if it is absent or unreadable.
    ///
    /// `nil` for "unreadable" is deliberately indistinguishable from "absent" here; the
    /// caller decides to quarantine, because only it knows whether it was expecting data.
    func read(_ convId: String) -> [DecryptedMessage]? {
        let u = url(convId)
        guard FileManager.default.fileExists(atPath: u.path),
              let data = try? Data(contentsOf: u, options: .mappedIfSafe)
        else { return nil }
        return try? JSONDecoder().decode([DecryptedMessage].self, from: data)
    }

    /// Every shard on disk, decoded off the main actor.
    ///
    /// Returns the conversations that decoded and, separately, the URLs that did NOT — the
    /// caller quarantines those. A shard that fails to decode must never be treated as an
    /// empty conversation: the next persist would write that emptiness over the file.
    func readAll() -> (loaded: [String: [DecryptedMessage]], unreadable: [URL]) {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == "json" } ?? []
        var loaded: [String: [DecryptedMessage]] = [:]
        var unreadable: [URL] = []
        for u in files {
            let conv = u.deletingPathExtension().lastPathComponent
            if let data = try? Data(contentsOf: u, options: .mappedIfSafe),
               let msgs = try? JSONDecoder().decode([DecryptedMessage].self, from: data) {
                loaded[conv] = msgs
            } else {
                unreadable.append(u)
            }
        }
        return (loaded, unreadable)
    }

    /// Whether any shard exists — used to decide whether the one-time blob migration runs.
    func hasAnyShard() -> Bool {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == "json" } ?? []
        return !files.isEmpty
    }
}
