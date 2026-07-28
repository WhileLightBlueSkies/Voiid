//
//  UserDirectory.swift
//  Voiid
//
//  The ONE place a human-readable name for a user id is produced.
//
//  WHY THIS EXISTS: names were resolved ad hoc at ~15 call sites, each with its own
//  fallback, and the call paths had no fallback at all — so an incoming call showed a
//  raw user UUID, and chat screens showed whatever name the peer typed at signup even
//  when you had them saved as something else in your address book. The address book
//  WAS read correctly (ContactsService), but only into a 120s in-memory cache that
//  died on relaunch and was never consulted by the call or chat UI.
//
//  PRECEDENCE (applies everywhere — calls, chat list, chat header, profile):
//     1. saved_name   — this device's address book. If you saved them as "Mum",
//                       every screen says "Mum", whatever they call themselves.
//     2. full_name    — the peer's own profile name.
//     3. phone_e164   — a number is still useful.
//     4. username     — Clips handle, last resort.
//     5. "Unknown"    — NEVER a raw user id. A UUID on screen is always a bug.
//
//  PRIVACY NOTE: this is also why the ring push carries no caller name. Sending one
//  would tell Apple and Google who is calling whom; instead the callee resolves the
//  name locally from `caller_id` through this directory, which needs no network and
//  works when the app was just launched cold by a push.
//

import Combine
import Foundation
import GRDB

/// A person as the app knows them locally, merged from every source.
struct DirectoryUser: Codable, FetchableRecord, PersistableRecord, Identifiable {
    static let databaseTableName = "users"

    var userId: String
    var savedName: String?
    var fullName: String?
    var username: String?
    var phoneE164: String?
    var photoURL: String?
    var bio: String?
    var updatedAt: Int64

    var id: String { userId }

    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case savedName = "saved_name"
        case fullName = "full_name"
        case username
        case phoneE164 = "phone_e164"
        case photoURL = "photo_url"
        case bio
        case updatedAt = "updated_at"
    }

    /// The name to show. See the precedence list at the top of this file.
    var displayName: String {
        for candidate in [savedName, fullName, phoneE164, username] {
            if let c = candidate?.trimmingCharacters(in: .whitespacesAndNewlines), !c.isEmpty {
                return c
            }
        }
        return "Unknown"
    }
}

@MainActor
final class UserDirectory: ObservableObject {
    static let shared = UserDirectory()

    private let db = VoiidDatabase.shared

    /// In-memory mirror so SwiftUI bodies can resolve a name synchronously without
    /// touching SQLite on every row render. Rebuilt from the database on launch, and
    /// kept in step by every upsert below — the database stays authoritative.
    @Published private(set) var byId: [String: DirectoryUser] = [:]

    private init() { reload() }

    // MARK: - Reads

    /// Synchronous, non-throwing, safe in a SwiftUI `body`. Returns nil only for a
    /// user we have never seen — callers decide what to show, but must never fall
    /// back to the raw id.
    func user(_ userId: String) -> DirectoryUser? { byId[userId] }

    /// The name for a user id, with the full precedence chain applied.
    ///
    /// `fallback` covers the genuinely-unknown case (a call from someone not in the
    /// directory yet). Pass a phone number or a group title if you have one; pass
    /// nothing and the user sees "Unknown", which is still better than a UUID.
    func displayName(_ userId: String, fallback: String? = nil) -> String {
        if let u = byId[userId] { return u.displayName }
        if let f = fallback?.trimmingCharacters(in: .whitespacesAndNewlines),
           !f.isEmpty, f != userId {
            return f
        }
        return "Unknown"
    }

    func photoURL(_ userId: String) -> String? { byId[userId]?.photoURL }

    /// Everyone a story can actually REACH: the address-book directory UNION every 1:1
    /// conversation peer.
    ///
    /// The directory alone is the wrong set. It is populated by address-book matching
    /// (upsertFromAddressBook) and a few profile fetches, so someone you chat with every day
    /// but never SAVED as a contact is absent from it — and the story composer, which built
    /// its audience from `byId` alone, could not even offer them. Their story never reached
    /// that person, and the reason was invisible.
    ///
    /// Android has always used conversation peers (StoriesStore.candidateAudience), so this
    /// also removes a real cross-platform asymmetry in who can receive a story. The union is
    /// the honest answer: a story ride needs an established 1:1 session, which either source
    /// implies. Ids with no directory row still resolve a name via `displayName(_:)`.
    func storyReachableUserIds() -> Set<String> {
        let me = TokenStore.shared.userId
        var ids = Set(byId.keys)
        for c in LocalStore.conversations() where c.type == .direct {
            if let peer = c.peerUserId, !peer.isEmpty { ids.insert(peer) }
        }
        if let me { ids.remove(me) }
        return ids
    }

    /// Forget everyone. Called on sign-out: the directory holds address-book names, phone
    /// numbers and photos for the previous account's contacts, and the process does not
    /// restart, so without this the next user's call screens and chat headers would resolve
    /// names from the previous user's address book.
    func wipe() {
        byId.removeAll()
    }

    func reload() {
        let rows = db.read { db in try DirectoryUser.fetchAll(db) } ?? []
        byId = Dictionary(uniqueKeysWithValues: rows.map { ($0.userId, $0) })
    }

    // MARK: - Writes
    //
    // Each source updates ONLY the columns it is authoritative for. This is the whole
    // point of storing the name components separately: a profile refresh from the
    // server must never clobber the address-book name, and a contacts re-sync must
    // never clobber the peer's own profile fields.

    /// From the device address book (ContactsService discovery). Authoritative for
    /// `saved_name` and the phone number, and for nothing else.
    ///
    /// The number is normalized to strict E.164 on the way in. CallKit matches a call
    /// to an address-book contact by the handle STRING, so storing "+91 91234 56789"
    /// here and "+919123456789" there would give one person two separate entries in
    /// the phone app's Recents. Canonical on write, canonical everywhere.
    func upsertFromAddressBook(userId: String, savedName: String?, phoneE164: String?) {
        let phoneE164 = CallManager.normalizedE164(phoneE164) ?? phoneE164
        db.write { db in
            try db.execute(sql: """
                INSERT INTO users (user_id, saved_name, phone_e164, updated_at)
                VALUES (?, ?, ?, ?)
                ON CONFLICT(user_id) DO UPDATE SET
                    saved_name = COALESCE(excluded.saved_name, users.saved_name),
                    phone_e164 = COALESCE(excluded.phone_e164, users.phone_e164),
                    updated_at = excluded.updated_at
                """, arguments: [userId, savedName, phoneE164, Int64(Date().timeIntervalSince1970)])
        }
        reload()
    }

    /// From a server profile payload. Authoritative for the peer's self-set fields.
    func upsertFromServer(userId: String, fullName: String?, username: String?,
                          photoURL: String?, bio: String? = nil, phoneE164: String? = nil) {
        db.write { db in
            try db.execute(sql: """
                INSERT INTO users (user_id, full_name, username, photo_url, bio, phone_e164, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(user_id) DO UPDATE SET
                    full_name  = COALESCE(excluded.full_name,  users.full_name),
                    username   = COALESCE(excluded.username,   users.username),
                    photo_url  = COALESCE(excluded.photo_url,  users.photo_url),
                    bio        = COALESCE(excluded.bio,        users.bio),
                    phone_e164 = COALESCE(excluded.phone_e164, users.phone_e164),
                    updated_at = excluded.updated_at
                """, arguments: [userId, fullName, username, photoURL, bio, phoneE164,
                                 Int64(Date().timeIntervalSince1970)])
        }
        reload()
    }

    /// Bulk variant of `upsertFromServer`. Use this for anything that resolves more
    /// than one peer — a conversation sync calls the single-row version once per
    /// direct chat, and each of those reloads the WHOLE table and publishes to every
    /// observing view. One transaction, one reload.
    func upsertManyFromServer(_ entries: [(userId: String, fullName: String?,
                                          username: String?, photoURL: String?)]) {
        guard !entries.isEmpty else { return }
        let now = Int64(Date().timeIntervalSince1970)
        db.write { db in
            for e in entries {
                try db.execute(sql: """
                    INSERT INTO users (user_id, full_name, username, photo_url, updated_at)
                    VALUES (?, ?, ?, ?, ?)
                    ON CONFLICT(user_id) DO UPDATE SET
                        full_name  = COALESCE(excluded.full_name,  users.full_name),
                        username   = COALESCE(excluded.username,   users.username),
                        photo_url  = COALESCE(excluded.photo_url,  users.photo_url),
                        updated_at = excluded.updated_at
                    """, arguments: [e.userId, e.fullName, e.username, e.photoURL, now])
            }
        }
        reload()
    }

    /// Bulk variant for a contacts sync — one transaction, one reload, so a 500-contact
    /// refresh doesn't publish 500 times and thrash every observing view.
    func upsertManyFromAddressBook(_ entries: [(userId: String, savedName: String?, phoneE164: String?)]) {
        guard !entries.isEmpty else { return }
        let now = Int64(Date().timeIntervalSince1970)
        // Canonical E.164 on write — see upsertFromAddressBook for why this matters
        // to the phone app's call log.
        let entries = entries.map {
            (userId: $0.userId,
             savedName: $0.savedName,
             phoneE164: CallManager.normalizedE164($0.phoneE164) ?? $0.phoneE164)
        }
        db.write { db in
            for e in entries {
                try db.execute(sql: """
                    INSERT INTO users (user_id, saved_name, phone_e164, updated_at)
                    VALUES (?, ?, ?, ?)
                    ON CONFLICT(user_id) DO UPDATE SET
                        saved_name = COALESCE(excluded.saved_name, users.saved_name),
                        phone_e164 = COALESCE(excluded.phone_e164, users.phone_e164),
                        updated_at = excluded.updated_at
                    """, arguments: [e.userId, e.savedName, e.phoneE164, now])
            }
        }
        reload()
    }
}
